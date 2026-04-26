#!/usr/bin/env -S OMP_NUM_THREADS=2 ORT_NUM_THREADS=2 node
/**
 * RAG Indexer - Incremental indexing for the knowledge base
 *
 * Runs via cron (hourly). Only re-indexes files whose mtime changed.
 * Targets: context .md, rag .md, results (7 days)
 */

// ── CPU 스레드 자기 방어 ──────────────────────────────────────────────────────
// ESM hoisting 때문에 process.env 설정으로는 ONNX 스레드 제한 불가.
// 반드시 rag-index-safe.sh 래퍼를 통해 실행해야 함 (shell에서 export OMP).
// 래퍼 없이 직접 node 실행 시 즉시 거부.
if (!['2', '4', '6', '8'].includes(process.env.OMP_NUM_THREADS)) {
  console.error('[rag-index] FATAL: OMP_NUM_THREADS!=2. rag-index-safe.sh를 통해 실행하세요.');
  console.error('  올바른 실행: bash rag/bin/rag-index-safe.sh');
  console.error('  잘못된 실행: node rag/bin/rag-index.mjs');
  process.exit(1);
}

import { readFile, writeFile, stat, unlink, open as fsOpen } from 'node:fs/promises';
import { readFileSync, writeFileSync, unlinkSync, appendFileSync, mkdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { config } from 'dotenv';

// 크론이 삭제된 임시 디렉토리에서 실행될 수 있으므로,
// dotenv.config()를 호출하기 전에 유효한 디렉토리로 변경해야 함.
// (ENOENT: uv_cwd 오류 방지)
const DEFAULT_HOME = INFRA_HOME;
const WORK_DIR = INFRA_HOME;
try {
  process.chdir(WORK_DIR);
} catch (e) {
  // WORK_DIR 접근 불가 시 홈 디렉토리로 변경
  try {
    process.chdir(homedir());
  } catch (_) {
    // 최악의 경우 /tmp로 변경
    process.chdir('/tmp');
  }
}

// .env 로드 (크론 환경 변수 주입)
config({ path: join(WORK_DIR, 'discord', '.env') });

import { RAGEngine } from '../lib/rag-engine.mjs';
import { RAG_HOME, INFRA_HOME, LANCEDB_PATH, INDEX_STATE_PATH, RAG_WRITE_LOCK as WRITE_LOCK_PATH, RAG_LOG_FILE as LOG_PATH, RAG_LOCK_DIR, STATE_DIR, INCIDENTS_PATH, ensureDirs } from '../lib/paths.mjs';

ensureDirs();

const BOT_HOME = INFRA_HOME;
const STATE_FILE = INDEX_STATE_PATH;
const RAG_LOG_FILE = LOG_PATH;

// 로그를 파일에 직접 쓰기 (nohup stdout 버퍼링 우회)
// console.log는 nohup 리다이렉션 시 프로세스 종료까지 버퍼에 쌓여서
// 진행 중 로그가 안 보이는 문제 발생. appendFileSync는 즉시 디스크에 기록.
function ragLog(msg) {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  try { appendFileSync(RAG_LOG_FILE, line); } catch { /* non-critical */ }
  process.stdout.write(line); // 터미널 직접 실행 시에도 출력
}
const PID_FILE = join(BOT_HOME, 'state', 'rag-index.pid');

// ─── Global RAG write mutex (cross-process, /tmp/jarvis-rag-write.lock) ───────
// Prevents concurrent LanceDB writes between rag-index cron and rag-watch daemon.
// Uses open(O_EXCL) which is atomic on POSIX — no TOCTOU race.
const RAG_WRITE_LOCK = WRITE_LOCK_PATH;
const RAG_WRITE_LOCK_TIMEOUT_MS = 60_000; // 60s max wait (rag-compact와 통일 — 비대칭 30s/60s 버그 수정 2026-03-24)
const RAG_WRITE_LOCK_POLL_MS   = 500;     // poll interval

let _ragWriteLockFd = null; // FileHandle for the lock file (kept open while held)

async function _tryAcquireWriteLock() {
  // Stale lock check: PID-based (time-based 120s는 장시간 실행 시 lock 탈취 위험)
  // lock 파일의 PID가 죽었으면 즉시 회수; 살아있으면 계속 기다림.
  try {
    const lockPid = parseInt((await readFile(RAG_WRITE_LOCK, 'utf-8')).trim(), 10);
    if (lockPid) {
      try {
        process.kill(lockPid, 0); // no-op: 프로세스 존재 확인만
        // 살아있음 → stale 아님, 계속 대기
      } catch {
        // ESRCH: 프로세스 종료됨 → stale lock 회수
        try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
      }
    } else {
      // 빈/손상 lock 파일 → 회수
      try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
    }
  } catch { /* lock file doesn't exist yet — OK */ }

  try {
    // O_EXCL: fails with EEXIST if file already exists — atomic on POSIX
    _ragWriteLockFd = await fsOpen(RAG_WRITE_LOCK, 'wx');
    await _ragWriteLockFd.writeFile(`${process.pid}\n`);
    return true;
  } catch (e) {
    if (e.code === 'EEXIST') return false;
    throw e; // unexpected error
  }
}

async function acquireWriteLock() {
  const deadline = Date.now() + RAG_WRITE_LOCK_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await _tryAcquireWriteLock()) return true;
    await new Promise(r => setTimeout(r, RAG_WRITE_LOCK_POLL_MS));
  }
  return false;
}

function releaseWriteLock() {
  try { if (_ragWriteLockFd) { _ragWriteLockFd.close().catch(() => {}); _ragWriteLockFd = null; } } catch {}
  try { unlinkSync(RAG_WRITE_LOCK); } catch {}
}

// 자기 중복 실행 방지: atomic PID lock (O_EXCL) + 프로세스 존재 확인
// PID 체크와 PID 쓰기 사이에 gap이 있으면 race condition 발생하므로,
// 먼저 PID를 atomic하게 쓰고, 기존 프로세스가 있으면 롤백.
{
  const _tmpPid = `${PID_FILE}.${process.pid}.tmp`;
  writeFileSync(_tmpPid, String(process.pid));
  try {
    const existingPid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
    if (existingPid && existingPid !== process.pid) {
      try {
        process.kill(existingPid, 0); // 존재 확인만
        // 살아있음 → 중복 실행, 즉시 종료
        try { unlinkSync(_tmpPid); } catch {}
        console.log(`[${new Date().toISOString()}] [rag-index] Already running (PID ${existingPid}). Skipping.`);
        process.exit(0);
      } catch { /* ESRCH: stale PID 파일 → 우리가 인수 */ }
    }
  } catch { /* PID 파일 없음 → 첫 실행 */ }
  // atomic rename으로 PID 파일 획득
  renameSync(_tmpPid, PID_FILE);
}

// Acquire global write lock before any LanceDB writes.
// Wait up to 30s for rag-watch to finish its current file, then skip if still busy.
const gotWriteLock = await acquireWriteLock();
if (!gotWriteLock) {
  console.log(`[${new Date().toISOString()}] [rag-index] RAG write lock timeout (${RAG_WRITE_LOCK_TIMEOUT_MS / 1000}s) — another process is writing. Skipping this run.`);
  // appendIncident 는 아래에 정의되므로 여기서는 인라인으로 incidents.md 기록
  try {
    let lockPid = '알 수 없음';
    try { lockPid = readFileSync(RAG_WRITE_LOCK, 'utf-8').trim() || '알 수 없음'; } catch { /* lock 파일 없음 */ }
    const incidentPath = INCIDENTS_PATH;
    const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
    appendFileSync(incidentPath, `\n- [${ts}] **[rag-index]** write lock timeout: rag-index write lock ${RAG_WRITE_LOCK_TIMEOUT_MS / 1000}s timeout — 이번 실행 skip됨. lock holder PID: ${lockPid}\n`);
  } catch { /* incidents 기록 실패는 non-critical */ }
  process.exit(0);
}

// Cleanup: release lock on all exit paths
const _cleanupLock = () => { releaseWriteLock(); };
process.on('exit', _cleanupLock);
// SIGTERM/SIGINT: state 긴급 저장 후 종료 (state 유실 → 무한 rebuild 루프 방지)
let _globalState = null; // run() 진입 후 참조 연결됨
let _pendingStateUpdates_global = [];
const _emergencySaveState = () => {
  // pending state updates를 _globalState에 반영
  if (_globalState && _pendingStateUpdates_global.length > 0) {
    for (const u of _pendingStateUpdates_global) {
      _globalState[u.filePath] = { mtime: u.mtime, chunks: u.chunks };
    }
    console.log(`[rag-index] SIGTERM: ${_pendingStateUpdates_global.length}개 pending state updates 반영`);
  }
  if (_globalState && Object.keys(_globalState).length > 0) {
    // 축소 보호: 기존 state보다 20% 이상 줄어들면 저장 거부
    try {
      const existingRaw = readFileSync(STATE_FILE, 'utf-8');
      const existingCount = (existingRaw.match(/"mtime"/g) || []).length; // 빠른 카운트
      const newCount = Object.keys(_globalState).length;
      if (existingCount > 100 && newCount < existingCount * 0.8) {
        console.warn(`[rag-index] SIGTERM: state 축소 보호 발동 (${existingCount} → ${newCount}) — 저장 건너뜀`);
        return;
      }
    } catch { /* 기존 파일 읽기 실패 시 그냥 저장 진행 */ }
    try {
      // atomic rename 시도 (renameSync는 동기 + POSIX atomic)
      const tmp = `${STATE_FILE}.emergency.tmp`;
      writeFileSync(tmp, JSON.stringify(_globalState, null, 2));
      renameSync(tmp, STATE_FILE);
      console.log(`[rag-index] SIGTERM: state ${Object.keys(_globalState).length}개 파일 긴급 저장 완료 (atomic)`);
    } catch (e) {
      // rename 실패 시 직접 쓰기 fallback
      try { writeFileSync(STATE_FILE, JSON.stringify(_globalState, null, 2)); } catch {}
      console.error(`[rag-index] SIGTERM: state 저장 (fallback): ${e.message}`);
    }
  }
};
const _emergencyCleanup = () => {
  _emergencySaveState();
  // 센티널에 interrupted 표시 (다음 run이 "이전이 중단됨"을 인식)
  const sentinel = join(BOT_HOME, 'state', 'rag-rebuilding.json');
  try {
    const raw = readFileSync(sentinel, 'utf-8');
    const data = JSON.parse(raw);
    data.interrupted = true;
    data.interrupted_at = new Date().toISOString();
    writeFileSync(sentinel, JSON.stringify(data));
  } catch { /* 센티널 없으면 무시 */ }
  _cleanupLock();
};
process.on('SIGTERM', () => { _emergencyCleanup(); process.exit(0); });
process.on('SIGINT',  () => { _emergencyCleanup(); process.exit(0); });

// EPIPE: stdout/stderr 파이프 끊겨도 state 저장 후 정상 종료
// (nohup/launchd 재시작 시 로그 파이프 끊기면 EPIPE → 기존엔 state 저장 없이 크래시)
process.stdout.on('error', (err) => { if (err.code === 'EPIPE') { _emergencyCleanup(); process.exit(0); } });
process.stderr.on('error', (err) => { if (err.code === 'EPIPE') { _emergencyCleanup(); process.exit(0); } });

// uncaughtException: 예상 못 한 에러로 크래시해도 state 저장
process.on('uncaughtException', (err) => {
  try { process.stderr.write(`[rag-index] uncaughtException: ${err.message}\n`); } catch {}
  _emergencyCleanup();
  process.exit(1);
});
process.on('unhandledRejection', (reason) => {
  try { process.stderr.write(`[rag-index] unhandledRejection: ${reason}\n`); } catch {}
  _emergencyCleanup();
  process.exit(1);
});

// rag-watch 인덱싱 중 동시 쓰기 방지: lock 파일만으로 판단 (레거시 호환 유지)
// (rag-watch.mjs가 engine.indexFile() 직전에 lock 파일을 갱신함)
const RAG_WATCH_LOCK = join(BOT_HOME, 'state', 'rag-watch-indexing.lock');
import { statSync } from 'node:fs';
function isRagWatchActive() {
  // lock 파일이 2분 이내 갱신됐으면 현재 쓰기 중 → 이번 run 스킵.
  // 프로세스 존재 여부는 체크하지 않음 (rag-watch는 항상 실행 중이므로 무의미).
  try {
    const s = statSync(RAG_WATCH_LOCK);
    return Date.now() - s.mtimeMs < 120_000;
  } catch {
    return false; // lock 파일 없음 = 인덱싱 중 아님
  }
}
// NOTE: rag-watch check retained for defence-in-depth, but global write lock
// above is the primary mutex. If rag-watch held the lock, acquireWriteLock()
// would have already timed out above.

// PID 재확인: write lock 대기 중 다른 인스턴스가 PID 파일을 쓴 경우 방어
// 자기 자신의 PID는 무시 (line 103에서 이미 atomic하게 등록됨)
try {
  const racePid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
  if (racePid && racePid !== process.pid) {
    try {
      process.kill(racePid, 0);
      console.log(`[${new Date().toISOString()}] [rag-index] Race condition detected — another instance registered PID ${racePid} while waiting for lock. Skipping.`);
      releaseWriteLock();
      process.exit(0);
    } catch { /* ESRCH: stale — proceed */ }
  }
} catch { /* PID 파일 없음 — 정상 진행 */ }

// PID 센티넬: rag-watch가 rag-index 실행 중임을 감지해 충돌 회피
writeFileSync(PID_FILE, String(process.pid));
const _cleanupPid = () => { try { unlinkSync(PID_FILE); } catch {} };
process.on('exit', _cleanupPid);
process.on('SIGTERM', () => { _cleanupPid(); process.exit(0); });
process.on('SIGINT',  () => { _cleanupPid(); process.exit(0); });

async function loadState() {
  // Phase 1: 정상 파일 시도
  try {
    const raw = await readFile(STATE_FILE, 'utf-8');
    const parsed = JSON.parse(raw);
    const entries = Object.keys(parsed).length;

    // 빈 state 의심 — .bak가 충실하면 손상 가능성
    if (entries === 0) {
      try {
        const bakRaw = await readFile(`${STATE_FILE}.bak`, 'utf-8');
        const bak = JSON.parse(bakRaw);
        const bakEntries = Object.keys(bak).length;
        if (bakEntries > 100) {
          console.warn(`[rag-index] ⚠️ state 비어있음 (0 entries) but .bak에 ${bakEntries}개 — 손상 의심, .bak에서 복구`);
          appendIncident('state 손상 복구', `state 0 entries → .bak ${bakEntries} entries로 복구 (4/25 풀 재인덱싱 재발 방지 가드)`);
          return bak;
        }
      } catch { /* .bak 없거나 읽기 실패 — 첫 실행이면 정상 */ }
    }
    return parsed;
  } catch (e) {
    // Phase 2: JSON 손상 — .bak에서 복구 시도
    try {
      const bakRaw = await readFile(`${STATE_FILE}.bak`, 'utf-8');
      const bak = JSON.parse(bakRaw);
      const bakEntries = Object.keys(bak).length;
      if (bakEntries > 0) {
        console.warn(`[rag-index] ⚠️ state JSON 손상 (${e.message?.slice(0, 60)}) — .bak ${bakEntries} entries로 복구`);
        appendIncident('state JSON 손상', `${STATE_FILE} 파싱 실패 → .bak ${bakEntries} entries로 복구`);
        return bak;
      }
    } catch { /* bak도 없음/손상 — 첫 실행 또는 양쪽 손상 */ }
    return {};
  }
}

async function saveState(state) {
  const newCount = Object.keys(state).length;

  // ─── 축소 보호: 기존 state 대비 20% 이상 줄어들면 저장 거부 ────────────────────
  // (emergency save 로직과 동일 — 4/25 07:30 풀 재인덱싱 재발 방지 가드)
  // 합법적 전체 재구축은 REBUILD_SENTINEL 경유 — 일반 saveState() path에 진입 X.
  try {
    const existingRaw = readFileSync(STATE_FILE, 'utf-8');
    const existingCount = (existingRaw.match(/"mtime"/g) || []).length;
    if (existingCount > 100 && newCount < existingCount * 0.8) {
      const msg = `state 축소 보호 발동 (${existingCount} → ${newCount}, 20%+ 감소)`;
      console.warn(`[rag-index] 🛡️ ${msg} — 저장 거부, 풀 재인덱싱 차단`);
      appendIncident('state 축소 차단', `${msg} — saveState() 거부. 의심 시나리오: index-state 손상 + 풀 재인덱싱 시도.`);
      return; // 저장 거부 → 다음 run에서 정상 incremental 진행
    }
  } catch { /* 기존 파일 읽기 실패 시 그냥 저장 진행 */ }

  // ─── 정상 atomic write (tmp + rename, POSIX atomic) ────────────────────────
  const tmp = `${STATE_FILE}.tmp`;
  const { rename, copyFile } = await import('node:fs/promises');
  await writeFile(tmp, JSON.stringify(state, null, 2));
  // 사고방지: state 저장 전 직전 상태 백업 (1세대 롤링)
  try { await copyFile(STATE_FILE, `${STATE_FILE}.bak`); } catch { /* 첫 저장 시 원본 없음 */ }
  await rename(tmp, STATE_FILE);
}

function appendIncident(type, detail) {
  try {
    const incidentPath = INCIDENTS_PATH;
    const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
    appendFileSync(incidentPath, `\n- [${ts}] **[rag-index]** ${type}: ${detail}\n`);
  } catch { /* non-critical */ }
}

// ─── Fragment corruption detection (mid-run auto-recovery) ──────────
const MAX_CONSECUTIVE_LANCE_ERRORS = 5;

function isFragmentCorruption(err) {
  return err.message?.includes('Not found:') && err.message?.includes('.lance');
}

// ─── 데이터 보호 게이트: DB에 청크가 있으면 절대 dropAndReinit 금지 ─────────────
// dropAndReinit은 "DB가 진짜 비어있거나 접근 불가할 때"만 허용.
// 에러가 나도 데이터가 있으면 날리지 않고 다음 cron에서 incremental로 복구.
async function _guardedDropAndReinit(engine, reason) {
  // 데이터 보호 최우선: 읽기 실패 시에도 데이터가 있을 수 있으므로 drop 거부가 기본값
  let chunkCount = -1; // -1 = 확인 불가 (보호 모드)
  try {
    const s = await engine.getStats();
    chunkCount = s.totalChunks || 0;
  } catch {
    try {
      const probe = await engine.table.query().select(['source']).limit(1).toArray();
      chunkCount = probe.length > 0 ? 1 : 0;
    } catch {
      // 읽기 실패 = 데이터 유무 확인 불가 → 안전하게 보호 (drop 금지)
      chunkCount = -1;
    }
  }

  // 물리 파일 존재 여부 추가 확인: DB 읽기 실패해도 .lance 파일이 있으면 데이터 보호
  if (chunkCount <= 0) {
    const { existsSync } = await import('node:fs');
    const { join } = await import('node:path');
    const lancePath = join(engine.dbPath, 'documents.lance');
    const hasFiles = existsSync(lancePath);
    if (hasFiles && chunkCount !== 0) {
      chunkCount = -1; // 파일 존재 but 읽기 실패 → 보호
    }
  }

  if (chunkCount !== 0) {
    const label = chunkCount === -1 ? '확인불가(읽기실패)' : `${chunkCount}`;
    const msg = `${reason} — DB 청크: ${label}, dropAndReinit 거부 (데이터 보호)`;
    console.warn(`[rag-index] 🛡️ DB 보호: ${msg}`);
    appendIncident('DB 보호 발동', msg);
    return false;
  }

  // chunkCount === 0 (확실히 비어있음)만 drop 허용
  await engine.dropAndReinit();
  return true;
}

async function getMtime(filePath) {
  try {
    const s = await stat(filePath);
    return s.mtimeMs;
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    return -1;
  }
}

async function main() {
  const startTime = Date.now();
  const engine = new RAGEngine(LANCEDB_PATH);
  await engine.init();

  // init() 후 최신 manifest 강제 획득 — compact()/optimize()가 직전에 실행됐을 경우
  // stale fragment 참조로 모든 write가 "Not found" 실패하는 것을 선제 방지.
  await engine.refreshTable().catch(e =>
    console.warn(`[rag-index] Pre-run refreshTable failed: ${e.message?.slice(0, 100)}`)
  );

  // Pre-run data probe: 실제 fragment 파일 접근 테스트.
  // refreshTable()은 manifest만 갱신하지만, 이 probe는 실제 데이터를 읽어봄.
  // getStats()가 놓치는 fragment 손상 (다른 fragment를 읽어서 통과) 선제 감지.
  // ⚠️ dropAndReinit()은 반드시 refreshTable() 재시도 후 최후 수단으로만 호출.
  // 단일 transient 에러로 수천 청크가 삭제되는 사고를 방지.
  if (engine.table) {
    try {
      await engine.table.query().select(['id', 'text']).limit(1).toArray();
    } catch (probeErr) {
      if (isFragmentCorruption(probeErr)) {
        // LanceDB internal cleanup이 final batch 직후 비동기로 실행될 수 있음.
        // 즉시 dropAndReinit 대신 최대 3회 재시도 (10초 간격) — transient 상태 대기.
        console.warn(`[rag-index] Pre-run probe failed — retrying up to 3x (10s apart) before dropAndReinit`);
        let probeOk = false;
        for (let attempt = 1; attempt <= 3; attempt++) {
          await new Promise(r => setTimeout(r, 10000)); // 10초 대기
          await engine.refreshTable().catch(() => {});
          try {
            await engine.table.query().select(['id', 'text']).limit(1).toArray();
            console.log(`[rag-index] Pre-run probe OK on retry ${attempt} — no dropAndReinit needed`);
            probeOk = true;
            break;
          } catch (retryErr) {
            if (!isFragmentCorruption(retryErr)) { probeOk = true; break; } // 다른 에러 → 무시
            console.warn(`[rag-index] Pre-run probe retry ${attempt}/3 still failing`);
          }
        }
        if (!probeOk) {
          console.warn(`[rag-index] Pre-run probe failed after 3 retries → _guardedDropAndReinit`);
          appendIncident('Pre-run 프로브 감지', `3회 재시도 후에도 "Not found .lance" → _guardedDropAndReinit 실행`);
          await _guardedDropAndReinit(engine, 'Pre-run probe 3회 실패');
        }
      }
    }
  }

  // DB-state 무결성 검사: index-state.json에 항목이 있는데 DB가 비어있으면
  // 동시 쓰기 충돌로 손상된 것으로 판단 → state 초기화 후 전체 재구성
  let state = await loadState();
  _globalState = state; // SIGTERM 핸들러에서 긴급 저장용
  const stateEntries = Object.keys(state).length;
  if (stateEntries > 0) {
    const currentStats = await engine.getStats();
    if (currentStats._staleManifest) {
      // stale manifest: DB가 실제로 비어있는 게 아닌 fragment 참조 손상
      // ⚠️ 먼저 refreshTable()로 최신 manifest 획득 시도 — compact 직후에 발생하는
      // 일시적 stale manifest는 refresh만으로 해결 가능. dropAndReinit은 최후 수단.
      console.warn(`[rag-index] WARN: stale manifest detected — trying refreshTable before dropAndReinit`);
      const refreshed = await engine.refreshTable().catch(() => false);
      let stillStale = true;
      if (refreshed) {
        const retryStats = await engine.getStats().catch(() => ({ _staleManifest: true }));
        stillStale = !!retryStats._staleManifest;
      }
      if (stillStale) {
        console.warn(`[rag-index] Stale manifest persists after refreshTable → _guardedDropAndReinit`);
        appendIncident('Stale manifest 감지', `getStats() + refreshTable 후에도 "Not found" 지속 → _guardedDropAndReinit 실행`);
        const dropped = await _guardedDropAndReinit(engine, 'Stale manifest refreshTable 실패');
        if (dropped) {
          state = {}; _globalState = state;
          await saveState(state);
        }
        // dropped=false면 DB 보호 → state 유지, 다음 cron에서 incremental 시도
      } else {
        console.log(`[rag-index] Stale manifest resolved by refreshTable — no dropAndReinit needed`);
      }
    } else if (currentStats._accessError) {
      // DB 접근 실패 ≠ 빈 DB. state 유지하고 다음 cron에서 재시도
      console.warn(`[rag-index] DB 접근 실패 (${currentStats._accessError}) — state 유지, 다음 run에서 재시도`);
      appendIncident('DB 접근 오류', `getStats 실패: ${currentStats._accessError} → state ${stateEntries}개 유지 (초기화 안 함)`);
    } else if (currentStats.totalChunks === 0) {
      // DB가 진짜 비어있는지 1회 재확인 (일시적 에러 방지)
      await new Promise(r => setTimeout(r, 2000));
      let recheckChunks = 0;
      try {
        await engine.refreshTable();
        const recheck = await engine.getStats();
        recheckChunks = recheck.totalChunks || 0;
      } catch { /* 재확인 실패 — 0으로 간주 */ }

      if (recheckChunks > 0) {
        ragLog(`[rag-index] DB 재확인: ${recheckChunks} chunks 발견 — 일시적 에러였음, state 유지`);
      } else {
        // 진짜 빈 DB — state 백업 후 리셋
        const backupPath = `${STATE_FILE}.bak.${new Date().toISOString().replace(/[:.]/g, '').slice(0, 15)}`;
        try {
          writeFileSync(backupPath, readFileSync(STATE_FILE));
          ragLog(`[rag-index] State 백업 완료: ${backupPath} (${stateEntries}개 엔트리)`);
        } catch { /* 백업 실패는 non-critical */ }

        console.warn(`[rag-index] WARN: DB empty but index-state has ${stateEntries} entries — state/DB mismatch. Resetting state for full rebuild.`);
        appendIncident('DB 손상 감지', `index-state ${stateEntries}개 vs DB 0 chunks 불일치 → state 백업(${backupPath}) 후 전체 재구성`);

        // Discord 알림 (non-blocking)
        try {
          const alertPath = join(BOT_HOME, 'bin', 'alert.sh');
          const { execSync } = await import('node:child_process');
          execSync(`bash "${alertPath}" "RAG DB 손상 감지: state ${stateEntries}개 vs DB 0 chunks. 전체 재구성 시작." 2>/dev/null`, { timeout: 5000 });
        } catch { /* 알림 실패는 non-critical */ }

        state = {}; _globalState = state;
        await saveState(state);
      }
    }
  }
  const _hadMismatch = Object.keys(state).length === 0 && stateEntries > 0;

  // fresh rebuild 감지: state + DB 모두 비어있어야 true
  // mergeInsert 대신 batched table.add() 사용 → 7000+ fragment 누적 및 LanceDB auto-compaction 방지
  const REBUILD_SENTINEL = join(BOT_HOME, 'state', 'rag-rebuilding.json');

  let isFreshRebuild = false;
  if (Object.keys(state).length === 0) {
    const _freshStats = await engine.getStats();
    // state 비어있는데 DB에 데이터 있음 → 비정상 종료로 state 유실.
    // 기존: DB 날리고 fresh rebuild → timeout/kill 시 state 또 못 저장 → 무한 루프!
    // 수정: DB에서 source 목록을 읽어 state 복구 → 증분 모드로 안전하게 진행.
    if (_freshStats.totalChunks > 0) {
      console.warn(`[rag-index] WARN: state empty but DB has ${_freshStats.totalChunks} chunks — recovering state from DB (NOT dropping)`);
      appendIncident('State 복구', `state 0개 vs DB ${_freshStats.totalChunks} chunks → DB 유지, source 기반 state 복원`);
      try {
        // table.query()로 plain scan — table.search('')는 FTS 트리거 → INVERTED index 없으면 오류
        const allSources = await engine.table.query().select(['source', 'modified_at']).limit(200000).toArray();
        const recovered = {};
        for (const row of allSources) {
          if (row.source && !recovered[row.source]) {
            // 실제 파일 mtime 사용 (DB의 modified_at은 인덱싱 시점이라 파일 mtime과 불일치 → 불필요 재인덱싱 방지)
            const actualMtime = await getMtime(row.source);
            recovered[row.source] = { mtime: actualMtime || row.modified_at || Date.now(), chunks: 1 };
          }
        }
        const recoveredCount = Object.keys(recovered).length;
        if (recoveredCount > 0) {
          Object.assign(state, recovered);
          await saveState(state);
          ragLog(`[rag-index] State 복구 완료: ${recoveredCount}개 파일 (DB 유지, 증분 모드로 전환)`);
          isFreshRebuild = false;
        } else {
          // DB에 청크 있는데 source 목록이 비어있음 (비정상)
          // → DB 보호: fresh rebuild 모드로 전환하되 DB는 날리지 않음
          // → 증분 모드(state={})로 모든 파일 재인덱싱 (deleteBySource+add로 중복 방지)
          console.warn(`[rag-index] State 복구 실패 (source 0개) — DB 보호: 증분 재인덱싱 모드`);
          appendIncident('State 복구 실패', `DB ${_freshStats.totalChunks}청크 보호, 증분 재인덱싱으로 전환`);
          isFreshRebuild = false; // incremental mode: deleteBySource+add → 중복 없음
        }
      } catch (recoverErr) {
        // 복구 쿼리 실패 — DB는 살아있으므로 절대 날리지 않음
        // 증분 모드로 전환 (state={} → 모든 파일 재인덱싱, deleteBySource로 중복 방지)
        console.warn(`[rag-index] State 복구 에러: ${recoverErr.message} — DB 보호: 증분 재인덱싱 모드`);
        appendIncident('State 복구 에러', `${recoverErr.message.slice(0,120)} → DB 보호, 증분 재인덱싱`);
        isFreshRebuild = false; // incremental mode
      }
    } else {
      isFreshRebuild = true;
    }
    // 이전 센티널의 interrupted 태그 확인 → 이전 실행이 중단된 경우 로그
    try {
      const prevSentinel = JSON.parse(readFileSync(REBUILD_SENTINEL, 'utf-8'));
      if (prevSentinel.interrupted) {
        console.log(`[rag-index] 이전 실행 중단 감지 (${prevSentinel.interrupted_at ?? 'unknown'}) — 이어서 처리`);
      }
    } catch { /* 센티널 없거나 파싱 실패 — 정상 */ }

    if (isFreshRebuild) {
      console.log(`[${new Date().toISOString()}] [rag-index] Fresh rebuild 모드 — batched table.add() 사용 (fragment 수 최소화)`);
      // 리빌드 센티널 기록 — rag-quality-check.sh가 이 파일을 보고 오탐 알람 억제.
      // (리빌드 중 "stale/schema/data-empty" 알람 → cron-fix 에이전트 기동 → DB 파기 사고 방지)
      try {
        await writeFile(REBUILD_SENTINEL, JSON.stringify({
          started_at: new Date().toISOString(),
          pid: process.pid,
          reason: 'fresh-rebuild',
        }));
      } catch { /* non-critical */ }
    }
  }

  // ─── P2: rag-watch 큐 소비 (Single Writer pattern) ───────────────────────────
  // rag-watch.mjs는 더 이상 LanceDB에 직접 쓰지 않음.
  // 변경 감지 시 rag-write-queue.jsonl에 경로만 기록 → 여기서 처리.
  const QUEUE_FILE = join(BOT_HOME, 'state', 'rag-write-queue.jsonl');
  const QUEUE_TMP  = QUEUE_FILE + '.processing';
  const pendingQueueIndexes = [];
  const pendingQueueDeletes = [];
  try {
    // rename은 POSIX atomic → rag-watch의 concurrent appendFile과 race 없음.
    // rename 성공 후 새 append는 새 QUEUE_FILE에 기록됨 (소실 없음).
    const { rename } = await import('node:fs/promises');
    await rename(QUEUE_FILE, QUEUE_TMP);
    const queueRaw = await readFile(QUEUE_TMP, 'utf-8').catch(() => '');
    try { await (await import('node:fs/promises')).unlink(QUEUE_TMP); } catch {}
    if (queueRaw.trim()) {
      for (const line of queueRaw.trim().split('\n').filter(Boolean)) {
        try {
          const { action, path: fp } = JSON.parse(line);
          if (action === 'index') pendingQueueIndexes.push(fp);
          else if (action === 'delete') pendingQueueDeletes.push(fp);
        } catch { /* malformed line — skip */ }
      }
      ragLog(`[rag-index] Queue: ${pendingQueueIndexes.length} index, ${pendingQueueDeletes.length} delete`);
    }
  } catch { /* queue file may not exist yet — normal */ }

  // 큐의 delete 항목은 index 완료 후 처리 (index-after-delete 방지)
  // EPIPE 등으로 프로세스가 중단돼도 index된 데이터는 보존됨.

  let indexed = 0;
  let skipped = 0;

  // Collect all target files
  const { readdir } = await import('node:fs/promises');
  const { extname } = await import('node:path');
  const targets = [];

  // 0. Wiki (Jarvis SSoT 메모리) — 최우선 처리
  // Compound Engineering 루프 핵심: meta/learned-mistakes.md, meta/eureka.jsonl 같은
  // 오답노트·통찰 저장소가 rag_search로 회수되어야 과거 실수 재발을 막는다.
  // 이전엔 7번째 카테고리에 있어 MAX_RUNTIME(90m) 안에 한 번도 도달 못함 → 1순위로 격상 (2026-04-22).
  async function collectWikiMd(dirPath) {
    try {
      const entries = await readdir(dirPath, { withFileTypes: true });
      for (const e of entries) {
        if (e.name.startsWith('.')) continue;
        const fullPath = join(dirPath, e.name);
        if (e.isDirectory()) {
          await collectWikiMd(fullPath);
        } else if (extname(e.name) === '.md') {
          targets.push(fullPath);
        }
      }
    } catch { /* wiki may not exist */ }
  }
  await collectWikiMd(join(BOT_HOME, 'wiki'));

  // 1. Context files (top-level + discord-history subdir)
  try {
    const contextDir = join(BOT_HOME, 'context');
    const entries = await readdir(contextDir, { withFileTypes: true });
    for (const e of entries) {
      if (!e.isDirectory() && extname(e.name) === '.md') {
        targets.push(join(contextDir, e.name));
      }
    }
    // discord-history: 최근 7일치만 (파일이 날마다 누적됨)
    const histDir = join(contextDir, 'discord-history');
    try {
      const histFiles = await readdir(histDir);
      for (const f of histFiles) {
        if (extname(f) !== '.md') continue;
        const fPath = join(histDir, f);
        const mtime = await getMtime(fPath);
        if (mtime) {
          const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
          if (ageDays <= 7) targets.push(fPath);
        }
      }
    } catch { /* discord-history 아직 없으면 스킵 */ }
    // context/owner/, context/career/, context/claude-memory/ (오너 프로필, 커리어, Claude Code 메모리)
    // claude-memory/interview-prep/ 등 1-depth 서브디렉토리도 포함
    for (const subDir of ['owner', 'career', 'claude-memory']) {
      try {
        const subDirPath = join(contextDir, subDir);
        const subEntries = await readdir(subDirPath, { withFileTypes: true });
        for (const e of subEntries) {
          if (!e.isDirectory() && extname(e.name) === '.md') {
            targets.push(join(subDirPath, e.name));
          } else if (e.isDirectory()) {
            try {
              const nested = await readdir(join(subDirPath, e.name));
              for (const nf of nested) {
                if (extname(nf) === '.md') targets.push(join(subDirPath, e.name, nf));
              }
            } catch { /* nested dir read fail */ }
          }
        }
      } catch { /* dir may not exist */ }
    }
    // context/claude-code-sessions/ — Claude Code CLI 대화 (최근 30일, 프로젝트별 서브디렉토리)
    try {
      const sessionsDir = join(contextDir, 'claude-code-sessions');
      const projDirs = await readdir(sessionsDir, { withFileTypes: true });
      for (const pd of projDirs) {
        if (!pd.isDirectory()) continue;
        const projPath = join(sessionsDir, pd.name);
        const sessFiles = await readdir(projPath);
        for (const f of sessFiles) {
          if (extname(f) !== '.md') continue;
          const fPath = join(projPath, f);
          const mtime = await getMtime(fPath);
          if (mtime) {
            const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
            if (ageDays <= 7) targets.push(fPath); // 30일→7일: 인덱스 크기 ~75% 감소
          }
        }
      }
    } catch { /* dir may not exist yet */ }
  } catch { /* dir may not exist */ }

  // 2. RAG memory files (decisions는 주간 파일 decisions-YYYY-WXX.md 동적 glob)
  for (const f of ['memory.md', 'handoff.md', 'incidents.md']) {
    targets.push(join(RAG_HOME, f));
  }
  // decisions 주간 파일: archive/ 제외하고 현재 rag/ 루트의 decisions-*.md만
  try {
    const ragDir = RAG_HOME;
    const ragEntries = await readdir(ragDir);
    for (const f of ragEntries) {
      if (f.startsWith('decisions-') && f.endsWith('.md')) {
        targets.push(join(ragDir, f));
      }
    }
  } catch { /* rag dir not found */ }

  // 3. Config 파일 (company-dna, autonomy-levels)
  for (const f of ['company-dna.md', 'autonomy-levels.md']) {
    targets.push(join(BOT_HOME, 'config', f));
  }

  // 3b. Inbox files (rag-watch 큐잉 + 다운타임 복구용 직접 스캔)
  try {
    const inboxDir = join(BOT_HOME, 'inbox');
    const inboxEntries = await readdir(inboxDir);
    for (const f of inboxEntries) {
      if (extname(f) === '.md') targets.push(join(inboxDir, f));
    }
  } catch { /* inbox may not exist */ }

  // 3c. Wiki: 카테고리 0번으로 이동됨 (라인 ~575). 중복 방지를 위해 여기서는 재호출하지 않음.

  // 4. 팀 보고서 & 공유 인박스 (팀 간 통신 이력)
  for (const dir of ['reports', 'shared-inbox']) {
    try {
      const dirPath = join(RAG_HOME, 'teams', dir);
      const entries = await readdir(dirPath);
      for (const f of entries) {
        if (extname(f) === '.md') targets.push(join(dirPath, f));
      }
    } catch { /* dir may not exist */ }
  }
  // proposals-tracker
  targets.push(join(RAG_HOME, 'teams', 'proposals-tracker.md'));

  // 5. 프로젝트 문서: README/ROADMAP/docs/adr는 봇 대화 컨텍스트에 부적합한 개발 메모이므로 제외.
  // Jarvis가 시스템 구조를 이해하려면 config/company-dna.md(섹션 3에서 이미 포함) 활용.

  // 5b. Vault (Obsidian Knowledge Hub) — 재귀 탐색
  //
  // RAG_EXCLUDED_VAULT_DIRS: 봇 대화에 부적합한 개발/아키텍처 문서 디렉토리.
  // 이 경로에 속한 파일은 BM25/벡터 검색 결과에 노이즈를 발생시키므로 인덱싱 제외.
  // - 06-knowledge/adr: ADR 개발 의사결정 메모 (haiku 날짜 코드, bash 패턴 등 기술 노트)
  // - 06-knowledge/architecture: 시스템 아키텍처 다이어그램/설계 문서
  const RAG_EXCLUDED_VAULT_DIRS = [
    'adr',
    'architecture',
  ];

  // RAG_EXCLUDED_VAULT_FILES: 특정 파일명 제외 (디렉토리 무관)
  const RAG_EXCLUDED_VAULT_FILES = new Set([
    'ARCHITECTURE.md',
    'upgrade-roadmap-v2.md',
    'docdd-roadmap.md',
    'obsidian-enhancement-plan.md',
    'PKM-Obsidian-Research.md',
    'session-changelog.md',
    'ADR-INDEX.md',
  ]);

  async function collectVaultMd(dirPath, opts = {}) {
    const { maxAgeDays } = opts;
    try {
      const entries = await readdir(dirPath, { withFileTypes: true });
      for (const e of entries) {
        if (e.name.startsWith('.')) continue; // .obsidian 등 제외
        const fullPath = join(dirPath, e.name);
        if (e.isDirectory()) {
          // 개발/아키텍처 문서 디렉토리 제외
          if (RAG_EXCLUDED_VAULT_DIRS.includes(e.name)) {
            console.log(`[rag-index] Skip excluded dir: ${fullPath}`);
            continue;
          }
          await collectVaultMd(fullPath, opts); // 재귀 탐색
        } else if (extname(e.name) === '.md') {
          // 개발 메모 파일명 제외
          if (RAG_EXCLUDED_VAULT_FILES.has(e.name)) {
            console.log(`[rag-index] Skip excluded file: ${fullPath}`);
            continue;
          }
          if (maxAgeDays) {
            const mtime = await getMtime(fullPath);
            if (!mtime || (Date.now() - mtime) / (1000 * 60 * 60 * 24) > maxAgeDays) continue;
          }
          targets.push(fullPath);
        }
      }
    } catch { /* dir may not exist */ }
  }
  try {
    const vaultBase = process.env.VAULT_DIR || join(homedir(), 'vault');
    // 상시 인덱싱: 01-system, 03-teams, 04-owner, 05-career, 06-knowledge (재귀)
    // 주의: 06-knowledge 내 adr/, architecture/ 은 collectVaultMd에서 자동 제외됨
    for (const dir of ['00-ceo', '01-system', '03-teams', '04-owner', '05-career', '05-decisions', '05-insights', '06-knowledge']) {
      await collectVaultMd(join(vaultBase, dir));
    }
    // 02-daily: 하위 디렉토리 자동 탐색 — 새 디렉토리 추가 시 자동 인덱싱
    // maxAgeDays 기본 7일, 디렉토리별 예외는 dailyAgeOverrides에 추가
    const dailyAgeOverrides = { kpi: 30 };
    const dailyDefaultAge = 7;
    try {
      const dailyDirs = await readdir(join(vaultBase, '02-daily'), { withFileTypes: true });
      for (const d of dailyDirs) {
        if (!d.isDirectory() || d.name.startsWith('.')) continue;
        const maxAgeDays = dailyAgeOverrides[d.name] ?? dailyDefaultAge;
        await collectVaultMd(join(vaultBase, '02-daily', d.name), { maxAgeDays });
      }
    } catch { /* 02-daily may not exist */ }
  } catch { /* vault may not exist */ }

  // 5c. 사용자 커스텀 메모리 (선택적 외부 경로)
  // BOT_EXTRA_MEMORY 환경변수에 경로를 지정하면 해당 디렉토리도 인덱싱
  const extraMemoryPath = process.env.BOT_EXTRA_MEMORY;
  if (extraMemoryPath) {
    const extraFixed = [
      'domains/owner-profile.md', 'domains/system-preferences.md',
      'domains/decisions.md', 'domains/persona.md',
      'hot/HOT_MEMORY.md', 'lessons.md',
    ];
    for (const p of extraFixed) {
      targets.push(join(extraMemoryPath, p));
    }
    for (const dir of ['teams/reports', 'teams/learnings', 'career']) {
      try {
        const dirPath = join(extraMemoryPath, dir);
        const entries = await readdir(dirPath);
        for (const f of entries) {
          if (extname(f) !== '.md') continue;
          const fPath = join(dirPath, f);
          const mtime = await getMtime(fPath);
          if (mtime) {
            const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
            if (ageDays <= 14) targets.push(fPath);
          }
        }
      } catch { /* dir may not exist */ }
    }
  }

  // 6b. OSS reports (rag/oss-reports/, 최근 30일)
  try {
    const ossReportDir = join(RAG_HOME, 'oss-reports');
    const entries = await readdir(ossReportDir);
    for (const f of entries) {
      if (extname(f) !== '.md') continue;
      const fPath = join(ossReportDir, f);
      const mtime = await getMtime(fPath);
      if (mtime) {
        const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
        if (ageDays <= 30) targets.push(fPath);
      }
    }
  } catch { /* dir may not exist yet */ }

  // 6. Results (latest per task, max 7 days)
  try {
    const resultsDir = join(BOT_HOME, 'results');
    const taskDirs = await readdir(resultsDir, { withFileTypes: true });
    for (const td of taskDirs) {
      if (!td.isDirectory()) continue;
      const taskDir = join(resultsDir, td.name);
      const files = await readdir(taskDir);
      const mdFiles = files
        .filter((f) => extname(f) === '.md')
        .sort()
        .reverse()
        .slice(0, 1); // Latest only
      for (const f of mdFiles) {
        const fPath = join(taskDir, f);
        const mtime = await getMtime(fPath);
        if (mtime) {
          const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
          if (ageDays <= 7) targets.push(fPath);
        }
      }
    }
  } catch { /* dir may not exist */ }

  // rag-watch 큐의 index 항목 병합 (정규 스캔에 없는 파일 추가)
  for (const fp of pendingQueueIndexes) {
    if (!targets.includes(fp)) targets.push(fp);
  }

  // Prune state entries for files that no longer exist (메모리/디스크 누수 방지)
  let pruned = 0;
  for (const filePath of Object.keys(state)) {
    if (await getMtime(filePath) === null) {
      delete state[filePath];
      pruned++;
    }
  }
  if (pruned > 0) ragLog(`[rag-index] Pruned ${pruned} stale state entries`);

  // Index changed files
  // MAX_RUNTIME_MS: fresh rebuild도 4시간 상한 적용 (Infinity는 stuck 시 무한 CPU 독식 위험)
  // incremental 모드는 90분 제한 (변경분만 처리하므로 충분)
  const MAX_RUNTIME_MS = isFreshRebuild ? 4 * 60 * 60 * 1000 : 90 * 60 * 1000;
  let _processed = 0;
  let _runtimeExceeded = false;

  // Fresh rebuild 배치 버퍼: FRESH_BATCH_CHUNKS 청크마다 table.add() 1회 → fragment 수 최소화
  // (mergeInsert 1회 = fragment 1개 → 7000개 파일 = 7000개 fragment → LanceDB auto-compaction 유발)
  const FRESH_BATCH_CHUNKS = 5000; // ~300 파일 × ~14 청크/파일 ≈ fragment 1개
  let _pendingRecords = [];
  _pendingStateUpdates_global = []; // batch flush 전까지 대기하는 state 항목 ({filePath, mtime, chunks})

  // Mid-run fragment corruption auto-recovery 상태
  let consecutiveLanceErrors = 0;
  let didMidRunRecovery = false;

  // ─── 2026-04-20 파일 단위 병렬 pre-warm ──────────────────────────
  // 현재 파일을 처리하는 동안 다음 N-1개 파일의 _prepareFileRecords()를
  // 병렬로 선행 발사 → Ollama HTTP 레이턴시와 청킹/파싱을 오버랩.
  // DB write(table.add)는 여전히 메인 루프에서 순차 실행 → 기존 fragment
  // corruption recovery / flush 로직 무결하게 유지.
  const PREFETCH_WINDOW = Math.max(1, Number(process.env.RAG_INDEX_CONCURRENCY) || 3);
  const prefetchCache = new Map();
  function prefetchFile(fp) {
    if (prefetchCache.has(fp)) return;
    prefetchCache.set(fp, (async () => {
      try {
        const mt = await getMtime(fp);
        if (mt === null) return null;
        const se = state[fp];
        const sm = (typeof se === 'object' && se !== null) ? se.mtime : se;
        if (sm === mt) return { mtime: mt, skipped: true };
        const records = await engine._prepareFileRecords(fp);
        return { mtime: mt, records };
      } catch (err) {
        return { error: err };
      }
    })());
  }
  // 초기 윈도우 채우기
  for (let j = 0; j < Math.min(PREFETCH_WINDOW, targets.length); j++) {
    prefetchFile(targets[j]);
  }
  ragLog(`[rag-index] 병렬 pre-warm 활성화: PREFETCH_WINDOW=${PREFETCH_WINDOW}`);

  for (let i = 0; i < targets.length; i++) {
    const filePath = targets[i];

    // 런타임 초과 시 안전 중단 (현재까지의 state는 저장함)
    if (Date.now() - startTime > MAX_RUNTIME_MS) {
      _runtimeExceeded = true;
      console.warn(`[rag-index] MAX_RUNTIME(90m) 초과 — ${indexed}개 처리 후 안전 중단. 다음 실행에서 이어서 처리.`);
      appendIncident('런타임 초과 중단', `${indexed}개 처리 후 90분 한도 초과 → 부분 state 저장, 다음 cron 이어서 처리`);
      break;
    }

    // 다음 윈도우 pre-warm — 현재 파일 소비 시점에 ahead 요청 발사
    if (i + PREFETCH_WINDOW < targets.length) {
      prefetchFile(targets[i + PREFETCH_WINDOW]);
    }

    // Pre-warmed 결과 await
    const pre = await prefetchCache.get(filePath);
    prefetchCache.delete(filePath);

    if (!pre) continue;              // mtime null (파일 사라짐)
    if (pre.skipped) { skipped++; continue; }
    if (pre.error) {
      // _prepareFileRecords 단계 실패 — 개별 파일 건너뛰고 진행
      // (fragment corruption은 table.add() 시점에만 발생하므로 아래 catch에서 처리)
      console.warn(`[rag-index] prepare 실패: ${filePath.slice(-60)} — ${pre.error.message?.slice(0, 80)}`);
      continue;
    }
    const mtime = pre.mtime;
    const _prefetchedRecords = pre.records;

    _processed++;

    // 500파일마다 테이블 참조 갱신 — 장시간 실행 중 stale manifest 방지 (incremental 모드만)
    if (!isFreshRebuild && _processed % 500 === 0) {
      await engine.refreshTable().catch(() => {});
    }

    // 진행 로그: 50파일마다 현황 출력 (임베딩 구간 침묵 방지)
    if (_processed % 50 === 0 && _processed > 0) {
      ragLog(`[rag-index] 진행: ${indexed} indexed / ${skipped} skipped / ${targets.length} total, pending ${_pendingRecords.length} chunks`);
    }

    // 주기적 중간 저장: 25파일마다 pending records를 DB에 flush + state 저장
    // SIGKILL 대비 — SIGTERM 핸들러가 실행 못 할 수 있음 (CPU-bound ONNX 임베딩)
    // DB와 state를 동시에 저장해야 다음 실행 시 불일치(state>0, DB=0) 방지
    if (_processed % 25 === 0 && _pendingRecords.length > 0) {
      try {
        await engine.table.add(_pendingRecords);
        for (const u of _pendingStateUpdates_global) {
          state[u.filePath] = { mtime: u.mtime, chunks: u.chunks };
        }
        ragLog(`[rag-index] 중간 저장: DB flush ${_pendingRecords.length} chunks + state ${Object.keys(state).length}개`);
        _pendingRecords = [];
        _pendingStateUpdates_global = [];
        await saveState(state);
      } catch (e) {
        ragLog(`[rag-index] 중간 저장 실패: ${e.message} — 다음 배치에서 재시도`);
      }
    }

    // state 갱신을 table.add() 성공 후로 지연 — batch 실패 시 "처리됨"으로 잘못 기록되는 것 방지
    // _pendingStateUpdates_global: batch flush 전까지 대기하는 state 항목들
    try {
      // _prefetchedRecords는 위 prefetchFile()에서 병렬로 미리 계산된 결과
      if (isFreshRebuild) {
        const records = _prefetchedRecords;
        if (records.length > 0) {
          _pendingRecords.push(...records);
          _pendingStateUpdates_global.push({ filePath, mtime, chunks: records.length });
          indexed++;
          if (_pendingRecords.length >= FRESH_BATCH_CHUNKS) {
            await engine.table.add(_pendingRecords);
            // table.add 성공 후에만 state 반영
            for (const u of _pendingStateUpdates_global) {
              state[u.filePath] = { mtime: u.mtime, chunks: u.chunks };
            }
            _pendingStateUpdates_global.length = 0;
            ragLog(`[rag-index] Batch add: ${_pendingRecords.length} chunks (누적 ${indexed}개 파일)`);
            _pendingRecords = [];
            await saveState(state); // 중간 저장 (crash 방어)
            // batch add 직후 manifest 갱신 — 다음 batch에서 stale fragment 참조 방지
            await engine.refreshTable().catch(() => {});
          }
        }
        consecutiveLanceErrors = 0;
      } else {
        const records = _prefetchedRecords;
        if (records.length > 0) {
          await engine.deleteBySource(filePath);
          _pendingRecords.push(...records);
          _pendingStateUpdates_global.push({ filePath, mtime, chunks: records.length });
          indexed++;
          if (_pendingRecords.length >= FRESH_BATCH_CHUNKS) {
            await engine.table.add(_pendingRecords);
            for (const u of _pendingStateUpdates_global) {
              state[u.filePath] = { mtime: u.mtime, chunks: u.chunks };
            }
            _pendingStateUpdates_global.length = 0;
            ragLog(`[rag-index] Incremental batch add: ${_pendingRecords.length} chunks (누적 ${indexed}개 파일)`);
            _pendingRecords = [];
            await saveState(state);
            await engine.refreshTable().catch(() => {});
          }
        }
        consecutiveLanceErrors = 0;
      }
    } catch (err) {
      // ─── Mid-run fragment corruption auto-recovery ─────────────────
      if (isFragmentCorruption(err)) {
        if (isFreshRebuild) {
          // Fresh rebuild 중 table.add() "Not found .lance" 오류
          // → LanceDB 내부 auto-compaction이 fragment 삭제 → 다음 batch.add() 실패
          // → 즉시 dropAndReinit + 현재 run 중단, 다음 cron에서 전체 재시작
          if (!didMidRunRecovery) {
            console.warn('[rag-index] Fresh rebuild "Not found .lance" → _guardedDropAndReinit');
            appendIncident(
              'Fresh rebuild fragment 오류',
              `table.add() "Not found .lance" → _guardedDropAndReinit (DB 청크 있으면 보호)`
            );
            const _droppedFresh = await _guardedDropAndReinit(engine, 'Fresh rebuild fragment 오류');
            if (_droppedFresh) { state = {}; _globalState = state; }
            await saveState(state);
            didMidRunRecovery = true;
            _pendingRecords = [];
            _pendingStateUpdates_global = [];
          }
          break; // 현재 run 즉시 중단 (다음 cron에서 전체 재시작)
        } else {
          // Incremental mode: 5회 연속 실패 시 recovery
          consecutiveLanceErrors++;
          if (consecutiveLanceErrors >= MAX_CONSECUTIVE_LANCE_ERRORS && !didMidRunRecovery) {
            // dropAndReinit 전 refreshTable 시도 (무한 루프 방지)
            console.warn(
              `[rag-index] ${consecutiveLanceErrors} consecutive "Not found .lance" errors — attempting refreshTable before dropAndReinit`
            );
            const _refreshOk = await engine.refreshTable().catch(() => false);
            if (_refreshOk) {
              console.log('[rag-index] refreshTable OK after fragment errors — resetting counter, continuing');
              consecutiveLanceErrors = 0;
              continue; // dropAndReinit 없이 다음 파일로
            }
            // refreshTable도 실패 → 보호 게이트: DB에 청크 있으면 drop 거부
            console.warn('[rag-index] refreshTable failed → _guardedDropAndReinit');
            appendIncident(
              'Mid-run 자동 복구',
              `${consecutiveLanceErrors}회 연속 fragment 오류 → refreshTable 실패 → _guardedDropAndReinit`
            );
            const _droppedIncr = await _guardedDropAndReinit(engine, `Incremental ${consecutiveLanceErrors}회 fragment 오류`);
            if (_droppedIncr) { state = {}; _globalState = state; }
            await saveState(state);
            isFreshRebuild = _droppedIncr;
            didMidRunRecovery = true;
            consecutiveLanceErrors = 0;
            _pendingRecords = [];
            _pendingStateUpdates_global = [];
            continue;
          }
        }
      } else {
        consecutiveLanceErrors = 0;
      }
      console.error(`Error indexing ${filePath}: ${err.message}`);
    }
  }

  // 최종 배치 flush (루프 종료 후 남은 레코드 — fresh rebuild + incremental 공통)
  if (_pendingRecords.length > 0) {
    await engine.table.add(_pendingRecords);
    // table.add 성공 후에만 state 반영
    for (const u of _pendingStateUpdates_global) {
      state[u.filePath] = { mtime: u.mtime, chunks: u.chunks };
    }
    _pendingStateUpdates_global = [];
    ragLog(`[rag-index] Final batch add: ${_pendingRecords.length} chunks`);
    _pendingRecords = [];
    await saveState(state); // 최종 flush 직후 중간 저장 (crash 방어)
  }

  const stats = await engine.getStats();
  const duration = ((Date.now() - startTime) / 1000).toFixed(1);

  // 안전장치: 파일을 처리했는데 DB에 0 chunks이면 쓰기 실패 → state 저장하지 않아 다음 실행에서 재시도
  if (indexed > 0 && stats.totalChunks === 0) {
    const msg = `indexed ${indexed} files but DB has 0 chunks — write failure. State NOT saved, will retry next run.`;
    console.error(`[${new Date().toISOString()}] [rag-index] ABORT: ${msg}`);
    appendIncident('쓰기 실패 ABORT', msg);
    process.exit(1);
  }

  await saveState(state);

  // 리빌드 완료 → 센티널 삭제 (rag-quality-check.sh 알람 복원)
  // 삭제 기준: "처리할 새 파일이 없다 (indexed=0, skipped>0)" = 모든 파일 인덱싱 완료.
  // isFreshRebuild+단일 run 완료도 포함.
  // 이 조건 덕분에 90분 분할 rebuild도 최종 run에서 자동 정리됨.
  const _rebuildDone =
    (isFreshRebuild && !_runtimeExceeded && stats.totalChunks > 0) ||  // 단일 run 완료
    (!isFreshRebuild && indexed === 0 && skipped > 0 && stats.totalChunks > 0); // 증분 모드 — 할 일 없음
  if (_rebuildDone) {
    try {
      const { unlink: _unlink, stat: _stat } = await import('node:fs/promises');
      await _stat(REBUILD_SENTINEL); // 파일 없으면 catch로 이동
      await _unlink(REBUILD_SENTINEL);
      ragLog(`[rag-index] Sentinel removed — rebuild complete (${stats.totalChunks} chunks)`);
    } catch { /* sentinel already gone — OK */ }
  }

  // 리빌드 완료 → compact 필요 플래그 기록
  // isFreshRebuild 완료 시: LanceDB에 수천 개 버전이 쌓여 있으므로 compact를 즉시 트리거.
  // rag-index-safe.sh가 이 플래그를 확인해 process 종료 직후 compact를 백그라운드로 실행함.
  if (isFreshRebuild && _rebuildDone) {
    try {
      const _compactFlag = join(BOT_HOME, 'state', 'rag-compact-needed');
      await writeFile(_compactFlag, new Date().toISOString());
      ragLog(`[rag-index] compact-needed 플래그 기록 — 리빌드 완료 후 compact 예약`);
    } catch { /* non-critical */ }
  }

  // DB 손상 후 재구성 성공 시 incidents.md 기록
  if (_hadMismatch && stats.totalChunks > 0) {
    appendIncident('DB 재구성 완료', `${stats.totalChunks} chunks / ${stats.totalSources} sources 복구됨 (${duration}s)`);
  }

  // 큐의 delete 항목 처리 (index 완료 후)
  for (const fp of pendingQueueDeletes) {
    try {
      await engine.deleteBySource(fp);
      delete state[fp];
    } catch (e) {
      console.error(`[rag-index] Queue delete failed: ${fp.split('/').pop()} — ${e.message}`);
      appendIncident('Queue delete 실패', `${fp.split('/').pop()}: ${e.message.slice(0, 100)}`);
    }
  }
  if (pendingQueueDeletes.length > 0) {
    await saveState(state);
  }

  ragLog(
    `RAG index: ${indexed} new/modified, ${skipped} unchanged, ${pruned} pruned, ` +
    `queue(${pendingQueueIndexes.length}idx/${pendingQueueDeletes.length}del), ` +
    `${stats.totalChunks} total chunks, ${stats.totalSources} sources (${duration}s)` +
    `${isFreshRebuild ? ' [FRESH]' : ''}${_runtimeExceeded ? ' [TIMEOUT]' : ''}`,
  );
}

main().catch((err) => {
  console.error(`RAG indexer failed: ${err.message}`);
  process.exit(1);
});
