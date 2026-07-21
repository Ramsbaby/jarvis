#!/bin/bash
# verdict-wrapper.sh — Exit code 중심의 작업 결과 판정 함수
#
# 역할:
#   로그 에러 vs API 실패를 정확히 구분하기 위해 exit code를 1순위로,
#   stderr 로그는 참고용으로만 사용하는 표준 판정 래퍼
#
# 규칙:
#   - exit code 0 → 성공 (stderr 로그는 무시)
#   - exit code != 0 → 실패 (로그 내용 참고 가능하지만 판정은 exit code에만 의존)
#   - 로그에 ERROR/FAIL이 있어도 exit code 0이면 성공 (도구의 정보 출력일 수 있음)
#
# 사용법:
#   source ~/.jarvis/lib/verdict-wrapper.sh
#   result_msg=$(run_command_with_verdict <exit_code> <command_description>)
#   if [[ $? -eq 0 ]]; then echo "성공"; else echo "실패"; fi

set -u

# 판정 함수: exit code를 기반으로 성공/실패 판정
# 입력: $1=exit_code, $2=command_description (선택)
# 반환: exit code (0=성공, 1=실패)
# 출력: 판정 메시지 (JSON 형식)
judge_by_exitcode() {
  local exit_code=${1:-0}
  local cmd_desc="${2:-unknown command}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # exit code가 숫자가 아니면 오류
  if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
    echo "{\"error\":\"invalid exit_code: $exit_code\",\"cmd\":\"$cmd_desc\",\"verdict\":\"INVALID\",\"timestamp\":\"$timestamp\"}" >&2
    return 1
  fi

  # 판정: exit code 0 → 성공
  if [[ $exit_code -eq 0 ]]; then
    echo "{\"verdict\":\"SUCCESS\",\"exit_code\":0,\"cmd\":\"$cmd_desc\",\"timestamp\":\"$timestamp\"}"
    return 0
  else
    # exit code != 0 → 실패
    echo "{\"verdict\":\"FAILURE\",\"exit_code\":$exit_code,\"cmd\":\"$cmd_desc\",\"timestamp\":\"$timestamp\"}"
    return 1
  fi
}

# 래퍼: 명령 실행 → exit code 캡처 → 판정
# 입력: $@=command_to_run
# 반환: exit code (0=성공, 1=실패)
# 출력: 판정 메시지
run_and_judge() {
  local cmd_to_run=("$@")
  local exit_code
  local cmd_str="${cmd_to_run[*]}"

  # 명령 실행 (exit code 캡처, 출력은 그대로 전달)
  "${cmd_to_run[@]}" 2>&1 || exit_code=$?
  exit_code=${exit_code:-0}

  # 판정 수행
  judge_by_exitcode "$exit_code" "$cmd_str"
  return $?
}

# 재시도 래퍼: max_attempts번 시도 후 판정
# 입력: $1=max_attempts, $@=command_to_run (2번째부터)
# 반환: exit code (0=성공, 1=모두_실패)
# 출력: 각 시도의 판정 메시지
run_with_retry_and_judge() {
  local max_attempts=${1:-3}
  local cmd_to_run=("${@:2}")
  local attempt=1
  local exit_code=1
  local cmd_str="${cmd_to_run[*]}"

  while [[ $attempt -le $max_attempts ]]; do
    echo "[ATTEMPT $attempt/$max_attempts] Running: $cmd_str" >&2

    # 명령 실행
    "${cmd_to_run[@]}" 2>&1 || exit_code=$?
    exit_code=${exit_code:-0}

    # 판정
    judge_by_exitcode "$exit_code" "$cmd_str (attempt $attempt)"

    if [[ $exit_code -eq 0 ]]; then
      echo "[RETRY] Final verdict: SUCCESS after $attempt attempt(s)" >&2
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -le $max_attempts ]]; then
      echo "[RETRY] Waiting 2s before retry..." >&2
      sleep 2
    fi
  done

  echo "[RETRY] Final verdict: FAILURE after $max_attempts attempts" >&2
  return 1
}

# 로그 에러 필터 (참고용): stderr에 특정 패턴이 있어도 판정은 exit code 의존
# 이 함수는 디버깅/로그 분석용. 판정 규칙을 변경하지 않음.
# 입력: $1=stderr_content, $2=pattern_name (선택)
# 출력: 매칭된 로그라인 또는 "no match"
filter_error_logs_for_reference() {
  local stderr_content="$1"
  local pattern_name="${2:-unknown}"
  local patterns=(
    "Connection timeout"
    "API error"
    "Authentication failed"
    "Rate limit"
    "Network unreachable"
  )

  # 패턴 매칭 (참고용, 판정에는 영향 없음)
  for pattern in "${patterns[@]}"; do
    if echo "$stderr_content" | grep -q "$pattern"; then
      echo "FOUND_FOR_REFERENCE: $pattern"
      return 0
    fi
  done

  echo "no_matching_error_pattern"
  return 0
}

export -f judge_by_exitcode
export -f run_and_judge
export -f run_with_retry_and_judge
export -f filter_error_logs_for_reference
