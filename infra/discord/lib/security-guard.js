/**
 * security-guard.js — 민감 경로 접근 차단 게이트
 *
 * Phase 0 Sensor의 보안 구멍 대응:
 *   bypassPermissions + allowDangerouslySkipPermissions 조합으로
 *   .env / secrets/* / SSH 키 / credentials 등의 민감 파일이 LLM에 유출 가능했음.
 *
 * 사용처:
 *   claude-runner.js의 canUseTool 콜백에서 SDK tool 호출 직전에 검사.
 *
 * 원칙:
 *   - 허용(allow)이 기본, 명시된 민감 패턴만 차단(deny)
 *   - Bash cmd / Read/Write/Edit file_path 양쪽 모두 스캔
 *   - 매치 시 차단 이유 문자열 반환 → 로깅/감사용
 */

// 절대·상대 경로 양쪽 커버. 대소문자 무관.
const SENSITIVE_PATTERNS = [
  /(^|[\/\s'"`])\.env($|[\/\s'"`.])/i,           // .env, .env.local, .env.production 등
  /(^|[\/\s'"`])\.envrc($|[\/\s'"`])/i,          // direnv
  /\bsecrets?\/[^\s'"`]+/i,                       // secrets/*, secret/*
  /\bcredentials?\b/i,                            // credentials, credential
  /(^|[\/\s'"`])id_(rsa|ed25519|ecdsa|dsa)\b/i,   // SSH private keys
  /\.ssh\/(id_|config\b)/i,                       // ~/.ssh/id_*, ~/.ssh/config
  /\.aws\/credentials\b/i,                        // AWS 자격증명
  /\.netrc\b/i,                                   // .netrc
  /\bprivate[_-]?key\b/i,                         // private_key, private-key
  /\bapi[_-]?key\b/i,                             // api_key 파일명 (값 아님)
  /\.pem\b/i,                                     // PEM keys
  /\.keystore\b/i,                                // Java keystore
  /\bmacos[_-]?keychain\b/i,
];

// tool별 입력에서 경로 후보를 뽑아내는 추출기
function extractPaths(toolName, input) {
  if (!input || typeof input !== 'object') return [];
  const name = toolName || '';
  const out = [];

  // Read / Write / Edit / NotebookEdit
  if (typeof input.file_path === 'string') out.push(input.file_path);
  if (typeof input.notebook_path === 'string') out.push(input.notebook_path);

  // Glob / Grep
  if (typeof input.path === 'string') out.push(input.path);
  if (typeof input.pattern === 'string' && /Glob|Grep/i.test(name)) out.push(input.pattern);

  // Bash: 명령어 전체를 스캔
  if (typeof input.command === 'string') out.push(input.command);

  return out;
}

/**
 * @param {string} toolName - SDK tool 이름 (Bash, Read, Edit ...)
 * @param {Record<string, unknown>} input - tool 입력
 * @returns {string|null} 차단된 경로/패턴 (차단 시) 또는 null (허용)
 */
export function checkSensitivePath(toolName, input) {
  const candidates = extractPaths(toolName, input);
  for (const c of candidates) {
    for (const pat of SENSITIVE_PATTERNS) {
      const m = pat.exec(c);
      if (m) return m[0].trim() || c.slice(0, 120);
    }
  }
  return null;
}

/** 테스트/감사용 노출 */
export const _SENSITIVE_PATTERNS = SENSITIVE_PATTERNS;
