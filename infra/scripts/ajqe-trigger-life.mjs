#!/usr/bin/env node
/**
 * ajqe-trigger-life.mjs v5.4 — Active Jarvis Question Engine: 일상·일정 trigger
 *
 * 주인님이 처음 원하신 카테고리 두 개:
 *   - 일상 질문: "오늘 점심 뭐 드셨어요?", "하루 어떠셨어요?"
 *   - 일정 후속: "면접 끝났는데 어떠셨어요?", "다른 기업도 지원하실 건가요?"
 *
 * 데이터 소스 (gog 인증 우회 — wiki·메모리 기반):
 *   - wiki/career/_facts.md: 면접·이력서 일정 키워드 추출
 *   - wiki/family/_facts.md, wiki/health/_facts.md: 일상 컨텍스트
 *   - 자비스 last_user_request 시간: 침묵 기반 안부
 *
 * 트리거 시간 (cron이 30분마다 호출 — 시간대 매칭 시만 적재):
 *   - 11:30~12:30 KST: 점심 안부 (1회/일)
 *   - 18:00~19:00 KST: 저녁 안부 (1회/일)
 *   - D-day ±1일 자동 감지: 면접 후속 (이벤트 1회)
 *
 * 사용:
 *   node ajqe-trigger-life.mjs            # 시간/이벤트 매칭 시 큐 적재
 *   node ajqe-trigger-life.mjs --dry-run
 *   node ajqe-trigger-life.mjs --force-lunch    # 시간 무시 점심 질문 강제 (테스트)
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';

const HOME = homedir();
const QUEUE_PATH = join(HOME, 'jarvis/runtime/state/ajqe-question-queue.jsonl');
const COOLDOWN_PATH = join(HOME, 'jarvis/runtime/state/ajqe-signal-cooldown.json');
const CAREER_FACTS = join(HOME, 'jarvis/runtime/wiki/career/_facts.md');
const ACTIVE_WORK = join(HOME, 'jarvis/runtime/state/active-work.json');

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run');
const FORCE_LUNCH = args.has('--force-lunch');
const FORCE_EVENING = args.has('--force-evening');

const nowKST = new Date(Date.now() + 9 * 3600 * 1000);
const TODAY = nowKST.toISOString().slice(0, 10);
const HOUR = nowKST.getUTCHours();
const MINUTE = nowKST.getUTCMinutes();

function loadJSONL(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8').split('\n').filter(l => l.trim())
    .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}
function loadJSON(path, fb) { try { return JSON.parse(readFileSync(path, 'utf-8')); } catch { return fb; } }
function loadExistingQueueIds() { return new Set(loadJSONL(QUEUE_PATH).map(q => q.id)); }
function isOnCooldown(signal) {
  if (!signal) return false;
  const cd = loadJSON(COOLDOWN_PATH, {});
  return cd[signal] && new Date(cd[signal]).getTime() > Date.now();
}

function makeLifeQuestion({ id, signal, headline, why, options }) {
  return {
    id, trigger: 'life-v5.4', signal,
    domain: 'owner', ssot: 'life-context',
    priority: 1, skipLlmRefine: true,
    purpose: '주인님 일상·일정 안부 — 자비스 능동 관심',
    questionText: `${headline}${why ? `\n\n_${why}_` : ''}${options ? `\n\n${options}` : '\n\n_답글로 한 줄이면 충분합니다._'}`,
    createdAt: new Date().toISOString(),
    status: 'pending',
  };
}

const questions = [];

// ── 1. 점심 안부 (11:30~12:30 KST 1회/일) ─────────────────────────
function checkLunch() {
  const inLunchWindow = (HOUR === 11 && MINUTE >= 30) || (HOUR === 12 && MINUTE <= 30);
  if (!inLunchWindow && !FORCE_LUNCH) return;
  questions.push(makeLifeQuestion({
    id: `life-lunch-${TODAY}`,
    signal: 'daily-lunch-checkin',
    headline: `🥗 **주인님, 점심 시간입니다**`,
    why: `오늘 점심 어떻게 드셨는지 / 드실 예정인지 궁금합니다.`,
    options: `_답글 예시: "샌드위치 먹었어", "단식 중", "안 먹음" 등 한 줄_\n_무시하시려면 \`무시\` (24h 동안 점심 안부 안 함)_`,
  }));
}

// ── 2. 저녁 안부 (18:00~19:00 KST 1회/일) ─────────────────────────
function checkEvening() {
  const inEveningWindow = (HOUR === 18) || (HOUR === 19 && MINUTE === 0);
  if (!inEveningWindow && !FORCE_EVENING) return;
  questions.push(makeLifeQuestion({
    id: `life-evening-${TODAY}`,
    signal: 'daily-evening-checkin',
    headline: `🌆 **주인님, 오늘 하루 어떠셨습니까?**`,
    why: `오늘 한 일·기분·기억할 만한 일 있으셨다면 한 줄 남겨주십시오. 자비스 위키에 기록드립니다.`,
    options: `_답글 예시: "면접 잘 봤음", "피곤한 하루", "특별한 일 없음" 등_\n_무시하시려면 \`무시\`_`,
  }));
}

// ── 3. 면접·일정 D-day 후속 (career _facts.md에서 추출) ──────────
// v5.4-fix: 어제(=어제 KST 날짜) 정확 매칭만 + 회상 기록 제외
function checkScheduleFollowup() {
  if (!existsSync(CAREER_FACTS)) return;
  const content = readFileSync(CAREER_FACTS, 'utf-8');

  // 어제 KST 날짜 계산
  const yesterday = new Date(Date.now() + 9 * 3600 * 1000 - 86400 * 1000)
    .toISOString().slice(0, 10);

  // 어제 날짜를 포함한 라인만 추출 + "면접/인터뷰" 키워드 + "회상/과거/이전" 같은 회고 문구 배제
  const seenIds = new Set();
  // v5.4-fix-2: 시각(HH:MM) 있는 라인 우선 — D-day 메모보다 진짜 일정 라인 채택
  const candidateLines = content.split('\n')
    .filter(line => line.includes(yesterday))
    .filter(line => /면접|인터뷰|interview|코딩테스트|과제 제출/i.test(line))
    .filter(line => !/회상|과거|이전\s|예전|지난해|작년/.test(line))
    .filter(line => !/SSoT|sidecar|분기|통일|ingest|RAG|JSON\(|interviewDate|wiki\s|registry|audit/i.test(line))
    .filter(line => /\d{1,2}:\d{2}|\d+분(?:\D|$)|\d+시(?:간|\D|$)|D-?\d|일정|예정|예약/i.test(line))
    .map(line => ({
      line,
      score: (/\d{1,2}:\d{2}/.test(line) ? 100 : 0)  // HH:MM 시각 우선
           + (/[가-힣]{2,5}\s*(?:물산|페이|증권|전자|건설|화학|카드|은행|뱅크|모터스)/.test(line) ? 50 : 0)  // 회사명
           + (line.length > 100 ? 20 : 0),  // 정보 풍부도
    }))
    .sort((a, b) => b.score - a.score);

  // 어제 면접 후속은 1건만 발송 (가장 정보 풍부한 라인 인용)
  if (candidateLines.length > 0) {
    const best = candidateLines[0].line;
    const cleanLine = best.replace(/^- \[\d{4}-\d{2}-\d{2}\] \[source:[^\]]+\] /, '').slice(0, 200);
    const id = `life-interview-${yesterday.replace(/-/g, '')}`;

    questions.push(makeLifeQuestion({
      id, signal: 'interview-followup',
      headline: `📋 **어제 면접 어떠셨습니까?**`,
      why: `자비스 기록에서 어제(${yesterday}) 면접 일정을 발견했습니다:\n\n> ${cleanLine}\n\n인상·다음 단계·회고 필요 여부 알고 싶어 여쭙습니다.`,
      options: `_답글 예시: "잘 봤음", "어려웠음 회고 필요", "결과 대기" 등_\n_무시하시려면 \`무시\`_`,
    }));
  }
}

// ── 4. 침묵 기반 안부 (active-work.json last_user_request 24h+ 침묵) ──
function checkSilence() {
  const aw = loadJSON(ACTIVE_WORK, null);
  if (!aw?.updated_at) return;
  const hoursSilent = (Date.now() - new Date(aw.updated_at).getTime()) / 3600000;
  if (hoursSilent < 24) return;
  questions.push(makeLifeQuestion({
    id: `life-silence-${TODAY}`,
    signal: 'silence-checkin',
    headline: `👋 **주인님, 잘 지내고 계십니까?**`,
    why: `최근 ${Math.floor(hoursSilent)}시간 동안 자비스에 말씀이 없으셔서 안부 여쭙습니다.`,
    options: `_답글 한 줄로 어떻게 지내시는지 알려주십시오._\n_답하기 어려우시면 \`무시\`_`,
  }));
}

// ── 메인 ──────────────────────────────────────────────────────────
checkLunch();
checkEvening();
checkScheduleFollowup();
// checkSilence(); // 비활성화 2026-06-11 — CLI 대화는 active-work.json 미갱신 → 영구 오탐

// 안전망: 같은 id 여러 번 push된 경우 dedupe (정규식 폭주 방지)
const seenIds = new Set();
const dedupedQuestions = questions.filter(q => {
  if (seenIds.has(q.id)) return false;
  seenIds.add(q.id);
  return true;
});

const existing = loadExistingQueueIds();
const newQuestions = dedupedQuestions
  .filter(q => !existing.has(q.id))
  .filter(q => !isOnCooldown(q.signal));

console.log(`# AJQE Trigger Life v5.4 (KST ${HOUR}:${String(MINUTE).padStart(2,'0')})`);
console.log(`스캔: ${questions.length}건 | 신규: ${newQuestions.length}건`);
for (const q of newQuestions.slice(0, 5)) console.log(`  [${q.id}] ${q.signal}`);

if (DRY_RUN || newQuestions.length === 0) {
  if (DRY_RUN) console.log('🧪 DRY RUN');
  process.exit(0);
}
mkdirSync(dirname(QUEUE_PATH), { recursive: true });
appendFileSync(QUEUE_PATH, newQuestions.map(q => JSON.stringify(q)).join('\n') + '\n');
console.log(`✅ ${newQuestions.length}건 큐 적재`);
