#!/usr/bin/env node
/**
 * ajqe-generate.mjs — Active Jarvis Question Engine: 질문 생성기
 *
 * 역할: ssot-registry.json의 LLM 주입 SSoT 단일 파일을 스캔하여
 *       약한 표현(PENDING/TODO/미정/미확인/추정/흐릿/🚧)을 발견하면
 *       자연어 질문으로 변환하여 question-queue.jsonl에 적재한다.
 *
 * 동일한 weakPatterns 사전을 interview-ssot-audit.mjs와 공유 (현재는 복제 — v2에서 모듈화 백로그).
 *
 * 사용:
 *   node ajqe-generate.mjs              # 스캔 + 큐 적재 + 카운트 출력
 *   node ajqe-generate.mjs --dry-run    # 큐 미적재, 발견 항목만 출력
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const SSOT_REGISTRY_PATH = join(HOME, 'jarvis/runtime/context/ssot-registry.json');
const QUEUE_PATH = join(HOME, 'jarvis/runtime/state/ajqe-question-queue.jsonl');
const POLICY_PATH = join(HOME, 'jarvis/runtime/config/ajqe-policy.json');

const DRY_RUN = process.argv.includes('--dry-run');

// interview-ssot-audit.mjs auditOwnerSsotFiles와 동일 패턴 (DRY 백로그)
const WEAK_PATTERNS = [
  { name: 'PENDING', re: /PENDING/i },
  { name: '🚧', re: /🚧/ },
  { name: 'TODO', re: /\bTODO\b/ },
  { name: '미정', re: /미정/ },
  { name: '미확인', re: /미확인/ },
  { name: '추정', re: /추정\s*(?:값|치)/ },
  { name: '흐릿', re: /(?:기억\s*)?흐릿/ },
];

function loadJSON(path, fallback) {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, 'utf-8')); }
  catch { return fallback; }
}

function expandPath(p) {
  return p.startsWith('~/') ? join(HOME, p.slice(2)) : p;
}

function loadExistingQueueIds() {
  if (!existsSync(QUEUE_PATH)) return new Set();
  const ids = new Set();
  for (const line of readFileSync(QUEUE_PATH, 'utf-8').split('\n')) {
    if (!line.trim()) continue;
    try { ids.add(JSON.parse(line).id); } catch {}
  }
  return ids;
}

function buildQuestionId(ssotName, lineNumber, weakName) {
  // 동일 라인+패턴은 한 번만 큐에 들어감 (라인 이동 시 새 id)
  return `${ssotName}-L${lineNumber}-${weakName}`;
}

function buildQuestionText(template, ctx) {
  return template
    .replaceAll('{ssot}', ctx.ssotName)
    .replaceAll('{ssotPath}', ctx.ssotPath.replace(HOME, '~'))
    .replaceAll('{line}', String(ctx.lineNumber))
    .replaceAll('{pattern}', ctx.weakName)
    .replaceAll('{excerpt}', ctx.excerpt.slice(0, 200))
    .replaceAll('{purpose}', ctx.purpose || '');
}

function scanSsotFile(ssot, policy) {
  if (!existsSync(ssot.path)) return [];
  const content = readFileSync(ssot.path, 'utf-8');
  const lines = content.split('\n');
  const findings = [];
  const ignoreContains = policy.ignoreLineContains || [];
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i];
    if (ignoreContains.some(kw => text.includes(kw))) continue; // false positive 방지
    for (const pat of WEAK_PATTERNS) {
      if (pat.re.test(text)) {
        findings.push({
          ssotName: ssot.name,
          ssotPath: ssot.path,
          domain: ssot.domain,
          purpose: ssot.purpose,
          lineNumber: i + 1,
          excerpt: text.trim(),
          weakName: pat.name,
        });
        break; // 라인당 1패턴만 (가장 처음 매칭)
      }
    }
  }
  return findings;
}

function priorityFor(domain, policy) {
  const idx = (policy.domainPriority || []).indexOf(domain);
  return idx === -1 ? 99 : idx;
}

// 침묵 도메인 trigger: wiki/<domain>/_facts.md가 N일 이상 미수정이면 질문 적재.
// id에 yyyy-WW(ISO week) 포함 → 주 1회만 적재.
function scanSilentDomains(policy) {
  const wikiDir = join(HOME, 'jarvis/runtime/wiki');
  if (!existsSync(wikiDir)) return [];
  const thresholdDays = policy.silenceThresholdDays ?? 30;
  const excludeDomains = new Set(policy.excludeDomains || []);
  const silentDomainsExclude = new Set(policy.silenceExcludeDomains || ['career', 'meta']);
  const findings = [];
  const domains = readdirSync(wikiDir).filter(d => {
    try { return statSync(join(wikiDir, d)).isDirectory(); }
    catch { return false; }
  });
  for (const domain of domains) {
    if (excludeDomains.has(domain) || silentDomainsExclude.has(domain)) continue;
    const factsPath = join(wikiDir, domain, '_facts.md');
    if (!existsSync(factsPath)) continue;
    const stat = statSync(factsPath);
    const daysSince = (Date.now() - stat.mtime.getTime()) / (24 * 60 * 60 * 1000);
    if (daysSince < thresholdDays) continue;
    findings.push({
      domain,
      factsPath,
      daysSinceUpdate: Math.floor(daysSince),
    });
  }
  return findings;
}

function isoWeekId() {
  // YYYY-WW (ISO 8601 week)
  const d = new Date();
  const target = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const dayNr = (target.getUTCDay() + 6) % 7;
  target.setUTCDate(target.getUTCDate() - dayNr + 3);
  const firstThursday = target.valueOf();
  target.setUTCMonth(0, 1);
  if (target.getUTCDay() !== 4) {
    target.setUTCMonth(0, 1 + ((4 - target.getUTCDay()) + 7) % 7);
  }
  const week = 1 + Math.ceil((firstThursday - target) / (7 * 24 * 60 * 60 * 1000));
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

const DEFAULT_POLICY = {
  domainPriority: ['owner', 'knowledge', 'meta'],
  excludeDomains: ['career'],
  ignoreLineContains: ['정직 가드', '단언 금지', '사내 자료'],
  questionTemplate: {
    weakPattern: `주인님, **{ssot}** ({ssotPath}) L{line}에 \`'{pattern}'\` 표시가 있습니다.\n\n> {excerpt}\n\n해당 위치의 SSoT 목적: _{purpose}_\n\n어떤 내용으로 채워지면 좋을지 알려주실 수 있을까요?`,
  },
};

function main() {
  const registry = loadJSON(SSOT_REGISTRY_PATH, { ssotFiles: [] });
  const userPolicy = loadJSON(POLICY_PATH, {});
  const policy = {
    ...DEFAULT_POLICY,
    ...userPolicy,
    questionTemplate: { ...DEFAULT_POLICY.questionTemplate, ...(userPolicy.questionTemplate || {}) },
  };

  const existing = loadExistingQueueIds();
  const newQuestions = [];
  const allFindings = [];

  const excludeDomains = new Set(policy.excludeDomains || []);
  // ── trigger 1: weak pattern (SSoT 파일 스캔) ──
  for (const ssotRaw of registry.ssotFiles || []) {
    if (ssotRaw.auditEnabled === false) continue;
    if (excludeDomains.has(ssotRaw.domain)) continue;
    const ssot = { ...ssotRaw, path: expandPath(ssotRaw.path) };
    const findings = scanSsotFile(ssot, policy);
    allFindings.push(...findings);
    for (const f of findings) {
      const id = buildQuestionId(f.ssotName, f.lineNumber, f.weakName);
      if (existing.has(id)) continue;
      const q = {
        id,
        trigger: 'weakPattern',
        domain: f.domain,
        ssot: f.ssotName,
        ssotPath: f.ssotPath,
        lineNumber: f.lineNumber,
        excerpt: f.excerpt,
        weakPattern: f.weakName,
        purpose: f.purpose,
        priority: priorityFor(f.domain, policy),
        questionText: buildQuestionText(policy.questionTemplate.weakPattern, f),
        createdAt: new Date().toISOString(),
        status: 'pending',
      };
      newQuestions.push(q);
    }
  }

  // ── trigger 2: silent domain (_facts.md mtime 기반, 주 1회) ──
  const silentTemplate = policy.questionTemplate.silentDomain
    || `주인님, **{domain}** 도메인의 _facts.md가 {days}일 이상 갱신되지 않았습니다.\n\n경로: {path}\n\n최근 변동 사항이나 새로 기록할 만한 사실이 있다면 한 줄로 공유 부탁드립니다.`;
  const week = isoWeekId();
  for (const s of scanSilentDomains(policy)) {
    const id = `silent-${s.domain}-${week}`;
    if (existing.has(id)) continue;
    const q = {
      id,
      trigger: 'silence',
      domain: s.domain,
      ssot: `wiki/${s.domain}/_facts.md`,
      ssotPath: s.factsPath,
      daysSinceUpdate: s.daysSinceUpdate,
      priority: priorityFor(s.domain, policy),
      questionText: silentTemplate
        .replaceAll('{domain}', s.domain)
        .replaceAll('{days}', String(s.daysSinceUpdate))
        .replaceAll('{path}', s.factsPath.replace(HOME, '~')),
      createdAt: new Date().toISOString(),
      status: 'pending',
    };
    newQuestions.push(q);
  }

  console.log(`# AJQE Generate (${new Date().toISOString()})`);
  console.log(`SSoT 스캔: ${(registry.ssotFiles || []).filter(f => f.auditEnabled !== false).length}개 파일`);
  console.log(`총 발견: ${allFindings.length}건 (약한 표현)`);
  console.log(`기존 큐: ${existing.size}개`);
  console.log(`신규 추가: ${newQuestions.length}건`);

  if (newQuestions.length > 0) {
    const byDomain = {};
    for (const q of newQuestions) byDomain[q.domain] = (byDomain[q.domain] || 0) + 1;
    console.log(`도메인별 신규: ${Object.entries(byDomain).map(([d, n]) => `${d}=${n}`).join(', ')}`);
    console.log(``);
    console.log(`샘플 (첫 3건):`);
    for (const q of newQuestions.slice(0, 3)) {
      if (q.trigger === 'silence') {
        console.log(`  [${q.id}] ${q.ssot} (침묵 ${q.daysSinceUpdate}일)`);
      } else {
        console.log(`  [${q.id}] ${q.ssot}:L${q.lineNumber} (${q.weakPattern})`);
        console.log(`    "${(q.excerpt || '').slice(0, 80)}"`);
      }
    }
  }

  if (DRY_RUN) {
    console.log(``);
    console.log(`🧪 DRY RUN — 큐 미적재`);
    return;
  }

  if (newQuestions.length > 0) {
    mkdirSync(dirname(QUEUE_PATH), { recursive: true });
    const lines = newQuestions.map(q => JSON.stringify(q)).join('\n') + '\n';
    appendFileSync(QUEUE_PATH, lines);
    console.log(``);
    console.log(`✅ ${QUEUE_PATH} 에 ${newQuestions.length}건 적재 완료`);
  } else {
    console.log(``);
    console.log(`✅ 신규 질문 없음 — 큐 변동 없음`);
  }
}

main();
