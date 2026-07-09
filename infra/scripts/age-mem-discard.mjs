#!/usr/bin/env node
/**
 * age-mem-discard.mjs — AgeMem DISCARD: 고아/스테일 RAG 청크 정리
 *
 * Rule 1 (Orphan): index-state.json에 등록됐으나 디스크에서 사라진 소스 → soft-delete
 * Rule 2 (Stale) : access-log.json 기반 30일+ 미참조 소스 → 보고서 생성 (자동 삭제 없음)
 *
 * 실행 주기: 매주 목요일 02:00 KST
 *   ← rag-stale-scan 일요일 03:00 → 수동 검토 기간(3~4일) → DISCARD 목요일 02:00
 *
 * 안전 설계:
 *   - rag-index.mjs / rag-compact.mjs 실행 중이면 즉시 종료 (쓰기 경합 방지)
 *   - Rule 1 soft-delete만 자동 수행. Rule 2는 보고서 전용.
 *   - Discord 알림은 orphan 삭제가 1건 이상일 때만 발송.
 */

import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME    = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');

// ─── 경로 상수 ───────────────────────────────────────────────────────────────
const RAG_ENGINE_PATH = join(HOME, 'jarvis/rag/lib/rag-engine.mjs');
const INDEX_STATE     = join(HOME, '.jarvis/rag/index-state.json');
const ACCESS_LOG      = join(BOT_HOME, 'rag/access-log.json');
const REPORT_DIR      = join(BOT_HOME, 'rag/teams/reports');
const ALERT_SCRIPT    = join(BOT_HOME, 'scripts/alert.sh');
const LEDGER_PATH     = join(HOME, '.jarvis/state/doctor-ledger.jsonl');

mkdirSync(REPORT_DIR, { recursive: true });

// ─── 유틸 ────────────────────────────────────────────────────────────────────
const ts  = () => new Date().toISOString();
const log = (...a) => console.log(`[${ts()}] [age-mem-discard]`, ...a);
const wrn = (...a) => console.warn(`[${ts()}] [age-mem-discard] WARN`, ...a);

// ─── 안전 가드: rag-index / rag-compact 실행 중이면 건너뜀 ───────────────────
try {
  execSync('pgrep -f "rag-index\\.mjs\\|rag-compact\\.mjs"', { stdio: 'ignore' });
  log('rag-index 또는 rag-compact 실행 중 — AgeMem DISCARD 건너뜀');
  process.exit(0);
} catch {
  // pgrep exit 1 = 프로세스 없음 → 안전하게 진행
}

log('=== AgeMem DISCARD 시작 ===');

// ─────────────────────────────────────────────────────────────────────────────
// Rule 1: Orphan Discard
//   index-state.json에 등록된 소스 경로가 디스크에서 사라졌으면 LanceDB soft-delete.
//   "소스 파일이 사라진 것" = 의도적 삭제 또는 이동 → RAG 청크 고아 확정.
// ─────────────────────────────────────────────────────────────────────────────
let orphanDeleted = 0;
const orphanSources = [];
const DRYRUN = process.env.DRYRUN === '1';

// [2026-07-08] index-state.json 대신 DB의 전체 source를 직접 순회 (순서 결함 수리).
//   근본: rag-index prune(30분 주기)이 원본 삭제 항목을 index-state에서 즉시 제거 →
//         state 기반 고아 탐지는 볼 대상이 항상 0건 → orphan cleanup 무력화.
//         DB source(distinct)를 직접 조회해 원본이 사라진 유령 청크를 실제로 잡는다.
//   DRYRUN=1: soft-delete 없이 유령 수만 집계 (대량 정리 전 검증용).
{
  // RAGEngine 동적 임포트 (임포트 실패 시 Rule 1 전체 건너뜀)
  let engine = null;
  try {
    const mod = await import(RAG_ENGINE_PATH);
    const { RAGEngine } = mod;
    // [2026-07-08] LanceDB 경로 명시 — 크론 환경엔 BOT_HOME/JARVIS_RAG_HOME env가 없어
    //   paths.mjs가 fallback(~/.local/share, 빈 DB)을 잡던 결함 수리. 실제 DB는 BOT_HOME/rag/lancedb.
    const LANCEDB = join(BOT_HOME, 'rag', 'lancedb');
    engine = new RAGEngine(LANCEDB);
    await engine.init();
    log(`RAGEngine 초기화 완료 (${DRYRUN ? 'DRYRUN — 삭제 없음' : 'write 모드'}) db=${LANCEDB.replace(HOME, '~')}`);
  } catch (e) {
    wrn('RAGEngine 초기화 실패:', e.message, '— Rule 1 건너뜀');
    engine = null;
  }

  if (engine) {
    let allSources = [];
    try {
      allSources = await engine.getAllSources();
    } catch (e) {
      wrn('getAllSources 실패:', e.message);
    }
    const orphanCandidates = allSources.filter(src => src && !existsSync(src));
    log(`DB source: ${allSources.length}개 / 고아(원본없음): ${orphanCandidates.length}개${DRYRUN ? ' [DRYRUN]' : ''}`);

    if (DRYRUN) {
      orphanDeleted = orphanCandidates.length;
    } else if (orphanCandidates.length > 0) {
      // [2026-07-08] 배치 soft-delete(IN 절) — 순차(100건/2분) 대비 대폭 빠름 → watcher 중단 시간 최소화.
      try {
        orphanDeleted = await engine.deleteBySources(orphanCandidates);
        log(`배치 soft-delete 완료: ${orphanDeleted}/${orphanCandidates.length}건`);
      } catch (e) {
        wrn(`deleteBySources 배치 실패(부분 처리 가능):`, e.message);
      }
    }
    orphanSources.push(...orphanCandidates.slice(0, 20)); // 보고서용 샘플만(대량 나열 방지)
  }
}

log(`Rule 1 완료: orphan ${DRYRUN ? '탐지(DRYRUN)' : 'soft-delete'} ${orphanDeleted}건`);

// ─────────────────────────────────────────────────────────────────────────────
// Rule 2: Stale Report (30일+ 미참조)
//   access-log.json에서 30일 초과 미참조 키를 집계하여 보고서에 기록.
//   자동 삭제 없음 — 대표님 수동 검토 후 결정.
// ─────────────────────────────────────────────────────────────────────────────
let staleCount    = 0;
const staleSources = [];
const CUTOFF_MS   = Date.now() - 30 * 24 * 3600 * 1000; // 30일

if (!existsSync(ACCESS_LOG)) {
  log('access-log.json 없음 — Rule 2 건너뜀');
} else {
  try {
    const accessLog = JSON.parse(readFileSync(ACCESS_LOG, 'utf-8'));
    for (const [key, v] of Object.entries(accessLog)) {
      const lastMs = new Date(v.lastAccessed || 0).getTime();
      if (lastMs < CUTOFF_MS) {
        staleSources.push({
          key,
          count:        v.count ?? 0,
          lastAccessed: v.lastAccessed || 'unknown',
          ageDays:      Math.floor((Date.now() - lastMs) / 86_400_000),
        });
      }
    }
    staleSources.sort((a, b) => a.ageDays - b.ageDays); // 오래된 순 내림차순
    staleCount = staleSources.length;
    log(`Rule 2 완료: 30일+ 미참조 ${staleCount}건 (보고서 전용)`);
  } catch (e) {
    wrn('access-log.json 읽기 실패:', e.message);
  }
}

// ─── 보고서 생성 ──────────────────────────────────────────────────────────────
const todayISO   = new Date().toISOString().slice(0, 10);
const todayLabel = new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' });
const reportPath = join(REPORT_DIR, `age-mem-discard-${todayISO}.md`);

const lines = [
  `# AgeMem DISCARD 보고서 — ${todayLabel} KST`,
  '',
  '## 요약',
  `- 🗑️ **Rule 1 (고아 정리)**: ${orphanDeleted}개 소스 soft-delete`,
  `- 📊 **Rule 2 (스테일 보고)**: ${staleCount}개 소스 30일+ 미참조 (삭제 없음)`,
  '',
];

if (orphanSources.length > 0) {
  lines.push('## 삭제된 고아 소스', '');
  orphanSources.forEach(s => lines.push(`- \`${s.replace(HOME, '~')}\``));
  lines.push('');
}

if (staleSources.length > 0) {
  lines.push('## 30일+ 미참조 스테일 후보 (수동 검토 필요)', '');
  staleSources.slice(0, 30).forEach(s =>
    lines.push(`- \`${s.key}\` — ${s.count}회 참조 | ${s.ageDays}일 미참조 | 마지막: ${s.lastAccessed}`)
  );
  if (staleSources.length > 30)
    lines.push(`- ... 외 ${staleSources.length - 30}건`);
  lines.push('');
  lines.push('> ⚠️ 자동 삭제 없음. `rag-stale-scan` 보고서와 교차 확인 후 대표님 판단.');
}

lines.push('', '---', `> 생성: age-mem-discard.mjs | ${ts()}`);

writeFileSync(reportPath, lines.join('\n'), 'utf-8');
log(`보고서 저장: ${reportPath}`);

// ─── doctor-ledger.jsonl 기록 ─────────────────────────────────────────────────
try {
  appendFileSync(
    LEDGER_PATH,
    JSON.stringify({ ts: ts(), type: 'scan', task: 'age-mem-discard', orphanDeleted, staleCount }) + '\n',
    'utf-8'
  );
} catch { /* ledger 실패는 무시 */ }

// ─── Discord 알림 (orphan 삭제 1건 이상일 때만) ────────────────────────────────
if (orphanDeleted > 0 && existsSync(ALERT_SCRIPT)) {
  try {
    execSync(
      `bash "${ALERT_SCRIPT}" "info" "AgeMem DISCARD" "고아 소스 ${orphanDeleted}개 정리 완료. 스테일 보고 ${staleCount}건."`,
      { stdio: 'ignore' }
    );
  } catch { /* Discord 알림 실패 무시 */ }
}

log(`=== AgeMem DISCARD 완료 (orphan:${orphanDeleted} stale:${staleCount}) ===`);
process.exit(0);
