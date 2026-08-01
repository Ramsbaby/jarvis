#!/usr/bin/env node
/**
 * improvement-scorecard-measure.mjs
 *
 * 2026-07-20 자비스가 한 6개 수정이 "말"이 아니라 "실제 개선"으로 이어졌는지 실측하는 계기판.
 * 핵심 질문: "의심하는 힘(독립 검증 루프)이 진짜 개선을 낳는가?"를 숫자로 확인한다.
 *
 * 설계 원칙 (BLOCKING):
 *  · 읽기 전용. 기존 원장만 읽는다. 새 크론·데몬 0. --baseline 일 때만 스냅샷 1개 파일을 쓴다.
 *  · 추측 금지. 원장 필드가 없으면 "측정불가+이유"로 정직 기록.
 *  · 상관 ≠ 인과. 개선 판정에 "다른 요인 섞일 수 있음"을 항상 명시한다.
 *
 * 사용법:
 *   node improvement-scorecard-measure.mjs --baseline   # 오늘(anchor) baseline 스냅샷 기록 (1회)
 *   node improvement-scorecard-measure.mjs               # baseline 대비 현재 델타 출력 (읽기전용)
 *   node improvement-scorecard-measure.mjs --json        # 기계 판독용 JSON
 *
 * 측정 6지표 · 각 지표는 독립검증(의심하는 힘)이 뒤집은 결정과 연결되어 있다 (link 필드).
 */

import { readFileSync, writeFileSync, existsSync, statSync, mkdirSync, appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const ANCHOR = '2026-07-20';
const BASELINE_FILE = join(HOME, 'jarvis/runtime/ledger/improvement-scorecard-baseline-20260720.json');

// ── 데이터 소스 (실측 확인된 실제 경로) ───────────────────────────────
const SRC = {
  autolearnMd:   join(HOME, '.claude/rules/jarvis-autolearn.md'),
  mistakeLedger: join(HOME, 'jarvis/runtime/state/mistake-ledger.jsonl'),
  promoterLedger:join(HOME, 'jarvis/runtime/ledger/promoter-ledger.jsonl'),
  independentVerify: join(HOME, 'jarvis/runtime/ledger/independent-verify.jsonl'),
  botResponseBus: join(HOME, 'jarvis/runtime/ledger/bot-response-bus.jsonl'),
  discordSendAudit: join(HOME, 'jarvis/runtime/ledger/discord-send-audit.jsonl'),
  outfileBaseline: join(HOME, 'jarvis/runtime/ledger/outfile-hook-holdout-baseline.json'),
  ragStats:      join(HOME, 'jarvis/rag/bin/rag-stats.mjs'),
};

// ── 채널 분류 ────────────────────────────────────────────────────────
// 개인 식별 채널명(커리어·가족)은 공개 저장소에 하드코딩하지 않고 env 로 주입한다.
//   CAREER_DOMAIN_CHANNEL : 커리어 도메인 채널명 (예: 배포처에서 지정)
//   PERSONAL_CHANNELS     : 개인/가족 채널명 쉼표 구분 목록
// 미설정 시 해당 채널은 분류에서 빠질 뿐, 나머지 측정은 정상 동작한다.
const CAREER_CH   = process.env.CAREER_DOMAIN_CHANNEL || '';
const PERSONAL_CH = (process.env.PERSONAL_CHANNELS || '').split(',').map(s => s.trim()).filter(Boolean);

const DAILY_CH    = new Set([...PERSONAL_CH, 'jarvis-preply-tutor', 'jarvis-lite', 'jarvis']);
const ANALYSIS_CH = new Set([CAREER_CH, 'jarvis-dev', 'jarvis-ceo', 'jarvis-market'].filter(Boolean));
const MAJOR_CH    = new Set(['jarvis','jarvis-ceo','jarvis-system']);
const RETRO_KW    = ['회고','retro','오답','세션 종료','learned','미스테이크','retrospect'];
const COMPLETION_KW = ['완료','검증','선언','존재','업로드','성공'];  // 완료선언류 재발

// ── 유틸 ──────────────────────────────────────────────────────────────
function readLines(path) {
  if (!existsSync(path)) return null;
  return readFileSync(path, 'utf8').split('\n').map(s => s.trim()).filter(Boolean);
}
function parseTs(ts) {
  if (!ts) return null;
  const d = new Date(ts);
  return isNaN(d.getTime()) ? null : d;
}
function pct(n, d) { return d === 0 ? null : Math.round((n / d) * 1000) / 10; }
function avg(arr) { return arr.length ? Math.round((arr.reduce((a,b)=>a+b,0)/arr.length)*10)/10 : null; }

// ── 각 지표 계산기 (now 기준 슬라이딩 윈도우) ─────────────────────────
function m1_autolearn(now) {
  const out = { name:'autolearn 배수', direction:'recurrence_lower_and_size_flat', unit:'bytes+count' };
  try {
    out.autolearn_bytes = statSync(SRC.autolearnMd).size;
  } catch (e) { out.autolearn_bytes = null; out.autolearn_note = '측정불가: '+e.message; }
  const lines = readLines(SRC.mistakeLedger);
  if (!lines) { out.recur_note = '측정불가: mistake-ledger 없음'; return out; }
  const d7 = new Date(now - 7*864e5);
  let total = 0, recur = 0;
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch { continue; }
    const t = parseTs(r.ts); if (!t || t < d7 || t > now) continue;
    const c = Number(r.count) || 1;
    total += c;
    const titles = Array.isArray(r.titles) ? r.titles.join(' ') : String(r.titles||'');
    if (COMPLETION_KW.some(k => titles.includes(k))) recur += c;
  }
  out.total_mistakes_last7d = total;
  out.completion_recur_last7d = recur;
  return out;
}

function m2_vera(now) {
  const out = { name:'VERA 수리 (독립검증 하네스 자체 건강)', direction:'failed_pct_lower', unit:'%' };
  const lines = readLines(SRC.independentVerify);
  if (!lines) { out.note = '측정불가: independent-verify.jsonl 없음'; return out; }
  let total = 0, failed = 0, first = null, last = null;
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch { continue; }
    total++;
    if (r.verdict === 'VERIFY_FAILED') failed++;
    const t = parseTs(r.ts); if (t) { if (!first||t<first) first=t; if (!last||t>last) last=t; }
  }
  out.verify_total = total;
  out.verify_failed = failed;
  out.verify_failed_pct = pct(failed, total);
  out.harness_first_ts = first ? first.toISOString() : null;
  out.harness_last_ts = last ? last.toISOString() : null;
  out.sample_note = total < 40 ? `표본 ${total}건 — 하네스 신생(약한 신호). 40건+ 누적 후 재판정 권장.` : `표본 ${total}건.`;
  return out;
}

function m3_mobile(now) {
  const out = { name:'모바일 길이 (일상채널 vs 분석채널 평균 글자수)', direction:'daily_lower_analysis_flat', unit:'chars', window:'14d' };
  const lines = readLines(SRC.botResponseBus);
  if (!lines) { out.note = '측정불가: bot-response-bus.jsonl 없음'; return out; }
  const d14 = new Date(now - 14*864e5);
  const daily = [], analysis = [], perCh = {};
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch { continue; }
    const t = parseTs(r.ts); if (!t || t < d14 || t > now) continue;
    if (r.is_error) continue;
    const ch = r.channel, n = r.response_chars;
    if (typeof n !== 'number') continue;
    (perCh[ch] = perCh[ch] || []).push(n);
    if (DAILY_CH.has(ch)) daily.push(n);
    else if (ANALYSIS_CH.has(ch)) analysis.push(n);
  }
  out.daily_avg_chars = avg(daily);   out.daily_n = daily.length;
  out.analysis_avg_chars = avg(analysis); out.analysis_n = analysis.length;
  out.per_channel = {};
  for (const [ch, arr] of Object.entries(perCh)) if (DAILY_CH.has(ch)||ANALYSIS_CH.has(ch)) out.per_channel[ch] = { avg: avg(arr), n: arr.length };
  return out;
}

function m4_retro(now) {
  const out = { name:'retro 라우팅 (주요채널로 간 회고성 발송/주)', direction:'count_lower', unit:'count/7d' };
  const lines = readLines(SRC.discordSendAudit);
  if (!lines) { out.note = '측정불가: discord-send-audit.jsonl 없음'; return out; }
  const d7 = new Date(now - 7*864e5);
  let cnt = 0; const byCh = {};
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch { continue; }
    const t = parseTs(r.ts); if (!t || t < d7 || t > now) continue;
    if (!MAJOR_CH.has(r.channel)) continue;
    const hay = ((r.title||'') + ' ' + (r.source||'')).toLowerCase();
    if (RETRO_KW.some(k => hay.includes(k.toLowerCase()))) { cnt++; byCh[r.channel]=(byCh[r.channel]||0)+1; }
  }
  out.major_retro_last7d = cnt;
  out.by_channel = byCh;
  return out;
}

function m5_outfile() {
  const out = { name:'outfile 훅 (별도 baseline·measure 존재 — 링크만)', direction:'delegated', unit:'link' };
  if (!existsSync(SRC.outfileBaseline)) { out.note = '측정불가: outfile baseline 없음'; return out; }
  try {
    const b = JSON.parse(readFileSync(SRC.outfileBaseline,'utf8'));
    out.linked_baseline = SRC.outfileBaseline;
    out.linked_measure_script = join(HOME, 'jarvis/infra/scripts/outfile-hook-holdout-measure.py');
    out.measure_after = b.measure_date_dplus14 || '2026-08-03';
    out.baseline_windows = b.baseline_windows || null;
    out.run_hint = 'python3 ~/jarvis/infra/scripts/outfile-hook-holdout-measure.py --measure  (D+14 이후)';
  } catch (e) { out.note = '측정불가: outfile baseline 파싱 실패 — '+e.message; }
  return out;
}

function m6_rag() {
  const out = { name:'RAG 관측 (env 미설정 rag-stats 거짓보고 여부)', direction:'false_report_zero', unit:'count' };
  if (!existsSync(SRC.ragStats)) { out.note = '측정불가: rag-stats.mjs 없음'; out.false_report_count = null; return out; }
  const env = { ...process.env };
  delete env.JARVIS_RAG_HOME; delete env.BOT_HOME;   // env 미설정 재현
  let js;
  try {
    let nodeCmd = process.env.NODE_BIN;
    if (!nodeCmd) {
      try { nodeCmd = execFileSync('bash', ['-c', 'command -v node'], { encoding:'utf8', timeout:5000 }).trim(); } catch {}
    }
    nodeCmd = nodeCmd || '/opt/homebrew/bin/node';
    const raw = execFileSync(nodeCmd, [SRC.ragStats, '--json'], { env, encoding:'utf8', timeout:60000 });
    js = JSON.parse(raw);
  } catch (e) { out.note = '측정불가: rag-stats 실행/파싱 실패 — '+e.message; out.false_report_count = null; return out; }
  // 거짓보고 신호: (1) 유령DB = dbExists=false 또는 totalChunks=0, (2) 영구 리빌드중 = rebuilding=true, (3) error
  const signals = [];
  if (!js.dbExists) signals.push('ghost_db(dbExists=false)');
  if (!js.totalChunks || js.totalChunks === 0) signals.push('ghost_db(totalChunks=0)');
  if (js.rebuilding) signals.push('false_rebuilding(rebuilding=true)');
  if (js.error) signals.push('error='+js.error);
  out.false_report_count = signals.length;
  out.false_report_signals = signals;
  out.db_exists = js.dbExists; out.total_chunks = js.totalChunks;
  out.rebuilding = js.rebuilding; out.path_source = js.pathSource; out.db_path = js.dbPath;
  return out;
}

// ── 정적 메타: 개선기준·측정캘린더·독립검증 연결 메모·상관caveat ──────
const DEFS = {
  m1_autolearn: {
    improvement_criterion: 'autolearn.md 바이트가 안정(과붊 없음) + 완료선언류 재발(mistake-ledger)이 이전 창 대비 감소.',
    measure_after: '다음 세션(며칠 뒤) 및 8-3. 재발은 주 단위 변동 커 최소 1주 간격 비교.',
    independent_verify_link: '독립검증(의심하는 힘)이 "규칙 수 늘어남 = 학습됨" 가정을 뒤집음 → 규칙 붊이 아니라 실제 재발 감소로 학습 여부를 판정하게 함.',
    caveat: '상관≠인과: 재발 감소는 작업량 변화·주제 편중·다른 가드가 섞일 수 있음. 완료류 키워드 프록시라 ±오차.',
  },
  m2_vera: {
    improvement_criterion: 'VERIFY_FAILED 비율 감소 (task 목표 30%→<10%). 하네스가 죽지 않고 판정을 완주.',
    measure_after: '표본 40건+ 누적 시 (하네스 사용 빈도에 따라 며칠~1주). 신생이라 조기 판정 금물.',
    independent_verify_link: '이 지표의 대상이 곧 독립검증 하네스 자신. VERIFY_FAILED = 의심하는 도구가 스스로 죽던 버그를 수리한 것 → 도구 신뢰성 회복 실측.',
    caveat: '상관≠인과: 표본 21건(신생). 실패가 하네스 결함인지 대상 주장 난이도인지 분리 필요. fail_reason 병행 확인.',
  },
  m3_mobile: {
    improvement_criterion: '일상채널 평균 글자수 감소(모바일 가독성↑) + 분석채널 평균 유지(깊이 훼손 없음).',
    measure_after: '1주 후 (충분한 봇 응답 표본 확보 후). 채널별 표본 편중 주의.',
    independent_verify_link: '독립검증이 "길수록 좋다" 가정을 일상채널에서 뒤집음 → 모바일에서 읽는 일상 대화는 짧게, 분석 채널만 길게 분리 결정.',
    caveat: '상관≠인과: preply-tutor가 일상군 표본 대부분(교재 특성상 김) → 일상 평균을 끌어올림. 채널별 값 병기로 왜곡 완화. 분석채널 표본은 적음(n<50).',
  },
  m4_retro: {
    improvement_criterion: '주요채널(jarvis·jarvis-ceo·jarvis-system)로 가는 회고성 발송/주 감소 (jarvis-retro로 라우팅 전환).',
    measure_after: '1주 후 (주 단위 발송량 비교가 유의미).',
    independent_verify_link: '독립검증이 "회고관(통합 뷰어) 신설"을 폐기 → 대안으로 회고성 알림을 전용 jarvis-retro 채널로 라우팅. 이 지표는 그 라우팅이 실제로 주요채널 소음을 줄였는지 실측.',
    caveat: '상관≠인과: 회고 키워드(회고/오답/세션종료) 프록시 매칭. 세션 수 자체가 늘면 회고 발송도 늘어 라우팅 효과와 섞임.',
  },
  m5_outfile: {
    improvement_criterion: 'post-bash-outfile-verify 훅 홀드아웃(별도 스크립트) — NARROW/BROAD 재발 감소.',
    measure_after: '2026-08-03 (D+14). 별도 스크립트로 측정.',
    independent_verify_link: '독립검증이 "파일생성 오답 자동분류기 신설"을 폐기 → 대안으로 직접 훅 FIX(post-bash-outfile-verify). 링크된 홀드아웃이 그 FIX 효과를 측정.',
    caveat: '상관≠인과: 링크된 baseline note 그대로 — 훅은 CLI 표면만 warn, 재발 감소에 다른 요인 섞임.',
  },
  m6_rag: {
    improvement_criterion: 'env 미설정 rag-stats 거짓보고(유령DB·영구 리빌드중) 0건 유지 (회귀 가드).',
    measure_after: '다음 세션 및 8-3 (회귀 감시 — 언제든 재실행 가능).',
    independent_verify_link: '독립검증이 rag-stats 자기보고("리빌드 중: 예")를 그대로 믿지 않고 실제 DB와 대조 → 유령DB·영구 리빌드중 거짓보고 2종을 적발·수리. 이 지표는 그 수리가 유지되는지 회귀 감시.',
    caveat: '상관≠인과 아님(회귀 가드): 이건 결정론 실측 — 거짓보고 신호 유무는 명령 출력으로 직접 확인. 다만 rag-rebuilding.json이 실제로 존재하는 정상 리빌드 시엔 rebuilding=true가 참(거짓 아님)임에 유의.',
  },
};

// ── 전체 계산 ─────────────────────────────────────────────────────────
function computeMetrics(now) {
  return {
    m1_autolearn: m1_autolearn(now),
    m2_vera: m2_vera(now),
    m3_mobile: m3_mobile(now),
    m4_retro: m4_retro(now),
    m5_outfile: m5_outfile(),
    m6_rag: m6_rag(),
  };
}

// ── 판정 (baseline vs current) ───────────────────────────────────────
function judge(id, base, cur) {
  const dir = (cur && cur.direction) || (base && base.direction);
  const R = (k) => ({ base: base?.[k], cur: cur?.[k], delta: (typeof cur?.[k]==='number' && typeof base?.[k]==='number') ? Math.round((cur[k]-base[k])*10)/10 : null });
  let verdict = '측정불가', detail = '';
  switch (id) {
    case 'm1_autolearn': {
      const rec = R('completion_recur_last7d'), by = R('autolearn_bytes');
      if (rec.delta === null) { detail = '재발 수치 없음'; break; }
      verdict = rec.delta < 0 ? '개선' : rec.delta === 0 ? '무변화' : '악화';
      detail = `완료류 재발 ${rec.base}→${rec.cur} (Δ${rec.delta}); autolearn 바이트 ${by.base}→${by.cur} (Δ${by.delta}, 과붊이면 악화 신호)`;
      break;
    }
    case 'm2_vera': {
      const p = R('verify_failed_pct');
      if (p.delta === null) { detail='비율 없음'; break; }
      verdict = p.delta < 0 ? '개선' : p.delta === 0 ? '무변화' : '악화';
      detail = `VERIFY_FAILED ${p.base}%→${p.cur}% (Δ${p.delta}%p); ${cur?.sample_note||''}`;
      break;
    }
    case 'm3_mobile': {
      const d = R('daily_avg_chars'), a = R('analysis_avg_chars');
      if (d.delta === null) { detail='일상 평균 없음'; break; }
      const analysisOk = (a.delta === null) || (a.base ? (a.cur >= a.base*0.8) : true);
      verdict = (d.delta < 0 && analysisOk) ? '개선' : (d.delta === 0 ? '무변화' : (d.delta>0 ? '악화' : '부분개선(분석채널 하락)'));
      detail = `일상 ${d.base}→${d.cur}자 (Δ${d.delta}); 분석 ${a.base}→${a.cur}자 (Δ${a.delta}, 20%↓ 이내 유지 조건)`;
      break;
    }
    case 'm4_retro': {
      const c = R('major_retro_last7d');
      if (c.delta === null) { detail='건수 없음'; break; }
      verdict = c.delta < 0 ? '개선' : c.delta === 0 ? '무변화' : '악화';
      detail = `주요채널 회고성 발송 ${c.base}→${c.cur}건/7d (Δ${c.delta})`;
      break;
    }
    case 'm5_outfile': {
      verdict = '위임'; detail = `별도 홀드아웃 — ${cur?.run_hint||''} (D+14=${cur?.measure_after||'2026-08-03'})`;
      break;
    }
    case 'm6_rag': {
      const f = R('false_report_count');
      if (f.cur === null || f.cur === undefined) { detail='rag-stats 실행 실패'; break; }
      verdict = f.cur === 0 ? (f.base===0?'무변화(정상 유지)':'개선') : '악화(거짓보고 재발)';
      detail = `거짓보고 신호 ${f.base}→${f.cur}건 [${(cur?.false_report_signals||[]).join(',')||'없음'}]; db_exists=${cur?.db_exists} chunks=${cur?.total_chunks} rebuilding=${cur?.rebuilding}`;
      break;
    }
  }
  return { verdict, detail };
}

// ── 실행 ─────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const now = new Date();

// ── --session-reminder: SessionStart 픽업용 읽기전용 리마인더 (빈 고리 닫기) ──
// 문제: 파수꾼(--check-due)이 측정일에 jarvis-retro로 카드를 발송해도, 다음 세션의
//   자비스가 그 결과를 자동으로 "읽고→판정→조치"할 연결이 없었다(빈 고리).
// 이 모드는 SessionStart 훅(session-context.sh)이 매 세션 호출한다. 읽기전용 — 발송·마커쓰기 0.
// 자기종료(self-terminating) 설계: 마스터 스위치 = "open && revisit_on<=오늘 인 미뤄둔 과제 존재".
//   자비스가 조치 후 deferred-tasks.jsonl의 status를 done으로 바꾸면 리마인더가 조용해진다.
//   측정 캘린더 버킷·발송 마커는 그 안에서 부가 정보로만 표시(단독 트리거 금지 → 영구 오염 방지).
// 날짜 하드코딩 금지 — 실제 KST 날짜. 복기일 전이면 아무것도 출력 안 함(세션 오염 0).
// 테스트: --assume-today=YYYY-MM-DD (미래 날짜 주입으로 복기일 도래 시나리오 실측).
if (argv.includes('--session-reminder')) {
  const getOpt = (name) => {
    const pfx = `--${name}=`;
    const hit = argv.find(a => a.startsWith(pfx));
    return hit ? hit.slice(pfx.length) : null;
  };
  const assume = getOpt('assume-today');
  const todayStr = assume || new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });

  const SENT_DIR   = join(HOME, 'jarvis/runtime/state/scorecard-due-sent');
  const DEFER_FILE = join(HOME, 'jarvis/runtime/ledger/deferred-tasks.jsonl');

  // (마스터 스위치) open && revisit_on<=오늘 인 미뤄둔 과제 — 이게 있어야만 리마인더가 뜬다.
  const dueDeferred = [];
  if (existsSync(DEFER_FILE)) {
    for (const raw of readFileSync(DEFER_FILE, 'utf8').split('\n')) {
      const s = raw.trim(); if (!s) continue;
      let r; try { r = JSON.parse(s); } catch { continue; }
      if ((r.status || 'open') !== 'open') continue;
      if (r.revisit_on && todayStr < r.revisit_on) continue;   // 아직 복기할 때 아님
      dueDeferred.push(r);
    }
  }
  // 복기할 과제 없으면 완전 침묵 → 평소 세션 오염 0
  if (dueDeferred.length === 0) process.exit(0);

  // 부가 정보: 오늘>=측정일인 측정 캘린더 버킷 + 파수꾼 발송 여부(마커)
  const dueBuckets = [];
  try {
    if (existsSync(BASELINE_FILE)) {
      const base = JSON.parse(readFileSync(BASELINE_FILE, 'utf8'));
      const cal = base.measure_calendar || {};
      for (const [k, metrics] of Object.entries(cal)) {
        const m = String(k).match(/(\d{4}-\d{2}-\d{2})/);
        if (!m) continue;                          // next_session 등 날짜 없는 버킷 제외
        const dueDate = m[1];
        if (todayStr < dueDate) continue;
        const sent = existsSync(join(SENT_DIR, `${dueDate}.measure.done`));
        dueBuckets.push({ key: k, metrics: Array.isArray(metrics) ? metrics : [], sent });
      }
    }
  } catch {}

  const lines = [`🔔 개선 계기판 복기 리마인더 (오늘 ${todayStr} KST) — 복기일 도래한 미뤄둔 과제 ${dueDeferred.length}건`];
  for (const b of dueBuckets) {
    const mark = b.sent
      ? '파수꾼 측정·발송함 ✅ → jarvis-retro 카드 읽고 판정'
      : '측정일 도달, 파수꾼 아직 미발송(월 08:00 크론 대기)';
    lines.push(`  · 측정일 도달: [${b.key}] ${b.metrics.join('·')} — ${mark}`);
  }
  for (const d of dueDeferred) {
    const link = d.linked_metric ? ` · 연결 ${d.linked_metric}` : '';
    lines.push(`  · [${d.id}] ${d.title} (복기일 ${d.revisit_on || '?'}${link})`);
  }
  lines.push(`  → 조치: jarvis-retro 측정 카드를 읽고 판정→조치. 완료 시 ${DEFER_FILE} 의 해당 과제 status를 "done"으로 바꾸면 이 리마인더 종료(미해결이면 다음 세션 재부상).`);
  console.log(lines.join('\n'));
  process.exit(0);
}

// ── --check-due: 측정일 파수꾼 (measure-day watchman) ─────────────────────
// 오늘이 measure_calendar의 측정일(또는 그 이후 아직 미발송분)이면 해당 지표를 measure하고
// discord-route(retro=jarvis-retro)로 알림. 측정일 아니면 조용히 exit 0. 새 크론·데몬 0.
// 날짜는 시스템 실제 날짜(KST). 하드코딩 금지. 문자열(YYYY-MM-DD) 사전식=연대순 비교.
// 테스트: --assume-today=YYYY-MM-DD (자동 dry-run — 실발송 금지, --force-send로만 우회).
//         --dry-run (실제 발송 대신 미리보기). 측정일 마커로 1회만 발송(호스트 재실행 안전).
if (argv.includes('--check-due')) {
  const getOpt = (name) => {
    const pfx = `--${name}=`;
    const hit = argv.find(a => a.startsWith(pfx));
    return hit ? hit.slice(pfx.length) : null;
  };
  const assume = getOpt('assume-today');
  // 안전장치: assume-today(테스트)는 명시적 --force-send 없으면 항상 dry-run → 채널 오염 방지
  const dryRun = argv.includes('--dry-run') || (!!assume && !argv.includes('--force-send'));
  const todayStr = assume || new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
  const measureNow = assume ? new Date(assume + 'T12:00:00+09:00') : now;

  const SENT_DIR     = join(HOME, 'jarvis/runtime/state/scorecard-due-sent');
  const DEFER_FILE   = join(HOME, 'jarvis/runtime/ledger/deferred-tasks.jsonl');
  const WATCH_LOG    = join(HOME, 'jarvis/runtime/logs/scorecard-watchman.log');
  const WATCH_LEDGER = join(HOME, 'jarvis/runtime/ledger/scorecard-watchman-ledger.jsonl');
  const ROUTE_LIB    = join(HOME, 'jarvis/infra/lib/discord-route.sh');

  const logLine = (s) => {
    const ln = `[${new Date().toISOString()}] ${s}`;
    console.log(ln);
    try { mkdirSync(join(HOME, 'jarvis/runtime/logs'), { recursive: true }); appendFileSync(WATCH_LOG, ln + '\n'); } catch {}
  };

  if (!existsSync(BASELINE_FILE)) { logLine(`[check-due] baseline 없음 — skip (today=${todayStr})`); process.exit(0); }
  const base = JSON.parse(readFileSync(BASELINE_FILE, 'utf8'));
  const cal = base.measure_calendar || {};

  // 지표 id → 계산 함수 (해당 측정일 지표만 계산 — 비측정일엔 아예 진입 안 함)
  const METRIC_FN = {
    m1_autolearn: () => m1_autolearn(measureNow),
    m2_vera:      () => m2_vera(measureNow),
    m3_mobile:    () => m3_mobile(measureNow),
    m4_retro:     () => m4_retro(measureNow),
    m5_outfile:   () => m5_outfile(),
    m6_rag:       () => m6_rag(),
  };

  // (A) 측정 캘린더 — 날짜 있는 버킷만. 오늘>=측정일 && 미발송(마커 없음) → 발동(catch-up 안전망).
  const firedBuckets = [];
  for (const [k, metrics] of Object.entries(cal)) {
    const m = String(k).match(/(\d{4}-\d{2}-\d{2})/);
    if (!m) continue;                              // next_session 등 날짜 없는 버킷은 캘린더 대상 아님
    const dueDate = m[1];
    if (todayStr < dueDate) continue;              // 아직 측정일 전 → 조용
    const markerFile = join(SENT_DIR, `${dueDate}.measure.done`);
    if (existsSync(markerFile) && !dryRun) continue; // 이미 발송됨(dry-run은 마커 무시하고 미리보기)
    const rows = [];
    for (const id of (Array.isArray(metrics) ? metrics : [])) {
      const fn = METRIC_FN[id];
      if (!fn) { rows.push({ id, name: id, verdict: '측정불가', detail: '알 수 없는 지표 id' }); continue; }
      let cur; try { cur = fn(); } catch (e) { rows.push({ id, name: id, verdict: '측정불가', detail: 'compute 실패: ' + e.message }); continue; }
      const j = judge(id, (base.metrics || {})[id], cur);
      rows.push({ id, name: cur.name || id, verdict: j.verdict, detail: j.detail });
    }
    firedBuckets.push({ bucketKey: k, dueDate, markerFile, rows });
  }

  // (B) 미뤄둔 과제 — open && revisit_on<=오늘. 마커 없음(해결 전까지 주간 재부상 = 파수꾼 넛지).
  const dueDeferred = [];
  if (existsSync(DEFER_FILE)) {
    for (const raw of readFileSync(DEFER_FILE, 'utf8').split('\n')) {
      const s = raw.trim(); if (!s) continue;
      let r; try { r = JSON.parse(s); } catch { continue; }
      if ((r.status || 'open') !== 'open') continue;
      if (r.revisit_on && todayStr < r.revisit_on) continue;  // 아직 복기할 때 아님
      dueDeferred.push(r);
    }
  }

  if (firedBuckets.length === 0 && dueDeferred.length === 0) {
    logLine(`[check-due] 오늘(${todayStr})은 측정일·과제복기일 아님 — 조용히 종료 (exit 0)`);
    process.exit(0);
  }

  // discord_route data kv: 콤마=쌍 구분, =키/값 구분 → 값에서 , 와 = 제거
  const clean = (v) => String(v).replace(/[,=]/g, ' ').replace(/\s+/g, ' ').trim();
  const kvParts = [`측정일=${clean(todayStr)}`];
  const stdoutLines = [`📊 개선 계기판 파수꾼 — ${todayStr}${dryRun ? ' [DRY-RUN 미리보기]' : ''}`];

  if (firedBuckets.length) {
    kvParts.push(`측정구간=${firedBuckets.map(b => clean(b.bucketKey)).join(' · ')}`);
    const allRows = firedBuckets.flatMap(b => b.rows);
    kvParts.push(`지표판정=${allRows.map(r => `${r.id}:${clean(r.verdict)}`).join(' · ')}`);
    stdoutLines.push('── 측정 발동 ──');
    for (const b of firedBuckets) {
      stdoutLines.push(`  [${b.bucketKey}]`);
      for (const r of b.rows) stdoutLines.push(`   • ${r.id} · ${r.name} → ${r.verdict}\n       ${r.detail}`);
    }
  }
  if (dueDeferred.length) {
    kvParts.push(`대기과제=${dueDeferred.map(d => clean(String(d.title || d.id || '').slice(0, 40))).join(' · ')}`);
    stdoutLines.push('── 복기할 미뤄둔 과제 ──');
    for (const d of dueDeferred) stdoutLines.push(`  • [${d.id}] ${d.title} (복기일 ${d.revisit_on || '?'}) — 트리거: ${d.trigger || d.trigger_condition || '?'}`);
  }
  kvParts.push(`상세=${clean(WATCH_LOG)}`);

  const title = `개선 계기판 측정일 도달${dueDeferred.length ? ' + 미뤄둔 과제' : ''}`;
  const kv = kvParts.join(',');
  for (const l of stdoutLines) logLine(l);

  let sent = false;
  if (dryRun) {
    logLine('[DRY-RUN] jarvis-retro 로 발송했을 카드:');
    logLine(`   title = [retro] ${title}`);
    logLine(`   kv    = ${kv}`);
  } else {
    try {
      const nodeCmd = process.env.NODE_BIN || (execFileSync('bash', ['-c', 'command -v node'], { encoding:'utf8', timeout:5000 }).trim()) || '/opt/homebrew/bin/node';
      execFileSync('bash', ['-c', 'source "$ROUTE_LIB" && discord_route retro "$SC_TITLE" "$SC_KV"'], {
        env: { ...process.env, ROUTE_LIB, SC_TITLE: title, SC_KV: kv, NODE_BIN: nodeCmd },
        stdio: 'inherit', timeout: 60000,
      });
      sent = true;
      mkdirSync(SENT_DIR, { recursive: true });   // 발송 성공 시에만 측정일 마커 기록(1회 발송 보장)
      for (const b of firedBuckets) { try { writeFileSync(b.markerFile, new Date().toISOString() + '\n'); } catch {} }
      logLine(`[check-due] jarvis-retro 발송 완료 · 측정일 마커 ${firedBuckets.length}건 기록`);
    } catch (e) {
      logLine(`[check-due] 발송 실패(마커 미기록 — 다음 실행 재시도): ${e.message}`);
    }
  }

  try {
    mkdirSync(join(HOME, 'jarvis/runtime/ledger'), { recursive: true });
    appendFileSync(WATCH_LEDGER, JSON.stringify({
      ts: new Date().toISOString(), today: todayStr, dry_run: dryRun, sent,
      fired_buckets: firedBuckets.map(b => ({ bucket: b.bucketKey, due: b.dueDate, verdicts: b.rows.map(r => `${r.id}:${r.verdict}`) })),
      due_deferred: dueDeferred.map(d => d.id),
    }) + '\n');
  } catch {}

  process.exit(0);
}

if (argv.includes('--baseline')) {
  const metrics = computeMetrics(now);
  // 정적 메타 병합
  for (const id of Object.keys(metrics)) Object.assign(metrics[id], DEFS[id] || {});
  const snapshot = {
    scorecard: 'improvement-scorecard',
    purpose: '2026-07-20 6개 수정이 "말"이 아니라 "실제 개선"인지 실측. 독립검증(의심하는 힘)이 진짜 개선을 낳는지 확인.',
    anchor: ANCHOR,
    recorded_at: now.toISOString(),
    recorded_at_kst: now.toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }) + ' KST',
    read_only: true,
    no_new_cron: true,
    global_caveat: '모든 개선 판정은 상관 관찰이며 인과 증명이 아니다. 작업량·주제편중·병행 가드 등 다른 요인이 섞일 수 있다. m6만 결정론 실측(회귀 가드).',
    measure_calendar: {
      next_session: ['m1_autolearn','m6_rag'],
      'D+7 (~2026-07-27)': ['m2_vera','m3_mobile','m4_retro'],
      'D+14 (2026-08-03)': ['m5_outfile','m1_autolearn','m6_rag'],
    },
    metrics,
  };
  writeFileSync(BASELINE_FILE, JSON.stringify(snapshot, null, 2) + '\n');
  console.log('✅ baseline 기록 완료 →', BASELINE_FILE);
  console.log('📊 6지표 오늘값:');
  for (const [id, m] of Object.entries(metrics)) {
    console.log(`  • ${id} — ${m.name}`);
    const vals = Object.fromEntries(Object.entries(m).filter(([k])=>!['name','direction','unit','improvement_criterion','measure_after','independent_verify_link','caveat','per_channel','baseline_windows','by_channel','false_report_signals'].includes(k)));
    console.log('     ', JSON.stringify(vals));
  }
  process.exit(0);
}

// 기본/--json: baseline 대비 현재 델타
if (!existsSync(BASELINE_FILE)) {
  console.error('❌ baseline 없음. 먼저: node improvement-scorecard-measure.mjs --baseline');
  process.exit(1);
}
const baseline = JSON.parse(readFileSync(BASELINE_FILE, 'utf8'));
const current = computeMetrics(now);
const report = { scorecard:'improvement-scorecard', anchor: baseline.anchor, baseline_recorded_at: baseline.recorded_at, measured_at: now.toISOString(), rows: {} };
for (const id of Object.keys(current)) {
  const j = judge(id, baseline.metrics[id], current[id]);
  report.rows[id] = { name: current[id].name, verdict: j.verdict, detail: j.detail, independent_verify_link: (baseline.metrics[id]||{}).independent_verify_link, caveat: (baseline.metrics[id]||{}).caveat };
}

if (argv.includes('--json')) {
  console.log(JSON.stringify({ report, baseline_metrics: baseline.metrics, current_metrics: current }, null, 2));
  process.exit(0);
}

// 사람이 읽는 표
console.log('📊 개선 계기판 — baseline(' + baseline.anchor + ') 대비 현재\n');
console.log('   기록:', baseline.recorded_at, '→ 측정:', now.toISOString());
console.log('   ⚠️ 상관≠인과: 아래 판정은 관찰이며 인과 증명 아님(m6 제외 — 회귀 결정론 실측).\n');
const ico = { '개선':'🟢','무변화':'⚪','악화':'🔴','위임':'🔗','측정불가':'⚠️' };
for (const [id, r] of Object.entries(report.rows)) {
  const mark = ico[r.verdict.split('(')[0]] || (r.verdict.startsWith('부분')?'🟡':'•');
  console.log(`${mark} ${id} · ${r.name}`);
  console.log(`    판정: ${r.verdict}`);
  console.log(`    실측: ${r.detail}`);
  console.log(`    독립검증 연결: ${r.independent_verify_link}`);
  console.log('');
}
console.log('측정 캘린더:', JSON.stringify(baseline.measure_calendar));
