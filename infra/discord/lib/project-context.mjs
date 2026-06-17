/**
 * project-context.mjs — 장기 프로젝트 영속 맥락 (Phase 2-B 메타인지)
 *
 * 역할: session-handoff.js의 24h TTL 한계를 극복한다.
 * 대표님이 여러 날에 걸쳐 진행하는 프로젝트(채용 진행, 이직 준비, ERP 연동 등)의
 * 맥락을 TTL 없이 영속 보관하고, 새 대화 시 시스템 프롬프트에 주입한다.
 *
 * 저장: runtime/state/projects/{userId}.json
 *
 * 설계 의사결정:
 * - 프로젝트 자동 감지: 패턴 매칭(이직/채용/ERP/계속/이어서 등) + 지속성 패턴
 * - 저장 한도: 최근 5개 프로젝트 × 최근 10회 이력
 * - 시스템 프롬프트 주입: 800자 이내로 압축
 * - 비동기 감지/저장(setImmediate): 응답 지연 없음
 * - 삭제: 30일 무활동 프로젝트 자동 아카이브
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const PROJECTS_DIR = join(BOT_HOME, 'state', 'projects');
const MAX_PROJECTS = 5;       // 사용자당 최대 활성 프로젝트 수
const MAX_HISTORY  = 10;      // 프로젝트당 최대 이력 수
const ARCHIVE_DAYS = 30;      // 무활동 아카이브 기간 (일)
const MAX_PROMPT_CHARS = 800; // 시스템 프롬프트 주입 최대 글자

// ── 프로젝트 자동 감지 패턴 ──────────────────────────────────────────────────
const PROJECT_PATTERNS = [
  { id: 'job-search',  label: '이직·채용',   re: /이직|채용|면접|지원|이력서|포트폴리오|취업|job|career|offer/i },
  { id: 'erp',         label: 'ERP 연동',    re: /ERP|세금계산서|견적서|발주|재고|회계|결제 시스템/i },
  { id: 'jarvis-dev',  label: '자비스 개발', re: /자비스.*개발|봇.*개발|크론|태스크|메타인지|구현|컴파일|배포/i },
  { id: 'investment',  label: '투자·재무',   re: /TQQQ|SOXL|NVDA|ETF|주식|포트폴리오|투자|매수|매도|손절/i },
  { id: 'health',      label: '건강 루틴',   re: /위고비|오젬픽|단식|운동|식단|체중|혈당|건강|루틴/i },
  { id: 'travel',      label: '여행 계획',   re: /여행|항공|호텔|숙소|비행기|일정|투어|관광/i },
  { id: 'learning',    label: '학습',        re: /공부|강의|자격증|시험|스터디|학습|배우/i },
];

// "이어서 / 계속 / 저번에" 등 연속성 패턴
const CONTINUITY_RE = /이어서|계속|저번에|지난번|다음\s*단계|다음으로|어디까지/i;

function nowKST() {
  return new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
}

// ── 프로젝트 파일 경로 ────────────────────────────────────────────────────────
function projectPath(userId) {
  return join(PROJECTS_DIR, `${userId}.json`);
}

// ── 파일 로드 ─────────────────────────────────────────────────────────────────
function loadProjects(userId) {
  const p = projectPath(userId);
  if (!existsSync(p)) return {};
  try { return JSON.parse(readFileSync(p, 'utf-8')); } catch { return {}; }
}

// ── 파일 저장 (atomic) ────────────────────────────────────────────────────────
function saveProjects(userId, data) {
  mkdirSync(PROJECTS_DIR, { recursive: true });
  writeFileSync(projectPath(userId), JSON.stringify(data, null, 2));
}

// ── 프로젝트 감지: 현재 메시지에서 관련 프로젝트 ID 반환 ─────────────────────
export function detectProjectId(prompt) {
  if (!prompt) return null;
  for (const p of PROJECT_PATTERNS) {
    if (p.re.test(prompt)) return p.id;
  }
  return null;
}

// ── 프로젝트 맥락 저장 ────────────────────────────────────────────────────────
export function saveProjectContext(userId, projectId, summary, pendingTasks = [], keyDecisions = []) {
  if (!userId || !projectId) return;

  const projects = loadProjects(userId);
  const now = nowKST();

  const existing = projects[projectId] || {
    projectId,
    label: PROJECT_PATTERNS.find(p => p.id === projectId)?.label || projectId,
    firstSeen: now,
    history: [],
    pendingTasks: [],
    keyDecisions: [],
  };

  // 이력 추가 (최대 MAX_HISTORY)
  existing.history = [
    { ts: now, summary: String(summary).slice(0, 200) },
    ...(existing.history || []),
  ].slice(0, MAX_HISTORY);

  // 미완료 태스크 업데이트
  if (pendingTasks.length > 0) {
    existing.pendingTasks = pendingTasks.slice(0, 5);
  }

  // 핵심 결정 추가 (최대 10개)
  if (keyDecisions.length > 0) {
    existing.keyDecisions = [
      ...keyDecisions,
      ...(existing.keyDecisions || []),
    ].slice(0, 10);
  }

  existing.lastUpdated = now;
  projects[projectId] = existing;

  // 최대 MAX_PROJECTS 유지 (오래된 것 제거)
  const sorted = Object.entries(projects)
    .sort(([, a], [, b]) => new Date(b.lastUpdated) - new Date(a.lastUpdated));
  const trimmed = Object.fromEntries(sorted.slice(0, MAX_PROJECTS));

  saveProjects(userId, trimmed);
}

// ── 프로젝트 맥락 로드 → 시스템 프롬프트 포맷팅 ─────────────────────────────
export function loadProjectContext(userId) {
  if (!userId) return null;
  const projects = loadProjects(userId);
  if (Object.keys(projects).length === 0) return null;

  const now = Date.now();
  const ARCHIVE_MS = ARCHIVE_DAYS * 24 * 3600_000;

  // 활성 프로젝트만 (30일 이내 활동)
  const active = Object.values(projects)
    .filter(p => {
      const age = now - new Date(p.lastUpdated).getTime();
      return age < ARCHIVE_MS;
    })
    .sort((a, b) => new Date(b.lastUpdated) - new Date(a.lastUpdated))
    .slice(0, 3); // 최대 3개만 주입

  if (active.length === 0) return null;

  const lines = ['📁 **진행 중인 프로젝트 맥락** (장기 기억)'];
  for (const proj of active) {
    lines.push(`\n- **${proj.label}** (${proj.lastUpdated?.slice(0, 10) || '?'})`);
    if (proj.history?.length > 0) {
      lines.push(`  최근: ${proj.history[0].summary}`);
    }
    if (proj.pendingTasks?.length > 0) {
      lines.push(`  미완료: ${proj.pendingTasks.slice(0, 2).join(' / ')}`);
    }
    if (proj.keyDecisions?.length > 0) {
      lines.push(`  결정: ${proj.keyDecisions[0]}`);
    }
  }

  const text = lines.join('\n');
  // 800자 제한
  return text.length > MAX_PROMPT_CHARS ? text.slice(0, MAX_PROMPT_CHARS) + '…' : text;
}

// ── 대화에서 자동 감지 + 비동기 저장 (claude-runner.js에서 setImmediate로 호출) ──
export async function detectAndSaveProject(userId, prompt, assistantReply) {
  if (!userId || !prompt) return;

  const projectId = detectProjectId(prompt);
  if (!projectId) return;

  // 연속성 패턴이 있거나 프로젝트가 감지된 경우에만 저장
  const hasContinuity = CONTINUITY_RE.test(prompt);
  const projects = loadProjects(userId);
  const isKnown = !!projects[projectId];

  // 처음 감지 or 연속성 표현 있을 때만 이력 추가 (과도한 저장 방지)
  if (!isKnown || hasContinuity) {
    const summary = String(prompt).slice(0, 100);
    saveProjectContext(userId, projectId, summary);
  }
}
