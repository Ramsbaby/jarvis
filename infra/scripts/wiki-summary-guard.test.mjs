import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanSummary } from './wiki-summary-guard.mjs';

const GOOD = '---\ntitle: "커리어"\ndomain: career\ntype: summary\nupdated: "2026-10-06"\n---\n\n## 경력\n- 한화에너지 입사 2026-09-14, 현재 온보딩 중이며 플랫폼 그룹 소속이다.\n';

test('정상 요약은 그대로 통과', () => {
  assert.equal(cleanSummary(GOOD), GOOD);
});

test('머리말 앞 서문은 잘라 낸다', () => {
  assert.equal(cleanSummary('구조화된 요약을 작성하겠습니다:\n\n' + GOOD), GOOD);
});

test('코드 펜스로 감싼 요약도 통과', () => {
  assert.equal(cleanSummary('```markdown\n' + GOOD + '```'), GOOD);
});

test('머리말 없는 권한 요청문(10-06 trading 실물)은 버린다', () => {
  const bad = '위키 저장소 경로를 먼저 찾아보겠습니다.\n\n```bash\nls -la ~/ | grep wiki\n실제 위치를 알려주시면 바로 작성해 저장하겠습니다. 파일명과 저장할 디렉토리만 지정하면 됩니다.';
  assert.equal(cleanSummary(bad), null);
});

test('굵은 글씨 가짜 머리말 + 끝의 되묻기(10-06 career 실물)는 버린다', () => {
  const bad = '**새 요약본**\n\n---\n\n**title**: "커리어"\n**type**: summary\n\n---\n\n## 학력\n- 세종대학교 졸업, 학점은 2016년에 모두 이수했다고 기록되어 있다.\n\n---\n\n**확인 사항**: 저장 위치가 이 경로가 맞는지 지시해주시면, 디렉토리 재생성 후 저장하겠습니다.';
  assert.equal(cleanSummary(bad), null);
});

test('올바른 머리말이어도 본문에 되묻기가 있으면 버린다', () => {
  assert.equal(cleanSummary(GOOD + '\n경로를 알려주시면 저장하겠습니다.\n'), null);
});

test('본문이 비면 버린다', () => {
  assert.equal(cleanSummary('---\ntype: summary\n---\n\n짧음'), null);
});

test('서문 + 빈 구분선 + 진짜 머리말(10-06 family 실물)은 서문만 잘라 통과', () => {
  assert.equal(cleanSummary('기존 구조를 존중하며 업데이트하겠습니다.\n\n---\n\n' + GOOD), GOOD);
});
