// ─────────────────────────────────────────────────────────────
// star-lookup.mjs — user-profile.md(SSoT)에서 STAR_LOOKUP 자동 생성.
//
// 배경: 과거 STAR_LOOKUP은 interview-fast-path.js에 손으로 베낀 하드코딩
//       복사본이었다. user-profile.md에 STAR가 추가될 때마다 코드를 같이
//       고쳐야 했고, 그 동기화가 끊겨 STAR-15~18·S1·S3·S4가 누락됐다.
//       (2026-06-24 SSoT 검토에서 적발 — fast-path는 STAR-14까지만 반영)
//
// 해결: SSoT를 user-profile.md 하나로 통일. 각 STAR 섹션에 기계가 읽는
//       메타 라인(`<!-- lookup: ... -->`) 1줄을 두고, 이 파서가 그것만
//       읽어 STAR_LOOKUP을 만든다. STAR 추가 시 메타 1줄만 같이 쓰면
//       코드 수정 없이 자동 반영된다. fast-path와 ssot-audit이 이 파서를
//       공유하므로 "코드 복사본이 SSoT를 못 따라가는" 구조 자체가 사라진다.
//
// 메타 라인 포맷 (STAR 헤더 `### STAR-N. ...` 바로 아래 1줄):
//   <!-- lookup: key=STAR-1-jandi-batch | projects=A,B | techs=C,D | numbers=1,2 | desc=... -->
//   - key      (필수): STAR_LOOKUP 키 (식별 슬러그 포함)
//   - projects (필수): 회사/프로젝트명 — 식별 가중치 2
//   - techs    (필수): 기술명 — 식별 가중치 1 + 답변 어휘 화이트리스트
//   - numbers  (선택): 수치 화이트리스트 — Frankenstein(타 STAR 수치 끼워넣기) 차단
//   - desc     (선택): 한 줄 설명. 없으면 헤더 제목으로 대체.
//   메타 라인이 없는 STAR(예: STAR-J3 이력서 자제)는 의도적으로 LOOKUP에서 제외된다.
// ─────────────────────────────────────────────────────────────

const META_RE = /<!--\s*lookup:\s*([\s\S]*?)\s*-->/;

/** "a, b ,c" → ['a','b','c'] (공백 trim, 빈 항목 제거). */
function splitList(raw) {
  if (!raw) return [];
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 한 STAR 섹션 텍스트에서 메타 라인을 파싱. 메타 없으면 null. */
function parseSection(sectionText) {
  const metaMatch = sectionText.match(META_RE);
  if (!metaMatch) return null;

  // key=... | projects=... | techs=... | numbers=... | desc=...
  const fields = {};
  for (const part of metaMatch[1].split('|')) {
    const eq = part.indexOf('=');
    if (eq === -1) continue;
    const k = part.slice(0, eq).trim();
    const v = part.slice(eq + 1).trim();
    if (k) fields[k] = v;
  }

  if (!fields.key) return null;

  // desc fallback: 헤더 `### STAR-N. <제목>`의 제목 부분.
  let desc = fields.desc;
  if (!desc) {
    const hdr = sectionText.match(/^###\s+STAR-[A-Z0-9]+\.\s*([^\n(]+)/);
    desc = hdr ? hdr[1].trim() : fields.key;
  }

  return {
    key: fields.key,
    info: {
      projects: splitList(fields.projects),
      techs: splitList(fields.techs),
      numbers: splitList(fields.numbers),
      desc,
    },
  };
}

/**
 * user-profile.md 전체 텍스트에서 STAR_LOOKUP 객체를 생성.
 * @param {string} profileText - user-profile.md 내용
 * @returns {Record<string, {projects:string[],techs:string[],numbers:string[],desc:string}>}
 */
export function parseStarLookup(profileText) {
  if (!profileText || typeof profileText !== 'string') return {};

  const lookup = {};
  // `### STAR-` 헤더 기준으로 섹션 분리 (헤더 줄 포함).
  const sections = profileText.split(/(?=^###\s+STAR-)/m);
  for (const sec of sections) {
    if (!/^###\s+STAR-/.test(sec)) continue;
    const parsed = parseSection(sec);
    if (parsed) lookup[parsed.key] = parsed.info;
  }
  return lookup;
}
