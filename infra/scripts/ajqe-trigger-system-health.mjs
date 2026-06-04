#!/usr/bin/env node
/**
 * ajqe-trigger-system-health.mjs v5.3 — Active Jarvis Question Engine: 시스템 자가치유 trigger
 *
 * v5.3 B 철학 (2026-05-07 주인님 정정):
 *   "주인님이 일일이 결재하지 않아도 자비스가 알아서 처리하고, 결과만 우아하게 보고한다."
 *
 *   - 가역적·안전한 신호 → 자동 액션 실행 + 결과 메시지 (질문 X)
 *   - 비가역·위험 신호 → 결재 요청 메시지 (현재 system-health에는 없음 — 모두 안전)
 *   - 모든 자동 실행은 백업 후 진행. "되돌려" 답글로 롤백 가능.
 *   - 같은 신호 24h 쿨다운 (id에 yyyy-MM-dd 포함).
 *
 * 신호별 자동 액션 매트릭스:
 *   paused-crons-stale (3일+) → effective-tasks.json enabled:false + cron-status 정리
 *   rag-indexer-stale (임계+)  → 조사 보고만 (crontab 자동 편집은 위험 — 결재 모드)
 *   discord-bot-unhealthy      → bot-preflight.sh 자동 재시작
 *   cron-failure-spike         → 조사 보고만 (액션 결정은 주인님)
 *   crash-count > 0            → 조사 보고만
 *   health-check-stale         → 조사 보고만 (cron 자동 편집 회피)
 */
import { readFileSync, existsSync, writeFileSync, statSync, appendFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { execSync } from 'node:child_process';

const HOME = homedir();
const QUEUE_PATH = join(HOME, 'jarvis/runtime/state/ajqe-question-queue.jsonl');
const HEALTH_PATH = join(HOME, 'jarvis/runtime/state/health.json');
const CRON_STATUS_PATH = join(HOME, 'jarvis/runtime/state/cron-status.json');
const CRON_DAILY_PATH = join(HOME, 'jarvis/runtime/state/cron-master-daily.jsonl');
const EFFECTIVE_TASKS_PATH = join(HOME, '.jarvis/config/effective-tasks.json');
const ACTIONS_PATH = join(HOME, 'jarvis/runtime/state/ajqe-actions.jsonl');
const COOLDOWN_PATH = join(HOME, 'jarvis/runtime/state/ajqe-signal-cooldown.json');
const BACKUP_DIR = join(HOME, 'jarvis/runtime/state/ajqe-backups');
const LOGS_DIR = join(HOME, 'jarvis/runtime/logs');

const DRY_RUN = process.argv.includes('--dry-run');
const TODAY = new Date(Date.now() + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);

const THRESHOLDS = {
  pausedCronMinDays: 3,
  fail24hAbsolute: 200,
  fail24hSpikeFactor: 1.5,
  healthStaleMinutes: 30,
  ragLogStaleHours: 6,
  crashCountMax: 0,
};

// ── 헬퍼 ──────────────────────────────────────────────────────────────────
function loadJSON(path, fallback) {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, 'utf-8')); } catch { return fallback; }
}
function loadJSONL(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8').split('\n').filter(l => l.trim())
    .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}
function loadExistingQueueIds() {
  return new Set(loadJSONL(QUEUE_PATH).map(q => q.id));
}
function isOnCooldown(signal) {
  if (!signal) return false;
  const cd = loadJSON(COOLDOWN_PATH, {});
  return cd[signal] && new Date(cd[signal]).getTime() > Date.now();
}
function daysSince(iso) { return (Date.now() - new Date(iso).getTime()) / 86400000; }

function backupFile(srcPath, tag) {
  if (!existsSync(srcPath)) return null;
  mkdirSync(BACKUP_DIR, { recursive: true });
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const dst = join(BACKUP_DIR, `${tag}-${ts}.bak`);
  copyFileSync(srcPath, dst);
  return dst;
}

function recordAction(record) {
  mkdirSync(dirname(ACTIONS_PATH), { recursive: true });
  appendFileSync(ACTIONS_PATH, JSON.stringify({
    ts: new Date().toISOString(),
    source: 'trigger-system-health-auto',
    ...record,
  }) + '\n');
}

// 보고형 메시지 빌더 (B 철학: 자동 실행 후 결과 보고)
function makeReport({ id, signal, domain, ssot, headline, what_did, evidence, reversal, requires_attention }) {
  const reversalLine = reversal ? `\n\n↩️ 되돌리려면 \`되돌려\` 답글 — ${reversal}` : '';
  const attentionLine = requires_attention ? `\n\n${requires_attention}` : '';
  return {
    id, trigger: 'systemHealth-v5.3', signal,
    domain: domain || 'ops', ssot: ssot || 'system-health',
    ssotPath: HEALTH_PATH, priority: 0, skipLlmRefine: true,
    purpose: '자비스 자가치유 — 안전 액션 자동 실행 후 결과 보고',
    questionText: `${headline}

📋 **자비스가 한 일**: ${what_did}${evidence ? `\n\n🔎 **근거**:\n${evidence}` : ''}${attentionLine}${reversalLine}`,
    createdAt: new Date().toISOString(),
    status: 'pending',
  };
}

// 결재요청 메시지 빌더 (위험 영역 — 자동 실행 안 하고 주인님 결정 대기)
function makeAttention({ id, signal, domain, ssot, what, options, why }) {
  return {
    id, trigger: 'systemHealth-v5.3-attention', signal,
    domain: domain || 'ops', ssot: ssot || 'system-health',
    ssotPath: HEALTH_PATH, priority: 0, skipLlmRefine: true,
    purpose: '자비스 자가치유 — 위험 영역, 주인님 결재 필요',
    questionText: `🟡 **주인님 결재 필요**

${what}${why ? `\n\n_${why}_` : ''}

**선택**:
${options}

답글로 한 단어만 적어주십시오.`,
    createdAt: new Date().toISOString(),
    status: 'pending',
  };
}

const questions = [];

// ── 1. paused 크론 자동 정리 (안전 — 가역적, 백업 후) ─────────────
function checkPausedCrons() {
  const cs = loadJSON(CRON_STATUS_PATH, { paused: [] });
  const stale = (cs.paused || []).filter(p => daysSince(p.since) >= THRESHOLDS.pausedCronMinDays);
  if (stale.length === 0) return;

  if (DRY_RUN) {
    questions.push(makeReport({
      id: `health-paused-crons-${TODAY}`, signal: 'paused-crons-stale',
      domain: 'ops', ssot: 'cron-status',
      headline: `🩹 **자가치유: paused 크론 ${stale.length}개 (DRY RUN)**`,
      what_did: '(dry-run — 실제 실행 안 함)',
      evidence: stale.slice(0, 5).map(p => `- \`${p.id}\` (${Math.floor(daysSince(p.since))}일 방치)`).join('\n'),
    }));
    return;
  }

  // 실제 실행
  const ids = stale.map(p => p.id);
  const tasksBackup = backupFile(EFFECTIVE_TASKS_PATH, 'effective-tasks');
  const statusBackup = backupFile(CRON_STATUS_PATH, 'cron-status');
  let disabledCount = 0;
  try {
    const cfg = loadJSON(EFFECTIVE_TASKS_PATH, { tasks: [] });
    for (const t of cfg.tasks || []) {
      if (ids.includes(t.id) && t.enabled !== false) {
        t.enabled = false;
        t.disabledAt = new Date().toISOString();
        t.disabledReason = `자비스 자가치유 (v5.3) — ${Math.floor(daysSince(stale.find(s => s.id === t.id).since))}일 paused 방치`;
        disabledCount++;
      }
    }
    writeFileSync(EFFECTIVE_TASKS_PATH, JSON.stringify(cfg, null, 2));
    cs.paused = (cs.paused || []).filter(p => !ids.includes(p.id));
    cs.lastSelfHeal = new Date().toISOString();
    writeFileSync(CRON_STATUS_PATH, JSON.stringify(cs, null, 2));
    recordAction({
      action: 'auto-disable-paused-crons', signal: 'paused-crons-stale',
      disabledCount, ids, backups: [tasksBackup, statusBackup],
    });
  } catch (e) {
    questions.push(makeReport({
      id: `health-paused-crons-${TODAY}`, signal: 'paused-crons-stale',
      headline: `❌ **자가치유 실패: paused 크론**`,
      what_did: `자동 처리 시도했으나 오류: ${e.message.slice(0, 200)}`,
      evidence: '', reversal: null,
    }));
    return;
  }

  questions.push(makeReport({
    id: `health-paused-crons-${TODAY}`, signal: 'paused-crons-stale',
    domain: 'ops', ssot: 'cron-status',
    headline: `🩹 **자가치유: paused 크론 ${disabledCount}개 정리**`,
    what_did: `${THRESHOLDS.pausedCronMinDays}일+ 방치된 ${disabledCount}개 크론을 \`effective-tasks.json\`에서 \`enabled:false\`로 영구 비활성화. \`cron-status.json\` paused 배열에서도 제거.`,
    evidence: stale.slice(0, 5).map(p => `- \`${p.id}\` (${Math.floor(daysSince(p.since))}일 방치)`).join('\n'),
    reversal: `\`${tasksBackup}\` 에서 복원`,
  }));
}

// ── 2. RAG 인덱서 stale → 조사 보고 (자동 disable은 crontab 편집이라 회피) ──
function checkRagIndexer() {
  const RAG_THRESHOLDS = {
    // 'rag-conversations.log': 2,  // 비활성화 2026-05-07 — claude-sessions 인덱싱 차단(LanceDB bloat). 크론 영구 disabled.
    'rag-compact.log': 26,
    'rag-bug-detector.log': 8,
  };
  for (const [fname, threshold] of Object.entries(RAG_THRESHOLDS)) {
    const p = join(LOGS_DIR, fname);
    if (!existsSync(p)) continue;
    const mtime = statSync(p).mtime;
    const hoursStale = (Date.now() - mtime.getTime()) / 3600000;
    if (hoursStale < threshold) continue;
    const indexerName = fname.replace(/\.log$/, '');
    // 마지막 5줄 미리보기 (조사 자동 포함)
    let preview = '';
    try {
      const tail = readFileSync(p, 'utf-8').split('\n').filter(l => l.trim()).slice(-5);
      preview = tail.join('\n').slice(0, 400);
    } catch {}
    questions.push(makeAttention({
      id: `health-rag-${indexerName}-${TODAY}`,
      signal: 'rag-indexer-stale',
      domain: 'ops', ssot: fname,
      what: `RAG 인덱서 \`${indexerName}\`이 ${Math.floor(hoursStale)}시간째 멈춰있습니다 (정상 ${threshold}h 이내).\n\n**최근 로그 미리보기**:\n\`\`\`\n${preview}\n\`\`\``,
      options: `- **조사** — 깊은 진단 (관련 cron·디렉토리·프로세스 점검)\n- **끄기** — crontab에서 영구 disable (수동 절차 안내)\n- **무시** — 24h 쿨다운`,
      why: 'crontab 편집은 위험해서 자동 실행 안 합니다. 결정 부탁드립니다.',
    }));
  }
}

// ── 3. discord-bot 비정상 → 자동 재시작 ──────────────────────────
function checkSystemHealth() {
  const h = loadJSON(HEALTH_PATH, null);
  if (!h) return;

  if (h.discord_bot && h.discord_bot !== 'healthy') {
    if (DRY_RUN) {
      questions.push(makeReport({
        id: `health-discord-${TODAY}`, signal: 'discord-bot-unhealthy',
        headline: `🩹 **자가치유: 디스코드 봇 재시작 (DRY RUN)**`,
        what_did: '(dry-run)', evidence: `\`${h.discord_bot}\` 상태`,
      }));
    } else {
      try {
        execSync('bash ~/jarvis/infra/scripts/bot-preflight.sh', { stdio: 'pipe' });
        recordAction({ action: 'auto-bot-restart', signal: 'discord-bot-unhealthy' });
        questions.push(makeReport({
          id: `health-discord-${TODAY}`, signal: 'discord-bot-unhealthy',
          headline: `🩹 **자가치유: 디스코드 봇 자동 재시작 완료**`,
          what_did: 'bot-preflight.sh 실행 → 봇 재가동.',
          evidence: `이전 상태: \`${h.discord_bot}\``,
          reversal: null,
        }));
      } catch (e) {
        questions.push(makeReport({
          id: `health-discord-${TODAY}`, signal: 'discord-bot-unhealthy',
          headline: `❌ **자가치유 실패: 봇 재시작**`,
          what_did: `bot-preflight.sh 실행 시도 실패: ${e.message.slice(0, 200)}`,
        }));
      }
    }
  }

  // crash_count, stale check은 조사 보고만
  if ((h.crash_count || 0) > THRESHOLDS.crashCountMax) {
    questions.push(makeReport({
      id: `health-crash-${TODAY}`, signal: 'crash-count',
      headline: `🟡 **자비스 crash 감지**`,
      what_did: '자동 조치 안 함 (원인 불명) — 주인님께 보고만 드립니다.',
      evidence: `crash_count: ${h.crash_count}, last_check: ${h.last_check}`,
      requires_attention: '`/investigate` 또는 `조사` 답글로 깊은 진단 가능.',
    }));
  }
}

// ── 4. 크론 실패 급증 → 조사 보고만 (자동 액션 위험) ────────────────
function checkCronFailureRate() {
  const lines = loadJSONL(CRON_DAILY_PATH);
  if (lines.length < 2) return;
  const today = lines[lines.length - 1];
  const yesterday = lines[lines.length - 2];
  const todayFail = today.fail_24h || 0;
  const yesterdayFail = yesterday.fail_24h || 1;
  const factor = todayFail / yesterdayFail;
  if (todayFail < THRESHOLDS.fail24hAbsolute && factor < THRESHOLDS.fail24hSpikeFactor) return;
  const reason = todayFail >= THRESHOLDS.fail24hAbsolute
    ? `오늘 ${todayFail}건 (임계 ${THRESHOLDS.fail24hAbsolute} 초과)`
    : `어제 ${yesterdayFail} → 오늘 ${todayFail} (${factor.toFixed(1)}배)`;
  questions.push(makeReport({
    id: `health-cron-fail-${TODAY}`, signal: 'cron-failure-spike',
    headline: `🟡 **크론 실패 비정상**`,
    what_did: '자동 조치 안 함 (어떤 크론 정확히 실패하는지 분석 필요) — 주인님께 보고만.',
    evidence: reason,
    requires_attention: '`조사` 답글로 자동 분석 가능.',
  }));
}

// ── 메인 ──────────────────────────────────────────────────────────
async function main() {
  await checkPausedCrons();
  await checkRagIndexer();
  await checkSystemHealth();
  await checkCronFailureRate();

  const existing = loadExistingQueueIds();
  const newQuestions = questions
    .filter(q => !existing.has(q.id))
    .filter(q => !isOnCooldown(q.signal));

  console.log(`# AJQE Trigger v5.3 (${new Date().toISOString()})`);
  console.log(`스캔: ${questions.length}건 | 신규: ${newQuestions.length}건`);
  if (newQuestions.length > 0) {
    for (const q of newQuestions.slice(0, 5)) {
      console.log(`  [${q.id}] ${q.signal}`);
    }
  }

  if (DRY_RUN || newQuestions.length === 0) {
    if (DRY_RUN) console.log('🧪 DRY RUN');
    return;
  }

  mkdirSync(dirname(QUEUE_PATH), { recursive: true });
  appendFileSync(QUEUE_PATH, newQuestions.map(q => JSON.stringify(q)).join('\n') + '\n');
  console.log(`✅ ${newQuestions.length}건 큐 적재`);
}

main().catch(e => { console.error(e); process.exit(1); });
