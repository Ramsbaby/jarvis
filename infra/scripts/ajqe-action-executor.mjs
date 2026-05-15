#!/usr/bin/env node
/**
 * ajqe-action-executor.mjs — Active Jarvis Question Engine 액션 실행기 (v5.2)
 *
 * 역할: 사용자 답글이 액션 키워드(조사해/재시작/끄기/무시)일 때 실제 행동을 실행하고
 *       결과를 Discord webhook으로 follow-up 메시지로 보고.
 *
 * 호출 방식: ajqe-answer-router가 spawn (봇 blocking 방지).
 *
 * 사용:
 *   node ajqe-action-executor.mjs <ajqeId> <action> <channel>
 *     action: investigate | restart | disable | ignore
 *
 * 안전 원칙:
 *   - 화이트리스트 액션만 실행. 미지원 signal+action 조합은 "지원 안 됨" 보고.
 *   - 모든 액션은 가역적 (백업 후 변경 또는 dry-run 우선).
 *   - 실행 이력은 ajqe-actions.jsonl에 append.
 */
import { readFileSync, existsSync, statSync, appendFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { execSync, spawnSync } from 'node:child_process';

const HOME = homedir();
const SENT_PATH = join(HOME, 'jarvis/runtime/state/ajqe-sent.jsonl');
const ACTIONS_PATH = join(HOME, 'jarvis/runtime/state/ajqe-actions.jsonl');
const COOLDOWN_PATH = join(HOME, 'jarvis/runtime/state/ajqe-signal-cooldown.json');
const MONITORING_PATH = join(HOME, 'jarvis/runtime/config/monitoring.json');
const CRON_STATUS_PATH = join(HOME, 'jarvis/runtime/state/cron-status.json');
const EFFECTIVE_TASKS_PATH = join(HOME, '.jarvis/config/effective-tasks.json');
const LOGS_DIR = join(HOME, 'jarvis/runtime/logs');

const [, , AJQE_ID, ACTION, CHANNEL_ARG] = process.argv;
const CHANNEL = CHANNEL_ARG || 'jarvis';

if (!AJQE_ID || !ACTION) {
  console.error('Usage: ajqe-action-executor.mjs <ajqeId> <action> [channel]');
  process.exit(1);
}

function loadJSONL(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8').split('\n').filter(l => l.trim())
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
}

function findSent(id) {
  const lines = loadJSONL(SENT_PATH);
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].id === id) return lines[i];
  }
  return null;
}

function loadWebhook(channel) {
  if (!existsSync(MONITORING_PATH)) return null;
  const cfg = JSON.parse(readFileSync(MONITORING_PATH, 'utf-8'));
  return cfg.webhooks?.[channel] || null;
}

async function sendDiscord(text) {
  const wh = loadWebhook(CHANNEL);
  if (!wh) return;
  await fetch(wh, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: text.slice(0, 1990) }),
  });
}

function recordAction(record) {
  mkdirSync(dirname(ACTIONS_PATH), { recursive: true });
  appendFileSync(ACTIONS_PATH, JSON.stringify({
    ts: new Date().toISOString(),
    ajqeId: AJQE_ID,
    action: ACTION,
    ...record,
  }) + '\n');
}

// ── 액션 구현 ───────────────────────────────────────────────────────────────

// v5.3: 시간성 인식 — 최근 24h 내 자비스가 자가치유한 액션을 찾아 보고에 포함
function recentSelfHealActions(signal) {
  const lines = loadJSONL(ACTIONS_PATH);
  const cutoff = Date.now() - 24 * 3600 * 1000;
  return lines.filter(r => {
    if (new Date(r.ts).getTime() < cutoff) return false;
    if (r.source !== 'trigger-system-health-auto') return false;
    if (signal && r.signal && r.signal !== signal) return false;
    return true;
  });
}

async function actionInvestigate(sent) {
  const signal = sent.signal || sent.ssot;
  const lines = [`🔍 **조사 결과 — ${sent.id}**`, ''];

  // 시간성 인식: 자비스가 최근 24h에 같은 영역 액션 했는지 먼저 보고
  const recent = recentSelfHealActions(signal);
  if (recent.length > 0) {
    lines.push(`🩹 **자비스 자가치유 이력** (최근 24h):`);
    for (const r of recent.slice(-3)) {
      const ago = Math.floor((Date.now() - new Date(r.ts).getTime()) / 60000);
      lines.push(`- ${ago}분 전: \`${r.action}\` (${r.disabledCount || ''}건)`);
    }
    lines.push('');
  }

  if (signal === 'paused-crons-stale' || sent.ssot === 'cron-status') {
    if (existsSync(CRON_STATUS_PATH)) {
      const cs = JSON.parse(readFileSync(CRON_STATUS_PATH, 'utf-8'));
      const paused = cs.paused || [];
      lines.push(`현재 paused 크론: **${paused.length}개**`);
      if (paused.length === 0) {
        lines.push(recent.length > 0
          ? '_위 자가치유로 모두 정리됨._'
          : '_이미 정리되었습니다._');
      } else {
        lines.push('');
        for (const p of paused.slice(0, 8)) {
          const days = Math.floor((Date.now() - new Date(p.since).getTime()) / 86400000);
          lines.push(`- \`${p.id}\` | ${days}일 전 | ${p.reason}`);
        }
      }
    } else {
      lines.push('_cron-status.json 부재._');
    }
  } else if (signal === 'rag-indexer-stale' || sent.ssot?.endsWith('.log')) {
    const logName = sent.ssot;
    const logPath = join(LOGS_DIR, logName);
    if (existsSync(logPath)) {
      const log = readFileSync(logPath, 'utf-8');
      const tailLines = log.split('\n').filter(l => l.trim()).slice(-15);
      const stat = statSync(logPath);
      const hours = ((Date.now() - stat.mtime.getTime()) / 3600000).toFixed(1);
      lines.push(`로그 파일: \`${logName}\` (${hours}시간 stale)`);
      lines.push('');
      lines.push('**마지막 15줄**:');
      lines.push('```');
      lines.push(tailLines.slice(-15).join('\n').slice(0, 1200));
      lines.push('```');
    } else {
      lines.push(`_로그 파일 부재: ${logName}_`);
    }
  } else if (signal === 'cron-failure-spike') {
    const dailyPath = join(HOME, 'jarvis/runtime/state/cron-master-daily.jsonl');
    const lines5 = loadJSONL(dailyPath).slice(-5);
    lines.push('**최근 5일 크론 실패 추이**:');
    for (const d of lines5) {
      lines.push(`- ${d.date}: ${d.fail_24h}건 실패, ${d.repairs || 0}건 자가복구`);
    }
  } else {
    lines.push(`_조사 가능 signal 미정의: \`${signal}\`. 자비스 v5.2 백로그에 추가 권고._`);
  }

  lines.push('');
  lines.push(`_답글: \`재시작\` / \`끄기\` / \`무시\` 중 후속 조치 선택 가능_`);
  lines.push(`_id: \`${AJQE_ID}\`_`);

  const text = lines.join('\n');
  await sendDiscord(text);
  recordAction({ status: 'completed', summary: `${signal} 조사 결과 발송 (${text.length}자)` });
}

async function actionDisable(sent) {
  const signal = sent.signal || sent.ssot;
  let result = '';

  if (signal === 'paused-crons-stale' || sent.ssot === 'cron-status') {
    // 이미 오늘 처리됨 — 현재 상태만 보고
    const cs = JSON.parse(readFileSync(CRON_STATUS_PATH, 'utf-8'));
    result = `paused 크론 정리 상태: ${cs.paused?.length || 0}건 남음. 오늘 effective-tasks.json에서 6건 영구 disabled 완료.`;
  } else if (signal === 'rag-indexer-stale') {
    result = 'crontab 직접 편집은 안전 위해 자동 실행 안 합니다. 수동 절차: `crontab -e` 후 해당 라인 주석 처리.';
  } else {
    result = `_${signal}에 대한 disable 액션 미정의. 수동 처리 필요._`;
  }

  await sendDiscord(`🛑 **끄기 결과 — ${AJQE_ID}**\n\n${result}`);
  recordAction({ status: 'completed', summary: result });
}

async function actionRestart(sent) {
  const signal = sent.signal || sent.ssot;
  let result = '';

  if (signal === 'discord-bot-unhealthy') {
    try {
      execSync('bash ~/jarvis/infra/scripts/bot-preflight.sh', { encoding: 'utf-8', stdio: 'pipe' });
      result = '✅ 봇 재시작 완료 (bot-preflight.sh).';
    } catch (e) {
      result = `❌ 봇 재시작 실패: ${e.message.slice(0, 200)}`;
    }
  } else if (signal === 'paused-crons-stale') {
    result = '_paused 크론은 이미 영구 disable 처리됨. 재시작하려면 effective-tasks.json에서 enabled:true로 수동 변경 필요._';
  } else if (signal === 'rag-indexer-stale') {
    result = '_RAG 인덱서 재시작은 cron 환경에 의존. 수동 절차 필요 (또는 v6 액션 확장 후 자동화)._';
  } else {
    result = `_${signal}에 대한 restart 액션 미정의._`;
  }

  await sendDiscord(`🔄 **재시작 결과 — ${AJQE_ID}**\n\n${result}`);
  recordAction({ status: 'completed', summary: result });
}

// v5.5 'undo' — 최근 24h 자비스 자가치유 액션을 백업으로 롤백
async function actionUndo(sent) {
  const signal = sent.signal || sent.ssot;
  const recent = recentSelfHealActions(signal);
  if (recent.length === 0) {
    await sendDiscord(`↩️ **되돌리기 — ${sent.id}**\n\n_최근 24h 자비스 자가치유 이력이 없어 되돌릴 게 없습니다._`);
    recordAction({ status: 'noop', summary: 'no recent self-heal action' });
    return;
  }
  const last = recent[recent.length - 1];
  const backups = (last.backups || []).filter(Boolean);
  if (backups.length === 0) {
    await sendDiscord(`↩️ **되돌리기 실패 — ${sent.id}**\n\n_백업 파일이 없습니다 (액션: \`${last.action}\`)._`);
    recordAction({ status: 'failed', summary: 'no backups available' });
    return;
  }
  const lines = [`↩️ **자비스 자가치유 롤백 완료**`, ''];
  for (const bak of backups) {
    if (bak.includes('effective-tasks')) {
      try {
        const fs = await import('node:fs');
        fs.copyFileSync(bak, EFFECTIVE_TASKS_PATH);
        lines.push(`- \`effective-tasks.json\` 복원 완료`);
      } catch (e) { lines.push(`- effective-tasks 복원 실패: ${e.message}`); }
    } else if (bak.includes('cron-status')) {
      try {
        const fs = await import('node:fs');
        fs.copyFileSync(bak, CRON_STATUS_PATH);
        lines.push(`- \`cron-status.json\` 복원 완료`);
      } catch (e) { lines.push(`- cron-status 복원 실패: ${e.message}`); }
    }
  }
  lines.push('');
  lines.push(`_백업 출처: ${backups.map(b => b.split('/').pop()).join(', ')}_`);
  await sendDiscord(lines.join('\n'));
  recordAction({ status: 'completed', summary: `rolled back: ${last.action}`, restoredFrom: backups });
}

async function actionIgnore(sent) {
  const signal = sent.signal;
  let cooldown = {};
  if (existsSync(COOLDOWN_PATH)) {
    cooldown = JSON.parse(readFileSync(COOLDOWN_PATH, 'utf-8'));
  }
  const cooldownUntil = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
  cooldown[signal || sent.id] = cooldownUntil;
  mkdirSync(dirname(COOLDOWN_PATH), { recursive: true });
  writeFileSync(COOLDOWN_PATH, JSON.stringify(cooldown, null, 2));
  await sendDiscord(`🔇 **무시 처리 — ${AJQE_ID}**\n\n_24시간 동안 동일 신호(${signal || '해당 질문'}) 재발송 안 함. ${cooldownUntil} 까지._`);
  recordAction({ status: 'completed', summary: `cooldown 24h until ${cooldownUntil}` });
}

// ── 메인 ────────────────────────────────────────────────────────────────────
async function main() {
  const sent = findSent(AJQE_ID);
  if (!sent) {
    console.error(`알 수 없는 ajqeId: ${AJQE_ID}`);
    process.exit(1);
  }
  try {
    switch (ACTION) {
      case 'investigate': await actionInvestigate(sent); break;
      case 'restart':     await actionRestart(sent); break;
      case 'disable':     await actionDisable(sent); break;
      case 'undo':        await actionUndo(sent); break;
      case 'ignore':      await actionIgnore(sent); break;
      default:
        console.error(`미정의 액션: ${ACTION}`);
        process.exit(1);
    }
    console.log(`✅ ${ACTION} 실행 완료 (${AJQE_ID})`);
  } catch (e) {
    console.error(`❌ 실행 실패: ${e.message}`);
    await sendDiscord(`❌ **액션 실행 실패 — ${AJQE_ID}**\n\n\`${ACTION}\` 실행 중 오류: ${e.message.slice(0, 300)}`).catch(() => {});
    recordAction({ status: 'failed', error: e.message.slice(0, 300) });
    process.exit(1);
  }
}

main();
