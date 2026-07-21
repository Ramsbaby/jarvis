#!/usr/bin/env node
/**
 * preply-complaint-scan.mjs — 보람님 불만을 자동 감지·누적·"미커버 반복 불만" 리포트 (렌더 아이 3층: 자동학습 루프).
 *
 * 왜 (2026-07-06):
 *  - 2026-07-06 사고: 보람님이 정답 노출·A4·영어뜻을 6일간 14회 반복 지적했는데, 자비스가 매번
 *    지적당한 뒤에야 국소 수정 → 근본 검사 추가가 늦었다. 이 "6일치 수동 대화 분석"을 자동화한다.
 *  - 원리: 보람님이 같은 유형 불만을 반복하면 시스템이 감지·집계해, "이건 아직 verify/렌더/비전이
 *    안 잡는 반복 불만"이라고 자비스·주인님께 알린다 → 검사에 흡수 → 재발 0으로 수렴.
 *  - jarvis-autolearn(mistake-promoter)의 오답 클러스터 승격 패턴을 보람님 피드백에 적용한 것.
 *
 * 사용법: node preply-complaint-scan.mjs [--days N] [--notify]
 *   --days N   최근 N일 스캔 (기본 7)
 *   --notify   미커버 반복 불만이 임계 이상이면 Discord(jarvis-system)로 알림
 *
 * 원장: ~/jarvis/runtime/state/preply-complaint-ledger.jsonl (msgId 기준 멱등 append)
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { homedir } from 'node:os';
import { createRequire } from 'node:module';

const require = createRequire('/Users/ramsbaby/jarvis/infra/discord/package.json');
const { Client, GatewayIntentBits } = require('discord.js');

const HOME = homedir();
const ENV_FILE = `${HOME}/jarvis/runtime/.env`;
const LEDGER = `${HOME}/jarvis/runtime/state/preply-complaint-ledger.jsonl`;
const UPLOAD_LEDGER = `${HOME}/jarvis/runtime/state/preply-upload-ledger.jsonl`; // 2026-07-13: 업로드 실패 상관분석용
const THRESHOLD = 3; // 미커버 불만이 이 횟수 이상이면 "검사 추가 필요" 승격

const argv = process.argv.slice(2);
const days = parseInt((argv[argv.indexOf('--days') + 1]) || '7', 10) || 7;
const notify = argv.includes('--notify');

// 불만 신호 — 부정·지적·재요청 (이게 있어야 "불만"으로 취급, 학생정보 제공 메시지 등은 제외)
const SIGNAL = /왜|다시|어떻게|안\s?(돼|되|만들|보|나)|없(어|네|이)|있으면|빼|가려|수정|틀|기록해|스킬로|기억해|!{1,}|아니|답답|짤|크게|꽉|보내(줘|라)|올려/;

// 카테고리 — covered=true는 이미 verify/렌더/비전이 검사하는 것. false는 아직 미커버(승격 후보).
const CATS = [
  { key: '정답노출', covered: true, re: /정답|답이|답 나와|가려|정답이 보|보기에.*답|answer/i },
  { key: '영어뜻병기', covered: true, re: /영어.*뜻|뜻.*영어|영어로|영어 설명|영어 예문|영어 해석/i },
  { key: '글씨크기', covered: true, re: /글씨|크게|작(아|게)|눈에 (잘 )?띄/i },
  { key: 'A4채움', covered: true, re: /꽉|1\s?장|한\s?장|A4|넘치|짤|답답|여백/i },
  { key: '파일전송', covered: false, re: /다시.{0,6}(보내|올려|업로드)|보내(라|줘야|달라)|안\s?(보내|올려|만들어)|어디에 올려/i },
  { key: '설명상세', covered: false, re: /자세히 설명|더 설명|왜.*다르|헷갈|간단히|자세히 써/i },
  { key: '프로필오타', covered: true, re: /(가|이|는|은)\s?아니(라|고).{0,25}(기록|기억|수정|업로드)|오타|이름.{0,8}틀|나오미가 아니라/i },
  { key: '분위기', covered: false, re: /밝게|어두|분위기|색/i },
];

function loadToken() {
  if (process.env.DISCORD_TOKEN) return process.env.DISCORD_TOKEN;
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^\s*DISCORD_TOKEN\s*=\s*(.+?)\s*$/);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }
  throw new Error('DISCORD_TOKEN 없음');
}

function loadSeen() {
  const seen = new Set();
  if (existsSync(LEDGER)) for (const l of readFileSync(LEDGER, 'utf8').split('\n')) {
    try { const d = JSON.parse(l); if (d.msgId) seen.add(d.msgId); } catch { /* skip */ }
  }
  return seen;
}

async function sendNotify(text) {
  // jarvis 채널 webhook으로 알림 (2026-07-13 주인님 지시로 jarvis-system → jarvis 변경). 실패는 비차단.
  try {
    const cfg = JSON.parse(readFileSync(`${HOME}/jarvis/runtime/config/monitoring.json`, 'utf8'));
    const url = cfg.webhooks?.['jarvis'];
    if (!url) return;
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: text.slice(0, 1990) }),
    });
  } catch { /* 알림 실패는 비차단 */ }
}

const client = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent] });
const timeout = setTimeout(() => { console.error('타임아웃'); process.exit(1); }, 60000);

client.once('clientReady', async () => {
  try {
    const ch = client.channels.cache.find((c) => c.isTextBased?.() && c.name === 'jarvis-preply-tutor');
    if (!ch) { console.error('채널 못찾음'); process.exit(1); }
    const cutoff = Date.now() - days * 86400000;
    const seen = loadSeen();
    let all = [], before;
    for (let p = 0; p < 6; p++) {
      const batch = await ch.messages.fetch({ limit: 100, ...(before ? { before } : {}) });
      if (batch.size === 0) break;
      all.push(...batch.values());
      before = batch.last().id;
      if (batch.last().createdTimestamp < cutoff || batch.size < 100) break;
    }
    const human = all.filter((m) => !m.author.bot && m.createdTimestamp >= cutoff);

    mkdirSync(dirname(LEDGER), { recursive: true });
    let newN = 0;
    const catCount = {};
    for (const m of human) {
      const text = (m.content || '').replace(/\n+/g, ' ').trim();
      if (!text || !SIGNAL.test(text)) continue; // 불만 신호 없으면 제외
      const cats = CATS.filter((c) => c.re.test(text)).map((c) => c.key);
      if (!cats.length) cats.push('기타');
      for (const c of cats) catCount[c] = (catCount[c] || 0) + 1;
      if (!seen.has(m.id)) {
        appendFileSync(LEDGER, JSON.stringify({ ts: new Date(m.createdTimestamp).toISOString(), msgId: m.id, text: text.slice(0, 160), cats }) + '\n');
        newN++;
      }
    }

    // 업로드 실패 상관분석 (2026-07-13): 같은 창(window)의 실제 업로드 실패를 원장에서 읽어
    // 보람님 '파일전송' 불만과 대조 → "미커버(원인 모름)" 대신 실제 원인을 대령한다.
    const uploadFails = [];
    if (existsSync(UPLOAD_LEDGER)) {
      for (const l of readFileSync(UPLOAD_LEDGER, 'utf8').split('\n')) {
        if (!l.trim()) continue;
        let r; try { r = JSON.parse(l); } catch { continue; }
        if (new Date(r.ts).getTime() < cutoff) continue;
        if (r.result && r.result !== 'ok') uploadFails.push(r);
      }
    }

    // 리포트 — 카테고리별 빈도 + 커버 여부
    const covMap = Object.fromEntries(CATS.map((c) => [c.key, c.covered]));
    const rows = Object.entries(catCount).sort((a, b) => b[1] - a[1]);
    console.log(`\n📊 보람님 불만 스캔 (최근 ${days}일 · 불만신호 메시지 ${human.filter((m) => SIGNAL.test(m.content || '')).length}건 · 신규 원장 ${newN}건)`);
    console.log('─'.repeat(52));
    const uncoveredHot = [];
    for (const [cat, n] of rows) {
      const cov = covMap[cat];
      const mark = cov === true ? '✅ 검사됨' : cov === false ? '🔴 미커버' : '⚪ 미분류';
      console.log(`  ${cat.padEnd(10)} ${String(n).padStart(3)}회  ${mark}`);
      if (cov === false && n >= THRESHOLD) uncoveredHot.push({ cat, n });
    }
    console.log('─'.repeat(52));

    if (uncoveredHot.length) {
      const msg = `🔴 preply 미커버 반복 불만 ${uncoveredHot.length}종 (검사 추가 필요): ` +
        uncoveredHot.map((u) => `${u.cat}(${u.n}회)`).join(', ') +
        ` — verify/렌더/비전에 아직 없는 반복 불만입니다. 검사 흡수 검토 필요.`;
      console.log(msg);
      if (notify) await sendNotify(msg);
    } else {
      console.log('✅ 미커버 반복 불만 없음 — 현재 검사가 반복 불만을 다 잡고 있음.');
    }

    // 파일전송 불만 ↔ 실제 업로드 실패 상관분석 (자동 원인 대령)
    const fileComplaints = catCount['파일전송'] || 0;
    if (fileComplaints > 0 || uploadFails.length > 0) {
      const recent = uploadFails.slice(-3).map((r) => {
        const fname = (r.files?.[0]?.path || '').split('/').pop() || '?';
        return `${fname}:${r.result}${r.error ? `(${String(r.error).slice(0, 40)})` : ''}`;
      }).join(' / ');
      const corr = uploadFails.length
        ? `📎 파일전송 상관분석: 보람님 불만 ${fileComplaints}건 ↔ 실제 업로드 실패 ${uploadFails.length}건 확인됨 (원인 규명) — 최근: ${recent}`
        : `📎 파일전송 상관분석: 보람님 불만 ${fileComplaints}건 있으나 업로드 원장엔 실패 0건 → 업로드는 성공, 생성/내용 문제 가능성 (verify/생성게이트 점검 방향)`;
      console.log(corr);
      // 실제 업로드 실패가 잡혔거나, 불만이 임계 이상이면 Discord 알림
      if (notify && (uploadFails.length > 0 || fileComplaints >= THRESHOLD)) await sendNotify(corr);
    }

    clearTimeout(timeout);
    await client.destroy();
    process.exit(0);
  } catch (e) {
    console.error('스캔 실패:', e.message);
    process.exit(1);
  }
});

client.login(loadToken()).catch((e) => { console.error('로그인 실패:', e.message); process.exit(1); });
