/**
 * commitment-tracker.js — Claude 응답에서 약속 감지 → commitments.jsonl 기록
 *
 * 사용법 (handlers.js에서):
 *   import { detectAndRecord, resolveCommitment } from './commitment-tracker.js';
 *   // Claude 응답 후:
 *   await detectAndRecord(claudeReply, { source: 'discord', channelId, userId });
 *
 * commitments.jsonl 구조:
 *   { "id": "...", "status": "open", "text": "...", "created_at": "ISO8601", "source": "discord" }
 *   { "id": "...", "status": "done", "resolved_at": "ISO8601" }
 */

import { existsSync, appendFileSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { log } from './claude-runner.js';

// ---------------------------------------------------------------------------
// 약속 감지 패턴 — Jarvis가 이행을 확약하는 표현
// 부정문("하지 않겠습니다") 등 FP 제거 목적으로 부정 lookahead 포함
// ---------------------------------------------------------------------------
const COMMITMENT_PATTERN =
  /(?<![아않])\b(?:하겠습니다|진행하겠습니다|처리하겠습니다|등록하겠습니다|추가하겠습니다|수정하겠습니다|구현하겠습니다|확인하겠습니다|완료하겠습니다|보내겠습니다|전달하겠습니다|저장하겠습니다|실행하겠습니다)/;

// 단일 메시지에서 여러 약속이 감지돼도 첫 번째만 기록 (중복 방지)
const MAX_PER_MESSAGE = 1;

// ---------------------------------------------------------------------------
// 약속 텍스트 정제 — 약속이 포함된 문장만 추출
// ---------------------------------------------------------------------------
function _extractCommitmentSentence(text) {
  // 약속 동사가 포함된 문장을 추출 (최대 120자)
  const sentences = text.split(/(?<=[.!?。])\s+|(?<=습니다[.]?)\s+/);
  for (const s of sentences) {
    if (COMMITMENT_PATTERN.test(s)) {
      return s.trim().slice(0, 120);
    }
  }
  // 문장 분리 실패 시 전체 슬라이스
  return text.slice(0, 120);
}

// ---------------------------------------------------------------------------
// detectAndRecord — Claude 응답 텍스트에서 약속 감지 후 JSONL에 기록
// ---------------------------------------------------------------------------
export async function detectAndRecord(replyText, { source = 'discord', channelId = '', userId = '' } = {}) {
  if (!replyText || !COMMITMENT_PATTERN.test(replyText)) return null;

  const botHome = process.env.BOT_HOME || `${homedir()}/.jarvis`;
  const commitFile = join(botHome, 'state', 'commitments.jsonl');

  const commitmentText = _extractCommitmentSentence(replyText);
  const entry = {
    id: randomUUID(),
    status: 'open',
    text: commitmentText,
    created_at: new Date().toISOString(),
    source,
    channelId,
    userId,
  };

  try {
    mkdirSync(dirname(commitFile), { recursive: true });
    appendFileSync(commitFile, JSON.stringify(entry) + '\n', 'utf-8');
    log('info', '[commitment-tracker] 약속 기록됨', { id: entry.id, text: commitmentText.slice(0, 60) });
    return entry;
  } catch (err) {
    log('warn', '[commitment-tracker] 기록 실패', { error: err.message });
    return null;
  }
}

// ---------------------------------------------------------------------------
// resolveCommitment — 특정 id 항목을 done으로 마킹
// ---------------------------------------------------------------------------
export function resolveCommitment(id) {
  const botHome = process.env.BOT_HOME || `${homedir()}/.jarvis`;
  const commitFile = join(botHome, 'state', 'commitments.jsonl');

  if (!existsSync(commitFile)) return false;

  const lines = readFileSync(commitFile, 'utf-8').split('\n').filter(l => l.trim());
  let found = false;
  const now = new Date().toISOString();

  const updated = lines.map(line => {
    try {
      const item = JSON.parse(line);
      if (item.id === id && item.status === 'open') {
        found = true;
        return JSON.stringify({ ...item, status: 'done', resolved_at: now });
      }
    } catch { /* 깨진 라인 유지 */ }
    return line;
  });

  if (found) {
    writeFileSync(commitFile, updated.join('\n') + '\n', 'utf-8');
    log('info', '[commitment-tracker] 약속 해소됨', { id });
  }
  return found;
}

// ---------------------------------------------------------------------------
// pruneResolved — 30일 이상 지난 done 항목 정리 (선택적 유지보수)
// ---------------------------------------------------------------------------
export function pruneResolved() {
  const botHome = process.env.BOT_HOME || `${homedir()}/.jarvis`;
  const commitFile = join(botHome, 'state', 'commitments.jsonl');

  if (!existsSync(commitFile)) return 0;

  const cutoff = Date.now() - 30 * 86400 * 1000;
  const lines = readFileSync(commitFile, 'utf-8').split('\n').filter(l => l.trim());
  const kept = lines.filter(line => {
    try {
      const item = JSON.parse(line);
      if (item.status === 'done' && item.resolved_at) {
        return new Date(item.resolved_at).getTime() > cutoff;
      }
    } catch { /* 깨진 라인 보존 */ }
    return true;
  });

  const removed = lines.length - kept.length;
  if (removed > 0) {
    writeFileSync(commitFile, kept.join('\n') + '\n', 'utf-8');
    log('info', '[commitment-tracker] 오래된 done 항목 정리', { removed });
  }
  return removed;
}
