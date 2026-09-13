#!/usr/bin/env bash
# cluster-guard-cl-02f731ffc275d999.sh — 데이터 신선도 가드 (표준 명명 shim)
#
# 클러스터: cl-02f731ffc275d999 — 데이터 이상 신호 거짓 경보 (검증 미선행)
#
# 이 파일은 표준 cluster-guard 명명 규칙(cluster-guard-<id>.sh)을 위한
# thin wrapper이다. 실제 구현은 이미 존재하는 data-freshness-guard.sh에
# 있고, 이 파일은 그것을 source하여 동일한 API를 노출한다.
#
# 이유: 다른 클러스터 가드들과의 조회·자동화(예: cluster-guard-runner)가
#       cluster-guard-<id>.sh 패턴을 그렙하므로, 그 규약을 만족시키되
#       기존 data-freshness-guard.sh 파일과 그 API를 그대로 유지한다.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-02f731ffc275d999.sh
#   check_file_freshness /path/to/data.json 30 label || true
#   annotate_context_with_timestamps
#   data_freshness_summary || true

# source 되어 호출되므로 set -e 남기지 않음
_CL_02F7_IMPL="${HOME}/projects/jarvis/infra/lib/data-freshness-guard.sh"
if [[ -f "$_CL_02F7_IMPL" ]]; then
    # shellcheck disable=SC1090
    source "$_CL_02F7_IMPL"
else
    printf '[cluster-guard-cl-02f731ffc275d999] 구현체 없음: %s\n' "$_CL_02F7_IMPL" >&2
    # 캘러가 || true로 감쌀 것으로 가정하고 조용히 return 대신 no-op stub 정의
    check_file_freshness() { return 0; }
    annotate_context_with_timestamps() { return 0; }
    data_freshness_summary() { return 0; }
    guard_cl_02f731_status() { printf 'cl-02f731ffc275d999 guard: implementation missing\n'; }
fi
