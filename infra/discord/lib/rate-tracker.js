/**
 * RateTracker — 5시간 슬라이딩 윈도우 기반 API 호출 속도 제한기
 *
 * === 레이트 제한 개념 ===
 *
 * [목적]
 *   - Claude API 또는 Claude CLI의 비용 폭증을 방지
 *   - 5시간당 최대 900 호출 제한 (180 calls/hour)
 *   - Discord 봇과 ask-claude.sh 크론 태스크가 공유
 *
 * [슬라이딩 윈도우 (Sliding Window) 방식]
 *   - 고정 시간대(예: 0:00~5:00)가 아님
 *   - "현재 시점에서 과거 5시간" 내의 호출 수를 추적
 *   - 예시:
 *     시각 12:00에 500호출 있었다면
 *     시각 17:00에는 그 500호출이 "윈도우 밖"으로 자동 제거됨
 *   - 따라서 부하가 자연스럽게 분산됨
 *
 * [경고 및 차단]
 *   - warn: 80% 이상 900호출 (720호출) → Discord 경고 메시지
 *   - reject: 90% 이상 900호출 (810호출) → 호출 자체 차단 (429 응답)
 *
 * [세션 토큰 카운트와의 차이점]
 *   ❌ "rate-tracker가 찬 것 = 세션 파일이 가득 찬 것" → 틀림
 *   ✓ rate-tracker: 호출 빈도 제한 (속도 제한)
 *   ✓ sessionStore.tokenCount: 누적 토큰 제한 (메모리 폭발 방지)
 *
 *   예시:
 *   - rate-tracker 80%: "5시간에 800호출 했으니, 더 느리게"
 *   - tokenCount 5000: "이 스레드의 컨텍스트가 5000 토큰이니, 세션 폐기"
 *
 * [실제 활용]
 *   1. Discord 메시지 도착 → messageCreate 핸들러
 *   2. rateTracker.check() 호출 → { count, pct, warn, reject }
 *   3. reject=true면 사용자에게 "API 속도 제한 중" 메시지
 *   4. 성공하면 rateTracker.record() 호출 (타임스탬프 추가)
 *
 * [파일 구조]
 *   ~/jarvis/runtime/state/rate-tracker.json
 *   - 구조: [1781143914412, 1781143915000, ...] (밀리초 타임스탐프 배열)
 *   - 크기: ~3.6MB (900개 호출 × 4bytes + overhead)
 *   - 부팅 시: 5시간 이전 항목 자동 제거 (prune)
 */

import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { dirname, join } from 'node:path';

const RATE_WINDOW_HOURS = 5;
const RATE_MAX_REQUESTS = 900;

export class RateTracker {
  constructor(filePath) {
    this.filePath = filePath;
    this.requests = [];
    this.load();
  }

  load() {
    try {
      const raw = readFileSync(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw);
      this.requests = Array.isArray(parsed)
        ? parsed
        : (Array.isArray(parsed.requests) ? parsed.requests : []);
    } catch {
      this.requests = [];
    }
  }

  save() {
    try {
      const tmp = join(dirname(this.filePath), `.rate-tracker-${process.pid}.tmp`);
      writeFileSync(tmp, JSON.stringify(this.requests));
      renameSync(tmp, this.filePath);
    } catch (err) {
      console.error(`[rate-tracker] save failed: ${err.message}`);
    }
  }

  prune() {
    const cutoff = Date.now() - RATE_WINDOW_HOURS * 3600 * 1000;
    this.requests = this.requests.filter((t) => t > cutoff);
  }

  record() {
    this.prune();
    this.requests.push(Date.now());
    this.save();
  }

  /**
   * 현재 레이트 제한 상태 조회 (비파괴)
   *
   * 반환값: { count, pct, max, warn, reject }
   *   - count: 현재 5시간 윈도우 내 호출 수
   *   - pct: 한계 대비 비율 (0.0 ~ 1.0)
   *   - max: 최대값 (900)
   *   - warn: 80% 이상 900개 (true면 경고 메시지 표시)
   *   - reject: 90% 이상 900개 (true면 호출 자체 차단)
   *
   * 사용 예:
   *   const status = rateTracker.check();
   *   if (status.reject) {
   *     message.reply("현재 API 호출이 많습니다. 잠시 후 다시 시도해주세요.");
   *     return;
   *   }
   *   if (status.warn) {
   *     message.reply(`⚠️ API 호출 제한: ${status.count}/900 (${(status.pct * 100).toFixed(0)}%)`);
   *   }
   *
   * 주의:
   *   - check()는 "조회만" 함 (호출 기록 안 됨)
   *   - 실제 호출 후에는 rateTracker.record()를 별도로 호출
   *   - record() 안에서 자동으로 prune() 실행
   */
  check() {
    this.prune();
    const count = this.requests.length;
    const pct = count / RATE_MAX_REQUESTS;
    return {
      count,
      pct,
      max: RATE_MAX_REQUESTS,
      warn: pct >= 0.8 && pct < 0.9,
      reject: pct >= 0.9,
    };
  }
}
