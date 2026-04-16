#!/usr/bin/env node
/**
 * failure-rule-engine.mjs — Anthropic Correction 패턴: 실패 → 규칙 자동화
 *
 * 실패 패턴을 학습하고 재발 시 자동 매칭 + 해결 제안.
 * recovery-learnings.md + cron.log에서 패턴 추출 → failure-rules.jsonl 관리.
 *
 * CLI:
 *   node failure-rule-engine.mjs match "에러 메시지"   → 매칭 규칙 반환 (JSON)
 *   node failure-rule-engine.mjs add "패턴" "해결법"   → 규칙 추가
 *   node failure-rule-engine.mjs outcome "rule-id" success|fail → 신뢰도 갱신
 *   node failure-rule-engine.mjs report              → 전체 규칙 요약
 *
 * 저장소: ~/.jarvis/state/failure-rules.jsonl
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const RULES_PATH = join(BOT_HOME, 'state', 'failure-rules.jsonl');
const LOG_PATH = join(BOT_HOME, 'logs', 'failure-rules.log');

// ── 로거 ─────────────────────────────────────────────────────────────────────
function log(msg) {
  const ts = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
  const line = `[${ts}] [failure-rules] ${msg}\n`;
  try { mkdirSync(dirname(LOG_PATH), { recursive: true }); appendFileSync(LOG_PATH, line); } catch {}
}

// ── 규칙 CRUD ────────────────────────────────────────────────────────────────

function loadRules() {
  if (!existsSync(RULES_PATH)) return [];
  try {
    return readFileSync(RULES_PATH, 'utf-8')
      .split('\n')
      .filter(Boolean)
      .map(line => JSON.parse(line));
  } catch { return []; }
}

function saveRules(rules) {
  mkdirSync(dirname(RULES_PATH), { recursive: true });
  writeFileSync(RULES_PATH, rules.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf-8');
}

function addRule(pattern, resolution, category = 'unknown') {
  const rules = loadRules();
  // 중복 체크
  if (rules.some(r => r.pattern === pattern)) {
    log(`SKIP: duplicate pattern — ${pattern.slice(0, 60)}`);
    return null;
  }
  const rule = {
    id: `rule-${Date.now()}`,
    pattern,
    resolution,
    category,
    confidence: 0.7,
    applied: 0,
    succeeded: 0,
    createdAt: new Date().toISOString(),
    lastApplied: null,
  };
  rules.push(rule);
  saveRules(rules);
  log(`ADD: ${rule.id} — ${pattern.slice(0, 60)}`);
  return rule;
}

// ── 패턴 매칭 ────────────────────────────────────────────────────────────────

function matchRule(errorMessage) {
  const rules = loadRules();
  const matches = [];

  for (const rule of rules) {
    try {
      const re = new RegExp(rule.pattern, 'i');
      if (re.test(errorMessage)) {
        matches.push(rule);
      }
    } catch {
      // 패턴이 정규식으로 유효하지 않으면 substring match
      if (errorMessage.toLowerCase().includes(rule.pattern.toLowerCase())) {
        matches.push(rule);
      }
    }
  }

  // 신뢰도 순 정렬
  matches.sort((a, b) => b.confidence - a.confidence);
  return matches[0] || null;
}

// ── 학습: 적용 결과 → 신뢰도 갱신 ───────────────────────────────────────────

function recordOutcome(ruleId, success) {
  const rules = loadRules();
  const rule = rules.find(r => r.id === ruleId);
  if (!rule) return null;

  rule.applied++;
  if (success) rule.succeeded++;
  // Bayesian-ish 신뢰도: (succeeded + 1) / (applied + 2) — smoothed
  rule.confidence = +((rule.succeeded + 1) / (rule.applied + 2)).toFixed(3);
  rule.lastApplied = new Date().toISOString();

  saveRules(rules);
  log(`OUTCOME: ${ruleId} — ${success ? 'success' : 'fail'} → confidence ${rule.confidence}`);
  return rule;
}

// ── 리포트 ───────────────────────────────────────────────────────────────────

function report() {
  const rules = loadRules();
  if (!rules.length) return '규칙 0건';
  const lines = [`실패 규칙 ${rules.length}건:`];
  for (const r of rules.sort((a, b) => b.confidence - a.confidence)) {
    const pct = (r.confidence * 100).toFixed(0);
    lines.push(`- [${pct}%] ${r.pattern.slice(0, 50)} → ${r.resolution.slice(0, 50)} (${r.succeeded}/${r.applied})`);
  }
  return lines.join('\n');
}

// ── 시드 규칙: recovery-learnings.md에서 초기 규칙 생성 ──────────────────────

function seedFromRecoveryLearnings() {
  const learningsPath = join(BOT_HOME, 'state', 'recovery-learnings.md');
  if (!existsSync(learningsPath)) { log('SEED: recovery-learnings.md not found'); return 0; }

  const content = readFileSync(learningsPath, 'utf-8');
  const rules = loadRules();
  let added = 0;

  // 패턴: "원인: ..." + "해결: ..." 블록 추출
  const blocks = content.split(/^## /m).filter(Boolean);
  for (const block of blocks) {
    const causeMatch = block.match(/원인:\s*(.+)/);
    const fixMatch = block.match(/(?:해결|복구완료):\s*(.+)/);
    if (causeMatch && fixMatch) {
      const pattern = causeMatch[1].trim().slice(0, 120);
      const resolution = fixMatch[1].trim().slice(0, 200);
      if (pattern.length > 10 && !rules.some(r => r.pattern === pattern)) {
        const rule = addRule(pattern, resolution, 'recovery-seed');
        if (rule) { rule.confidence = 0.8; added++; } // 실제 복구 이력이므로 초기 신뢰도 높음
      }
    }
  }

  if (added > 0) {
    saveRules(loadRules()); // confidence 갱신 반영
    log(`SEED: ${added}건 규칙 추출 완료`);
  }
  return added;
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const [,, cmd, ...args] = process.argv;

switch (cmd) {
  case 'match': {
    const errorMsg = args.join(' ');
    const rule = matchRule(errorMsg);
    console.log(JSON.stringify(rule || { match: null }));
    break;
  }
  case 'add': {
    const [pattern, resolution, category] = args;
    const rule = addRule(pattern, resolution || '', category || 'manual');
    console.log(JSON.stringify(rule || { error: 'duplicate or invalid' }));
    break;
  }
  case 'outcome': {
    const [ruleId, result] = args;
    const rule = recordOutcome(ruleId, result === 'success');
    console.log(JSON.stringify(rule || { error: 'rule not found' }));
    break;
  }
  case 'report': {
    console.log(report());
    break;
  }
  case 'seed': {
    const count = seedFromRecoveryLearnings();
    console.log(JSON.stringify({ seeded: count }));
    break;
  }
  default:
    console.error('Usage: failure-rule-engine.mjs <match|add|outcome|report|seed> [args...]');
    process.exit(1);
}
