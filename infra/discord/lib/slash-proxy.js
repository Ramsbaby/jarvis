// slash-proxy.js — 슬래시 커맨드가 SSoT 스킬을 호출할 때 사용하는 프록시 매핑.
//
// 흐름:
// 1. 사용자가 `/mock-interview 삼성물산` 슬래시 커맨드 실행
// 2. commands.js가 registerSlashProxy(channelId, userId, content) 호출 후
//    `interaction.channel.send(content)` — 봇 이름으로 채널에 메시지 발송
// 3. handlers.js의 messageCreate가 이 봇 메시지를 받으면 consumeSlashProxy로
//    일치 여부 확인 → 일치하면 원래 사용자 ID로 처리 계속 (봇 필터 bypass)
//
// 왜 매핑이 필요한가: 봇이 보낸 메시지는 message.author.bot === true 이므로
// 기본적으로 messageCreate가 무시한다. 그러나 슬래시 커맨드 경로의 프록시
// 메시지는 실제 사용자 발화를 대리하는 것이므로, 이 매핑을 통해 예외 처리.
//
// 만료: 5초. 네트워크 지연 여유 포함. 사용되면 즉시 삭제.

const PROXIES = new Map(); // channelId -> { userId, content, expiresAt }
const TTL_MS = 5000;

export function registerSlashProxy(channelId, userId, content) {
  PROXIES.set(channelId, {
    userId,
    content,
    expiresAt: Date.now() + TTL_MS,
  });
}

// 모의면접 활성 세션 추적 — `/mock-interview` 호출 후 N분 동안은
// 같은 (채널, 사용자)의 후속 메시지를 면접 세션으로 간주해 가드 우회.
// 세션 종료: 사용자가 "끝", "그만", "피드백 줘" 입력 → deactivateMockSession
const MOCK_SESSIONS = new Map(); // `${channelId}:${userId}` → expiresAt
const MOCK_SESSION_TTL_MS = 30 * 60 * 1000; // 30분

// 면접 전용 채널 — 이 채널에서는 mock session 항상 active (mockActive === true).
// /mock-interview 슬래시 커맨드 없이도 자동으로 면접 답변 모드가 발동하며,
// 일반 채널의 Hard Guard도 우회된다 (handlers.js 라우팅 분기).
// 페르소나·모델 override는 personas.json + models.json에서 관리.
export const INTERVIEW_CHANNEL_ID = '1497124568031301752'; // jarvis-interview

export function activateMockSession(channelId, userId) {
  MOCK_SESSIONS.set(`${channelId}:${userId}`, Date.now() + MOCK_SESSION_TTL_MS);
}

export function isMockSessionActive(channelId, userId) {
  // 면접 전용 채널은 상시 활성
  if (channelId === INTERVIEW_CHANNEL_ID) return true;
  const key = `${channelId}:${userId}`;
  const expiresAt = MOCK_SESSIONS.get(key);
  if (!expiresAt) return false;
  if (expiresAt < Date.now()) {
    MOCK_SESSIONS.delete(key);
    return false;
  }
  return true;
}

export function deactivateMockSession(channelId, userId) {
  MOCK_SESSIONS.delete(`${channelId}:${userId}`);
}

// 취약성 질문(실수/실패/갈등/약점) 대기 상태 — 다음 사용자 입력은 실제 경험으로 해석.
// 이 매커니즘 이유: 모델이 RAG 실증 경험 위에 안티패턴 나레이션을 창작하는 편향 때문에
// 프롬프트 규칙만으로는 차단 불가. 실제 경험을 사용자에게서 받아 컨텍스트로 주입해야 안전.
const PENDING_VULNERABILITY = new Map(); // `${channelId}:${userId}` → { question, expiresAt }
const PENDING_VULNERABILITY_TTL_MS = 10 * 60 * 1000; // 10분

export function registerPendingVulnerability(channelId, userId, question) {
  PENDING_VULNERABILITY.set(`${channelId}:${userId}`, {
    question,
    expiresAt: Date.now() + PENDING_VULNERABILITY_TTL_MS,
  });
}

export function consumePendingVulnerability(channelId, userId) {
  const key = `${channelId}:${userId}`;
  const entry = PENDING_VULNERABILITY.get(key);
  if (!entry) return null;
  if (entry.expiresAt < Date.now()) {
    PENDING_VULNERABILITY.delete(key);
    return null;
  }
  PENDING_VULNERABILITY.delete(key);
  return entry;
}

// 모의면접 세션 컨텍스트 — /mock-interview 호출 시 RAG pre-fetch 1회 실행 후 저장.
// 어떤 질문이 와도 이 컨텍스트를 재료로 답변 생성 → 카드 하드코딩 없이 범용 대응.
const MOCK_CONTEXT = new Map(); // `${channelId}:${userId}` → { context, expiresAt, company }

export function setMockContext(channelId, userId, context, company) {
  MOCK_CONTEXT.set(`${channelId}:${userId}`, {
    context,
    company,
    expiresAt: Date.now() + MOCK_SESSION_TTL_MS,
  });
}

export function getMockContext(channelId, userId) {
  const key = `${channelId}:${userId}`;
  const entry = MOCK_CONTEXT.get(key);
  if (!entry || entry.expiresAt < Date.now()) {
    MOCK_CONTEXT.delete(key);
    return null;
  }
  return entry;
}

export function consumeSlashProxy(channelId, content) {
  const entry = PROXIES.get(channelId);
  if (!entry) return null;
  if (entry.expiresAt < Date.now()) {
    PROXIES.delete(channelId);
    return null;
  }
  if (entry.content !== content) return null;
  PROXIES.delete(channelId);
  return { userId: entry.userId };
}
