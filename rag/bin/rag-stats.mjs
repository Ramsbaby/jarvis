#!/usr/bin/env node
/**
 * rag-stats.mjs — RAG DB 안전 진단 CLI
 *
 * openReadOnly()만 사용하므로 DB를 절대 생성하지 않음.
 * 상태 확인은 반드시 이 스크립트를 사용할 것 (RAGEngine().init() 직접 호출 금지).
 *
 * 사용법: node ~/jarvis/runtime/bin/rag-stats.mjs [--json]
 */

import { join, dirname } from 'node:path';
import { existsSync, statSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { RAG_HOME, STATE_DIR } from '../lib/paths.mjs';

const JSON_MODE = process.argv.includes('--json');

// ── 경로 결정 ──
// paths.mjs는 env(JARVIS_RAG_HOME/BOT_HOME)가 없으면 ~/.local/share/jarvis/rag(XDG 폴백)로
// 조용히 떨어진다. 소유자 머신에서 그 폴백은 비어있는 '유령 DB'라 rag-stats가 거짓 보고를 했다.
// → env 미설정이면 저장소 상대의 진짜 런타임 DB가 채워져 있는지 확인해 그쪽으로 자동 교정한다.
const ENV_SET = Boolean(process.env.JARVIS_RAG_HOME || process.env.BOT_HOME);

let RAG_HOME_EFF  = RAG_HOME;
let STATE_DIR_EFF = STATE_DIR;
let PATH_SOURCE   = process.env.JARVIS_RAG_HOME ? 'JARVIS_RAG_HOME'
  : process.env.BOT_HOME ? 'BOT_HOME' : 'XDG 폴백 (env 미설정)';
let AUTO_REDIRECTED = false;

if (!ENV_SET) {
  const here        = dirname(fileURLToPath(import.meta.url));   // .../jarvis/rag/bin
  const repoRuntime = join(here, '..', '..', 'runtime');         // .../jarvis/runtime
  const repoRagHome = join(repoRuntime, 'rag');
  if (existsSync(join(repoRagHome, 'lancedb', 'documents.lance'))) {
    RAG_HOME_EFF    = repoRagHome;
    STATE_DIR_EFF   = join(repoRuntime, 'state');
    PATH_SOURCE     = 'repo-runtime 자동교정 (BOT_HOME 미설정)';
    AUTO_REDIRECTED = true;
  }
}

const DB_PATH   = join(RAG_HOME_EFF, 'lancedb');
// 리빌드 상태의 SSoT는 시스템 전역이 쓰는 state/rag-rebuilding.json (존재=리빌드 중, 제거=완료).
// rag-index.mjs가 이 파일을 생성/삭제한다. (구버전은 아무도 만들지 않는 RAG_HOME/.rebuild-complete를
//  '없으면 리빌드 중'으로 해석 → 영구 거짓 "리빌드 중: 예"를 출력하던 단독 버그였다.)
const SENTINEL  = join(STATE_DIR_EFF, 'rag-rebuilding.json');
const LOCK_FILE = join(RAG_HOME_EFF, 'write.lock');

function log(msg)  { if (!JSON_MODE) process.stdout.write(msg + '\n'); }
function warn(msg) { if (!JSON_MODE) process.stderr.write('[warn] ' + msg + '\n'); }

async function main() {
  const result = {
    dbExists:      false,
    totalChunks:   0,
    totalSources:  0,
    deletedChunks: 0,
    dbSizeKB:      0,
    lastModified:  null,
    rebuilding:    false,
    locked:        false,
    error:         null,
  };

  // ── 리빌드/락 파일 확인 ──
  result.locked     = existsSync(LOCK_FILE);
  result.rebuilding = existsSync(SENTINEL);  // rag-rebuilding.json 존재 = 리빌드 진행 중

  if (AUTO_REDIRECTED) warn('BOT_HOME 미설정 — 저장소 런타임 DB로 자동 교정하여 보고: ' + DB_PATH);
  else if (!ENV_SET)   warn('BOT_HOME 미설정 — XDG 폴백 경로 사용 중(비어있을 수 있음). 진짜 DB를 보려면: export BOT_HOME=~/jarvis/runtime');
  if (result.locked)     warn('write lock active: ' + LOCK_FILE);
  if (result.rebuilding) warn('rebuild in progress — sentinel present: ' + SENTINEL);

  // ── DB 존재 여부 ──
  const lancePath = join(DB_PATH, 'documents.lance');
  if (!existsSync(lancePath)) {
    result.error = 'DB not found: ' + lancePath;
    log('RAG DB 없음: ' + lancePath);
    if (JSON_MODE) process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    process.exit(0);
  }
  result.dbExists = true;

  // ── DB 폴더 크기 ──
  try {
    let totalBytes = 0;
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else totalBytes += statSync(full).size;
      }
    };
    walk(lancePath);
    result.dbSizeKB = Math.round(totalBytes / 1024);

    // 마지막 수정 시각: documents.lance 폴더의 최신 파일 mtime
    let latest = 0;
    const walkMtime = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) walkMtime(full);
        else { const mt = statSync(full).mtimeMs; if (mt > latest) latest = mt; }
      }
    };
    walkMtime(lancePath);
    if (latest > 0) result.lastModified = new Date(latest).toISOString();
  } catch (e) {
    warn('DB size/mtime scan failed: ' + e.message);
  }

  // ── openReadOnly로 청크/소스 수 조회 ──
  try {
    const { RAGEngine } = await import('../lib/rag-engine.mjs');
    const engine = new RAGEngine(DB_PATH);
    await engine.openReadOnly();
    const stats = await engine.getStats();
    result.totalChunks   = stats.totalChunks   ?? 0;
    result.totalSources  = stats.totalSources  ?? 0;
    result.deletedChunks = stats.deletedChunks ?? 0;
  } catch (e) {
    result.error = e.message;
    warn('getStats failed: ' + e.message);
  }

  // ── 경로 출처 메타 (--json 소비자용, 추가 필드) ──
  result.dbPath     = DB_PATH;
  result.pathSource = PATH_SOURCE;

  // ── 출력 ──
  if (JSON_MODE) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } else {
    log('');
    log('=== RAG DB 상태 ===');
    log(`  DB 경로   : ${DB_PATH}`);
    log(`  경로 출처  : ${PATH_SOURCE}`);
    log(`  DB 크기   : ${result.dbSizeKB.toLocaleString()} KB`);
    log(`  마지막 수정: ${result.lastModified ?? '알 수 없음'}`);
    log(`  청크(active): ${result.totalChunks.toLocaleString()}`);
    log(`  소스 파일  : ${result.totalSources.toLocaleString()}`);
    log(`  삭제(soft) : ${result.deletedChunks.toLocaleString()}`);
    log(`  리빌드 중  : ${result.rebuilding ? '예 (rag-rebuilding.json 존재)' : '아니오'}`);
    log(`  Write 락   : ${result.locked ? '있음 (' + LOCK_FILE + ')' : '없음'}`);
    if (result.error) log(`  오류       : ${result.error}`);
    log('');
  }
}

main().catch(e => {
  process.stderr.write('[rag-stats] fatal: ' + e.message + '\n');
  process.exit(0); // exit 0 — 상태 확인이 응답을 차단하면 안 됨
});
