#!/usr/bin/env node
// skill-loop-promote.mjs — decision 파일 적용: 승인→등재 / 폐기→보관 / 보류→유지
// 권한 분리 설계: Discord 봇은 의사만 기록, 실제 파일 이동·설치는 이 스크립트(크론/CLI)가 수행
// v2 (2026-06-10 /verify B1 수리): 결정 1건의 예외가 배치 전체를 죽이지 못하도록 격리 +
//   재승인 시 approved/ 경로 충돌(ENOTEMPTY) 안전 처리 + 실패 decision은 failed/로 소비 (무한 크래시 루프 차단)
// Usage: node skill-loop-promote.mjs

import { readFileSync, readdirSync, existsSync, appendFileSync, unlinkSync, cpSync, renameSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const DRAFTS = join(HOME, 'jarvis', 'runtime', 'state', 'skill-drafts');
const DECISIONS = join(DRAFTS, 'decisions');
const LEDGER = join(HOME, 'jarvis', 'runtime', 'ledger', 'skill-loop.jsonl');
const VALIDATOR = join(HOME, '.claude', 'commands', 'skill-creator', 'scripts', 'quick_validate.py');
const INSTALL_BASE = join(HOME, '.claude', 'skills');

const ledger = (event, data) =>
  appendFileSync(LEDGER, JSON.stringify({ ts: new Date().toISOString(), event, ...data }) + '\n');
// 목적지 충돌 시 타임스탬프 접미사 (ENOTEMPTY 크래시 방지)
const safeDest = (p) => (existsSync(p) ? `${p}-${Date.now()}` : p);

function applyDecision(p, f) {
  let dec; try { dec = JSON.parse(readFileSync(p, 'utf8')); } catch { unlinkSync(p); return 0; }
  const { slug, decision, by } = dec;
  if (!/^[a-z0-9-]{1,64}$/.test(slug || '')) { unlinkSync(p); return 0; }
  const src = join(DRAFTS, 'pending', slug);
  ledger('decision', { slug, decision, by });

  if (decision === 'hold') { unlinkSync(p); return 0; } // pending 유지, 재결재 가능

  if (!existsSync(src)) { console.log(`✗ ${slug}: pending에 없음 (이미 처리/만료)`); unlinkSync(p); return 0; }

  if (decision === 'reject') {
    renameSync(src, safeDest(join(DRAFTS, 'archive', `${slug}-rejected-${new Date().toISOString().slice(0, 10)}`)));
    ledger('archived', { slug, reason: 'rejected', by });
    console.log(`🗑️ ${slug}: 폐기 → archive`);
    unlinkSync(p); return 1;
  }

  if (decision === 'approve') {
    // 등재 직전 최종 기계 검증 (승인 후 변조 가드)
    try { execFileSync('python3', [VALIDATOR, src], { stdio: 'pipe' }); }
    catch (e) {
      console.log(`✗ ${slug}: 등재 전 검증 실패 — 보류`);
      ledger('promote-failed', { slug, error: String(e.stdout || e.message).slice(0, 150) });
      unlinkSync(p); return 0;
    }
    const target = join(INSTALL_BASE, slug);
    if (existsSync(target)) {
      console.log(`✗ ${slug}: 설치 경로 이미 존재 — 충돌, 수동 확인 필요`);
      ledger('promote-failed', { slug, error: 'install path exists' });
      unlinkSync(p); return 0;
    }
    mkdirSync(INSTALL_BASE, { recursive: true });
    cpSync(src, target, { recursive: true });
    renameSync(src, safeDest(join(DRAFTS, 'approved', slug)));
    ledger('promoted', { slug, by, installedTo: target });
    console.log(`✅ ${slug}: 등재 → ${target}`);
    unlinkSync(p); return 1;
  }

  // 알 수 없는 decision 값 — 소비하고 기록
  ledger('promote-failed', { slug, error: `unknown decision: ${decision}` });
  unlinkSync(p); return 0;
}

if (!existsSync(DECISIONS)) { console.log('decision 없음'); process.exit(0); }
const files = readdirSync(DECISIONS).filter(f => f.endsWith('.json'));
let applied = 0;

for (const f of files) {
  const p = join(DECISIONS, f);
  try {
    applied += applyDecision(p, f);
  } catch (e) {
    // B1 가드: 예외 1건이 배치를 죽이거나(decision 잔존 → 매일 밤 재크래시) 무한 루프가 되지 않도록
    // decision을 failed/로 옮겨 소비하고 다음 건 계속
    const failedDir = join(DECISIONS, 'failed');
    mkdirSync(failedDir, { recursive: true });
    try { renameSync(p, join(failedDir, `${Date.now()}-${f}`)); } catch { try { unlinkSync(p); } catch { /* 최후: 잔존 허용, 로그로 추적 */ } }
    ledger('promote-error', { file: f, error: String(e.message).slice(0, 200) });
    console.log(`✗ ${f}: promote 예외 — decisions/failed/로 격리, 배치 계속 (${String(e.message).slice(0, 80)})`);
  }
}
console.log(`promote 완료 — ${applied}건 적용 (decision ${files.length}건 소비)`);
