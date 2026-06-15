#!/usr/bin/env node
// mistake-promoter.mjs — 오답 클러스터 자동 승격 엔진 (자율 증류 사다리)
//
// 매일 04:10 KST cron 실행 (재발 카운터 03:30 → 체크리스트 03:45 → 승격 04:10).
//
// 동작 흐름:
//   ① 입력: ~/jarvis/runtime/state/mistake-recurrence.json 의 top_clusters (빈도순 최대 10개)
//      — recurrence-audit.sh 가 매일 03:30 생성. 파일 부재 시 audit 1회 재실행으로 복구.
//   ② 판정: llm-gateway.sh 경유 sonnet 1콜 — 클러스터별 {skip|tier_a|tier_b|tier_c}
//      + tier_a 는 룰 블록 텍스트 생성 (쉬운말 · BLOCKING 톤 · 출처 클러스터 ID 명기)
//   ③ tier_a 적용: 적용 전 haiku 시뮬 1콜 (룰 주입 시 교정 행동 YES/NO) —
//      YES → ~/.claude/rules/jarvis-autolearn.md 에 블록 append (30개 초과 시 가장
//      오래된 블록을 backups/autolearn-archive.md 로 이동) / NO → 보류 + retro 통보
//   ④ tier_b → dev-queue(task-store.mjs enqueue) 제안 / tier_c → retro 통보 / 공통 info 통보
//   ⑤ 멱등성: ledger/promoter-ledger.jsonl 에 클러스터 ID별 최종 처리 기록 — 재처리 금지
//   ⑥ 비용 상한: LLM 최대 3콜/실행 (sonnet 판정 1 + haiku 시뮬 최대 2) — 초과 분기 없음
//
// 안전 원칙:
//   - LLM 호출은 반드시 llm-gateway.sh 경유 (격리 장수명 토큰 자동 주입 — 메인 credentials 미사용)
//   - Discord 송출은 discord-route.sh 의 discord_route 함수만 사용 (1h dedup 내장)
//   - 실패해도 다른 크론에 영향 없도록 최상위 try/catch + exit code 관리
//
// 옵션:
//   --dry-run                 LLM·쓰기·송출 없이 후보 목록만 출력
//   PROMOTER_MAX_APPLY=N      실행당 tier_a 적용 상한 (기본 1)
//   PROMOTER_MAX_LLM_CALLS=N  실행당 LLM 호출 상한 (기본 3)

import {
  readFileSync, writeFileSync, appendFileSync, existsSync,
  mkdirSync, mkdtempSync, rmSync,
} from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { createHash } from 'node:crypto';

// ─── 경로 상수 (하드코딩 금지 — 환경변수 우선) ───
const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const INFRA = process.env.JARVIS_INFRA_HOME || join(HOME, 'jarvis', 'infra');
const REPORT_FILE = join(BOT_HOME, 'state', 'mistake-recurrence.json');
const AUDIT_SH = join(INFRA, 'scripts', 'mistake-recurrence-audit.sh');
const LEDGER_FILE = join(BOT_HOME, 'ledger', 'promoter-ledger.jsonl');
// PROMOTER_RULES_FILE: 테스트/검증용 경로 재정의 (샌드박스 검증 시 실제 rules 디렉토리 오염 방지)
const RULES_FILE = process.env.PROMOTER_RULES_FILE || join(HOME, '.claude', 'rules', 'jarvis-autolearn.md');
const ARCHIVE_FILE = join(BOT_HOME, 'backups', 'autolearn-archive.md');
const GATEWAY_SH = join(INFRA, 'lib', 'llm-gateway.sh');
const DISCORD_ROUTE_SH = join(INFRA, 'lib', 'discord-route.sh');
const TASK_STORE_MJS = join(INFRA, 'lib', 'task-store.mjs');

// ─── 정책 상수 ───
const MAX_LLM_CALLS = parseInt(process.env.PROMOTER_MAX_LLM_CALLS || '3', 10); // ⑥ 비용 상한
const MAX_APPLY = parseInt(process.env.PROMOTER_MAX_APPLY || '1', 10);          // 실행당 룰 적용 상한
const MAX_ACTIVE_BLOCKS = 30;            // autolearn 활성 블록 상한 — 초과분은 아카이브 이동
const REPORT_FRESH_HOURS = 26;           // 리포트 신선도 경고 임계 (03:30 생성 + 여유)
const MODEL_JUDGE = 'claude-sonnet-4-6';            // ② 판정용
const MODEL_SIM = 'claude-haiku-4-5-20251001';      // ③ 시뮬용
// 최종 상태 — 이 상태로 ledger 에 기록된 클러스터는 재처리 금지 (⑤ 멱등성)
const FINAL_STATUSES = new Set(['applied', 'held_sim_no', 'proposed_dev_queue', 'proposed_retro', 'skip']);

const DRY_RUN = process.argv.includes('--dry-run');
let llmCalls = 0; // 실행당 LLM 호출 카운터

// ─── 유틸 ───
// KST ISO 타임스탬프 (UTC 표기 금지 — jarvis 시간 정책)
function nowKST() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().replace(/\.\d+Z$/, '+09:00');
}
function todayKST() { return nowKST().slice(0, 10); }
function log(msg) { console.log(`[${nowKST()}] ${msg}`); }

// 클러스터 안정 ID — sha256(시드)[:16] (임베딩 캐시 키 규약과 동일 해시 함수)
function clusterId(seed) {
  return 'cl-' + createHash('sha256').update(seed, 'utf-8').digest('hex').slice(0, 16);
}

// discord_route data_kv 값 정화 — 구분자(콤마·등호)와 따옴표·개행 제거
function kvSanitize(s) {
  return String(s).replace(/[,="\n\r]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 120);
}

// ─── LLM 호출 (llm-gateway.sh 경유 — 격리 토큰은 게이트웨이가 자동 주입) ───
function gatewayCall({ prompt, system, model, timeout = 240 }) {
  if (llmCalls >= MAX_LLM_CALLS) {
    throw new Error(`LLM 호출 상한(${MAX_LLM_CALLS}콜/실행) 도달 — 비용 가드 발동`);
  }
  llmCalls += 1;
  const dir = mkdtempSync(join(tmpdir(), 'mistake-promoter-'));
  const pFile = join(dir, 'prompt.txt');
  const sFile = join(dir, 'system.txt');
  const oFile = join(dir, 'out.json');
  writeFileSync(pFile, prompt, 'utf-8');
  writeFileSync(sFile, system || '', 'utf-8');
  // 프롬프트는 파일 경유로 전달 — 셸 인젝션 차단
  const snippet = [
    'set -euo pipefail',
    'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"',
    `source "${GATEWAY_SH}"`,
    'llm_call --prompt "$(cat "$PROMOTER_PROMPT_FILE")" \\',
    '  --system "$(cat "$PROMOTER_SYSTEM_FILE")" \\',
    '  --model "$PROMOTER_MODEL" --timeout "$PROMOTER_TIMEOUT" \\',
    '  --output "$PROMOTER_OUT_FILE"',
  ].join('\n');
  try {
    execFileSync('/bin/bash', ['-c', snippet], {
      env: {
        ...process.env,
        JARVIS_BATCH_MODE: '1',        // 배치 모드 — 토큰 절감 플래그
        TASK_ID: 'mistake-promoter',
        PROMOTER_PROMPT_FILE: pFile,
        PROMOTER_SYSTEM_FILE: sFile,
        PROMOTER_OUT_FILE: oFile,
        PROMOTER_MODEL: model,
        PROMOTER_TIMEOUT: String(timeout),
      },
      stdio: ['ignore', 'inherit', 'inherit'],
      timeout: (timeout + 30) * 1000,
    });
    const out = JSON.parse(readFileSync(oFile, 'utf-8'));
    return String(out.result ?? '');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ─── Discord 통보 (discord-route.sh 의 discord_route 만 사용) ───
function notify(severity, title, kvObj) {
  if (DRY_RUN) { log(`[DRY] discord_route ${severity} "${title}"`); return; }
  const kv = Object.entries(kvObj)
    .map(([k, v]) => `${kvSanitize(k)}=${kvSanitize(v)}`)
    .join(',');
  const snippet = `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; source "${DISCORD_ROUTE_SH}"; discord_route "$1" "$2" "$3"`;
  try {
    execFileSync('/bin/bash', ['-c', snippet, 'bash', severity, title, kv], {
      stdio: ['ignore', 'inherit', 'inherit'], timeout: 30_000,
    });
  } catch (e) {
    log(`WARN: Discord 통보 실패 (${severity}/${title}): ${e.message}`); // 통보 실패는 비치명
  }
}

// ─── ledger (⑤ 멱등성) ───
function loadProcessedIds() {
  const done = new Set();
  if (!existsSync(LEDGER_FILE)) return done;
  for (const line of readFileSync(LEDGER_FILE, 'utf-8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const d = JSON.parse(line);
      if (d.type === 'cluster' && FINAL_STATUSES.has(d.status)) done.add(d.cluster_id);
    } catch { /* 손상 라인 무시 */ }
  }
  return done;
}
function ledgerAppend(entry) {
  if (DRY_RUN) { log(`[DRY] ledger: ${JSON.stringify(entry)}`); return; }
  mkdirSync(join(BOT_HOME, 'ledger'), { recursive: true });
  appendFileSync(LEDGER_FILE, JSON.stringify({ ts: nowKST(), ...entry }) + '\n', 'utf-8');
}

// ─── jarvis-autolearn.md 블록 관리 ───
const RULES_HEADER = `# jarvis-autolearn — 오답 클러스터 자동 승격 행동 룰

> ⚠️ **자동 관리 파일** — \`mistake-promoter.mjs\` 가 생성·관리합니다. **블록 단위 삭제로 롤백**하십시오.
> 블록 경계: \`<!-- AL:BEGIN id=... -->\` ~ \`<!-- AL:END id=... -->\`
> 활성 블록 ${MAX_ACTIVE_BLOCKS}개 초과 시 가장 오래된 블록은 \`~/jarvis/runtime/backups/autolearn-archive.md\` 로 이동됩니다.
> 처리 원장: \`~/jarvis/runtime/ledger/promoter-ledger.jsonl\`
`;

// 활성 블록 30개 초과 시 가장 오래된(파일 상단) 블록을 아카이브로 이동
function rotateBlocks(content) {
  const blockRe = /<!-- AL:BEGIN id=[^>]+-->[\s\S]*?<!-- AL:END id=[^>]+-->\n?/g;
  const blocks = content.match(blockRe) || [];
  let moved = 0;
  while (blocks.length - moved > MAX_ACTIVE_BLOCKS) {
    const oldest = blocks[moved]; // append 순서상 첫 블록 = 가장 오래된 블록
    mkdirSync(join(BOT_HOME, 'backups'), { recursive: true });
    if (!existsSync(ARCHIVE_FILE)) {
      writeFileSync(ARCHIVE_FILE, '# autolearn-archive — 승격 룰 보관소 (활성 30개 초과분 이동)\n', 'utf-8');
    }
    appendFileSync(ARCHIVE_FILE, `\n<!-- 아카이브 이동: ${nowKST()} -->\n${oldest}`, 'utf-8');
    content = content.replace(oldest, '');
    moved += 1;
  }
  if (moved > 0) log(`autolearn 회전: 오래된 블록 ${moved}개 → ${ARCHIVE_FILE}`);
  return content;
}

// tier_a 룰 블록 적용 — 반환: 'applied' | 'already'
function applyRuleBlock(cid, title, ruleBlock, cluster) {
  mkdirSync(dirname(RULES_FILE), { recursive: true });
  let content = existsSync(RULES_FILE) ? readFileSync(RULES_FILE, 'utf-8') : RULES_HEADER;
  if (content.includes(`AL:BEGIN id=${cid} `)) return 'already'; // 이중 적용 가드
  const block = [
    '',
    `<!-- AL:BEGIN id=${cid} date=${todayKST()} -->`,
    `## [자동학습] ${title} (BLOCKING · 자동 등재 ${todayKST()})`,
    '',
    ruleBlock.trim(),
    '',
    `- 출처 클러스터: \`${cid}\` (최근 7일 재발 ${cluster.size}건 · 시드: "${cluster.seed}")`,
    `<!-- AL:END id=${cid} -->`,
    '',
  ].join('\n');
  content = rotateBlocks(content + block);
  if (DRY_RUN) { log(`[DRY] 룰 블록 적용 생략: ${cid}`); return 'applied'; }
  writeFileSync(RULES_FILE, content, 'utf-8');
  return 'applied';
}

// ─── dev-queue 제안 (task-store.mjs enqueue — jarvis-auditor.sh 와 동일 인터페이스) ───
function enqueueDevQueue(cid, title, promptText) {
  const id = `mistake-promoter-${cid}`;
  if (DRY_RUN) { log(`[DRY] dev-queue enqueue 생략: ${id}`); return { action: 'dry' }; }
  const out = execFileSync(process.execPath, [
    TASK_STORE_MJS, 'enqueue',
    '--id', id,
    '--title', title,
    '--prompt', promptText,
    '--priority', 'low',
    '--source', 'mistake-promoter',
    '--batch-id', `promoter-${todayKST()}`,
    '--type', 'code-fix',
  ], { encoding: 'utf-8', timeout: 30_000 });
  try { return JSON.parse(out.trim().split('\n').pop()); } catch { return { action: 'unknown' }; }
}

// ─── ② sonnet 판정 ───
function judgeClusters(candidates) {
  const clustersForPrompt = candidates.map((c) => ({
    id: c.id, size: c.size, seed: c.seed, members: c.members.slice(0, 8), // 토큰 절약 — 멤버 8개 캡
  }));
  const system = [
    '너는 Jarvis 학습 루프의 승격 심사관이다. 반복 실수 클러스터를 보고 등급을 판정한다.',
    '출력은 반드시 JSON 배열 하나만 — 설명·마크다운 코드펜스 금지.',
  ].join('\n');
  const prompt = `다음은 최근 7일간 반복된 실수(오답) 클러스터 목록이다 (빈도순).

${JSON.stringify(clustersForPrompt, null, 1)}

각 클러스터를 아래 기준으로 판정하라:
- "tier_a": 시스템 프롬프트 행동 룰 1개로 교정 가능한 반복 행동 패턴 (빈도 높고 룰 텍스트만으로 효과 기대)
- "tier_b": 룰만으로 부족 — 코드/스크립트/자동 가드 구현 작업이 필요 (개발 큐 제안 가치)
- "tier_c": 당장 조치 불요 — 주간 회고 안건으로 기록할 가치
- "skip": 잡음·일회성·이미 다른 가드가 커버

출력 스키마 (JSON 배열, 각 원소):
{
 "id": "<클러스터 id 그대로>",
 "tier": "skip|tier_a|tier_b|tier_c",
 "title": "<20자 내외 한국어 제목>",
 "reason": "<판정 근거 1문장>",
 "rule_block": "<tier_a 만. 400자 이내 행동 룰 본문. 조건: ① 어려운 용어 없이 쉬운 말 ② BLOCKING 톤(금지/필수 명령형) ③ 본문 안에 출처 클러스터 ID(${candidates.map((c) => c.id).join(', ')} 중 해당 id)를 명기 ④ 자기검열 체크 1줄 포함>",
 "scenario": "<tier_a 만. 이 실수가 재현되는 사용자 요청 상황 1~2문장>",
 "proposal": "<tier_b/tier_c 만. 제안 작업/안건 2문장 이내>"
}`;
  const raw = gatewayCall({ prompt, system, model: MODEL_JUDGE, timeout: 300 });
  // JSON 배열 강건 파싱 — 코드펜스/서두 텍스트 방어
  const start = raw.indexOf('[');
  const end = raw.lastIndexOf(']');
  if (start < 0 || end <= start) throw new Error(`판정 응답 파싱 실패: ${raw.slice(0, 200)}`);
  return JSON.parse(raw.slice(start, end + 1));
}

// ─── ③ haiku 시뮬 — 룰 주입 시 교정 행동 YES/NO ───
function simulateRule(ruleBlock, scenario) {
  const prompt = `다음은 어시스턴트가 과거 반복한 실수가 재현되는 상황이다:
"${scenario}"

아래 행동 룰이 어시스턴트의 시스템 프롬프트에 주입되어 있다:
---
${ruleBlock}
---

질문: 이 룰이 주입된 상태라면 어시스턴트가 위 상황에서 교정된 행동(실수 회피)을 보일 것으로 판단되는가?
첫 줄에 YES 또는 NO 한 단어로만 답하라. 둘째 줄에 근거 1문장.`;
  const raw = gatewayCall({ prompt, system: '', model: MODEL_SIM, timeout: 120 });
  const first = raw.trim().split('\n')[0].trim().toUpperCase();
  return { pass: first.startsWith('YES'), raw: raw.trim().slice(0, 300) };
}

// ─── 메인 ───
function main() {
  log(`mistake-promoter 시작 (dry_run=${DRY_RUN}, max_llm=${MAX_LLM_CALLS}, max_apply=${MAX_APPLY})`);

  // ① 입력 확보 — 리포트 부재 시 recurrence-audit 1회 재실행으로 복구
  if (!existsSync(REPORT_FILE)) {
    log(`리포트 부재 — recurrence-audit 1회 실행으로 생성 시도: ${AUDIT_SH}`);
    try {
      execFileSync('/bin/bash', [AUDIT_SH], {
        env: { ...process.env, BOT_HOME }, stdio: ['ignore', 'inherit', 'inherit'], timeout: 300_000,
      });
    } catch (e) { log(`WARN: audit 실행 실패: ${e.message}`); }
  }
  if (!existsSync(REPORT_FILE)) {
    log('ERROR: mistake-recurrence.json 생성 불가 — 종료');
    process.exit(1);
  }
  const report = JSON.parse(readFileSync(REPORT_FILE, 'utf-8'));
  const ageHours = (Date.now() - new Date(report.generated_at).getTime()) / 3600e3;
  if (ageHours > REPORT_FRESH_HOURS) {
    log(`WARN: 리포트 신선도 경고 — ${ageHours.toFixed(1)}h 경과 (임계 ${REPORT_FRESH_HOURS}h). 03:30 크론 점검 필요`);
  }

  // top_clusters 는 이미 빈도(size)순 최대 10개 — 안정 ID 부여
  const clusters = (report.top_clusters || []).map((c) => ({ ...c, id: clusterId(c.seed) }));
  const processed = loadProcessedIds();
  const candidates = clusters.filter((c) => !processed.has(c.id));
  log(`클러스터 ${clusters.length}개 중 미처리 후보 ${candidates.length}개 (ledger 멱등 필터)`);

  const counters = { applied: 0, held: 0, dev_queue: 0, retro: 0, skip: 0, deferred: 0 };

  if (candidates.length === 0) {
    log('처리할 신규 클러스터 없음 — metrics 만 기록 후 종료');
    ledgerAppend({ type: 'run_metrics', report_generated_at: report.generated_at, clusters_total: clusters.length, candidates: 0, llm_calls: 0, ...counters });
    return;
  }
  if (DRY_RUN) {
    candidates.forEach((c) => log(`[DRY] 후보: ${c.id} size=${c.size} seed="${c.seed}"`));
    log('[DRY] LLM 판정·적용·통보 생략 — 종료');
    return;
  }

  // ② LLM 판정 (sonnet 1콜)
  const verdicts = judgeClusters(candidates);
  const byId = new Map(candidates.map((c) => [c.id, c]));

  // tier_a 우선 처리(빈도순) — 시뮬 콜은 적용 가능한 만큼만 소비 (비용 가드)
  const ordered = verdicts
    .filter((v) => byId.has(v.id))
    .sort((a, b) => (byId.get(b.id).size - byId.get(a.id).size));

  for (const v of ordered) {
    const cluster = byId.get(v.id);
    const base = { type: 'cluster', cluster_id: v.id, seed: cluster.seed, size: cluster.size, tier: v.tier, reason: v.reason || '' };

    if (v.tier === 'tier_a') {
      if (counters.applied >= MAX_APPLY) {
        log(`tier_a 적용 상한(${MAX_APPLY}) 도달 — ${v.id} 다음 실행으로 이연 (ledger 미기록)`);
        counters.deferred += 1;
        continue;
      }
      if (llmCalls >= MAX_LLM_CALLS) {
        log(`LLM 상한 도달 — ${v.id} 시뮬 불가, 다음 실행으로 이연`);
        counters.deferred += 1;
        continue;
      }
      if (!v.rule_block || !v.scenario) {
        log(`WARN: ${v.id} tier_a 인데 rule_block/scenario 누락 — 보류 처리`);
        ledgerAppend({ ...base, status: 'held_sim_no', sim: 'missing rule_block/scenario' });
        counters.held += 1;
        continue;
      }
      // ③ 적용 전 시뮬 (haiku 1콜) — 교정 행동 미확인 시 적용 보류
      const sim = simulateRule(v.rule_block, v.scenario);
      if (!sim.pass) {
        log(`시뮬 NO — ${v.id} 적용 보류 + retro 통보`);
        ledgerAppend({ ...base, status: 'held_sim_no', sim: sim.raw });
        notify('retro', `오답 승격 보류 (시뮬 NO) ${todayKST()}`, {
          클러스터: v.id, 제목: v.title || cluster.seed, 재발: `${cluster.size}건`, 사유: '시뮬에서 교정 행동 미확인',
        });
        counters.held += 1;
        continue;
      }
      const res = applyRuleBlock(v.id, v.title || cluster.seed.slice(0, 30), v.rule_block, cluster);
      ledgerAppend({ ...base, status: 'applied', sim: sim.raw, rule_title: v.title || '', apply_result: res });
      counters.applied += 1;
      log(`tier_a 적용 완료 (${res}): ${v.id} → ${RULES_FILE}`);
    } else if (v.tier === 'tier_b') {
      const promptText = [
        '다음 반복 실수 클러스터에 대한 구조적 가드(코드/스크립트/자동 검사)를 설계·구현하라.',
        '',
        `클러스터 ID: ${v.id} (최근 7일 재발 ${cluster.size}건)`,
        `대표 시드: ${cluster.seed}`,
        `멤버 예시: ${cluster.members.slice(0, 5).join(' / ')}`,
        `제안: ${v.proposal || '(없음)'}`,
        '',
        '수정 시 기존 동작 파괴 금지.',
        // 2026-06-12 사고: "Discord에 결과 보고"라는 자유 지시만 주자 야간 에이전트가 monitoring.json에서
        // jarvis-boram(가족 채널) 웹훅을 임의로 골라 내부 완료 임베드를 오발송. 보고 명령을 정확히 고정한다.
        '완료 보고는 반드시 아래 명령 한 가지만 사용한다 (monitoring.json 웹훅 직접 호출·임의 채널 선택 절대 금지):',
        `source ~/jarvis/infra/lib/discord-route.sh && discord_route info "오답승격 가드 구현 완료 ${v.id}" "클러스터=${v.id},결과=<한줄요약>"`,
      ].join('\n');
      const q = enqueueDevQueue(v.id, `[오답승격 tier_b] ${v.title || cluster.seed.slice(0, 40)}`, promptText);
      ledgerAppend({ ...base, status: 'proposed_dev_queue', dev_queue_action: q.action || 'unknown' });
      counters.dev_queue += 1;
      log(`tier_b dev-queue 제안 (${q.action}): ${v.id}`);
    } else if (v.tier === 'tier_c') {
      ledgerAppend({ ...base, status: 'proposed_retro' });
      notify('retro', `오답 회고 안건 (tier_c) ${todayKST()} ${v.id}`, {
        클러스터: v.id, 제목: v.title || cluster.seed, 재발: `${cluster.size}건`, 제안: v.proposal || '-',
      });
      counters.retro += 1;
      log(`tier_c retro 안건 등재: ${v.id}`);
    } else {
      ledgerAppend({ ...base, status: 'skip' });
      counters.skip += 1;
    }
  }

  // 일일 metrics 1줄 append (주간 히트맵·doctor 소비용)
  ledgerAppend({
    type: 'run_metrics', report_generated_at: report.generated_at,
    clusters_total: clusters.length, candidates: candidates.length, llm_calls: llmCalls, ...counters,
  });

  // ④ 공통 info 통보 (제목에 날짜 포함 — discord-route 1h dedup 회피)
  notify('info', `오답 자동 승격 결과 ${todayKST()}`, {
    후보: `${candidates.length}건`, 룰적용: `${counters.applied}건`, 보류: `${counters.held}건`,
    개발큐: `${counters.dev_queue}건`, 회고: `${counters.retro}건`, 스킵: `${counters.skip}건`,
    LLM콜: `${llmCalls}회`,
  });
  log(`완료 — applied=${counters.applied} held=${counters.held} dev_queue=${counters.dev_queue} retro=${counters.retro} skip=${counters.skip} deferred=${counters.deferred} llm_calls=${llmCalls}`);
}

try {
  main();
} catch (e) {
  log(`ERROR: ${e.message}`);
  process.exit(1);
}
