/**
 * task-fsm.mjs — Jarvis 태스크 상태 머신 (순수 함수)
 * 부수효과 없음. 상태 전이 검증 + 변환만 수행.
 */

// 허용된 상태 전이 테이블
const TRANSITIONS = {
  pending:  ['queued', 'skipped'],
  queued:   ['running', 'skipped', 'pending'],
  running:  ['done', 'failed', 'queued'],   // queued = 재시도
  failed:   ['queued', 'pending', 'done'],   // 수동 복구 또는 재시도 성공 시 done
  done:     [],                              // terminal
  skipped:  ['pending', 'queued'],            // 수동 복구 또는 CB 쿨다운 해제 후 재큐
};

export const VALID_STATUSES = Object.keys(TRANSITIONS);

/**
 * 상태 전이 가능 여부 확인
 * @param {string} from
 * @param {string} to
 * @returns {boolean}
 */
export function canTransition(from, to) {
  return TRANSITIONS[from]?.includes(to) ?? false;
}

/**
 * 상태 전이 적용 (순수 함수 — 새 객체 반환)
 * @param {Object} task
 * @param {string} to
 * @returns {Object}
 * @throws {Error} 유효하지 않은 전이 시
 */
export function applyTransition(task, to) {
  if (!canTransition(task.status, to)) {
    throw new Error(`유효하지 않은 상태 전이: ${task.status} → ${to} (task: ${task.id})`);
  }
  return { ...task, status: to, updated_at: Date.now() };
}

/**
 * 다음 실행 가능 태스크 선택 (의존성 충족 + 재시도 한도)
 * @param {Object[]} tasks
 * @returns {Object|null}
 */
export function pickNextTask(tasks) {
  const doneIds = new Set(tasks.filter(t => t.status === 'done').map(t => t.id));
  return tasks
    .filter(t => t.status === 'queued')
    .filter(t => (t.depends ?? []).every(dep => doneIds.has(dep)))
    .filter(t => (t.retries ?? 0) < (t.maxRetries ?? 2))
    .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0))[0] ?? null;
}
