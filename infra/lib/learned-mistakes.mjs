// learned-mistakes.mjs — 오답노트 본체+아카이브 통합 조회 헬퍼 (DRY · SSoT, JS)
//
// 배경(2026-07-22 Step 1-0 감사): learned-mistakes.md를 월별 아카이브로 분할하면 전체본을
//   readFileSync로 파싱하던 리포트/체크리스트가 아카이브분을 조용히 누락한다. glob 조회를 단일화.
//
// 계약: 아카이브는 `learned-mistakes*.md`로 명명하고 원본 헤더 `## YYYY-MM-DD — 제목`을 유지한다.
//   그래야 `split(/^## (\d{4}-\d{2}-\d{2}) — /m)` 같은 기존 파서가 파일 이동과 무관하게 균일 동작한다.
//
// 사용:
//   import { readAllMistakes, lmFiles } from '../lib/learned-mistakes.mjs';
//   const content = readAllMistakes();   // 본체+아카이브 concat (기존 readFileSync 대체)

import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const META_DIR = join(
  process.env.BOT_HOME || `${process.env.HOME}/jarvis/runtime`,
  'wiki/meta',
);

// 오답노트 파일 경로 목록(본체 + 아카이브). 디렉토리 없으면 빈 배열.
export function lmFiles(dir = META_DIR) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^learned-mistakes.*\.md$/.test(f))
    .sort() // 본체(learned-mistakes.md) < 아카이브(-YYYY-MM.md) 안정 순서
    .map((f) => join(dir, f));
}

// 전체 오답노트 파일 내용을 concat해서 반환(기존 단일 readFileSync 대체).
export function readAllMistakes(dir = META_DIR) {
  return lmFiles(dir)
    .map((f) => {
      try { return readFileSync(f, 'utf8'); } catch { return ''; }
    })
    .join('\n');
}
