/**
 * citation-formatter.js — RAG/출처 인용 각주 자동 포맷팅
 *
 * Claude.ai의 Citations 기능을 Discord 봇에 이식.
 * 본문 안에 흩어진 bare citation(`[파일명.md]`, `(출처: ...)`, `[^N]`)을
 * 통일된 각주 번호로 치환하고, 응답 끝에 깔끔한 출처 블록을 첨부한다.
 *
 * 트리거:
 *   - 2개 이상의 citation이 감지되면 포맷 적용
 *   - 1개 이하면 원본 유지 (가독성 위해 굳이 각주화하지 않음)
 *
 * 인용 패턴 (우선순위 순):
 *   1. `[^1]` / `[^1]: source`       — 이미 각주 포맷 (정규화만 수행)
 *   2. `[filename.ext]`              — bare filename (md/mjs/js/ts/json 등)
 *   3. `(출처: text)` / `(source: text)` — 명시적 출처 표기
 *   4. `[[wiki-link]]`               — Obsidian 스타일
 *
 * 반환:
 *   { content, citations, changed }
 *   - content: 포맷된 본문 (각주 번호 + 하단 출처 블록)
 *   - citations: [{ n, label, full }] 검출된 각주 배열
 *   - changed: boolean (포맷 적용 여부)
 */

const CITATION_HEADER = '-# 📚 **출처**';
const MAX_LABEL_LEN = 100;

// 파일 확장자 화이트리스트 — 너무 광범위한 `[단어]`와 혼동 방지
const FILE_EXT_PATTERN = /\[([^\]\n[]{1,80}\.(?:md|mdx|mjs|js|ts|tsx|jsx|json|yaml|yml|py|java|kt|go|rs|sh|sql|txt|pdf))\]/g;

// 이미 각주 형태 ([^1], [^1]: text)
const FOOTNOTE_REF_PATTERN = /\[\^(\d+)\]/g;
const FOOTNOTE_DEF_PATTERN = /^\[\^(\d+)\]:\s*(.+)$/gm;

// 한국어/영어 출처 표기
const SOURCE_PAREN_PATTERN = /\((?:출처|source|참고|ref|참조)[:：]\s*([^()\n]{1,100})\)/gi;

// Obsidian wiki-link
const WIKI_LINK_PATTERN = /\[\[([^\]\n[]{1,80})\]\]/g;

// ---------------------------------------------------------------------------
// 라벨 정규화 — 경로 → 파일명만, 너무 길면 자르기
// ---------------------------------------------------------------------------
function _normalizeLabel(raw) {
  if (!raw) return '';
  let label = String(raw).trim();
  // 경로에서 파일명만
  if (label.includes('/')) {
    const parts = label.split('/').filter(Boolean);
    label = parts[parts.length - 1];
  }
  if (label.length > MAX_LABEL_LEN) {
    label = label.slice(0, MAX_LABEL_LEN - 1) + '…';
  }
  return label;
}

// ---------------------------------------------------------------------------
// extractCitations — 본문 스캔, 각 인용의 { kind, raw, label, index } 수집
// ---------------------------------------------------------------------------
export function extractCitations(content) {
  if (!content || typeof content !== 'string') return [];
  const hits = [];

  // 1. 이미 각주 형태
  let m;
  while ((m = FOOTNOTE_REF_PATTERN.exec(content)) !== null) {
    hits.push({ kind: 'footnote', raw: m[0], label: m[1], index: m.index });
  }
  FOOTNOTE_REF_PATTERN.lastIndex = 0;

  // 2. 파일명
  while ((m = FILE_EXT_PATTERN.exec(content)) !== null) {
    hits.push({ kind: 'file', raw: m[0], label: _normalizeLabel(m[1]), index: m.index });
  }
  FILE_EXT_PATTERN.lastIndex = 0;

  // 3. 출처 표기
  while ((m = SOURCE_PAREN_PATTERN.exec(content)) !== null) {
    hits.push({ kind: 'source', raw: m[0], label: _normalizeLabel(m[1]), index: m.index });
  }
  SOURCE_PAREN_PATTERN.lastIndex = 0;

  // 4. Obsidian
  while ((m = WIKI_LINK_PATTERN.exec(content)) !== null) {
    hits.push({ kind: 'wiki', raw: m[0], label: _normalizeLabel(m[1]), index: m.index });
  }
  WIKI_LINK_PATTERN.lastIndex = 0;

  // index 순 정렬
  hits.sort((a, b) => a.index - b.index);
  return hits;
}

// ---------------------------------------------------------------------------
// formatCitations — bare citation을 [^N]으로 치환, 하단에 출처 블록
// ---------------------------------------------------------------------------
export function formatCitations(content, opts = {}) {
  const minCitations = opts.minCitations ?? 2;
  if (!content || typeof content !== 'string') {
    return { content: content || '', citations: [], changed: false };
  }

  // 이미 출처 블록이 붙어있으면 스킵 (finalize 중복 방지)
  if (content.includes(CITATION_HEADER)) {
    return { content, citations: [], changed: false };
  }

  const hits = extractCitations(content);
  if (hits.length < minCitations) {
    return { content, citations: [], changed: false };
  }

  // 라벨 기준 dedupe → 각 unique label에 번호 배정
  const labelToNum = new Map();
  const citations = [];
  let nextNum = 1;

  for (const h of hits) {
    const key = h.label.toLowerCase();
    if (!labelToNum.has(key)) {
      labelToNum.set(key, nextNum);
      citations.push({ n: nextNum, label: h.label, kind: h.kind });
      nextNum++;
    }
  }

  // 2 미만이면 원본 유지
  if (citations.length < minCitations) {
    return { content, citations: [], changed: false };
  }

  // 치환 — 각 패턴별로 본문에 [^N] 삽입
  let formatted = content;

  // footnote는 이미 번호 있는 경우가 많음 — 그대로 두고 label만 매핑
  // file/source/wiki는 raw를 [^N]으로 치환

  // 같은 raw 문자열이 여러 번 나올 수 있으므로 replaceAll 사용 (단, raw 에는 정규식 메타 포함 가능 → 이스케이프)
  for (const h of hits) {
    if (h.kind === 'footnote') continue; // 기존 footnote는 손대지 않음
    const num = labelToNum.get(h.label.toLowerCase());
    const escaped = h.raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(escaped, 'g');
    formatted = formatted.replace(re, `[^${num}]`);
  }

  // 하단 출처 블록 — Discord `-#` 메타 스타일로 눈에 띄지 않게
  const footer = [
    '',
    '',
    CITATION_HEADER,
    ...citations.map(c => `-# \`[^${c.n}]\` ${c.label}`),
  ].join('\n');

  return {
    content: formatted.replace(/\s+$/, '') + footer,
    citations,
    changed: true,
  };
}

// ---------------------------------------------------------------------------
// RAG 검색 결과를 citation으로 변환 (agentic rag_search 직접 주입용)
// ---------------------------------------------------------------------------
export function ragResultsToCitations(results) {
  if (!Array.isArray(results)) return [];
  return results
    .filter(r => r && (r.source || r.path))
    .map((r, i) => ({
      n: i + 1,
      label: _normalizeLabel(r.source || r.path),
      snippet: (r.text || '').slice(0, 200),
      kind: 'rag',
    }));
}
