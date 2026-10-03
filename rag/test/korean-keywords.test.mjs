// node --test rag/test/korean-keywords.test.mjs
// 한국어 키워드 줄기 뽑기의 단위 시험 — 색인·임베딩 없이 돈다.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  koreanStem, keywordTokens, stemmedQuery, dropStopwords, matchedTermCount,
} from '../lib/korean-keywords.mjs';

test('조사·하다/되다 어미를 떼어 줄기를 낸다', () => {
  const cases = {
    서버에서: '서버', 로그인을: '로그인', 만료됐다: '만료', 토큰이: '토큰', 기출부터: '기출',
    합격선이랑: '합격선', 구현했었어: '구현', 금지됐었지: '금지', 단계였지: '단계', 확인해: '확인',
    중요한: '중요', sigkill에서: 'sigkill', api를: 'api',
  };
  for (const [w, stem] of Object.entries(cases)) assert.equal(koreanStem(w), stem, w);
});

test('줄기가 한 글자가 되면 떼지 않는다 (동사·짧은 명사 오탐 방지)', () => {
  for (const w of ['하는', '가는', '먹이', '회의', '이해', '역할', '포함', '서버', 'server']) {
    assert.equal(koreanStem(w), null, w);
  }
});

test('질의와 문서가 같은 줄기로 만난다', () => {
  const q = dropStopwords(keywordTokens('서버에서 로그인이 만료됐다'));
  const d = keywordTokens('어제 서버가 재시작돼서 로그인을 다시 했고 토큰 만료 시각을 확인했다');
  assert.deepEqual(q, ['서버', '로그인', '만료']);
  assert.equal(matchedTermCount(q, d), 3);
});

test('낱말 수는 그대로다 (1:1 치환 — 문서 길이 보정 기준 유지)', () => {
  const text = 'LanceDB 색인에서 FTS 질의를 돌렸다';
  assert.equal(keywordTokens(text).length, 5);
});

test('영어·코드 낱말은 그대로 둔다', () => {
  assert.deepEqual(keywordTokens('oauth-refresh.sh credentials.json reload'), ['oauth', 'refresh', 'sh', 'credentials', 'json', 'reload']);
});

test('줄기 질의: 군말을 빼고 줄기만 잇는다, 영어만 있으면 null', () => {
  assert.equal(stemmedQuery('다낭에서 해산물 저녁집 예약은 어떻게 하라고 했었나'), '다낭 해산물 저녁집 예약');
  assert.equal(stemmedQuery('MAX_SCAN_MS global install swap'), null);
  assert.equal(stemmedQuery('STREAMER-NEW SPLIT-TRACE'), null);
});
