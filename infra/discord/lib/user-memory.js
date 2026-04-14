/**
 * UserMemory — per-user persistent long-term memory.
 * Stores facts, preferences, corrections per Discord userId.
 * File: ~/.jarvis/state/users/{userId}.json
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const USERS_DIR = join(BOT_HOME, 'state', 'users');

// Family 채널용 노이즈 fact 필터 — 컴팩션 아티팩트·세션 메타 텍스트 제거
// 너무 광범위한 userid 패턴 대신 정확한 노이즈 패턴만 차단
const FAMILY_JUNK_RE = /^\[userid:|compacted at|사용자 의도|완료된 작업|미완 작업|핵심 참조/i;

// 카테고리 자동 감지 — 텍스트 키워드 기반 분류
const CATEGORY_RULES = [
  { cat: 'trading',  re: /stock|주식|트레이딩|레버리지|etf|매수|매도|포트폴리오|s&p|nasdaq|코스피|cpi|fomc|금리|배당|수익률/i },
  { cat: 'work',     re: /***|***|백엔드|spring|kafka|grpc|redis|aws|이직|면접|연봉|프로젝트|업무|회사|사수|팀장|개발/i },
  { cat: 'family',   re: /아내|와이프|가족|부모님|아이|육아/i },
  { cat: 'travel',   re: /여행|destination-a|destination-b|해외|항공|숙소|노보리베쓰|휴가|출장/i },
  { cat: 'health',   re: /건강|운동|병원|의사|약|몸무게|다이어트|수면|피로|두통/i },
];

function detectCategory(text) {
  for (const { cat, re } of CATEGORY_RULES) {
    if (re.test(text)) return cat;
  }
  return 'general';
}

function _path(userId) {
  return join(USERS_DIR, `${userId}.json`);
}

function _load(userId) {
  const defaults = { userId, facts: [], preferences: [], corrections: [], plans: [], updatedAt: null };
  try {
    const data = JSON.parse(readFileSync(_path(userId), 'utf-8'));
    const merged = { ...defaults, ...data };
    // null/non-array 값이 파일에 있으면 spread가 기본 배열을 덮어쓰므로 재보정
    merged.facts = Array.isArray(merged.facts) ? merged.facts : [];
    merged.preferences = Array.isArray(merged.preferences) ? merged.preferences : [];
    merged.corrections = Array.isArray(merged.corrections) ? merged.corrections : [];
    merged.plans = Array.isArray(merged.plans) ? merged.plans : [];
    return merged;
  } catch (err) {
    console.warn(`[user-memory] JSON parse failed for userId=${userId}: ${err.message}`);
    return defaults;
  }
}

function _save(data) {
  mkdirSync(USERS_DIR, { recursive: true });
  writeFileSync(_path(data.userId), JSON.stringify(data, null, 2));
}

export const userMemory = {
  get(userId) {
    return _load(userId);
  },

  addFact(userId, fact) {
    const data = _load(userId);
    // facts는 string 또는 {text, addedAt[, category]} 혼용 허용 (하위 호환)
    const normText = (f) => (typeof f === 'string' ? f : f?.text ?? '');
    const exists = data.facts.some(f => normText(f) === fact);
    if (!exists) {
      data.facts.push({
        text: fact,
        addedAt: new Date().toISOString(),
        category: detectCategory(fact),
      });
      data.updatedAt = new Date().toISOString();
      _save(data);
    }
  },

  addPlan(userId, plan) {
    if (!plan?.key || typeof plan.key !== 'string') {
      // key 없는 plan은 중복 방지 불가 — 저장 거부
      return;
    }
    const data = _load(userId);
    // key 기반 upsert — 같은 key면 덮어쓰기 (일정 업데이트)
    const idx = data.plans.findIndex(p => p.key === plan.key);
    if (idx >= 0) {
      data.plans[idx] = { ...data.plans[idx], ...plan, updatedAt: new Date().toISOString() };
    } else {
      data.plans.push({ ...plan, createdAt: new Date().toISOString() });
    }
    data.updatedAt = new Date().toISOString();
    _save(data);
  },

  getRelevantMemories(userId, currentPrompt, topN = 8) {
    try {
      const data = _load(userId);
      if (!data.facts.length) return this.getPromptSnippet(userId);

      // 불용어 집합
      const STOPWORDS = new Set([
        'the', 'is', 'a', 'an', 'in', 'of', 'to', 'and', 'or', 'for',
        '이', '가', '을', '를', '은', '는', '에', '의', '도', '로', '한',
        '하', '그', '저', '어', '이다', '있다', '없다', '것', '수', '등',
      ]);

      // 단어 토큰화 (불용어 + 1글자 제거)
      const tokenize = (text) =>
        (text || '').toLowerCase()
          .split(/[\s,.\-!?()[\]{}:;'"]+/)
          .filter(w => w.length > 1 && !STOPWORDS.has(w));

      const promptWords = new Set(tokenize(currentPrompt));
      const now = Date.now();
      const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;
      const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

      // facts 정규화 (category 포함, 레거시 호환)
      const normalize = (f) => typeof f === 'string'
        ? { text: f, addedAt: null, category: detectCategory(f) }
        : { text: f?.text ?? '', addedAt: f?.addedAt ?? null, category: f?.category ?? detectCategory(f?.text ?? '') };

      const allFacts = data.facts
        .map(normalize)
        .filter(f => f.text.length > 0);

      // 프롬프트 카테고리 감지 → 해당 카테고리 fact 부스트
      const promptCategory = detectCategory(currentPrompt);

      // 각 fact에 관련성 점수 산출
      const scored = allFacts.map(f => {
        const factWords = tokenize(f.text);
        const factSet = new Set(factWords);
        let score = 0;
        if (factSet.size > 0) {
          let intersect = 0;
          for (const w of promptWords) {
            if (factSet.has(w)) intersect++;
          }
          score = intersect / factSet.size;
        }
        if (f.addedAt) {
          const age = now - new Date(f.addedAt).getTime();
          if (age <= SEVEN_DAYS_MS) score += 0.3;
          if (age <= THREE_DAYS_MS) score += 0.2;
        }
        // 카테고리 매칭 부스트 — 같은 주제끼리 우선 surfacing
        if (f.category !== 'general' && f.category === promptCategory) score += 0.4;
        return { ...f, score };
      });

      // 점수 내림차순 정렬
      scored.sort((a, b) => b.score - a.score);

      // topN 선택
      const selected = scored.slice(0, topN);
      const selectedTexts = new Set(selected.map(f => f.text));

      // 최신 기억 3개 최소 보장 (시간 기준 정렬)
      const byTime = [...allFacts].sort((a, b) => {
        const ta = a.addedAt ? new Date(a.addedAt).getTime() : 0;
        const tb = b.addedAt ? new Date(b.addedAt).getTime() : 0;
        return tb - ta;
      });
      for (const f of byTime.slice(0, 3)) {
        if (!selectedTexts.has(f.text)) {
          selected.push({ ...f, score: 0 });
          selectedTexts.add(f.text);
        }
      }

      if (!selected.length) return this.getPromptSnippet(userId);

      // 출력 형식: getPromptSnippet()과 동일한 텍스트 형식
      const lines = [];
      const factLines = ['## 사용자 장기 기억'];
      for (const f of selected) {
        factLines.push(`- ${f.text}`);
      }
      lines.push(factLines.join('\n'));

      if (data.preferences.length) lines.push('## 선호 패턴\n' + data.preferences.map(p => `- ${p}`).join('\n'));
      if (data.corrections.length) lines.push('## 수정 사항\n' + data.corrections.map(c => `- ${c}`).join('\n'));
      if (data.plans.length) {
        const activePlans = data.plans.filter(p => !p.done);
        if (activePlans.length) lines.push('## 진행 중인 계획\n' + activePlans.map(p => `- [${p.key}] ${p.summary}`).join('\n'));
      }
      return lines.join('\n\n');
    } catch (err) {
      // 오류 시 fallback
      return this.getPromptSnippet(userId);
    }
  },

  getPromptSnippet(userId) {
    const data = _load(userId);
    const lines = [];

    if (data.facts.length) {
      // facts는 string(레거시) 또는 {text, addedAt[, category]} 혼용 허용
      const normalize = (f) => typeof f === 'string'
        ? { text: f, addedAt: null, category: detectCategory(f) }
        : { text: f?.text ?? '', addedAt: f?.addedAt ?? null, category: f?.category ?? detectCategory(f?.text ?? '') };

      const now = Date.now();
      const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

      // 최신 순 정렬 (addedAt 없는 레거시는 중간 우선순위)
      const sorted = data.facts
        .map(normalize)
        .filter(f => f.text.length > 0)
        .sort((a, b) => {
          const ta = a.addedAt ? new Date(a.addedAt).getTime() : (now - SEVEN_DAYS_MS);
          const tb = b.addedAt ? new Date(b.addedAt).getTime() : (now - SEVEN_DAYS_MS);
          return tb - ta; // 최신 먼저
        });

      // 최근 7일 항목은 최대 10개 우선, 그 외 오래된 것 5개 추가 = 최대 15개
      const recent = sorted.filter(f => {
        if (!f.addedAt) return false;
        return (now - new Date(f.addedAt).getTime()) <= SEVEN_DAYS_MS;
      }).slice(0, 10);

      const recentTexts = new Set(recent.map(f => f.text));
      const older = sorted.filter(f => !recentTexts.has(f.text)).slice(0, 5);

      const factLines = [];
      if (recent.length) {
        factLines.push('### 최근 7일');
        factLines.push(...recent.map(f => `- ${f.text}`));
      }
      if (older.length) {
        factLines.push('### 이전 기억');
        factLines.push(...older.map(f => `- ${f.text}`));
      }
      if (!recent.length && !older.length) {
        // 레거시 string-only 폴백: addedAt 없는 항목만 있을 때
        factLines.push(...sorted.slice(0, 15).map(f => `- ${f.text}`));
      }

      if (factLines.length) {
        lines.push('## 사용자 장기 기억\n' + factLines.join('\n'));
      }
    }

    if (data.preferences.length) lines.push('## 선호 패턴\n' + data.preferences.map(p => `- ${p}`).join('\n'));
    if (data.corrections.length) lines.push('## 수정 사항\n' + data.corrections.map(c => `- ${c}`).join('\n'));
    if (data.plans.length) {
      const activePlans = data.plans.filter(p => !p.done);
      if (activePlans.length) lines.push('## 진행 중인 계획\n' + activePlans.map(p => `- [${p.key}] ${p.summary}`).join('\n'));
    }
    return lines.join('\n\n');
  },
};
