// insight-store.mjs — 통찰 도메인: 통찰을 휘발성 메시지가 아니라 영속 자산으로.
//
// 주인님 비전: ① 함께 고민 ② 까먹지 않음 ③ 먼저 챙김.
// 이 스토어가 ①②의 척추 — 각 통찰이 생애주기(open→answered→resolved)와 도메인을 갖고,
// 다음 통찰은 백지가 아니라 "열린 통찰 + 주인님 답" 위에서 자란다(진화·중복방지).
//
// append-only JSONL (감사 가능). id별 최신 상태로 집계.

import { readFileSync, appendFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const BOT_HOME = process.env.BOT_HOME || join(process.env.HOME, 'jarvis/runtime');
const STORE = join(BOT_HOME, 'state/owner-state/insight-store.jsonl');

const VALID_DOMAINS = ['career', 'health', 'family', 'finance', 'life'];
const DOMAIN_PATTERNS = {
  career: /면접|코테|코딩테스트|이직|커리어|DOP|자격증|공고|지원|취업|연봉|채용|면접관/g,
  health: /건강|체중|수면|단식|컨디션|피로|운동|식사|영양|몸|스트레스/g,
  family: /가족|여행|아내|딸|아들|부모|배우자/g,
  finance: /투자|주식|포트폴리오|단타|환전/g,
};
// first-match-wins → 최다 득표 (각 도메인 키워드 히트 수). 동점 우선순위: 본인 관련(health) 우선.
function classifyDomain(text) {
  const t = String(text);
  const score = {};
  for (const [d, re] of Object.entries(DOMAIN_PATTERNS)) score[d] = (t.match(re) || []).length;
  const order = ['health', 'family', 'finance', 'career'];
  let best = 'life', bestScore = 0;
  for (const d of order) if (score[d] > bestScore) { best = d; bestScore = score[d]; }
  return best;
}

function hashId(s) { let h = 0; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) | 0; return Math.abs(h).toString(36).slice(0, 6); }

// 발송 통찰을 스토어에 영속 (status: open) + id 부여
export function persistInsights(insights, ts) {
  const stamp = ts || new Date().toISOString();
  return insights.map(x => {
    const id = 'ist-' + stamp.replace(/[^0-9]/g, '').slice(0, 8) + '-' + hashId(x.insight);
    // LLM 자기선언 domain 우선(유효 enum일 때). 무효·부재면 키워드 분류 폴백.
    const domain = (x.domain && VALID_DOMAINS.includes(x.domain)) ? x.domain : classifyDomain((x.insight || '') + (x.action || ''));
    appendFileSync(STORE, JSON.stringify({
      event: 'sent', id, ts: stamp, domain,
      status: 'open', type: x.type, insight: x.insight, action: x.action || '', question: x.question || '',
    }) + '\n');
    return { ...x, id };
  });
}

// 열린(미해결) 통찰 로드 — 다음 통찰이 중복 안 내고 진화하도록 주입
export function loadOpenInsights(limit = 12) {
  if (!existsSync(STORE)) return [];
  const rows = readFileSync(STORE, 'utf-8').trim().split('\n').filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const byId = new Map();
  for (const r of rows) byId.set(r.id, { ...(byId.get(r.id) || {}), ...r });   // id별 최신 상태
  return [...byId.values()]
    // open(미해결) + answered(주인님이 답함, 최근 3일) → 답한 통찰도 다음 판단에 넣어 진화시킨다
    .filter(x => x.status === 'open' || (x.status === 'answered' && x.owner_answer && (Date.now() - new Date(x.ts)) / 86400000 < 3))
    .sort((a, b) => (b.ts || '').localeCompare(a.ts || ''))
    .slice(0, limit)
    .map(x => ({ id: x.id, domain: x.domain, type: x.type, insight: x.insight, sent: (x.ts || '').slice(0, 10), question: x.question, owner_answer: x.owner_answer || '' }));
}

// 상태 갱신 (answered: 주인님이 답함 / resolved: 해결됨) + 주인님 답 연결
export function updateStatus(id, status, ownerAnswer, ts) {
  appendFileSync(STORE, JSON.stringify({
    event: 'update', id, ts: ts || new Date().toISOString(), status, owner_answer: ownerAnswer || '',
  }) + '\n');
}

// 발송된 디스코드 메시지 id ↔ 그 안에 묶인 통찰 id들 매핑 (양방향 역추적의 다리)
export function linkDiscordMessage(discordMsgId, insightIds, ts) {
  appendFileSync(STORE, JSON.stringify({
    event: 'discord_link', discord_msg_id: String(discordMsgId), insight_ids: insightIds, ts: ts || new Date().toISOString(),
  }) + '\n');
}

// 답글이 달린 디스코드 메시지 id → 그 통찰 id들 역조회 (없으면 빈 배열 = 매칭 포기)
export function findInsightsByDiscordMsg(discordMsgId) {
  if (!existsSync(STORE)) return [];
  const rows = readFileSync(STORE, 'utf-8').trim().split('\n').filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const link = rows.reverse().find(r => r.event === 'discord_link' && r.discord_msg_id === String(discordMsgId));
  return link ? link.insight_ids : [];
}

// CLI: node insight-store.mjs status <id> <answered|resolved> "주인님 답"
const [, , cmd, a1, a2, a3] = process.argv;
if (cmd === 'status' && a1 && a2) { updateStatus(a1, a2, a3); console.log(`[insight-store] ${a1} → ${a2}${a3 ? ' ("' + a3.slice(0, 30) + '")' : ''}`); }
