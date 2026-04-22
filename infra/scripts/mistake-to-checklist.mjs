#!/usr/bin/env node
// mistake-to-checklist.mjs — 오답노트 → 스킬별 체크리스트 자동 생성
//
// learned-mistakes.md의 각 오답 블록을 파싱하여 `대응` 필드를 추출하고,
// 제목·패턴에서 관련 스킬(investigate/verify/deploy/review 등)을 추정한 뒤
// ~/jarvis/runtime/wiki/meta/checklists/<skill>.md 로 그룹화 저장.
//
// 효과: 스킬 실행 전 해당 체크리스트를 참조하면 과거 실수 대응책이 바로 보임.
// 주기: 일 1회 (03:45 KST, 재발 카운터 이후) 또는 수동 실행.
//
// 안전: 기존 파일 덮어쓰기 전 git diff 가능한 형태로만 write. 실패해도 기존 파일 유지.

import fs from 'node:fs';
import path from 'node:path';

const BOT_HOME = process.env.BOT_HOME || `${process.env.HOME}/jarvis/runtime`;
const MISTAKES = `${BOT_HOME}/wiki/meta/learned-mistakes.md`;
const OUT_DIR = `${BOT_HOME}/wiki/meta/checklists`;
const LOG = `${BOT_HOME}/logs/mistake-to-checklist.log`;

const ts = () => new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }).replace(' ', 'T') + '+09:00';
const log = (msg) => {
  fs.mkdirSync(path.dirname(LOG), { recursive: true });
  fs.appendFileSync(LOG, `[${ts()}] ${msg}\n`);
};

if (!fs.existsSync(MISTAKES)) {
  log('learned-mistakes.md 없음 — skip');
  process.exit(0);
}

const content = fs.readFileSync(MISTAKES, 'utf8');

// split 기반 파싱 (matchAll 유니코드 regex 이슈 우회)
// 결과: [prefix, date1, rest1, date2, rest2, ...]
// rest_i 는 "title\n\n- **패턴**: ...\n- **대응**: ...\n\n---\n" 형태
const parts = content.split(/^## (\d{4}-\d{2}-\d{2}) — /m);

// 키워드 → 스킬 매핑 (복수 매칭 시 각 스킬에 복제 등재)
const SKILL_KEYWORDS = {
  investigate: ['근본원인', '근본 원인', '5 why', '디버깅', '장애', 'investigate'],
  verify: ['검증', '단정', '실증', '회귀', 'verify', 'pass', 'fail'],
  deploy: ['배포', '커밋', 'push', 'deploy', 'ship', '릴리즈'],
  review: ['리뷰', '코드 검토', 'review'],
  crisis: ['긴급', '장애 대응', '봇 다운', 'crisis'],
  doctor: ['점검', '건강 체크', 'doctor'],
  oops: ['오답', '학습', '재발'],
  general: [], // fallback
};

const classifyBlock = (header, body) => {
  const text = `${header}\n${body}`.toLowerCase();
  const hits = [];
  for (const [skill, kws] of Object.entries(SKILL_KEYWORDS)) {
    if (kws.some((kw) => text.includes(kw.toLowerCase()))) {
      hits.push(skill);
    }
  }
  return hits.length ? hits : ['general'];
};

const extractResponse = (body) => {
  // `- **대응**:` 부터 다음 필드(`- **`) 또는 `---` 또는 끝까지
  const m = body.match(/- \*\*대응\*\*:\s*([\s\S]+?)(?=\n- \*\*|\n---|\n*$)/m);
  return m ? m[1].trim().replace(/\n\s+/g, ' ').slice(0, 400) : '';
};

const blocks = [];
// parts[0]은 prefix. parts[1,3,5,...]는 날짜, parts[2,4,6,...]는 rest.
for (let i = 1; i < parts.length - 1; i += 2) {
  const date = parts[i];
  const rest = parts[i + 1];
  // rest의 첫 줄이 title, 그 아래가 body
  const nlIdx = rest.indexOf('\n');
  if (nlIdx < 0) continue;
  const title = rest.slice(0, nlIdx).trim();
  const body = rest.slice(nlIdx + 1);
  const response = extractResponse(body);
  if (!response || response.length < 20) continue; // 구조적 가드 없는 오답 제외
  blocks.push({ date, title, skills: classifyBlock(title, body), response });
}

// 스킬별 그룹화
const grouped = {};
for (const b of blocks) {
  for (const s of b.skills) {
    grouped[s] = grouped[s] || [];
    grouped[s].push(b);
  }
}

// 출력 디렉토리 준비
fs.mkdirSync(OUT_DIR, { recursive: true });

const generated = ts();
let totalWritten = 0;
for (const [skill, items] of Object.entries(grouped)) {
  // 최신순 정렬 + 최대 30개
  items.sort((a, b) => b.date.localeCompare(a.date));
  const top = items.slice(0, 30);

  const lines = [
    '---',
    `category: meta/checklists`,
    `skill: ${skill}`,
    `generated_at: ${generated}`,
    `source: learned-mistakes.md`,
    `item_count: ${top.length}`,
    '---',
    '',
    `# ${skill === 'general' ? '일반' : `/${skill}`} 체크리스트 — 과거 오답 기반`,
    '',
    `> 자동 생성 파일. 편집 금지 — 오답노트가 SSoT.`,
    `> 스킬 실행 전 본 체크리스트를 1회 스캔하고, 각 항목의 **대응**을 이번 작업에 적용하는지 확인하십시오.`,
    '',
    `생성: ${generated} | 항목 수: ${top.length}`,
    '',
    '---',
    '',
  ];

  for (const it of top) {
    lines.push(`## ${it.date} — ${it.title}`);
    lines.push('');
    lines.push(`**대응**: ${it.response}`);
    lines.push('');
    lines.push('---');
    lines.push('');
  }

  const out = path.join(OUT_DIR, `${skill}.md`);
  fs.writeFileSync(out, lines.join('\n'));
  totalWritten++;
}

// 인덱스 파일
const idxLines = [
  '---',
  'category: meta/checklists',
  `generated_at: ${generated}`,
  'source: learned-mistakes.md',
  '---',
  '',
  '# 체크리스트 인덱스',
  '',
  '| 스킬 | 오답 수 | 파일 |',
  '|---|---:|---|',
];
for (const [skill, items] of Object.entries(grouped).sort((a, b) => b[1].length - a[1].length)) {
  idxLines.push(`| ${skill === 'general' ? '일반' : `/${skill}`} | ${items.length} | \`${skill}.md\` |`);
}
fs.writeFileSync(path.join(OUT_DIR, 'INDEX.md'), idxLines.join('\n'));

log(`생성 완료 — ${totalWritten}개 스킬 체크리스트, 총 오답 ${blocks.length}건 분류`);
console.log(`✅ ${totalWritten}개 스킬 체크리스트 생성 (${OUT_DIR})`);
console.log(`총 오답 ${blocks.length}건 → 스킬별 최대 30건 요약`);
