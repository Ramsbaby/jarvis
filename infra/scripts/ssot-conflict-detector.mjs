#!/usr/bin/env node
/**
 * ssot-conflict-detector.mjs — SSoT 값 레벨 충돌 감지 (cl-de95f30916b8c9a2)
 *
 * 왜 있나:
 *   기존 가드(cl-1a81b2956a7f0cc9)는 파일 경로 레벨 SSoT를 잡는다.
 *   이 가드는 다른 층을 잡는다 — 신규 입력이 기존 슬롯 값과 모순될 때.
 *   wiki-engine.mjs는 같은 key 덮어쓰기를 throw로 막지만:
 *     ① 쓰기 직전 pre-flight check가 없다 (호출자가 catch 안 하면 오염 전파)
 *     ② 다른 key 간 의미 모순은 감지하지 못한다 (phase=협상중 vs base_salary=확정값)
 *     ③ 충돌 감지 후 다중 산출물 전파를 차단할 체크포인트가 없다
 *
 * 사용법:
 *   node ssot-conflict-detector.mjs --check-key KEY --value "새 값"
 *   node ssot-conflict-detector.mjs --scan
 *   node ssot-conflict-detector.mjs --pending
 *   node ssot-conflict-detector.mjs --resolve CONFLICT_ID
 *   node ssot-conflict-detector.mjs --json   (--scan 또는 --pending과 조합)
 *
 * 종료코드:
 *   0 — 충돌 없음
 *   1 — 경고 수준 (다른 키 간 의미 모순 가능성)
 *   2 — 차단 수준 (같은 키 활성값과 충돌 → 전파 차단 트리거)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const HOME = homedir();
const JARVIS = join(HOME, 'projects/jarvis');
const WIKI_SLOTS_BIN = join(homedir(), '.openclaw/workspace/scripts/wiki-slots.mjs');
const PATTERNS_PATH = join(JARVIS, 'infra/config/ssot-conflict-patterns.json');
const PENDING_PATH = join(HOME, '.jarvis/state/ssot-pending-conflicts.json');
const LEDGER_PATH = join(JARVIS, 'runtime/ledger/ssot-conflict-detector.jsonl');

const GUARD_CLUSTER = 'cl-de95f30916b8c9a2';
const GUARD_VERSION = '1.0';

const C = {
  RED: '\x1b[0;31m', YELLOW: '\x1b[1;33m', GREEN: '\x1b[0;32m',
  BLUE: '\x1b[0;34m', CYAN: '\x1b[0;36m', RESET: '\x1b[0m',
};

// ── 유틸 ──────────────────────────────────────────────────────────────────

function kstNow() {
  return new Date().toLocaleString('sv', { timeZone: 'Asia/Seoul' }).replace(' ', 'T') + '+09:00';
}

function log(level, msg) {
  const colors = { ERROR: C.RED, WARN: C.YELLOW, INFO: C.BLUE, OK: C.GREEN };
  process.stderr.write(`${colors[level] || ''}[${level}]${C.RESET} ${msg}\n`);
}

function ensureDir(p) { mkdirSync(p, { recursive: true }); }

function appendLedger(record) {
  ensureDir(require_path_dir(LEDGER_PATH));
  const line = JSON.stringify({ ts: kstNow(), ...record }) + '\n';
  const { appendFileSync } = await_import_sync('node:fs');
  appendFileSync(LEDGER_PATH, line);
}

// node:fs의 appendFileSync를 직접 가져온다 (top-level import 없이)
function ledgerAppend(record) {
  const { appendFileSync } = { appendFileSync: (p, d) => {
    const { writeFileSync: wfs, readFileSync: rfs, existsSync: efs } = { writeFileSync, readFileSync, existsSync };
    const existing = efs(p) ? rfs(p, 'utf8') : '';
    wfs(p, existing + JSON.stringify({ ts: kstNow(), ...record }) + '\n');
  }};
  try {
    ensureDir(LEDGER_PATH.slice(0, LEDGER_PATH.lastIndexOf('/')));
    // appendFileSync가 없으므로 read+write로 구현
    const existing = existsSync(LEDGER_PATH) ? readFileSync(LEDGER_PATH, 'utf8') : '';
    writeFileSync(LEDGER_PATH, existing + JSON.stringify({ ts: kstNow(), ...record }) + '\n');
  } catch { /* 원장 실패가 가드 실패여선 안 됨 */ }
}

function conflictId(key, existingText, newValue) {
  return createHash('sha1')
    .update(`${key}|${existingText.slice(0, 80)}|${newValue.slice(0, 80)}`)
    .digest('hex').slice(0, 12);
}

// ── wiki-slots 조회 ────────────────────────────────────────────────────────

function loadActiveSlots() {
  const result = spawnSync('node', [WIKI_SLOTS_BIN, '--json'], {
    encoding: 'utf8', timeout: 15000,
  });
  if (result.status !== 0 || !result.stdout) {
    log('WARN', `wiki-slots.mjs 조회 실패: ${result.stderr?.slice(0, 200)}`);
    return [];
  }
  try {
    const slots = JSON.parse(result.stdout);
    return Array.isArray(slots) ? slots.filter(s => s.active) : [];
  } catch {
    log('WARN', 'wiki-slots.mjs JSON 파싱 실패');
    return [];
  }
}

// ── 패턴 로드 ─────────────────────────────────────────────────────────────

function loadPatterns() {
  if (!existsSync(PATTERNS_PATH)) {
    log('WARN', `충돌 패턴 파일 없음: ${PATTERNS_PATH}`);
    return { phase_conflict_groups: [], numeric_conflict_groups: [], blocking_key_patterns: [] };
  }
  try { return JSON.parse(readFileSync(PATTERNS_PATH, 'utf8')); }
  catch { log('WARN', '충돌 패턴 파일 파싱 실패'); return { phase_conflict_groups: [], numeric_conflict_groups: [], blocking_key_patterns: [] }; }
}

// ── 충돌 감지 로직 ────────────────────────────────────────────────────────

/**
 * 같은 key에 이미 활성 슬롯이 있는지 확인 — blocking 수준 충돌
 */
function checkSameKeyConflict(key, newValue, activeSlots) {
  const existing = activeSlots.find(s => s.key === key);
  if (!existing) return null;

  const existingText = existing.text || '';
  if (existingText.trim() === newValue.trim()) return null; // 동일 값 → 충돌 아님

  return {
    id: conflictId(key, existingText, newValue),
    severity: 'blocking',
    type: 'same_key',
    key,
    existing_slot: {
      recorded_at: existing.recorded_at,
      source: existing.source,
      text_preview: existingText.slice(0, 200),
    },
    new_value_preview: newValue.slice(0, 200),
    reason: `슬롯 '${key}'에 이미 활성 값이 있습니다. supersedes:true 없이 덮어쓸 수 없습니다.`,
    action_required: 'supersedes:true로 명시적 대체 또는 기존 값 무효화 처리 필요',
  };
}

/**
 * 의미 충돌 — 다른 key이지만 논리적으로 모순되는 상태
 */
function checkSemanticConflicts(key, newValue, activeSlots, patterns) {
  const conflicts = [];
  const groups = patterns.phase_conflict_groups || [];

  for (const group of groups) {
    // 관련 키 그룹인지 확인
    const isRelevantKey = group.relevant_keys?.some(k =>
      key === k || key.startsWith(k.replace('*', ''))
    );

    for (const stateSet of (group.state_sets || [])) {
      // 신규 값이 이 상태에 해당하는지
      const newMatchesThis = stateSet.keywords.some(kw => {
        const re = new RegExp(kw, 'i');
        return re.test(newValue);
      });
      if (!newMatchesThis) continue;

      // 충돌하는 상태에 해당하는 기존 슬롯이 있는지
      const conflictingLabels = stateSet.conflicts_with || [];
      for (const conflictLabel of conflictingLabels) {
        const conflictSet = group.state_sets.find(s => s.label === conflictLabel);
        if (!conflictSet) continue;

        for (const existingSlot of activeSlots) {
          const slotText = existingSlot.text || '';
          const existingMatchesConflict = conflictSet.keywords.some(kw => {
            const re = new RegExp(kw, 'i');
            return re.test(slotText);
          });
          if (!existingMatchesConflict) continue;
          // 같은 key면 same_key 충돌로 이미 잡힘 — 여기선 다른 key만
          if (existingSlot.key === key) continue;

          conflicts.push({
            id: conflictId(`${key}↔${existingSlot.key}`, slotText, newValue),
            severity: 'warning',
            type: 'semantic',
            key_new: key,
            key_existing: existingSlot.key,
            conflict_group: group.id,
            state_new: stateSet.label,
            state_existing: conflictLabel,
            existing_slot: {
              recorded_at: existingSlot.recorded_at,
              text_preview: slotText.slice(0, 200),
            },
            new_value_preview: newValue.slice(0, 200),
            reason: `신규 값(${stateSet.label})이 기존 슬롯 '${existingSlot.key}'(${conflictLabel})과 의미 모순입니다.`,
            action_required: '두 슬롯이 실제로 모순인지 확인하고, 낡은 슬롯을 무효화하십시오.',
          });
        }
      }
    }
  }
  return conflicts;
}

/**
 * 차단 키 패턴에 해당하는지 — blocking 수준 격상
 */
function isBlockingKey(key, patterns) {
  return (patterns.blocking_key_patterns || []).some(p => {
    if (p.startsWith('*.')) return key.endsWith(p.slice(1));
    return key === p;
  });
}

// ── 전체 슬롯 내부 모순 스캔 ──────────────────────────────────────────────

function scanAllConflicts(activeSlots, patterns) {
  const conflicts = [];
  const groups = patterns.phase_conflict_groups || [];

  for (const group of groups) {
    // 각 state set 쌍을 검사
    for (let i = 0; i < group.state_sets.length; i++) {
      const setA = group.state_sets[i];
      for (const conflictLabel of (setA.conflicts_with || [])) {
        const setB = group.state_sets.find(s => s.label === conflictLabel);
        if (!setB) continue;

        // setA에 해당하는 슬롯
        const slotsA = activeSlots.filter(s =>
          setA.keywords.some(kw => new RegExp(kw, 'i').test(s.text || ''))
        );
        // setB에 해당하는 슬롯
        const slotsB = activeSlots.filter(s =>
          setB.keywords.some(kw => new RegExp(kw, 'i').test(s.text || ''))
        );

        for (const slotA of slotsA) {
          for (const slotB of slotsB) {
            if (slotA.key === slotB.key) continue; // same-key는 wiki-engine이 잡음
            conflicts.push({
              id: conflictId(`${slotA.key}↔${slotB.key}`, slotA.text || '', slotB.text || ''),
              severity: 'warning',
              type: 'semantic_scan',
              key_a: slotA.key,
              key_b: slotB.key,
              state_a: setA.label,
              state_b: setB.label,
              conflict_group: group.id,
              slot_a_preview: (slotA.text || '').slice(0, 120),
              slot_b_preview: (slotB.text || '').slice(0, 120),
              reason: `슬롯 '${slotA.key}'(${setA.label})과 '${slotB.key}'(${setB.label})이 의미 모순입니다.`,
              action_required: '낡은 슬롯을 [invalid:날짜]로 닫으십시오.',
            });
          }
        }
      }
    }
  }

  // 중복 제거 (같은 id)
  const seen = new Set();
  return conflicts.filter(c => { if (seen.has(c.id)) return false; seen.add(c.id); return true; });
}

// ── 미해결 충돌 레지스트리 ────────────────────────────────────────────────

function loadPending() {
  if (!existsSync(PENDING_PATH)) return { conflicts: [] };
  try { return JSON.parse(readFileSync(PENDING_PATH, 'utf8')); }
  catch { return { conflicts: [] }; }
}

function savePending(state) {
  ensureDir(PENDING_PATH.slice(0, PENDING_PATH.lastIndexOf('/')));
  writeFileSync(PENDING_PATH, JSON.stringify(state, null, 2));
}

function registerConflicts(newConflicts) {
  const state = loadPending();
  const existingIds = new Set(state.conflicts.map(c => c.id));
  let added = 0;
  for (const c of newConflicts) {
    if (!existingIds.has(c.id)) {
      state.conflicts.push({ ...c, registered_at: kstNow(), resolved: false });
      added++;
    }
  }
  if (added > 0) savePending(state);
  return added;
}

function resolveConflict(conflictId) {
  const state = loadPending();
  const conflict = state.conflicts.find(c => c.id === conflictId);
  if (!conflict) { log('ERROR', `충돌 ID 없음: ${conflictId}`); return false; }
  conflict.resolved = true;
  conflict.resolved_at = kstNow();
  savePending(state);
  log('OK', `충돌 해결 처리: ${conflictId}`);
  return true;
}

// ── 출력 ──────────────────────────────────────────────────────────────────

function printConflict(c, asJson) {
  if (asJson) return;
  const color = c.severity === 'blocking' ? C.RED : C.YELLOW;
  const icon = c.severity === 'blocking' ? '🚫' : '⚠️';
  process.stdout.write(`\n${color}${icon} [${c.severity.toUpperCase()}] ${c.type}${C.RESET}\n`);
  process.stdout.write(`  ID: ${c.id}\n`);
  if (c.key) process.stdout.write(`  키: ${c.key}\n`);
  if (c.key_existing) process.stdout.write(`  충돌 키: ${c.key_existing}\n`);
  process.stdout.write(`  이유: ${c.reason}\n`);
  process.stdout.write(`  조치: ${c.action_required}\n`);
  if (c.existing_slot?.text_preview) {
    process.stdout.write(`  기존값: ${c.existing_slot.text_preview.slice(0, 100)}...\n`);
  }
}

// ── CLI ───────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const asJson = args.includes('--json');

  if (args.includes('--version') || args.includes('-v')) {
    process.stdout.write(`ssot-conflict-detector v${GUARD_VERSION} (${GUARD_CLUSTER})\n`);
    return;
  }

  if (args.includes('--pending')) {
    const state = loadPending();
    const unresolved = state.conflicts.filter(c => !c.resolved);
    if (asJson) {
      process.stdout.write(JSON.stringify({ unresolved_count: unresolved.length, conflicts: unresolved }, null, 2) + '\n');
    } else {
      log('INFO', `미해결 충돌: ${unresolved.length}건`);
      for (const c of unresolved) printConflict(c, false);
    }
    process.exit(unresolved.length > 0 ? (unresolved.some(c => c.severity === 'blocking') ? 2 : 1) : 0);
    return;
  }

  if (args.includes('--resolve')) {
    const idx = args.indexOf('--resolve');
    const id = args[idx + 1];
    if (!id) { log('ERROR', '--resolve 다음에 충돌 ID가 필요합니다'); process.exit(1); }
    resolveConflict(id) ? process.exit(0) : process.exit(1);
    return;
  }

  if (args.includes('--scan')) {
    const activeSlots = loadActiveSlots();
    const patterns = loadPatterns();

    if (activeSlots.length === 0) {
      log('WARN', '활성 슬롯이 없거나 조회 실패 — 검사 불가');
      process.exit(0);
    }

    log('INFO', `활성 슬롯 ${activeSlots.length}개 로드, 내부 모순 검사 중...`);
    const conflicts = scanAllConflicts(activeSlots, patterns);

    if (asJson) {
      process.stdout.write(JSON.stringify({
        scanned: activeSlots.length, conflict_count: conflicts.length, conflicts,
      }, null, 2) + '\n');
    } else {
      if (conflicts.length === 0) {
        log('OK', '슬롯 내부 모순 없음');
      } else {
        log('WARN', `슬롯 내부 모순 ${conflicts.length}건 발견`);
        for (const c of conflicts) printConflict(c, false);
      }
    }

    if (conflicts.length > 0) {
      const added = registerConflicts(conflicts);
      if (added > 0) log('INFO', `미해결 충돌 레지스트리에 ${added}건 추가: ${PENDING_PATH}`);
      ledgerAppend({ mode: 'scan', scanned: activeSlots.length, found: conflicts.length, registered: added });
    }

    process.exit(conflicts.length > 0 ? 1 : 0);
    return;
  }

  // --check-key 모드
  const keyIdx = args.indexOf('--check-key');
  const valueIdx = args.indexOf('--value');

  if (keyIdx < 0 || valueIdx < 0) {
    process.stderr.write([
      `ssot-conflict-detector.mjs v${GUARD_VERSION} (${GUARD_CLUSTER})`,
      '',
      '사용법:',
      '  node ssot-conflict-detector.mjs --check-key KEY --value "새 값"',
      '  node ssot-conflict-detector.mjs --scan            # 전체 슬롯 내부 모순 검사',
      '  node ssot-conflict-detector.mjs --pending         # 미해결 충돌 목록',
      '  node ssot-conflict-detector.mjs --resolve ID      # 충돌 해결 처리',
      '  --json 플래그: JSON 출력',
      '',
      '종료코드: 0=충돌없음, 1=경고, 2=차단',
    ].join('\n') + '\n');
    process.exit(0);
    return;
  }

  const key = args[keyIdx + 1];
  const newValue = args[valueIdx + 1];

  if (!key || !newValue) {
    log('ERROR', '--check-key 와 --value 에 값이 필요합니다');
    process.exit(1);
  }

  log('INFO', `슬롯 충돌 사전 검사: key='${key}'`);

  const activeSlots = loadActiveSlots();
  const patterns = loadPatterns();
  const allConflicts = [];

  // 1. 같은 key 충돌 (blocking)
  const sameKeyConflict = checkSameKeyConflict(key, newValue, activeSlots);
  if (sameKeyConflict) {
    // 차단 키 패턴이면 severity 그대로 blocking
    if (isBlockingKey(key, patterns)) {
      sameKeyConflict.severity = 'blocking';
      sameKeyConflict.blocking_key_matched = true;
    }
    allConflicts.push(sameKeyConflict);
  }

  // 2. 의미 모순 (warning or blocking depending on key)
  const semanticConflicts = checkSemanticConflicts(key, newValue, activeSlots, patterns);
  for (const c of semanticConflicts) {
    if (isBlockingKey(key, patterns)) c.severity = 'blocking';
    allConflicts.push(c);
  }

  const maxSeverity = allConflicts.some(c => c.severity === 'blocking') ? 'blocking'
    : allConflicts.length > 0 ? 'warning' : 'clean';
  const exitCode = maxSeverity === 'blocking' ? 2 : maxSeverity === 'warning' ? 1 : 0;

  if (asJson) {
    process.stdout.write(JSON.stringify({
      key, severity: maxSeverity, conflict_count: allConflicts.length, conflicts: allConflicts,
    }, null, 2) + '\n');
  } else {
    if (allConflicts.length === 0) {
      log('OK', `충돌 없음 — key='${key}' 쓰기 안전`);
    } else {
      for (const c of allConflicts) printConflict(c, false);
    }
  }

  if (allConflicts.length > 0) {
    const added = registerConflicts(allConflicts);
    if (added > 0) log('INFO', `미해결 충돌 레지스트리에 ${added}건 추가: ${PENDING_PATH}`);
    ledgerAppend({ mode: 'check_key', key, severity: maxSeverity, found: allConflicts.length });
  }

  process.exit(exitCode);
}

main().catch(err => { log('ERROR', String(err)); process.exit(2); });
