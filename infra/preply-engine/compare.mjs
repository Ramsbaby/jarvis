#!/usr/bin/env node
// compare.mjs — 원본 교재 vs 재조립 교재 의미 동등성 검사기 (preply-engine 파일럿 게이트)
//
// 검사 4종 (전부 PASS여야 파일럿 통과):
//   1. class 인벤토리: 모든 class 속성값의 종류·개수 완전 일치
//   2. 가시 텍스트: 태그·스크립트 제거 후 공백 정규화 텍스트 완전 일치 (콘텐츠 소실 0 증명)
//   3. 퀴즈 정답 시퀀스: checkQ(this,bool) 불리언 순서 완전 일치 (정답 뒤바뀜 0 증명)
//   4. onclick 인벤토리: 상호작용 핸들러 종류·개수 일치 (플립·탭·정답보기 보존 증명)
//
// 사용: node compare.mjs <원본.html> <재조립.html>

import { readFileSync } from 'node:fs';

const [, , fileA, fileB] = process.argv;
const A = readFileSync(fileA, 'utf-8');
const B = readFileSync(fileB, 'utf-8');

let pass = 0, fail = 0;
const report = (name, ok, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ' — ' + detail : ''}`);
  ok ? pass++ : fail++;
};

// 1. class 인벤토리
function classInventory(html) {
  const map = new Map();
  for (const m of html.matchAll(/class="([^"]+)"/g)) {
    map.set(m[1], (map.get(m[1]) || 0) + 1);
  }
  return map;
}
const invA = classInventory(A), invB = classInventory(B);
const invDiff = [];
for (const [k, v] of invA) if (invB.get(k) !== v) invDiff.push(`${k}: ${v}→${invB.get(k) || 0}`);
for (const [k, v] of invB) if (!invA.has(k)) invDiff.push(`${k}: 0→${v}`);
report('class 인벤토리', invDiff.length === 0, invDiff.length ? invDiff.slice(0, 5).join(' | ') : `${invA.size}종 일치`);

// 2. 가시 텍스트 (script/style 제거 → 태그 제거 → 공백 정규화)
function visibleText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}
const txtA = visibleText(A), txtB = visibleText(B);
if (txtA === txtB) {
  report('가시 텍스트', true, `${txtA.length}자 완전 일치`);
} else {
  // 첫 불일치 지점 표시
  let i = 0;
  while (i < Math.min(txtA.length, txtB.length) && txtA[i] === txtB[i]) i++;
  report('가시 텍스트', false, `첫 불일치 @${i}: A="${txtA.slice(i, i + 60)}" B="${txtB.slice(i, i + 60)}"`);
}

// 3. 퀴즈 정답 시퀀스
const seqA = [...A.matchAll(/checkQ\(this,\s*(true|false)\)/g)].map((m) => m[1]);
const seqB = [...B.matchAll(/checkQ\(this,\s*(true|false)\)/g)].map((m) => m[1]);
report('퀴즈 정답 시퀀스', JSON.stringify(seqA) === JSON.stringify(seqB), `${seqA.length}개 보기 (정답 ${seqA.filter((x) => x === 'true').length}개)`);

// 4. onclick 인벤토리 (함수명 단위)
function onclickInventory(html) {
  const map = new Map();
  for (const m of html.matchAll(/onclick="([a-zA-Z_.]+[($])/g)) {
    map.set(m[1], (map.get(m[1]) || 0) + 1);
  }
  return map;
}
const ocA = onclickInventory(A), ocB = onclickInventory(B);
const ocDiff = [];
for (const [k, v] of ocA) if (ocB.get(k) !== v) ocDiff.push(`${k}: ${v}→${ocB.get(k) || 0}`);
for (const [k, v] of ocB) if (!ocA.has(k)) ocDiff.push(`${k}: 0→${v}`);
report('onclick 인벤토리', ocDiff.length === 0, ocDiff.length ? ocDiff.join(' | ') : [...ocA.entries()].map(([k, v]) => `${k}×${v}`).join(' '));

console.log(`\n결과: ${pass}/4 PASS${fail ? ` · ${fail} FAIL` : ''}`);
process.exit(fail ? 1 : 0);
