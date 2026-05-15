#!/usr/bin/env node
/**
 * cron-importer.mjs — crontab -l 잡을 tasks.json 엔트리로 변환
 *
 * 모드:
 *   --dry-run  (default): 변환 결과만 stdout, tasks.json 미수정
 *   --apply              : tasks.json에 실제 추가 + crontab 라인 제거
 *
 * 사고 방어:
 *   - 중복 감지 (.jarvis/scripts vs jarvis/runtime/scripts 동일 잡 → 둘 다 보고, 후자만 채택 권고)
 *   - 인라인 명령(find/pgrep) → kind=cleanup 분류, justification 자동 생성
 *   - jarvis-cron.sh / bot-cron.sh wrapper 감지 → 이미 SSoT 경로 (id 추정)
 *   - @reboot 트리거 → kind=boot 분류 (tasks.json schedule 미지원 영역, plist 권고)
 *
 * 출력:
 *   - candidates: tasks.json 추가 후보 (kind/owner 자동 추정)
 *   - duplicates: .jarvis vs runtime 중복 쌍
 *   - skipped: SSoT 호환 불가 (@reboot, 인라인 등)
 *
 * 안전:
 *   - tasks.json 변경 시 백업 (tasks.json.bak.YYYYMMDD-HHMMSS)
 *   - --apply도 crontab 자체는 수정하지 않음 (사용자 결재 후 별도 단계)
 */

import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const TASKS_PATH = join(HOME, 'jarvis/runtime/config/tasks.json');
const ARGS = process.argv.slice(2);
const APPLY = ARGS.includes('--apply');
const VERBOSE = ARGS.includes('-v');

function log(...a) { console.log(...a); }
function err(...a) { console.error(...a); }

// crontab raw 라인 가져오기
function getCrontab() {
  try {
    const raw = execSync('crontab -l 2>/dev/null', { encoding: 'utf8' });
    return raw.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  } catch { return []; }
}

// crontab 라인 파싱 → schedule + command
function parseLine(line) {
  // @reboot 처리
  if (line.startsWith('@reboot')) {
    return { schedule: '@reboot', command: line.slice('@reboot'.length).trim(), kind: 'boot' };
  }
  // 5-field cron expression + 나머지가 명령
  const m = line.match(/^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$/);
  if (!m) return null;
  return { schedule: m[1], command: m[2], kind: null };
}

// command 분석 → id 추정 + kind 분류
function classify(parsed) {
  const cmd = parsed.command;

  // Wrapper 감지: bot-cron.sh / jarvis-cron.sh <task-id>
  const wrapMatch = cmd.match(/(?:bot-cron\.sh|jarvis-cron\.sh)\s+(\S+)/);
  if (wrapMatch) {
    return { id: wrapMatch[1], kind: 'wrapper', via: 'bot-cron-or-jarvis-cron', confidence: 'high' };
  }

  // 스크립트 직접 호출: 마지막 .sh / .mjs / .py
  const scriptMatch = cmd.match(/\/([a-zA-Z0-9-_]+)\.(sh|mjs|py|js)\b/);
  if (scriptMatch) {
    const id = scriptMatch[1];
    let kind = 'system';
    if (id.includes('report')) kind = 'report';
    else if (id.includes('audit') || id.includes('check')) kind = 'audit';
    else if (id.includes('alert') || id.includes('reminder')) kind = 'alert';
    else if (id.includes('sync') || id.includes('backup')) kind = 'data-pipeline';
    else if (id.includes('rag') || id.includes('vault')) kind = 'data-pipeline';

    // 경로 분기 — .jarvis vs jarvis/runtime
    const path = cmd.match(/(\/Users\/ramsbaby\/(?:\.jarvis|jarvis\/runtime)\/[^\s>]+)/)?.[1] || null;
    return { id, kind, script: path, confidence: 'medium' };
  }

  // 인라인 (find/pgrep 등)
  if (/^(?:find|pgrep|kill|rm)\s/.test(cmd)) {
    return { id: null, kind: 'cleanup-inline', confidence: 'low', skip: true };
  }

  return { id: null, kind: 'unknown', confidence: 'low', skip: true };
}

// owner 추정 (kind + id 키워드)
function inferOwner(c) {
  const id = (c.id || '').toLowerCase();
  if (id.includes('rag') || id.includes('lance')) return 'infra';
  if (id.includes('report') || id.includes('weekly') || id.includes('daily')) return 'archive';
  if (id.includes('audit') || id.includes('check')) return 'audit';
  if (id.includes('news') || id.includes('intel') || id.includes('recon')) return 'intel';
  if (id.includes('boram') || id.includes('reminder')) return 'user';
  if (id.includes('vault') || id.includes('backup') || id.includes('cleanup')) return 'infra';
  if (id.includes('mistake') || id.includes('insight')) return 'learning';
  if (id.includes('brand') || id.includes('oss') || id.includes('promo')) return 'brand';
  if (id.includes('growth') || id.includes('career')) return 'growth';
  return 'infra';
}

// 메인
function main() {
  const lines = getCrontab();
  log(`📋 crontab 라인 ${lines.length}건 발견\n`);

  const tasksJson = JSON.parse(readFileSync(TASKS_PATH, 'utf8'));
  const existingIds = new Set(tasksJson.tasks.map(t => t.id));

  const candidates = [];
  const duplicates = new Map(); // id → [paths]
  const skipped = [];

  for (const line of lines) {
    const parsed = parseLine(line);
    if (!parsed) { skipped.push({ line, reason: 'parse-fail' }); continue; }

    const c = classify(parsed);

    if (c.skip || !c.id) {
      skipped.push({ line, reason: c.kind || 'unknown' });
      continue;
    }

    if (existingIds.has(c.id)) {
      // 이미 tasks.json 등록 — wrapper로 호출하는 잡일 가능성
      candidates.push({ ...parsed, ...c, status: 'already-in-ssot', action: 'remove-from-crontab' });
      continue;
    }

    // 중복 추적
    if (!duplicates.has(c.id)) duplicates.set(c.id, []);
    duplicates.get(c.id).push({ schedule: parsed.schedule, command: parsed.command });

    candidates.push({
      ...parsed,
      ...c,
      owner: inferOwner(c),
      status: 'new',
      action: 'add-to-tasks-json'
    });
  }

  // 중복 정리
  const realDuplicates = [...duplicates.entries()].filter(([, arr]) => arr.length > 1);

  // 보고
  log('═'.repeat(60));
  log(`📊 분류 결과\n`);
  log(`  신규 후보 (tasks.json 추가): ${candidates.filter(c => c.status === 'new').length}`);
  log(`  이미 SSoT 등록 (crontab 제거 권고): ${candidates.filter(c => c.status === 'already-in-ssot').length}`);
  log(`  중복 ID (.jarvis vs runtime 양쪽): ${realDuplicates.length}`);
  log(`  스킵 (인라인/@reboot/파싱불가): ${skipped.length}`);
  log('═'.repeat(60));

  if (realDuplicates.length) {
    log('\n🔁 중복 ID 상세:');
    for (const [id, arr] of realDuplicates) {
      log(`\n  [${id}]`);
      arr.forEach((a, i) => log(`    ${i+1}. ${a.schedule} ${a.command.slice(0, 80)}${a.command.length > 80 ? '...' : ''}`));
    }
  }

  log('\n📥 신규 후보 샘플 (최대 5건):');
  const newOnes = candidates.filter(c => c.status === 'new');
  for (const c of newOnes.slice(0, 5)) {
    log(`\n  id: ${c.id}`);
    log(`  schedule: ${c.schedule}`);
    log(`  kind: ${c.kind}  owner: ${c.owner}`);
    log(`  script: ${c.script || '(inline)'}`);
  }

  if (newOnes.length > 5) log(`\n  ... 외 ${newOnes.length - 5}건`);

  log('\n🚫 스킵 샘플 (최대 5건):');
  for (const s of skipped.slice(0, 5)) {
    log(`  [${s.reason}] ${s.line.slice(0, 100)}${s.line.length > 100 ? '...' : ''}`);
  }

  log('\n═'.repeat(60));
  log(APPLY ? '⚠️  --apply 모드: tasks.json 수정 예정' : '🔍 dry-run 모드 (--apply로 실제 적용)');
  log('═'.repeat(60));

  if (!APPLY) {
    process.exit(0);
  }

  // --apply: 실제 적용은 별도 결재 후 — 안전을 위해 본 단계는 일부러 미구현
  err('\n❌ --apply 모드는 SSoT 문서 P3 단계 (사용자 결재 후) 활성화. 현재는 dry-run만 지원.');
  process.exit(2);
}

main();
