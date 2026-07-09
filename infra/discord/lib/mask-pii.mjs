/**
 * mask-pii.mjs — RAG 적재 전 PII 마스킹 공통 유틸 (SSoT).
 *
 * 배경(2026-07-09): CLI 대화 원문이 inbox/claude-cli-*.md 로 마스킹 없이 적재돼
 *   RAG(LanceDB)에 오너 실명·회사명·절대경로·이메일이 평문으로 인덱싱됨(실측: 실명 330·회사 995·경로 1148 파일).
 *   git privacy 가드(.githooks/pre-commit)는 runtime/**가 gitignore라 RAG 경로에 도달 불가.
 *   → 적재 파이프라인(claude-cli-rag-sync·wiki-engine)이 저장 직전 이 함수로 마스킹.
 *
 * 설계 원칙:
 *   - 삭제가 아니라 치환 → 검색 맥락 보존(예: 경로는 $HOME 으로).
 *   - **개인 식별자(실명·별칭·회사·도메인)는 코드에 하드코딩 금지(privacy 정책)**.
 *     env(OWNER_NAME/OWNER_ALIASES) + private/config/owner-companies.txt 로 주입.
 */
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const _esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 오너 식별자 동적 로드: env(콤마 구분) + private 파일(회사·도메인·별칭 범용, 부재 시 skip).
function _loadIdentifiers() {
  const set = new Set();
  for (const v of (process.env.OWNER_NAME || '').split(',')) if (v.trim().length >= 2) set.add(v.trim());
  for (const v of (process.env.OWNER_ALIASES || '').split(',')) if (v.trim().length >= 2) set.add(v.trim());
  try {
    const ct = join(HOME, 'jarvis', 'private', 'config', 'owner-companies.txt');
    if (existsSync(ct)) {
      for (const v of readFileSync(ct, 'utf-8').split(/[\n,]/)) if (v.trim().length >= 2) set.add(v.trim());
    }
  } catch { /* private 파일 없으면 식별자 마스킹 생략 */ }
  // 긴 항목 먼저 치환(부분 매치 방지)
  return [...set].sort((a, b) => b.length - a.length);
}
const IDENTIFIERS = _loadIdentifiers();

// 정적 패턴(개인 식별자 아님 — 형식만): 시크릿·이메일·전화·절대경로.
const STATIC_PATTERNS = [
  { re: /sk-ant-[a-zA-Z0-9_-]{20,}/g, sub: () => 'sk-ant-***' },              // Anthropic 키
  { re: /sk-[a-zA-Z0-9]{20,}/g, sub: () => 'sk-***' },                        // 일반 시크릿
  { re: /gh[pousr]_[A-Za-z0-9]{20,}/g, sub: () => 'gh_***' },                 // GitHub 토큰
  { re: /([\w.+-]+)@([\w-]+\.[\w.-]+)/g,                                       // 이메일(로컬부 마스킹, 도메인 보존)
    sub: (m, l, d) => (l.includes('*') ? m : `${l[0]}***@${d}`) },
  { re: /\b01\d-\d{3,4}-\d{4}\b/g, sub: () => '010-****-****' },              // 전화
  { re: /\/Users\/[A-Za-z0-9_.-]+\//g, sub: () => '$HOME/' },                 // 절대경로(맥락 보존)
];

/**
 * 텍스트의 PII를 마스킹한다. 문자열이 아니면 원본 반환.
 * @param {string} text
 * @returns {string}
 */
export function maskPII(text) {
  if (typeof text !== 'string' || !text) return text;
  let out = text;
  for (const { re, sub } of STATIC_PATTERNS) out = out.replace(re, sub);
  for (const id of IDENTIFIERS) out = out.replace(new RegExp(_esc(id), 'g'), '***');
  return out;
}

export default maskPII;
