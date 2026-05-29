/**
 * intent-classifier.mjs — Embedding 기반 발화 의도 분류
 *
 * 키워드 정규식 폐기. Ollama bge-m3로 발화 벡터화 → 카테고리 벡터와 코사인 유사도.
 *
 * 출처: 2026-05-28 베스트 프랙티스 검증
 *   - 매 발화 LLM 분류 = FAIL (latency·비용 폭탄)
 *   - Embedding + cosine = sub-100ms, 비용 0 (로컬 Ollama)
 *   - 산업 표준: sentence-transformers / BERT classifier
 *
 * 카테고리:
 *   emotional   — 위로 필요 (공감 톤)
 *   analytical  — 분석/판단 (깊이 응답)
 *   code        — 코딩/디버그 (SSoT·Serena 가드)
 *   casual      — 잡담 (가벼움)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const OLLAMA_URL = process.env.OLLAMA_URL || 'http://localhost:11434/api/embeddings';
const EMBED_MODEL = 'bge-m3';
const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const CACHE_PATH = join(BOT_HOME, 'state', 'intent-category-vectors.json');

// 카테고리별 sample 발화 (다양성 확보)
const CATEGORIES = Object.freeze({
  emotional: [
    '진짜 너무 안타깝다 가슴이 찢어진다',
    '공황장애 올 것 같아',
    '마음이 너무 무겁다',
    '후회된다 그때 그렇게 했더라면',
    '버티기 힘들다',
    '허무하다 의욕이 안 난다',
    '눈물이 난다',
    '어떻게 해야 할지 모르겠다',
    '내 인생 천추의 한이다',
    '랜선으로 했더라면 결과가 달랐을까',
    '진짜 답답해 미치겠다',
    '왜 나한테만 이런 일이',
    '그냥 모든 걸 다 포기하고 싶다',
    // [2026-05-29 결함 수리 #7] 단답·짧은 감정 발화 보강 — 감사관 실측 "답답해/허하다/지친다" 오분류
    '답답해',
    '허하다',
    '지친다',
    '힘들다',
    '아프다',
    '슬프다',
    '괴롭다',
    '막막해',
    '서럽다',
    '울고싶다',
    '하 진짜',
    '미쳐버리겠다',
    '어떡해',
  ],
  analytical: [
    '이거 어떻게 생각해? 분석해줘',
    '장단점 비교해줘',
    '왜 이렇게 됐는지 근본 원인 분석',
    '리스크 평가 부탁',
    'ROI 계산해줘',
    '시나리오 분기 해줘',
    '메타 비즈니스 동기 추론',
    '다음 단계 뭐가 좋아?',
    '의사결정 도와줘 옵션 정리',
    '이 회사 지원 전략 어때',
    '이력서 개선 포인트 짚어줘',
    '경쟁 분석 해줘',
  ],
  code: [
    '이 함수 버그 고쳐줘',
    'API 엔드포인트 추가해줘',
    '리팩터링 부탁',
    '테스트 코드 작성',
    '이 코드 왜 안 돼?',
    'TypeScript 타입 에러 수정',
    'SQL 쿼리 최적화',
    '함수 시그니처 확인',
    'docker 설정 디버그',
    '크론 작업 추가',
    'launchctl plist 수정',
    'webhook 핸들러 구현',
  ],
  casual: [
    '안녕',
    '오늘 점심 뭐 먹지',
    '지금 뭐 해?',
    '고마워',
    'ㅋㅋㅋ',
    '잘 자',
    '오케이',
    '응 좋아',
    '재밌네',
    '시간 어때',
    '날씨 어떄',
    '잠깐',
  ],
});

let _vectorCache = null;
let _embedFailureCount = 0;
const _MAX_FAILURES = 3;

async function getEmbedding(text, timeoutMs = 3000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(OLLAMA_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: EMBED_MODEL, prompt: text }),
      signal: ctrl.signal,
    });
    clearTimeout(t);
    if (!res.ok) throw new Error(`Ollama ${res.status}`);
    const data = await res.json();
    return data.embedding;
  } catch (e) {
    clearTimeout(t);
    _embedFailureCount++;
    throw e;
  }
}

function cosineSim(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

async function buildCategoryVectors() {
  const vectors = {};
  for (const [cat, samples] of Object.entries(CATEGORIES)) {
    const embeddings = [];
    for (const s of samples) {
      try {
        const e = await getEmbedding(s);
        if (e && e.length) embeddings.push(e);
      } catch { /* skip */ }
    }
    if (!embeddings.length) {
      throw new Error(`No embeddings for category ${cat}`);
    }
    const dim = embeddings[0].length;
    const avg = new Array(dim).fill(0);
    for (const e of embeddings) {
      for (let i = 0; i < dim; i++) avg[i] += e[i];
    }
    for (let i = 0; i < dim; i++) avg[i] /= embeddings.length;
    vectors[cat] = avg;
  }
  return vectors;
}

async function loadVectors() {
  if (_vectorCache) return _vectorCache;
  if (existsSync(CACHE_PATH)) {
    try {
      _vectorCache = JSON.parse(readFileSync(CACHE_PATH, 'utf-8'));
      return _vectorCache;
    } catch {
      // 캐시 손상 — 재계산
    }
  }
  _vectorCache = await buildCategoryVectors();
  try {
    mkdirSync(dirname(CACHE_PATH), { recursive: true });
    writeFileSync(CACHE_PATH, JSON.stringify(_vectorCache));
  } catch { /* best-effort */ }
  return _vectorCache;
}

/**
 * 키워드 기반 fallback (Ollama 다운 / embedding 실패 시).
 * 핵심 신호어만 — 정규식 떡칠 회피.
 */
const KEYWORD_FALLBACK_EMOTIONAL = /힘들다|답답하|공황|찢어진|후회|버티|허무|울고싶|눈물|미치겠|막막|불안|괴롭|허탈|망했|천추의 한|한이 될|가슴이|마음이 무거/;
const KEYWORD_FALLBACK_CODE = /코드|버그|디버그|함수|클래스|리팩터|implement|fix|API|launchctl|cron|크론|test|테스트/;
const KEYWORD_FALLBACK_ANALYTICAL = /분석|비교|왜|근본 원인|장단점|리스크|시나리오|ROI|평가|판단|전략/;

function keywordFallback(text) {
  if (KEYWORD_FALLBACK_EMOTIONAL.test(text)) return 'emotional';
  if (KEYWORD_FALLBACK_CODE.test(text)) return 'code';
  if (KEYWORD_FALLBACK_ANALYTICAL.test(text)) return 'analytical';
  return 'casual';
}

/**
 * 발화 의도 분류.
 *
 * @param {string} prompt — 사용자 발화
 * @param {{ confidenceThreshold?: number, useCache?: boolean }} opts
 * @returns {Promise<{ intent: string, confidence: number, scores: object, source: string }>}
 */
export async function classifyIntent(prompt, opts = {}) {
  const { confidenceThreshold = 0.3 } = opts;
  if (!prompt || prompt.trim().length < 2) {
    return { intent: 'casual', confidence: 0, scores: {}, source: 'too-short' };
  }

  // Ollama 연속 실패 시 키워드 fallback (서킷브레이커)
  if (_embedFailureCount >= _MAX_FAILURES) {
    return { intent: keywordFallback(prompt), confidence: 0.5, scores: {}, source: 'fallback-circuit' };
  }

  try {
    const vectors = await loadVectors();
    const emb = await getEmbedding(prompt);
    const scores = {};
    for (const [cat, vec] of Object.entries(vectors)) {
      scores[cat] = cosineSim(emb, vec);
    }
    const sorted = Object.entries(scores).sort((a, b) => b[1] - a[1]);
    const [topCat, topScore] = sorted[0];
    _embedFailureCount = 0; // 성공 시 리셋

    if (topScore < confidenceThreshold) {
      // 낮은 confidence — keyword fallback과 비교
      const kwIntent = keywordFallback(prompt);
      return { intent: kwIntent, confidence: topScore, scores, source: 'low-confidence-fallback' };
    }

    return { intent: topCat, confidence: topScore, scores, source: 'embedding' };
  } catch (e) {
    return { intent: keywordFallback(prompt), confidence: 0.5, scores: {}, source: `fallback-error:${e.message}` };
  }
}

/**
 * 사전 워밍업 (봇 시작 시 1회 호출 권장).
 * 카테고리 벡터를 캐시 파일에 적재.
 */
export async function warmupIntentClassifier() {
  try {
    await loadVectors();
    return true;
  } catch (e) {
    return false;
  }
}

// 캐시 강제 재구축 (sample 발화 변경 시)
export function clearIntentCache() {
  _vectorCache = null;
}
