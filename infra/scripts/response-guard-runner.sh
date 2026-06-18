#!/bin/bash

# 응답 검증 태스크 러너 (오답승격 방지 가드)
# 용도: 최근 생성된 응답들을 순회하며 가드 파이프라인 실행
# 설정: cluster_id = cl-fd25ae4c34818568

set -euo pipefail

CLUSTER_ID="cl-fd25ae4c34818568"
RESULTS_DIR="${HOME}/.jarvis/results/response-guard-check"
RESPONSE_CACHE="${HOME}/.jarvis/state/recent-responses.jsonl"
PIPELINE="${HOME}/.jarvis/lib/response-guard-pipeline.mjs"

mkdir -p "$RESULTS_DIR"

# 최근 응답 캐시 확인
if [[ ! -f "$RESPONSE_CACHE" ]]; then
  echo "응답 캐시 없음: $RESPONSE_CACHE (초회 실행)"
  exit 0
fi

# 최근 30분 응답 필터링 및 검증
NOW=$(date +%s)
THIRTY_MIN_AGO=$((NOW - 1800))
validated=0
failed=0
rewrite_needed=0

# 최근 응답 파일 읽기 (JSONL 형식)
tail -100 "$RESPONSE_CACHE" | while IFS= read -r line; do
  # 각 줄 파싱
  timestamp=$(echo "$line" | jq -r '.ts // 0' 2>/dev/null || echo 0)

  # 30분 이내 필터
  if [[ $timestamp -lt $THIRTY_MIN_AGO ]]; then
    continue
  fi

  content=$(echo "$line" | jq -r '.content // ""' 2>/dev/null)
  recipient=$(echo "$line" | jq -r '.recipient // {}' 2>/dev/null)

  if [[ -z "$content" ]]; then
    continue
  fi

  # 가드 파이프라인 실행
  if guard_output=$(echo "$recipient" | jq -c '{content: '"\"$(echo "$content" | jq -Rs .)\""', recipient_age: .age, recipient_gender: .gender, recipient_health_status: .health_status}' 2>/dev/null | \
    node "$PIPELINE" 2>/dev/null); then

    # 결과 파싱
    requires_rewrite=$(echo "$guard_output" | jq -r '.requires_rewrite // false')
    severity=$(echo "$guard_output" | jq -r '.summary.severity // "pass"')

    if [[ "$requires_rewrite" == "true" ]]; then
      ((rewrite_needed++))

      # 재작성이 필요한 경우 경고 로그 기록
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | GUARD_ALERT | severity=$severity | $(echo "$guard_output" | jq -c '.rewrite_issues')" >> "$RESULTS_DIR/alerts.jsonl"
    fi

    ((validated++))
  else
    ((failed++))
  fi
done

# 결과 요약
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | 응답검증 완료 | cluster=$CLUSTER_ID | validated=$validated | rewrite_needed=$rewrite_needed | failed=$failed" >> "$RESULTS_DIR/runner.log"

# 요약 리포트
cat << EOF > "$RESULTS_DIR/summary-$(date +%Y-%m-%d-%H%M%S).json"
{
  "cluster_id": "$CLUSTER_ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "validated_count": $validated,
  "rewrite_needed_count": $rewrite_needed,
  "failed_count": $failed,
  "severity": "$([ $rewrite_needed -gt 0 ] && echo "alert" || echo "ok")"
}
EOF

echo "✅ 응답검증 완료: $validated 건 검증, $rewrite_needed 건 재작성 필요"
