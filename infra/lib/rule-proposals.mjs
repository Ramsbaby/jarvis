// rule-proposals.mjs — 규칙 승격 **제안서** 저장소 (SELF-HEAL-PLAN 4b)
//
// 배경: mistake-promoter.mjs 의 tier_a 판정은 2026-07-19 부터 규칙 파일에 자동 기재되지 않는다
// (PROMOTER_WRITE_RULES 게이트). 그 뒤 판정 결과는 promoter-ledger 에 `status:"applied"` 로만
// 남고 룰 본문은 버려졌다 — "적용됨" 이라 적히지만 실제로는 아무 데도 반영되지 않는 상태.
// 이 모듈은 그 자리를 **사람이 읽고 승격하는 제안서**로 바꾼다.
//
//   SSoT  : ${BOT_HOME}/state/rule-proposals.json   (기계용 — 이 파일만 편집 대상)
//   렌더  : ${BOT_HOME}/wiki/meta/rule-proposals.md (사람용 — 항상 JSON 에서 재생성, RAG 인제스트)
//   CLI   : infra/scripts/rule-proposal-ctl.mjs (list / show / promote / reject / render)
//
// 불변 규칙:
//   ① 근거(mistake-ledger.jsonl 의 실제 발생 행) 가 MIN_EVIDENCE(3) 미만이면 제안서에 오르지 않는다.
//   ② 같은 제안은 하나만 — 시드 fingerprint 일치 또는 멤버 fingerprint 겹침 ≥ OVERLAP 이면 병합.
//      (2026-07-19 사고: 시드 문구가 매일 조금씩 달라져 같은 룰이 17개의 다른 클러스터 ID 로
//       17번 자동 등재됨. 클러스터 ID(sha256(시드)) 는 dedupe 키로 부적합 — 여기서는 안 쓴다.)
//   ③ 승격(promoted)·기각(rejected) 뒤에 같은 패턴이 다시 오면 새 제안을 만들지 않고
//      해당 제안의 `recurrence_after_decision` 을 올린다 — "룰을 넣었는데도 재발" 신호.
//   ④ 규칙 파일 쓰기는 이 모듈이 하지 않는다. promote 는 상태 전이 + (사람이 --to 로 지정한
//      파일에만) 블록 append.

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, appendFileSync,
} from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';

const HOME = homedir();
export const BOT_HOME = process.env.BOT_HOME || join(HOME, '.openclaw-data', 'runtime');
export const STATE_FILE = process.env.RULE_PROPOSALS_STATE || join(BOT_HOME, 'state', 'rule-proposals.json');
export const MD_FILE = process.env.RULE_PROPOSALS_MD || join(BOT_HOME, 'wiki', 'meta', 'rule-proposals.md');
export const MISTAKE_LEDGER = process.env.MISTAKE_LEDGER_FILE || join(BOT_HOME, 'state', 'mistake-ledger.jsonl');

export const MIN_EVIDENCE = parseInt(process.env.RULE_PROPOSAL_MIN_EVIDENCE || '3', 10);
export const OVERLAP = 0.5;          // 멤버 fingerprint 겹침 비율(작은 쪽 기준) — 이 이상이면 같은 제안
const EVIDENCE_LIST_CAP = 12;        // md 에 나열하는 근거 행 수 (건수는 전체를 센다)
export const STATUSES = ['pending', 'promoted', 'rejected'];

// ─── 유틸 ───
export function nowKST() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().replace(/\.\d+Z$/, '+09:00');
}
export function fingerprint(title) {
  // mistake-recurrence-audit.sh 의 fingerprint() 와 동일 규칙 — 소문자·특수문자 제거·60자
  return String(title || '').toLowerCase().replace(/[^\p{L}\p{N}_]+/gu, ' ').trim().replace(/\s+/g, ' ').slice(0, 60);
}
function sha(s, n = 10) { return createHash('sha256').update(s, 'utf-8').digest('hex').slice(0, n); }
export function proposalIdFor(seed) { return 'rp-' + sha(fingerprint(seed)); }

function emptyState() {
  return { schema_version: 1, updated_at: null, min_evidence: MIN_EVIDENCE, proposals: [] };
}
export function loadState(file = STATE_FILE) {
  if (!existsSync(file)) return emptyState();
  try {
    const d = JSON.parse(readFileSync(file, 'utf-8'));
    if (!Array.isArray(d.proposals)) d.proposals = [];
    return d;
  } catch (e) {
    throw new Error(`rule-proposals 상태 파일 파싱 실패 (${file}): ${e.message} — 손상 파일은 덮어쓰지 않음`);
  }
}
export function saveState(state, file = STATE_FILE) {
  state.updated_at = nowKST();
  state.min_evidence = MIN_EVIDENCE;
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n', 'utf-8');
  renameSync(tmp, file); // 원자 교체 — 크론과 CLI 가 겹쳐도 반쪽 파일이 남지 않는다
}

// ─── 근거 수집: mistake-ledger.jsonl 에서 멤버 제목과 fingerprint 가 같은 발생 행 ───
// 반환: [{ts, title, source, session}] — (ts,fingerprint) 유일, 최신순
export function collectEvidence(members, ledgerFile = MISTAKE_LEDGER) {
  const want = new Set(members.map(fingerprint).filter(Boolean));
  if (!want.size || !existsSync(ledgerFile)) return [];
  const seen = new Set();
  const out = [];
  for (const line of readFileSync(ledgerFile, 'utf-8').split('\n')) {
    if (!line.trim()) continue;
    let d;
    try { d = JSON.parse(line); } catch { continue; } // 손상 행 무시
    const titles = Array.isArray(d.titles) ? d.titles : [];
    for (const t of titles) {
      const fp = fingerprint(t);
      if (!want.has(fp)) continue;
      const k = `${d.ts}|${fp}`;
      if (seen.has(k)) continue;
      seen.add(k);
      out.push({
        ts: d.ts || '', title: String(t).slice(0, 120), source: d.source || '?',
        session: d.session_file ? basename(String(d.session_file)) : null,
      });
    }
  }
  out.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
  return out;
}

// ─── dedupe: 기존 제안과 같은 패턴인가 ───
export function findMatch(state, { seed, members = [] }) {
  const seedFp = fingerprint(seed);
  const memberFps = new Set([seedFp, ...members.map(fingerprint)].filter(Boolean));
  for (const p of state.proposals) {
    if (p.fingerprint === seedFp || (p.seed_fingerprints || []).includes(seedFp)) return { proposal: p, how: 'seed' };
    const theirs = new Set(p.member_fingerprints || []);
    if (!theirs.size || !memberFps.size) continue;
    let inter = 0;
    for (const f of memberFps) if (theirs.has(f)) inter += 1;
    const ratio = inter / Math.min(memberFps.size, theirs.size);
    if (ratio >= OVERLAP) return { proposal: p, how: `overlap ${inter}/${Math.min(memberFps.size, theirs.size)}` };
  }
  return null;
}

function mergeEvidence(existing, incoming) {
  const seen = new Set(existing.map((e) => `${e.ts}|${fingerprint(e.title)}`));
  for (const e of incoming) {
    const k = `${e.ts}|${fingerprint(e.title)}`;
    if (seen.has(k)) continue;
    seen.add(k); existing.push(e);
  }
  existing.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
  return existing;
}

// ─── 등재/병합 ───
// 입력: {cluster_id, seed, members, size, rule_title, rule_block, scenario, reason, sim, judged_by}
// 반환: {action: 'new'|'merged'|'recurred_after_decision'|'insufficient', id, evidence_count, how}
// action 이 'insufficient' 면 상태 파일에 아무것도 쓰지 않는다 (불변 규칙 ①).
export function upsertProposal(input, opts = {}) {
  const stateFile = opts.stateFile || STATE_FILE;
  const ledgerFile = opts.ledgerFile || MISTAKE_LEDGER;
  const dry = !!opts.dryRun;
  const state = loadState(stateFile);
  const members = Array.isArray(input.members) ? input.members : [];
  const evidence = collectEvidence([input.seed, ...members], ledgerFile);
  const ts = nowKST();

  const match = findMatch(state, { seed: input.seed, members });
  if (match) {
    const p = match.proposal;
    const before = p.evidence_count || 0;
    mergeEvidence(p.evidence, evidence);
    p.evidence_count = p.evidence.length;
    const seedFp = fingerprint(input.seed);
    if (!p.seed_fingerprints.includes(seedFp)) p.seed_fingerprints.push(seedFp);
    for (const m of members) { const f = fingerprint(m); if (f && !p.member_fingerprints.includes(f)) p.member_fingerprints.push(f); }
    if (input.cluster_id && !p.cluster_ids.includes(input.cluster_id)) p.cluster_ids.push(input.cluster_id);
    p.last_seen = p.evidence[0]?.ts || ts;
    p.updated_at = ts;
    let action = 'merged';
    if (p.status !== 'pending') {
      action = 'recurred_after_decision';
      p.recurrence_after_decision = (p.recurrence_after_decision || 0) + 1;
    }
    p.history.push({ ts, ev: action, note: `클러스터 ${input.cluster_id || '-'} (${match.how}) 근거 ${before}→${p.evidence_count}` });
    if (!dry) { saveState(state, stateFile); renderMarkdown(state, opts.mdFile); }
    return { action, id: p.id, evidence_count: p.evidence_count, how: match.how, status: p.status };
  }

  if (evidence.length < MIN_EVIDENCE) {
    return { action: 'insufficient', id: proposalIdFor(input.seed), evidence_count: evidence.length, how: `min ${MIN_EVIDENCE}` };
  }
  const p = {
    id: proposalIdFor(input.seed),
    status: 'pending',
    title: String(input.rule_title || input.seed).slice(0, 60),
    seed: String(input.seed).slice(0, 120),
    fingerprint: fingerprint(input.seed),
    seed_fingerprints: [fingerprint(input.seed)],
    member_fingerprints: [...new Set([fingerprint(input.seed), ...members.map(fingerprint)].filter(Boolean))],
    members: members.map((m) => String(m).slice(0, 120)),
    cluster_ids: input.cluster_id ? [input.cluster_id] : [],
    cluster_size: input.size || members.length,
    rule_block: String(input.rule_block || '').trim(),
    scenario: String(input.scenario || '').trim(),
    reason: String(input.reason || '').trim(),
    sim: String(input.sim || '').trim().slice(0, 300),
    judged_by: input.judged_by || null,
    evidence,
    evidence_count: evidence.length,
    first_seen: evidence[evidence.length - 1]?.ts || ts,
    last_seen: evidence[0]?.ts || ts,
    created_at: ts, updated_at: ts,
    promoted_at: null, promoted_to: null, rejected_at: null, reject_reason: null,
    recurrence_after_decision: 0,
    history: [{ ts, ev: 'new', note: `클러스터 ${input.cluster_id || '-'} 근거 ${evidence.length}건` }],
  };
  state.proposals.push(p);
  if (!dry) { saveState(state, stateFile); renderMarkdown(state, opts.mdFile); }
  return { action: 'new', id: p.id, evidence_count: p.evidence_count, how: 'new', status: 'pending' };
}

// ─── 상태 전이 (사람의 결정) ───
export function findProposal(state, idOrPrefix) {
  const hit = state.proposals.filter((p) => p.id === idOrPrefix || p.id.startsWith(idOrPrefix));
  if (hit.length === 1) return hit[0];
  if (hit.length > 1) throw new Error(`모호한 id: ${idOrPrefix} → ${hit.map((p) => p.id).join(', ')}`);
  return null;
}

function ruleBlockFor(p) {
  const day = nowKST().slice(0, 10);
  return [
    '',
    `<!-- RP:BEGIN id=${p.id} promoted=${day} -->`,
    `## ${p.title} (제안 ${p.id} · 승격 ${day})`,
    '',
    p.rule_block,
    '',
    `- 출처: 규칙 제안서 \`${p.id}\` — 근거 ${p.evidence_count}건 (${p.first_seen.slice(0, 10)} ~ ${p.last_seen.slice(0, 10)}), 클러스터 ${p.cluster_ids.join(', ') || '-'}`,
    `<!-- RP:END id=${p.id} -->`,
    '',
  ].join('\n');
}

// promote: pending → promoted. `to` 가 있으면 그 파일 끝에 블록을 붙인다 (사람이 지정한 파일만).
export function promoteProposal(idOrPrefix, { to = null, note = '', by = 'human' } = {}, opts = {}) {
  const stateFile = opts.stateFile || STATE_FILE;
  const state = loadState(stateFile);
  const p = findProposal(state, idOrPrefix);
  if (!p) throw new Error(`제안 없음: ${idOrPrefix}`);
  if (p.status === 'promoted') return { action: 'already', id: p.id, promoted_to: p.promoted_to };
  if (!p.rule_block) throw new Error(`${p.id}: rule_block 이 비어 있어 승격할 수 없습니다`);
  let written = null;
  if (to) {
    const target = to.startsWith('~/') ? join(HOME, to.slice(2)) : to;
    if (existsSync(target) && readFileSync(target, 'utf-8').includes(`RP:BEGIN id=${p.id} `)) {
      written = `${target} (이미 존재 — 중복 append 생략)`;
    } else {
      mkdirSync(dirname(target), { recursive: true });
      appendFileSync(target, ruleBlockFor(p), 'utf-8');
      written = target;
    }
  }
  const ts = nowKST();
  p.status = 'promoted'; p.promoted_at = ts; p.promoted_to = to || note || '(수동 반영)'; p.updated_at = ts;
  p.history.push({ ts, ev: 'promoted', note: `${by}: ${to || note || '수동 반영'}` });
  saveState(state, stateFile); renderMarkdown(state, opts.mdFile);
  return { action: 'promoted', id: p.id, promoted_to: p.promoted_to, written };
}

export function rejectProposal(idOrPrefix, { reason, by = 'human' }, opts = {}) {
  if (!reason || !String(reason).trim()) throw new Error('reject: --reason 필요 — 기각 사유 없는 제안은 닫지 않는다');
  const stateFile = opts.stateFile || STATE_FILE;
  const state = loadState(stateFile);
  const p = findProposal(state, idOrPrefix);
  if (!p) throw new Error(`제안 없음: ${idOrPrefix}`);
  if (p.status === 'rejected') return { action: 'already', id: p.id };
  const ts = nowKST();
  p.status = 'rejected'; p.rejected_at = ts; p.reject_reason = String(reason).trim(); p.updated_at = ts;
  p.history.push({ ts, ev: 'rejected', note: `${by}: ${p.reject_reason}` });
  saveState(state, stateFile); renderMarkdown(state, opts.mdFile);
  return { action: 'rejected', id: p.id };
}

export function reopenProposal(idOrPrefix, { note = '', by = 'human' } = {}, opts = {}) {
  const stateFile = opts.stateFile || STATE_FILE;
  const state = loadState(stateFile);
  const p = findProposal(state, idOrPrefix);
  if (!p) throw new Error(`제안 없음: ${idOrPrefix}`);
  if (p.status === 'pending') return { action: 'already', id: p.id };
  const ts = nowKST();
  p.status = 'pending'; p.updated_at = ts;
  p.history.push({ ts, ev: 'reopened', note: `${by}: ${note || 'reopen'}` });
  saveState(state, stateFile); renderMarkdown(state, opts.mdFile);
  return { action: 'reopened', id: p.id };
}

// ─── 요약/렌더 ───
export function summarize(state) {
  const by = { pending: 0, promoted: 0, rejected: 0 };
  let recurred = 0;
  for (const p of state.proposals) { by[p.status] = (by[p.status] || 0) + 1; if (p.recurrence_after_decision) recurred += 1; }
  return { total: state.proposals.length, ...by, recurred_after_decision: recurred };
}
export function summaryLine(state) {
  const s = summarize(state);
  return `규칙 제안 대기 ${s.pending}건 — 승격 ${s.promoted}건, 기각 ${s.rejected}건, 결정 후 재발 ${s.recurred_after_decision}건`;
}

function d10(ts) { return ts ? String(ts).slice(0, 10) : '-'; }
function esc(s) { return String(s || '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' '); }

export function renderMarkdown(state, mdFile = MD_FILE) {
  const s = summarize(state);
  const pending = state.proposals.filter((p) => p.status === 'pending').sort((a, b) => b.evidence_count - a.evidence_count);
  const decided = state.proposals.filter((p) => p.status !== 'pending').sort((a, b) => (a.updated_at < b.updated_at ? 1 : -1));
  const L = [];
  L.push('---');
  L.push('category: meta');
  L.push('title: 규칙 승격 제안서 (자동 생성 · 사람이 승격)');
  L.push(`last_updated: ${state.updated_at || nowKST()}`);
  L.push('schema_version: 1');
  L.push('generated_by: infra/lib/rule-proposals.mjs');
  L.push('---');
  L.push('');
  L.push('# 규칙 승격 제안서');
  L.push('');
  L.push('> **이 파일은 규칙이 아니다.** `mistake-promoter.mjs`(매일 04:10) 가 반복 실수 클러스터를 판정해 룰 초안을 여기에 **제안**한다.');
  L.push(`> 규칙 파일에 넣는 결정은 사람이 한다. 근거 ${state.min_evidence}건 미만인 항목은 여기에 오르지 않는다. 같은 패턴은 병합되어 하나만 남는다.`);
  L.push('> 정본은 `runtime/state/rule-proposals.json` — 이 문서는 거기서 재생성되므로 직접 편집하지 않는다.');
  L.push('>');
  L.push('> 승격: `node ~/projects/jarvis/infra/scripts/rule-proposal-ctl.mjs promote <id> --to ~/.claude/rules/<파일>.md`');
  L.push('> 기각: `node ~/projects/jarvis/infra/scripts/rule-proposal-ctl.mjs reject <id> --reason "<사유>"`');
  L.push('');
  L.push(`**${summaryLine(state)}** (총 ${s.total}건)`);
  L.push('');
  L.push(`## 대기 중 ${pending.length}건`);
  L.push('');
  if (!pending.length) {
    L.push('_없음_');
  } else {
    L.push('| id | 제목 | 근거 | 첫 발생 | 마지막 발생 | 클러스터 |');
    L.push('|---|---|---|---|---|---|');
    for (const p of pending) {
      L.push(`| \`${p.id}\` | ${esc(p.title)} | ${p.evidence_count}건 | ${d10(p.first_seen)} | ${d10(p.last_seen)} | ${p.cluster_ids.length}개 |`);
    }
  }
  for (const p of pending) {
    L.push('');
    L.push(`### \`${p.id}\` — ${p.title} (근거 ${p.evidence_count}건)`);
    L.push('');
    L.push(`- 시드: ${esc(p.seed)}`);
    L.push(`- 판정 근거: ${esc(p.reason) || '-'}`);
    L.push(`- 시뮬(룰 주입 시 교정 예상): ${esc(p.sim).slice(0, 160) || '-'}`);
    L.push(`- 클러스터: ${p.cluster_ids.map((c) => `\`${c}\``).join(', ') || '-'} · 멤버 ${p.members.length}개 · 제안 ${d10(p.created_at)} · 갱신 ${d10(p.updated_at)}`);
    L.push('');
    L.push('**제안 규칙 본문**');
    L.push('');
    L.push('```text');
    L.push(p.rule_block || '(비어 있음)');
    L.push('```');
    L.push('');
    L.push(`**재현 상황**: ${p.scenario || '-'}`);
    L.push('');
    L.push(`**근거** (${p.evidence_count}건${p.evidence_count > EVIDENCE_LIST_CAP ? `, 최근 ${EVIDENCE_LIST_CAP}건만 표시` : ''})`);
    L.push('');
    for (const e of p.evidence.slice(0, EVIDENCE_LIST_CAP)) {
      L.push(`- ${d10(e.ts)} [${e.source}] ${esc(e.title)}${e.session ? ` — \`${e.session}\`` : ''}`);
    }
  }
  L.push('');
  L.push(`## 결정됨 — 승격 ${s.promoted}건 · 기각 ${s.rejected}건`);
  L.push('');
  if (!decided.length) {
    L.push('_없음_');
  } else {
    L.push('| id | 제목 | 결정 | 일시 | 결정 후 재발 | 비고 |');
    L.push('|---|---|---|---|---|---|');
    for (const p of decided) {
      const when = p.status === 'promoted' ? p.promoted_at : p.rejected_at;
      const memo = p.status === 'promoted' ? p.promoted_to : p.reject_reason;
      L.push(`| \`${p.id}\` | ${esc(p.title)} | ${p.status === 'promoted' ? '승격' : '기각'} | ${d10(when)} | ${p.recurrence_after_decision || 0}회 | ${esc(memo)} |`);
    }
  }
  L.push('');
  mkdirSync(dirname(mdFile), { recursive: true });
  const tmp = `${mdFile}.tmp-${process.pid}`;
  writeFileSync(tmp, L.join('\n'), 'utf-8');
  renameSync(tmp, mdFile);
  return mdFile;
}
