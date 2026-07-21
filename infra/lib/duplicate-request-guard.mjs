#!/usr/bin/env node
/**
 * Duplicate Request Guard — 중복 요청 감지 미들웨어
 * 클러스터 cl-3d5ba801bdad1df9: 2분 내 동일 요청 반복 실행 방지
 *
 * 기능:
 * - 2분 내 동일 TASK_ID + PROMPT 조합 감지
 * - 최근 N턴 이력 추적 및 중복 횟수 카운팅
 * - 캐시 자동 회전 (TTL 기반)
 * - 상세 로깅 및 통계 기록
 *
 * 사용법:
 *   node duplicate-request-guard.mjs check TASK_ID PROMPT [N_TURNS=5]
 *   node duplicate-request-guard.mjs cleanup  # TTL 만료 항목 정리
 *   node duplicate-request-guard.mjs stats    # 통계 조회
 *
 * 반환:
 *   - check: {"status":"ok|duplicate", "message":"...", "request_id":"...", ...} (JSON)
 *   - exit: 0 (새로운 요청) / 1 (중복 감지 또는 오류)
 */

import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

const STATE_DIR = process.env.BOT_HOME
  ? path.join(process.env.BOT_HOME, 'state')
  : path.join(process.env.HOME || '/tmp', 'jarvis/runtime/state');

const CACHE_FILE = path.join(STATE_DIR, 'duplicate-request-cache.jsonl');
const STATS_FILE = path.join(STATE_DIR, 'duplicate-request-stats.json');
const LOG_FILE = path.join(STATE_DIR, 'duplicate-request-detections.jsonl');
const WINDOW_MINUTES = 2;
const DEFAULT_N_TURNS = 5;
const CACHE_MAX_LINES = 1000;  // 파일 크기 제한: 1000라인 초과 시 회전

/**
 * 요청 해싱: TASK_ID + PROMPT의 SHA256 (처음 256자)
 */
function hashRequest(taskId, prompt) {
  const truncated = prompt.substring(0, 256);
  const input = `${taskId}|${truncated}`;
  return crypto.createHash('sha256').update(input).digest('hex').substring(0, 16);
}

/**
 * TTL 확인: 생성 시간 기준 N분 이내
 */
function isWithinWindow(createdAt, nowMs, windowMinutes = WINDOW_MINUTES) {
  const age = nowMs - createdAt;
  return age <= windowMinutes * 60 * 1000;
}

/**
 * 캐시 로드: JSONL 형식 파일 읽기
 */
function loadCache() {
  if (!fs.existsSync(CACHE_FILE)) {
    return [];
  }
  try {
    const lines = fs.readFileSync(CACHE_FILE, 'utf8')
      .split('\n')
      .filter(line => line.trim());
    return lines.map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    }).filter(x => x !== null);
  } catch {
    return [];
  }
}

/**
 * 캐시 저장: JSONL 형식으로 추가 + 자동 회전
 */
function saveToCache(entry) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.appendFileSync(CACHE_FILE, JSON.stringify(entry) + '\n');

    // 캐시 파일 크기 체크 — 1000라인 초과 시 회전
    const stats = fs.statSync(CACHE_FILE);
    const lines = fs.readFileSync(CACHE_FILE, 'utf8').split('\n').filter(l => l.trim()).length;

    if (lines > CACHE_MAX_LINES) {
      const cache = loadCache();
      const nowMs = Date.now();
      const ttlMs = WINDOW_MINUTES * 60 * 1000 * 3;

      const fresh = cache.filter(entry =>
        nowMs - entry.created_at <= ttlMs
      );

      if (fresh.length < cache.length) {
        fs.writeFileSync(
          CACHE_FILE,
          fresh.map(e => JSON.stringify(e)).join('\n') + (fresh.length > 0 ? '\n' : '')
        );
      }
    }
  } catch (e) {
    console.error(`[duplicate-request-guard] Failed to save cache: ${e.message}`);
  }
}

/**
 * 감지 로그 기록: 중복 감지 사건 추적
 */
function logDetection(result, isDuplicate) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const logEntry = {
      timestamp: new Date().toISOString(),
      task_id: result.task_id,
      request_id: result.request_id,
      is_duplicate: isDuplicate,
      duplicate_count: result.recent_count,
      window_minutes: WINDOW_MINUTES,
    };
    fs.appendFileSync(LOG_FILE, JSON.stringify(logEntry) + '\n');
  } catch (e) {
    console.error(`[duplicate-request-guard] Failed to log detection: ${e.message}`);
  }
}

/**
 * 통계 업데이트
 */
function updateStats(isDuplicate) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    let stats = { total_checks: 0, total_duplicates: 0, last_check: null };

    if (fs.existsSync(STATS_FILE)) {
      try {
        stats = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
      } catch {
        // stats 파일이 손상되면 재초기화
        stats = { total_checks: 0, total_duplicates: 0, last_check: null };
      }
    }

    stats.total_checks++;
    if (isDuplicate) stats.total_duplicates++;
    stats.last_check = new Date().toISOString();

    fs.writeFileSync(STATS_FILE, JSON.stringify(stats, null, 2));
  } catch (e) {
    console.error(`[duplicate-request-guard] Failed to update stats: ${e.message}`);
  }
}

/**
 * 중복 감지 로직
 */
function checkDuplicate(taskId, prompt, nTurns = DEFAULT_N_TURNS) {
  const nowMs = Date.now();
  const requestHash = hashRequest(taskId, prompt);
  const cache = loadCache();

  // 최근 2분 내 동일 해시 찾기
  const recentSame = cache.filter(entry =>
    entry.task_id === taskId &&
    entry.request_hash === requestHash &&
    isWithinWindow(entry.created_at, nowMs, WINDOW_MINUTES)
  );

  const isDuplicate = recentSame.length > 0;
  const requestId = `${taskId}-${Date.now()}-${process.pid}`;

  // 새 항목 추가 (중복 여부 상관없이 기록)
  const newEntry = {
    created_at: nowMs,
    task_id: taskId,
    request_hash: requestHash,
    request_id: requestId,
    duplicate_count: recentSame.length,
  };
  saveToCache(newEntry);

  // 결과 구성
  const result = {
    status: isDuplicate ? 'duplicate' : 'ok',
    message: isDuplicate
      ? `이미 처리 중인 요청입니다 (최근 ${WINDOW_MINUTES}분 내 ${recentSame.length + 1}회 반복)`
      : '새로운 요청으로 처리됩니다',
    request_id: requestId,
    is_duplicate: isDuplicate,
    recent_count: recentSame.length + 1, // 현재 요청 포함
    task_id: taskId,
    window_minutes: WINDOW_MINUTES,
    request_hash: requestHash,
  };

  // 로깅 및 통계 업데이트
  logDetection(result, isDuplicate);
  updateStats(isDuplicate);

  return result;
}

/**
 * 캐시 정리: TTL 만료 항목 제거
 */
function cleanupExpired() {
  try {
    const cache = loadCache();
    const nowMs = Date.now();
    const ttlMs = WINDOW_MINUTES * 60 * 1000 * 3; // 조금 여유 있게

    const fresh = cache.filter(entry =>
      nowMs - entry.created_at <= ttlMs
    );

    if (fresh.length < cache.length) {
      fs.mkdirSync(STATE_DIR, { recursive: true });
      fs.writeFileSync(
        CACHE_FILE,
        fresh.map(e => JSON.stringify(e)).join('\n') + (fresh.length > 0 ? '\n' : '')
      );
      console.error(`[duplicate-request-guard] Cleanup: removed ${cache.length - fresh.length} expired entries`);
    }
  } catch (e) {
    console.error(`[duplicate-request-guard] Cleanup failed: ${e.message}`);
  }
}

/**
 * 통계 조회
 */
function getStats() {
  try {
    if (!fs.existsSync(STATS_FILE)) {
      return { total_checks: 0, total_duplicates: 0, last_check: null, duplicate_rate: 0 };
    }

    const stats = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
    const duplicate_rate = stats.total_checks > 0
      ? ((stats.total_duplicates / stats.total_checks) * 100).toFixed(2)
      : 0;

    return {
      ...stats,
      duplicate_rate: parseFloat(duplicate_rate),
      cache_entries: fs.existsSync(CACHE_FILE)
        ? fs.readFileSync(CACHE_FILE, 'utf8').split('\n').filter(l => l.trim()).length
        : 0,
    };
  } catch (e) {
    console.error(`[duplicate-request-guard] Failed to get stats: ${e.message}`);
    return { total_checks: 0, total_duplicates: 0, last_check: null, duplicate_rate: 0 };
  }
}

/**
 * CLI 진입점
 */
async function main() {
  const [cmd, taskId, prompt, nTurns] = process.argv.slice(2);

  if (cmd === 'check') {
    if (!taskId || !prompt) {
      console.error('Usage: node duplicate-request-guard.mjs check TASK_ID PROMPT [N_TURNS]');
      process.exit(1);
    }

    const result = checkDuplicate(taskId, prompt, nTurns ? parseInt(nTurns) : DEFAULT_N_TURNS);
    console.log(JSON.stringify(result));

    // 중복 감지 시 exit 1, 새 요청 시 exit 0
    process.exit(result.is_duplicate ? 1 : 0);
  } else if (cmd === 'cleanup') {
    cleanupExpired();
    console.error('[duplicate-request-guard] Cleanup completed');
    process.exit(0);
  } else if (cmd === 'stats') {
    const stats = getStats();
    console.log(JSON.stringify(stats, null, 2));
    process.exit(0);
  } else {
    console.error('Unknown command:', cmd);
    console.error('Usage:');
    console.error('  node duplicate-request-guard.mjs check TASK_ID PROMPT [N_TURNS]');
    console.error('  node duplicate-request-guard.mjs cleanup');
    console.error('  node duplicate-request-guard.mjs stats');
    process.exit(1);
  }
}

main().catch(e => {
  console.error(`[duplicate-request-guard] Fatal error: ${e.message}`);
  process.exit(1);
});
