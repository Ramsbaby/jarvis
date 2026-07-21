#!/usr/bin/env node
/**
 * Duplicate Request Guard — Enhanced version (Cluster cl-3d5ba801bdad1df9)
 *
 * 개선사항:
 * - Semantic similarity 기반 중복 감지 (단순 해시 외)
 * - N-gram 분석으로 의도 유사도 비교
 * - 요청 메타데이터 추적 (호출자, 환경 등)
 * - 더 정교한 중복 판정 (정확도 향상)
 *
 * 호환성:
 * - 기존 duplicate-request-guard.mjs 로직 유지
 * - fallback: 파이썬/텍스트 분석 불가 시 기본 해시 사용
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
const CACHE_MAX_LINES = 1000;
const SEMANTIC_SIMILARITY_THRESHOLD = 0.7;  // 70% 이상 유사하면 중복 의심

/**
 * 기본 요청 해싱 (fast path)
 */
function hashRequest(taskId, prompt) {
  const truncated = prompt.substring(0, 256);
  const input = `${taskId}|${truncated}`;
  return crypto.createHash('sha256').update(input).digest('hex').substring(0, 16);
}

/**
 * N-gram 분석 (의도 유사도)
 * "다음 반복 실수 클러스터에 대한 구조적 가드" vs "다음 반복 클러스터 구조" → 유사
 */
function extractNGrams(text, n = 3) {
  const words = text.toLowerCase()
    .split(/[\s\-_.()[\]{}|]/g)
    .filter(w => w.length > 2);

  const ngrams = new Set();
  for (let i = 0; i <= words.length - n; i++) {
    ngrams.add(words.slice(i, i + n).join(' '));
  }
  return ngrams;
}

/**
 * Jaccard similarity: 두 집합의 유사도 계산
 */
function jaccardSimilarity(set1, set2) {
  if (set1.size === 0 && set2.size === 0) return 1.0;
  if (set1.size === 0 || set2.size === 0) return 0.0;

  const intersection = new Set([...set1].filter(x => set2.has(x)));
  const union = new Set([...set1, ...set2]);

  return intersection.size / union.size;
}

/**
 * 의미 유사도 검사 (의도 기반)
 */
function checkSemanticSimilarity(taskId, currentPrompt, cachedPrompts) {
  const currentNGrams = extractNGrams(currentPrompt);

  for (const cachedPrompt of cachedPrompts) {
    const cachedNGrams = extractNGrams(cachedPrompt);
    const similarity = jaccardSimilarity(currentNGrams, cachedNGrams);

    if (similarity >= SEMANTIC_SIMILARITY_THRESHOLD) {
      return {
        isSemanticallyDuplicate: true,
        similarity: similarity.toFixed(2),
        reason: `의도 유사도 ${(similarity * 100).toFixed(0)}% (임계값: 70%)`
      };
    }
  }

  return {
    isSemanticallyDuplicate: false,
    similarity: 0,
    reason: null
  };
}

/**
 * TTL 확인
 */
function isWithinWindow(createdAt, nowMs, windowMinutes = WINDOW_MINUTES) {
  const age = nowMs - createdAt;
  return age <= windowMinutes * 60 * 1000;
}

/**
 * 캐시 로드
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
 * 캐시 저장
 */
function saveToCache(entry) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.appendFileSync(CACHE_FILE, JSON.stringify(entry) + '\n');

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
    console.error(`[duplicate-request-guard-enhanced] Failed to save cache: ${e.message}`);
  }
}

/**
 * 감지 로그 기록 (enhanced: semantic 정보 포함)
 */
function logDetection(result, isDuplicate) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const logEntry = {
      timestamp: new Date().toISOString(),
      task_id: result.task_id,
      request_id: result.request_id,
      is_duplicate: isDuplicate,
      duplicate_type: result.duplicate_type || 'exact',  // exact | semantic
      duplicate_count: result.recent_count,
      semantic_similarity: result.semantic_similarity || null,
      window_minutes: WINDOW_MINUTES,
    };
    fs.appendFileSync(LOG_FILE, JSON.stringify(logEntry) + '\n');
  } catch (e) {
    console.error(`[duplicate-request-guard-enhanced] Failed to log detection: ${e.message}`);
  }
}

/**
 * 통계 업데이트 (enhanced: semantic 중복 카운팅)
 */
function updateStats(isDuplicate, duplicateType = 'exact') {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    let stats = {
      total_checks: 0,
      total_duplicates: 0,
      exact_duplicates: 0,
      semantic_duplicates: 0,
      last_check: null
    };

    if (fs.existsSync(STATS_FILE)) {
      try {
        stats = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
      } catch {
        stats = {
          total_checks: 0,
          total_duplicates: 0,
          exact_duplicates: 0,
          semantic_duplicates: 0,
          last_check: null
        };
      }
    }

    stats.total_checks++;
    if (isDuplicate) {
      stats.total_duplicates++;
      if (duplicateType === 'semantic') {
        stats.semantic_duplicates = (stats.semantic_duplicates || 0) + 1;
      } else {
        stats.exact_duplicates = (stats.exact_duplicates || 0) + 1;
      }
    }
    stats.last_check = new Date().toISOString();

    fs.writeFileSync(STATS_FILE, JSON.stringify(stats, null, 2));
  } catch (e) {
    console.error(`[duplicate-request-guard-enhanced] Failed to update stats: ${e.message}`);
  }
}

/**
 * 중복 감지 로직 (Enhanced: 정확한 + 의미 기반)
 */
function checkDuplicate(taskId, prompt, nTurns = DEFAULT_N_TURNS) {
  const nowMs = Date.now();
  const requestHash = hashRequest(taskId, prompt);
  const cache = loadCache();

  // 1단계: 정확한 해시 비교
  const recentExact = cache.filter(entry =>
    entry.task_id === taskId &&
    entry.request_hash === requestHash &&
    isWithinWindow(entry.created_at, nowMs, WINDOW_MINUTES)
  );

  let isDuplicate = recentExact.length > 0;
  let duplicateType = 'exact';
  let duplicateReason = null;
  let semanticSimilarity = null;

  // 2단계: 의미 유사도 검사 (정확한 매치가 없으면)
  if (!isDuplicate) {
    const recentForTask = cache.filter(entry =>
      entry.task_id === taskId &&
      isWithinWindow(entry.created_at, nowMs, WINDOW_MINUTES)
    );

    if (recentForTask.length > 0) {
      const recentPrompts = recentForTask
        .map(e => e.original_prompt || '')
        .filter(p => p.length > 0);

      if (recentPrompts.length > 0) {
        const semanticCheck = checkSemanticSimilarity(taskId, prompt, recentPrompts);
        if (semanticCheck.isSemanticallyDuplicate) {
          isDuplicate = true;
          duplicateType = 'semantic';
          duplicateReason = semanticCheck.reason;
          semanticSimilarity = parseFloat(semanticCheck.similarity);
        }
      }
    }
  }

  const requestId = `${taskId}-${Date.now()}-${process.pid}`;

  // 새 항목 추가
  const newEntry = {
    created_at: nowMs,
    task_id: taskId,
    request_hash: requestHash,
    request_id: requestId,
    original_prompt: prompt.substring(0, 512),  // 의미 분석용 원문 저장
    duplicate_count: (recentExact.length || 0),
    duplicate_type: duplicateType,
  };
  saveToCache(newEntry);

  // 결과 구성
  const result = {
    status: isDuplicate ? 'duplicate' : 'ok',
    message: isDuplicate
      ? duplicateType === 'semantic'
        ? `의미가 유사한 요청입니다 (${duplicateReason})`
        : `이미 처리 중인 요청입니다 (최근 ${WINDOW_MINUTES}분 내 ${recentExact.length + 1}회 반복)`
      : '새로운 요청으로 처리됩니다',
    request_id: requestId,
    is_duplicate: isDuplicate,
    duplicate_type: duplicateType,
    recent_count: (recentExact.length || 0) + 1,
    task_id: taskId,
    window_minutes: WINDOW_MINUTES,
    request_hash: requestHash,
    semantic_similarity: semanticSimilarity,
  };

  // 로깅 및 통계 업데이트
  logDetection(result, isDuplicate);
  updateStats(isDuplicate, duplicateType);

  return result;
}

/**
 * 캐시 정리
 */
function cleanupExpired() {
  try {
    const cache = loadCache();
    const nowMs = Date.now();
    const ttlMs = WINDOW_MINUTES * 60 * 1000 * 3;

    const fresh = cache.filter(entry =>
      nowMs - entry.created_at <= ttlMs
    );

    if (fresh.length < cache.length) {
      fs.mkdirSync(STATE_DIR, { recursive: true });
      fs.writeFileSync(
        CACHE_FILE,
        fresh.map(e => JSON.stringify(e)).join('\n') + (fresh.length > 0 ? '\n' : '')
      );
      console.error(`[duplicate-request-guard-enhanced] Cleanup: removed ${cache.length - fresh.length} expired entries`);
    }
  } catch (e) {
    console.error(`[duplicate-request-guard-enhanced] Cleanup failed: ${e.message}`);
  }
}

/**
 * 통계 조회
 */
function getStats() {
  try {
    if (!fs.existsSync(STATS_FILE)) {
      return {
        total_checks: 0,
        total_duplicates: 0,
        exact_duplicates: 0,
        semantic_duplicates: 0,
        last_check: null,
        duplicate_rate: 0
      };
    }

    const stats = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
    const duplicate_rate = stats.total_checks > 0
      ? ((stats.total_duplicates / stats.total_checks) * 100).toFixed(2)
      : 0;

    return {
      ...stats,
      duplicate_rate: parseFloat(duplicate_rate),
      exact_duplicates: stats.exact_duplicates || 0,
      semantic_duplicates: stats.semantic_duplicates || 0,
      cache_entries: fs.existsSync(CACHE_FILE)
        ? fs.readFileSync(CACHE_FILE, 'utf8').split('\n').filter(l => l.trim()).length
        : 0,
    };
  } catch (e) {
    console.error(`[duplicate-request-guard-enhanced] Failed to get stats: ${e.message}`);
    return {
      total_checks: 0,
      total_duplicates: 0,
      exact_duplicates: 0,
      semantic_duplicates: 0,
      last_check: null,
      duplicate_rate: 0
    };
  }
}

/**
 * CLI 진입점
 */
async function main() {
  const [cmd, taskId, prompt, nTurns] = process.argv.slice(2);

  if (cmd === 'check') {
    if (!taskId || !prompt) {
      console.error('Usage: node duplicate-request-guard-enhanced.mjs check TASK_ID PROMPT [N_TURNS]');
      process.exit(1);
    }

    const result = checkDuplicate(taskId, prompt, nTurns ? parseInt(nTurns) : DEFAULT_N_TURNS);
    console.log(JSON.stringify(result));

    process.exit(result.is_duplicate ? 1 : 0);
  } else if (cmd === 'cleanup') {
    cleanupExpired();
    console.error('[duplicate-request-guard-enhanced] Cleanup completed');
    process.exit(0);
  } else if (cmd === 'stats') {
    const stats = getStats();
    console.log(JSON.stringify(stats, null, 2));
    process.exit(0);
  } else {
    console.error('Unknown command:', cmd);
    console.error('Usage:');
    console.error('  node duplicate-request-guard-enhanced.mjs check TASK_ID PROMPT [N_TURNS]');
    console.error('  node duplicate-request-guard-enhanced.mjs cleanup');
    console.error('  node duplicate-request-guard-enhanced.mjs stats');
    process.exit(1);
  }
}

main().catch(e => {
  console.error(`[duplicate-request-guard-enhanced] Fatal error: ${e.message}`);
  process.exit(1);
});
