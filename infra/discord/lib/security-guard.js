/**
 * security-guard.js — 민감 경로 접근 차단 게이트
 *
 * Phase 0 Sensor의 보안 구멍 대응 + 팀 검토 반영(2026-04-17):
 *   - Symlink 해석: realpath로 실제 경로 확인 후 패턴 매칭
 *   - 패턴 확장: .bash_history / .git-credentials / .npmrc / service-account*.json 등
 *   - false positive 완화: credentials 패턴을 경로 segment 기준으로 좁힘
 *
 * 사용처: claude-runner.js의 PreToolUse 훅 (canUseTool 대신 — 'default' 모드에서
 *        내부 'allow' 판정 시 canUseTool 미발화하는 SDK 동작 우회 목적)
 *
 * 원칙:
 *   - 허용(allow)이 기본, 명시된 민감 패턴만 차단(deny)
 *   - Bash cmd / Read/Write/Edit file_path 양쪽 모두 스캔
 *   - Symlink 타겟도 해석하여 검사 (ln -s ~/.env /tmp/note 우회 차단)
 */

import { realpathSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

// 절대·상대 경로 양쪽 커버. 대소문자 무관.
// 누락 패턴 추가 (2026-04-17): .bash_history, .git-credentials 류
const SENSITIVE_PATTERNS = [
  /(^|[\/\s'"`])\.env($|[\/\s'"`.])/i,           // .env, .env.local, .env.production 등
  /(^|[\/\s'"`])\.envrc($|[\/\s'"`])/i,          // direnv
  /\bsecrets?\/[^\s'"`]+/i,                       // secrets/*, secret/*
  /(^|[\/\s'"`])\.?(aws|gcp|azure)\/credentials\b/i, // 클라우드 자격증명 (path segment 기준)
  /(^|[\/\s'"`])id_(rsa|ed25519|ecdsa|dsa)\b/i,   // SSH private keys
  /\.ssh\/(id_|config\b)/i,                       // ~/.ssh/id_*, ~/.ssh/config
  /(^|[\/\s'"`])\.netrc\b/i,                      // .netrc (FTP·curl 자격)
  /(^|[\/\s'"`])\.git-credentials\b/i,            // git credential helper store
  /(^|[\/\s'"`])\.(bash|zsh|fish)_history\b/i,    // shell history (종종 토큰 포함)
  /(^|[\/\s'"`])\.npmrc\b/i,                      // npm auth token
  /(^|[\/\s'"`])\.pypirc\b/i,                     // PyPI auth
  /\.docker\/config\.json\b/i,                    // docker registry creds
  /\.config\/gh\/hosts\.yml\b/i,                  // GitHub CLI
  /\bkubeconfig\b/i,                              // Kubernetes cluster creds (literal 'kubeconfig' 단어)
  /(^|[\/\s'"`])\.kube\/config\b/i,               // 실제 기본 경로 ~/.kube/config
  /\b(service-account|gcp-key|google-credentials)[-_]?\S*\.json\b/i, // GCP service account
  /\bprivate[_-]?key\b/i,                         // private_key, private-key
  /\bapi[_-]?key\s*[:=]\s*['"`]?[\w\-\.\/+]{12,}/i, // api_key = "실제값..." (값 기준, 파일명 아님)
  /\.pem\b/i,                                     // PEM keys
  /\.keystore\b/i,                                // Java keystore
  /\.gpg$|secring\.\w+/i,                         // GPG keyrings
  /\bmacos[_-]?keychain\b/i,
];

/**
 * 단일 경로를 realpath 해석. 실패 시 원본 반환 (존재 안 할 수 있음).
 */
function resolveSymlink(p) {
  if (!p || typeof p !== 'string') return p;
  // 너무 긴 문자열(Bash 명령어 등)에는 realpath 적용 안 함 — 경로 구성요소만 처리
  if (p.length > 4096) return p;
  try {
    const abs = resolve(p.replace(/^~/, process.env.HOME || ''));
    if (existsSync(abs)) return realpathSync(abs);
  } catch { /* non-existent or EACCES — fall through */ }
  return p;
}

// tool별 입력에서 경로 후보를 뽑아내는 추출기
function extractPaths(toolName, input) {
  if (!input || typeof input !== 'object') return [];
  const name = toolName || '';
  const out = [];

  // Read / Write / Edit / NotebookEdit
  if (typeof input.file_path === 'string') {
    out.push(input.file_path);
    out.push(resolveSymlink(input.file_path));
  }
  if (typeof input.notebook_path === 'string') {
    out.push(input.notebook_path);
    out.push(resolveSymlink(input.notebook_path));
  }

  // Glob / Grep
  if (typeof input.path === 'string') {
    out.push(input.path);
    out.push(resolveSymlink(input.path));
  }
  if (typeof input.pattern === 'string' && /Glob|Grep/i.test(name)) out.push(input.pattern);

  // Bash: 명령어 전체를 scan (symlink 해석은 안 함 — 너무 비용 큼, 문자열 매칭으로 충분)
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
  // 중복 제거
  const seen = new Set();
  for (const c of candidates) {
    if (!c || seen.has(c)) continue;
    seen.add(c);
    for (const pat of SENSITIVE_PATTERNS) {
      const m = pat.exec(c);
      if (m) return m[0].trim() || c.slice(0, 120);
    }
  }
  return null;
}

/** 테스트/감사용 노출 */
export const _SENSITIVE_PATTERNS = SENSITIVE_PATTERNS;
