#!/usr/bin/env node
// collect-snapshot.mjs — 1층 통합 뷰: 흩어진 신호 → 단일 '주인님 상태' 스냅샷
//
// 소스: 카카오 캘린더(gog) · wiki/*/​_facts.md · portfolio.json · hot-events.json
// 모든 날짜 메타(요일·D-day)는 fact-guard로 코드 실측해 부착한다 (LLM 추정 금지).

import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { weekdayKST, daysUntilKST, freshness, todayKST, addDays } from './fact-guard.mjs';
import { loadOpenInsights } from './insight-store.mjs';

const HOME = process.env.HOME;
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');
const OUT_DIR = join(BOT_HOME, 'state/owner-state');
const KAKAO_CAL = '6ucgla9qclkiielcajug4j148446klr3@import.calendar.google.com';
const GOOGLE_ACCOUNT = process.env.GOOGLE_ACCOUNT || ''; // 개인 이메일 하드코딩 제거 — runtime/.env의 GOOGLE_ACCOUNT 사용

mkdirSync(OUT_DIR, { recursive: true });

const today = todayKST();
const stale_sources = [];

// ── 1. 카카오 캘린더 (gog --json), 향후 21일 ──
let calendar = [];
try {
  const to = addDays(today, 21);
  const raw = execSync(
    `gog calendar events "${KAKAO_CAL}" --from "${today}" --to "${to}" --account "${GOOGLE_ACCOUNT}" --json`,
    { encoding: 'utf-8', timeout: 25000 }
  );
  const j = JSON.parse(raw);
  calendar = (j.events || []).map(e => {
    const start = e.start?.date || (e.start?.dateTime || '').slice(0, 10);
    return {
      date: start,
      weekday: weekdayKST(start),   // 코드 실측 — LLM 추정 금지
      dday: daysUntilKST(start),
      summary: e.summary || '(제목 없음)',
      allday: !!e.start?.date,
    };
  }).filter(e => e.date).sort((a, b) => a.date.localeCompare(b.date));
} catch (err) {
  stale_sources.push({ source: 'kakao-calendar', error: String(err.message).slice(0, 100) });
}

// ── 2. _facts.md 도메인별 최근 항목 (14일 신선도) ──
const facts = {};
for (const domain of ['career', 'health', 'family', 'trading', 'ops']) {
  const fp = join(BOT_HOME, `wiki/${domain}/_facts.md`);
  const fresh = freshness(fp, 14);
  try {
    const lines = readFileSync(fp, 'utf-8').split('\n').filter(l => l.trim().startsWith('- ['));
    facts[domain] = { recent: lines.slice(-6).map(l => l.slice(0, 300)), freshness: fresh };
    if (fresh.stale) stale_sources.push({ source: `facts-${domain}`, ageDays: fresh.ageDays });
  } catch {
    facts[domain] = { recent: [], freshness: fresh };
  }
}

// ── 3. 투자/포트폴리오 — 의도적 제외 (A안, 2026-06-24) ──
// 단타·주가·환율로 수시 변동하는데 4월 수동 SSoT가 마지막이라, 이 데이터로 조언하면 틀린다.
// 못 따라가는 영역은 억지로 조언하지 않는다. 투자는 주인님이 /portfolio로 실시간 직접 판단.

// ── 4. hot-events.json 미만료 최근 15건 ──
let hot_events = [];
try {
  const j = JSON.parse(readFileSync(join(BOT_HOME, 'context/owner/hot-events.json'), 'utf-8'));
  hot_events = (j.events || [])
    // [2026-07-08] cli-session(백그라운드 크론) 이벤트 제외 — writer 차단의 이중 방어(재오염 시 봇 도달 차단)
    .filter(e => (!e.expires || e.expires >= today) && e.channel !== 'cli-session')
    .slice(-15)
    .map(e => ({ date: e.date, channel: e.channel, summary: String(e.summary || '').slice(0, 200) }));
} catch {}

// ── 5. 오늘 주인님 발화·결정 (CLI 세션 맥락) ──
// 캘린더·기록만으론 "주인님이 오늘 뭘 결정/고민했나"를 못 본다 → 모순을 못 찾는다.
// inbox의 오늘 세션에서 [사용자] 발화만 압축 추출해 살아있는 맥락을 채운다.
let recent_decisions = [];
try {
  const inboxDir = join(BOT_HOME, 'inbox');
  const files = readdirSync(inboxDir).filter(f => f.startsWith(`claude-cli-${today}`)).sort();
  const utterances = [];
  for (const f of files) {
    const text = readFileSync(join(inboxDir, f), 'utf-8');
    for (const b of text.split(/^## \*\*\[/m)) {
      if (!b.startsWith('사용자]')) continue;
      const body = b.split('\n').slice(1).join(' ').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
      // cron이 LLM에 보낸 프롬프트가 [사용자]로 섞임 → 메타 프롬프트 제외, 진짜 발화만
      const META = /다음은 AI|세션 요약|상태 스냅샷|context-bus|보고서입니다|이 JSON|분석 결과|대화 로그|시스템 프롬프트|아래는|평가하라|판정하라/;
      if (body.length > 12 && body.length < 280
        && !body.startsWith('Caveat') && !body.startsWith('/') && !META.test(body)
        && !/^(네|응|확인중|고고|그래|좋아|오케이|ok)\b/i.test(body))
        utterances.push(body.slice(0, 180));
    }
  }
  recent_decisions = utterances.slice(-25);
} catch { /* inbox 없거나 첫 실행 */ }

// ── 6. 열린 통찰 (통찰 도메인 — 누적·진화·중복방지) ──
// 이미 주인님께 보낸 미해결 통찰. 다음 통찰이 백지가 아니라 이 위에서 자란다.
let open_insights = [];
try { open_insights = loadOpenInsights(10); } catch { /* 첫 실행 — 스토어 없음 */ }

// ── 합성 ──
const snapshot = {
  generated_at: new Date().toISOString(),
  today,
  today_weekday: weekdayKST(today),
  calendar,
  facts,
  hot_events,
  recent_decisions,
  open_insights,
  stale_sources,
  advisory_excluded: ['투자/포트폴리오/주식 — 실시간 추적 불가(단타·주가·환율 변동). 조언 대상 아님. 주인님이 /portfolio로 직접 판단'],
};
writeFileSync(join(OUT_DIR, 'snapshot-latest.json'), JSON.stringify(snapshot, null, 2));
console.log(`[collect-snapshot] ✅ ${today}(${snapshot.today_weekday}) — 일정 ${calendar.length} · facts ${Object.keys(facts).length}도메인 · hot ${hot_events.length} · stale ${stale_sources.length}`);
