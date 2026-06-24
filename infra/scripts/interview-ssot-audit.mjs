#!/usr/bin/env node
/**
 * interview-ssot-audit.mjs
 *
 * SSoT 분기 자동 검출 — user-profile.md (SSoT) ↔ interview-fast-path.js STAR_LOOKUP cross-check.
 *
 * 배경: 2026-04-26 STAR-1 / STAR-S1 분기 사고 두 번 — 같은 사실이 코드와 문서에 별개 hardcoded.
 * 가드: 주간 cron으로 자동 실행, 분기 발견 시 Discord alert.
 *
 * 사용:
 *   node interview-ssot-audit.mjs           # 분기 list 출력 (exit 0=일치, 1=분기)
 *   node interview-ssot-audit.mjs --notify  # 분기 시 Discord webhook 송출 (jarvis-interview)
 */
import { readFileSync, existsSync } from 'node:fs';
import { parseStarLookup } from '../discord/lib/star-lookup.mjs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const UP_PATH = join(homedir(), 'jarvis/runtime/context/user-profile.md');
const FP_PATH = join(homedir(), 'jarvis/infra/discord/lib/interview-fast-path.js');
const MONITORING_PATH = join(homedir(), 'jarvis/runtime/config/monitoring.json');
// v2.0 (2026-04-27 주인님 지시·verify-20260427-141350 권고 P0-1):
// _facts.md ↔ user-profile.md 양방향 분기 검사 추가. 본 사고 재발 자동 감지 가드.
const FACTS_PATH = join(homedir(), 'jarvis/runtime/wiki/career/_facts.md');

// v3.1 (2026-04-27 주인님 승인 — Registry 패턴 도입):
// 모든 LLM 주입 SSoT를 ~/jarvis/runtime/context/ssot-registry.json에서 읽어 자동 순회.
// 새 SSoT 추가 시 registry에 등록만 하면 자동 가드 적용.
const SSOT_REGISTRY_PATH = join(homedir(), 'jarvis/runtime/context/ssot-registry.json');

function loadSsotRegistry() {
  if (!existsSync(SSOT_REGISTRY_PATH)) {
    console.warn(`⚠️ ssot-registry.json 부재 — fallback hardcoded list 사용`);
    return {
      ssotFiles: [
        { name: 'owner-preferences', path: join(homedir(), 'jarvis/runtime/context/owner/preferences.md'), factsCandidates: ['knowledge', 'meta'], deepTagPrefixes: ['preference-deep', 'comm-deep'], auditEnabled: true },
        { name: 'owner-visualization', path: join(homedir(), 'jarvis/runtime/context/owner/visualization.md'), factsCandidates: ['knowledge'], deepTagPrefixes: ['viz-deep', 'design-deep'], auditEnabled: true },
        { name: 'owner-persona', path: join(homedir(), 'jarvis/runtime/context/owner/persona.md'), factsCandidates: ['meta'], deepTagPrefixes: ['persona-deep'], auditEnabled: true },
      ],
    };
  }
  try {
    const reg = JSON.parse(readFileSync(SSOT_REGISTRY_PATH, 'utf-8'));
    // ~ 경로 확장
    for (const f of reg.ssotFiles || []) {
      if (typeof f.path === 'string' && f.path.startsWith('~/')) {
        f.path = join(homedir(), f.path.slice(2));
      }
    }
    return reg;
  } catch (err) {
    console.warn(`⚠️ ssot-registry.json 파싱 실패: ${err.message}`);
    return { ssotFiles: [] };
  }
}

const SSOT_REGISTRY = loadSsotRegistry();
// owner 도메인만 추출 (career는 별도 audit으로 처리)
const OWNER_SSOT_FILES = (SSOT_REGISTRY.ssotFiles || []).filter(f => f.domain === 'owner' && f.auditEnabled !== false);

// user-profile.md에서 ### STAR-X 섹션별 본문 추출 (헤더 포함 — 헤더에만 등장하는 단어도 SSoT)
function parseUserProfileStars() {
  if (!existsSync(UP_PATH)) return {};
  const content = readFileSync(UP_PATH, 'utf-8');
  const stars = {};
  const sections = content.split(/(?=^### STAR-)/m).slice(1);
  for (const sec of sections) {
    const headerMatch = sec.match(/^### (STAR-[A-Z0-9]+)\.\s*([^\n]*)/);
    if (!headerMatch) continue;
    const id = headerMatch[1];
    const title = headerMatch[2].trim();
    // 헤더 포함한 전체 섹션 (다음 STAR 섹션 직전까지)
    const body = sec.split(/^### STAR-/m)[0];
    stars[id] = { title, body };
  }
  return stars;
}

// QUESTION_STAR_MAPPING hints 영역 추출 (각 hint string)
function parseFastPathHints() {
  if (!existsSync(FP_PATH)) return [];
  const content = readFileSync(FP_PATH, 'utf-8');
  const mappingMatch = content.match(/const QUESTION_STAR_MAPPING = \[([\s\S]*?)\n\];/);
  if (!mappingMatch) return [];
  const hints = [];
  const hintBlocks = mappingMatch[1].matchAll(/hints:\s*\[([\s\S]*?)\]/g);
  for (const m of hintBlocks) {
    const blockHints = [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1]);
    hints.push(...blockHints);
  }
  return hints;
}

// evidenceWhitelist (backtick template literal) line별 추출
function parseFastPathEvidence() {
  if (!existsSync(FP_PATH)) return [];
  const content = readFileSync(FP_PATH, 'utf-8');
  const evMatch = content.match(/const evidenceWhitelist = isOffWhitelist[\s\S]*?:\s*`([\s\S]*?)`;/);
  if (!evMatch) return [];
  return evMatch[1].split('\n').map(l => l.trim().replace(/^•\s*/, '')).filter(Boolean);
}

// 텍스트에서 숫자 토큰 추출 (단위 포함) — 자유 텍스트의 SSoT 검증용
function extractNumberTokens(text) {
  const tokens = new Set();
  // 숫자 + 한국어 단위 (e.g. '20대', '30%', '3시간 12분', '124,984 청크')
  for (const m of text.matchAll(/\d[\d,.]*\s*(?:대|개|초|분|시간|일|주|건|줄|%|s|ms|gb|mb|만|배|회|호실|호)/gi)) {
    tokens.add(m[0].replace(/\s+/g, ' ').trim());
  }
  // 단순 큰 숫자 (4자리+)
  for (const m of text.matchAll(/\b\d{4,}\b/g)) {
    tokens.add(m[0]);
  }
  // 화살표 표기 (e.g. '20대 → 5대', '3~4분 → 10초')
  for (const m of text.matchAll(/\d[\d,.]*\s*(?:대|개|초|분|시간|일|건|%|s|ms)?\s*[→─-]+\s*\d[\d,.]*\s*(?:대|개|초|분|시간|일|건|%|s|ms)?/g)) {
    tokens.add(m[0].replace(/\s+/g, ' ').trim());
  }
  return [...tokens];
}

// STAR_LOOKUP 추출 — fast-path.js는 더 이상 하드코딩하지 않고 user-profile.md(SSoT)의
// 메타 라인(<!-- lookup: ... -->)에서 런타임 생성한다(2026-06-24 수리). audit도 동일
// 파서를 공유하므로, 이 검사는 사실상 "본문 산문 ↔ 메타 라인" 정합성 + 메타 라인 누락
// STAR 검출이 된다. fast-path의 정규식 추출과 달리 SSoT가 갈라질 수 없는 구조.
function parseFastPathStars() {
  if (!existsSync(UP_PATH)) return {};
  const lookup = parseStarLookup(readFileSync(UP_PATH, 'utf-8'));
  const stars = {};
  for (const [fpId, info] of Object.entries(lookup)) {
    const upId = fpId.match(/^(STAR-[A-Z0-9]+)/)?.[1];
    if (!upId) continue;
    stars[upId] = {
      fpId,
      numbers: info.numbers,
      techs: info.techs,
      projects: info.projects,
      desc: info.desc,
    };
  }
  return stars;
}

// fast-path token이 user-profile body에 등장하는지 (tilde/콤마/대소문자 정규화)
function bodyContains(upBody, token) {
  if (!token || String(token).length < 1) return true;
  const tokenRaw = String(token).toLowerCase().trim();
  if (!tokenRaw) return true;
  const haystackRaw = upBody.toLowerCase();
  const haystackNoComma = haystackRaw.replace(/,/g, ''); // 12,345 ↔ 12345 매칭

  // 1) raw 직접 매칭
  if (haystackRaw.includes(tokenRaw)) return true;
  if (haystackNoComma.includes(tokenRaw)) return true;

  // 2) 숫자 부분만 매칭 (예: '5~8대' → '5'와 '8' 모두 user-profile에 있는지)
  const numStr = tokenRaw.replace(/[^\d]/g, '');
  if (numStr && numStr.length >= 3 && haystackNoComma.includes(numStr)) return true;

  // 3) 단위 분리 (예: '5~8대' → '5', '8', '대' 각각 + 결합도 체크)
  const segments = tokenRaw.split(/[~\-]/);
  if (segments.length > 1) {
    const allSegmentsFound = segments.every(seg => {
      const segNum = seg.replace(/[^\d]/g, '');
      return segNum && haystackNoComma.includes(segNum);
    });
    if (allSegmentsFound) return true;
  }

  return false;
}

function audit() {
  const upStars = parseUserProfileStars();
  const upWholeText = existsSync(UP_PATH) ? readFileSync(UP_PATH, 'utf-8') : '';
  const fpStars = parseFastPathStars();
  const issues = [];

  // 단순화: fast-path token이 user-profile.md 어디에든 등장하는지 검사 (STAR section 분리는 정확 매핑 어려움).
  // 진짜 분기(STAR-1 옛 SSoT 같은 사고)는 token이 user-profile 전체에서 0건 → 잡음.
  for (const [id, fp] of Object.entries(fpStars)) {
    const up = upStars[id];
    if (!up) {
      issues.push({ severity: 'error', id, msg: `fast-path STAR_LOOKUP에 정의되었으나 user-profile.md에 ${id} 섹션 없음` });
      continue;
    }
    const orphanedNumbers = fp.numbers.filter(n => !bodyContains(upWholeText, n));
    const orphanedTechs = fp.techs.filter(t => !bodyContains(upWholeText, t));
    if (orphanedNumbers.length) {
      issues.push({ severity: 'warn', id, kind: 'numbers', items: orphanedNumbers, msg: `${id} (${up.title}): fast-path numbers ${orphanedNumbers.length}개가 user-profile.md 전체에 없음 → ${orphanedNumbers.join(', ')}` });
    }
    if (orphanedTechs.length) {
      issues.push({ severity: 'warn', id, kind: 'techs', items: orphanedTechs, msg: `${id} (${up.title}): fast-path techs ${orphanedTechs.length}개가 user-profile.md 전체에 없음 → ${orphanedTechs.join(', ')}` });
    }
  }

  for (const upId of Object.keys(upStars)) {
    if (upId === 'S1' || upId === 'S2' || upId.startsWith('STAR-S')) continue;
    if (!fpStars[upId]) {
      issues.push({ severity: 'info', id: upId, msg: `${upId} (${upStars[upId].title}): user-profile.md에 있으나 fast-path STAR_LOOKUP 미등록 (의도적이면 무시)` });
    }
  }

  // 확장 audit: QUESTION_STAR_MAPPING hints 영역 숫자 토큰 cross-check
  const hints = parseFastPathHints();
  const hintTokens = new Set();
  for (const h of hints) {
    for (const t of extractNumberTokens(h)) hintTokens.add(t);
  }
  const orphanedHintTokens = [...hintTokens].filter(t => !bodyContains(upWholeText, t));
  if (orphanedHintTokens.length) {
    issues.push({
      severity: 'warn',
      id: 'HINTS',
      msg: `QUESTION_STAR_MAPPING hints 숫자 ${orphanedHintTokens.length}개가 user-profile.md 전체에 없음 → ${orphanedHintTokens.join(', ')}`,
    });
  }

  // 확장 audit: evidenceWhitelist 숫자 토큰 cross-check
  const evidenceLines = parseFastPathEvidence();
  const evTokens = new Set();
  for (const line of evidenceLines) {
    for (const t of extractNumberTokens(line)) evTokens.add(t);
  }
  const orphanedEvTokens = [...evTokens].filter(t => !bodyContains(upWholeText, t));
  if (orphanedEvTokens.length) {
    issues.push({
      severity: 'warn',
      id: 'EVIDENCE',
      msg: `evidenceWhitelist 숫자 ${orphanedEvTokens.length}개가 user-profile.md 전체에 없음 → ${orphanedEvTokens.join(', ')}`,
    });
  }

  // v2.0 (2026-04-27 P0-1): _facts.md ↔ user-profile.md 양방향 분기 검사.
  // 본 사고 (2026-04-27): _facts.md에 interview-deep-* 태그로 풀 디테일 존재했으나
  // user-profile.md에 한 줄짜리만 있어 자비스가 PENDING으로 처리한 사고.
  // 검사 방향: _facts.md의 interview-deep-* unique source 추출 → user-profile.md에 키워드 흡수 여부 검사.
  const factsAbsorption = auditFactsMdAbsorption();
  issues.push(...factsAbsorption);

  // v3.0 (2026-04-27 도메인 일반화): owner 도메인 SSoT 단일 파일 존재 + 한 줄짜리 행 검출.
  const ownerCheck = auditOwnerSsotFiles();
  issues.push(...ownerCheck);

  return { issues, upStars, fpStars, hintsCount: hints.length, evidenceLinesCount: evidenceLines.length, factsSourcesCount: factsAbsorption.factsSourcesCount || 0 };
}

// v3.0: owner 도메인 SSoT 단일 파일 audit.
// 목적: preferences/visualization/persona가 user-profile.md와 동일한 PENDING 단정 사고 방지.
// 검사 1) 파일 존재. 2) 한 줄짜리 항목(예: 'TODO', 'PENDING', '미정', '추정', '미확인') 존재 시 warn.
//       3) 도메인 _facts.md에 deep-tagged 사실 있는데 SSoT에 흡수 안 됐는지 (현재 owner 도메인은 deep-tag 사전 없으므로 info로 시작).
function auditOwnerSsotFiles() {
  const issues = [];
  for (const ssot of OWNER_SSOT_FILES) {
    if (!existsSync(ssot.path)) {
      issues.push({
        severity: 'error',
        id: `OWNER-${ssot.name}`,
        msg: `🚨 owner SSoT 단일 파일 부재: ${ssot.path} — LLM 주입 SSoT 누락 위험. example 파일에서 복사하여 생성 필요.`,
      });
      continue;
    }
    const content = readFileSync(ssot.path, 'utf-8');
    const lines = content.split('\n');
    // PENDING/미정/추정/TODO 등 약한 표현 검출
    const weakPatterns = [/PENDING/i, /🚧/, /\bTODO\b/, /미정/, /미확인/, /추정\s*(?:값|치)/, /기억\s*흐릿/, /흐릿/];
    const weakLines = lines
      .map((l, i) => ({ n: i + 1, text: l }))
      .filter(({ text }) => weakPatterns.some(p => p.test(text)));
    if (weakLines.length > 0) {
      issues.push({
        severity: 'warn',
        id: `OWNER-${ssot.name}-weak`,
        msg: `${ssot.name}: 약한 표현 ${weakLines.length}건 — ${weakLines.slice(0, 3).map(w => `L${w.n}: "${w.text.slice(0, 50)}"`).join(' | ')}. cross-search로 사실 보강 권고.`,
      });
    }
    // 도메인 _facts.md cross-search 후보
    for (const factsDomain of ssot.factsCandidates) {
      const factsPath = join(homedir(), `jarvis/runtime/wiki/${factsDomain}/_facts.md`);
      if (!existsSync(factsPath)) continue;
      const facts = readFileSync(factsPath, 'utf-8');
      // ssot.name과 도메인 매칭되는 deep-tag 검색 (예: 'preferences-deep', 'persona-deep')
      const tagPattern = new RegExp(`\\[source:.*-deep-${ssot.name.replace('owner-', '')}|${ssot.name.replace('owner-', '')}-deep`, 'gi');
      const matches = [...facts.matchAll(tagPattern)];
      if (matches.length > 0) {
        // 흡수 검사 — 매칭된 라인의 키워드가 SSoT에 있는지 (간이)
        const ssotLower = content.toLowerCase();
        // 단순히 매칭 카운트만 알림 (정밀 흡수 검사는 keywordHints 사전 필요)
        issues.push({
          severity: 'info',
          id: `OWNER-${ssot.name}-deep`,
          msg: `${ssot.name}: wiki/${factsDomain}/_facts.md에 deep-tag ${matches.length}건 발견 — SSoT 흡수 여부 수동 확인 권고`,
        });
      }
    }
  }
  return issues;
}

// v2.0: _facts.md absorption 검사 — interview-deep-* 태그 source가 user-profile.md에 흡수됐는지.
// 키워드 매칭(영역 명사 OR 합성). 매칭 실패 = 자비스가 user-profile만 보고 결정 시 사실 누락 위험.
function auditFactsMdAbsorption() {
  const issues = [];
  if (!existsSync(FACTS_PATH)) return issues;
  if (!existsSync(UP_PATH)) return issues;

  const factsContent = readFileSync(FACTS_PATH, 'utf-8');
  const upContent = readFileSync(UP_PATH, 'utf-8').toLowerCase();

  // [source:interview-deep-<영역>] 태그 unique source 추출
  const sources = new Map();
  for (const m of factsContent.matchAll(/\[source:interview-deep-([a-z0-9-]+)\]/g)) {
    const src = m[1];
    sources.set(src, (sources.get(src) || 0) + 1);
  }

  // 영역 키워드 사전 (source 토큰 → user-profile 매칭 기대 키워드)
  // 예: 'jandi-deadlock' → ['잔디드라이브', '데드락'] OR ['jandi', 'deadlock']
  const keywordHints = {
    'jandi-batch': ['배치', '20배', '멤버 접속'],
    'jandi-deadlock': ['잔디드라이브', '데드락', 'race condition'],
    'jandi-zombie': ['좀비 캐시', '한도 카운터', 'ttl'],
    'jandi-redis': ['리액션', 'redis set', 'sadd'],
    'jandi-grpc': ['grpc', '인증서버', '30대'],
    'jandi-kafka': ['kafka eda', 'choreography', '토픽'],
    'skd-deadlock': ['스케줄러 데드락', 'lock 20초', 'requires_new'],
    'skd-deadlock-cleanup': ['스케줄러 데드락'],
    'skd-iot': ['iot', 'adapter', '벤더'],
    'skd-vt': ['virtual thread', 'hikaricp', '50'],
    'skd-sqs': ['sqs', 'dlq', '멱등'],
    'skd-hectofs': ['핵토', '가상계좌', '3중'],
    'skd-eroom': ['eroom', '이룸', '마이그레이션', '27만'],
    'skd-metaagent': ['메타에이전트', '메타브릿지', '사내 ai'],
    'skd-redisson': ['redisson', 'rlock', 'iot 장비'],
  };

  const orphanSources = [];
  for (const [src, count] of sources) {
    const hints = keywordHints[src];
    if (!hints) {
      // 사전에 없는 새 source — 무시(false positive 방지)하되 info 로깅
      issues.push({
        severity: 'info',
        id: `FACTS-${src}`,
        msg: `_facts.md interview-deep-${src} (${count}건) 키워드 사전 미등록 — keywordHints에 추가 권고`,
      });
      continue;
    }
    // 매칭: 등록된 키워드 중 1개 이상이 user-profile에 등장하면 흡수된 것으로 간주
    const found = hints.some(k => upContent.includes(k.toLowerCase()));
    if (!found) {
      orphanSources.push({ src, count, hints });
      issues.push({
        severity: 'error',
        id: `FACTS-${src}`,
        msg: `🚨 _facts.md interview-deep-${src} (${count}건 사실)이 user-profile.md에 흡수되지 않음 — LLM 시스템 프롬프트에서 누락. 기대 키워드: [${hints.join(', ')}]. 즉시 user-profile.md에 STAR 섹션 추가 필요.`,
      });
    }
  }

  // 부가 통계
  issues.factsSourcesCount = sources.size;
  if (orphanSources.length === 0 && sources.size > 0) {
    issues.push({
      severity: 'info',
      id: 'FACTS-OK',
      msg: `✅ _facts.md interview-deep-* ${sources.size}개 source 모두 user-profile.md에 흡수 확인.`,
    });
  }

  return issues;
}

async function notifyWebhook(text) {
  try {
    if (!existsSync(MONITORING_PATH)) return;
    const cfg = JSON.parse(readFileSync(MONITORING_PATH, 'utf-8'));
    const url = cfg.webhooks?.['jarvis-interview'];
    if (!url) return;
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: text.slice(0, 1990) }),
    });
  } catch { /* ignore */ }
}

const NOTIFY = process.argv.includes('--notify');
const result = audit();

console.log(`# Interview SSoT Audit (${new Date().toISOString()})`);
console.log(`SSoT  : ${UP_PATH}`);
console.log(`Target: ${FP_PATH}`);
console.log(``);
console.log(`STAR_LOOKUP (fast-path): ${Object.keys(result.fpStars).length}개`);
console.log(`STAR sections (user-profile): ${Object.keys(result.upStars).length}개`);
console.log(`QUESTION_STAR_MAPPING hints: ${result.hintsCount}개`);
console.log(`evidenceWhitelist lines: ${result.evidenceLinesCount}개`);
console.log(``);

if (result.issues.length === 0) {
  console.log(`✅ 분기 없음 — SSoT 완전 일치`);
  if (NOTIFY) await notifyWebhook(`✅ Interview SSoT Audit: 분기 없음`);
  process.exit(0);
}

const errors = result.issues.filter(i => i.severity === 'error');
const warns = result.issues.filter(i => i.severity === 'warn');
const infos = result.issues.filter(i => i.severity === 'info');

console.log(`🚨 ${result.issues.length}개 issue (error ${errors.length}, warn ${warns.length}, info ${infos.length}):`);
console.log(``);
for (const line of [...errors, ...warns, ...infos]) {
  const prefix = line.severity === 'error' ? '❌' : line.severity === 'warn' ? '⚠️ ' : 'ℹ️ ';
  console.log(`${prefix} ${line.msg}`);
}
console.log(``);
console.log(`# 권고: user-profile.md (SSoT) 기준으로 fast-path.js STAR_LOOKUP 정정`);
console.log(`# (warn 수치는 정확 substring 매칭 한계로 false positive 가능 — 사용자 확인 필요)`);

if (NOTIFY) {
  const summary = `🚨 **Interview SSoT Audit 분기 ${result.issues.length}건** (error ${errors.length}, warn ${warns.length})\n${[...errors, ...warns].slice(0, 10).map(l => `• ${l.msg.slice(0, 200)}`).join('\n')}`;
  await notifyWebhook(summary);
}

process.exit(errors.length > 0 ? 1 : 0);
