#!/usr/bin/env bash
# validate-channel-map.sh — 채널 ID·웹훅 환경변수 맵핑 검증 가드
#
# 클러스터 ID: cl-975bafeb5bb2be2b (채널 ID 오인 → 환경변수 맵핑 오류)
# 목적: channel-map.json의 severity→channel 라우팅과
#       monitoring.json의 webhooks 키가 일치하는지 검증
#
# 반환값:
#   exit 0 — 설정 일치 (정상)
#   exit 1 — 불일치 또는 필수 키 누락 (전송 차단)
#
# 사용법:
#   ~/jarvis/infra/guards/validate-channel-map.sh
#   ~/jarvis/infra/guards/validate-channel-map.sh --quiet   # 오류만 출력
#   ~/jarvis/infra/guards/validate-channel-map.sh --channel jarvis-info  # 특정 채널만 검증

set -euo pipefail

# ── 경로 상수 ────────────────────────────────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL_MAP="${INFRA_DIR}/config/channel-map.json"
MONITORING_RT="${HOME}/jarvis/runtime/config/monitoring.json"
MONITORING_INFRA="${INFRA_DIR}/config/monitoring.json"
CLUSTER_ID="cl-975bafeb5bb2be2b"
LOG_DIR="${HOME}/jarvis/runtime/logs"
LOG_FILE="${LOG_DIR}/validate-channel-map.log"

# ── 출력 모드 ────────────────────────────────────────────────────────────────
QUIET=0
TARGET_CHANNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet|-q)   QUIET=1 ; shift ;;
        --channel)    TARGET_CHANNEL="$2" ; shift 2 ;;
        *)            shift ;;
    esac
done

# ── 헬퍼 ────────────────────────────────────────────────────────────────────
_log() {
    local level="$1" msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] [%s] [%s] %s\n' "$ts" "$CLUSTER_ID" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    if [[ "$level" == "ERROR" ]] || [[ "$QUIET" -eq 0 ]]; then
        printf '[validate-channel-map] [%s] %s\n' "$level" "$msg" >&2
    fi
}

_fail() {
    _log "ERROR" "$1"
    exit 1
}

# ── jq 의존성 확인 ───────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    _fail "jq가 설치되어 있지 않습니다. 검증 불가."
fi

# ── 설정 파일 존재 확인 ──────────────────────────────────────────────────────
if [[ ! -f "$CHANNEL_MAP" ]]; then
    _fail "channel-map.json 없음: $CHANNEL_MAP"
fi

# monitoring.json: runtime 우선, 없으면 infra/config
MONITORING=""
if [[ -f "$MONITORING_RT" ]]; then
    MONITORING="$MONITORING_RT"
elif [[ -f "$MONITORING_INFRA" ]]; then
    MONITORING="$MONITORING_INFRA"
else
    _fail "monitoring.json 없음: $MONITORING_RT 또는 $MONITORING_INFRA"
fi

[[ "$QUIET" -eq 0 ]] && _log "INFO" "channel-map: $CHANNEL_MAP"
[[ "$QUIET" -eq 0 ]] && _log "INFO" "monitoring:  $MONITORING"

# ── [1] severity→channel 라우팅 검증 ────────────────────────────────────────
# channel-map.json의 severity_to_channel이 discord-route.sh 하드코딩과 일치해야 함
# (연관 배열 대신 함수로 구현 — bash 3.x 호환)
_expected_channel_for() {
    case "$1" in
        critical) echo "jarvis-system" ;;
        info)     echo "jarvis-info"   ;;
        retro)    echo "jarvis-retro"  ;;
    esac
}

ERRORS=0

for severity in critical info retro; do
    mapped_channel=$(jq -r ".severity_to_channel.${severity} // empty" "$CHANNEL_MAP" 2>/dev/null || true)
    expected=$(_expected_channel_for "$severity")

    if [[ -z "$mapped_channel" ]]; then
        _log "ERROR" "severity '${severity}' → channel 매핑 누락 (channel-map.json)"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if [[ "$mapped_channel" != "$expected" ]]; then
        _log "ERROR" "severity '${severity}' 불일치: channel-map='${mapped_channel}' vs discord-route='${expected}'"
        ERRORS=$((ERRORS + 1))
    else
        [[ "$QUIET" -eq 0 ]] && _log "OK" "severity '${severity}' → '${mapped_channel}' 일치"
    fi
done

# ── [2] 필수 채널 → monitoring.json webhooks 키 존재 검증 ──────────────────
# severity 라우팅 대상 채널(jarvis-system, jarvis-info, jarvis-retro)이
# monitoring.json의 webhooks 오브젝트에 반드시 존재해야 함
REQUIRED_CHANNELS=("jarvis-system" "jarvis-info" "jarvis-retro")

for ch in "${REQUIRED_CHANNELS[@]}"; do
    # 특정 채널만 검증 모드
    if [[ -n "$TARGET_CHANNEL" && "$TARGET_CHANNEL" != "$ch" ]]; then
        continue
    fi

    # channel-map.json에서 webhook_key 조회
    webhook_key=$(jq -r ".channels[\"${ch}\"].webhook_key // empty" "$CHANNEL_MAP" 2>/dev/null || true)

    if [[ -z "$webhook_key" || "$webhook_key" == "null" ]]; then
        _log "ERROR" "채널 '${ch}'의 webhook_key가 channel-map.json에 없음"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # monitoring.json에서 해당 webhook_key 존재 및 비어있지 않은지 확인
    webhook_url=$(jq -r ".webhooks[\"${webhook_key}\"] // empty" "$MONITORING" 2>/dev/null || true)

    if [[ -z "$webhook_url" || "$webhook_url" == "null" ]]; then
        _log "ERROR" "monitoring.json에 webhook 키 '${webhook_key}' 없음 (채널: ${ch})"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if [[ "$webhook_url" == "" ]]; then
        _log "ERROR" "monitoring.json의 webhooks.${webhook_key} 값이 비어 있음 (채널: ${ch})"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    [[ "$QUIET" -eq 0 ]] && _log "OK" "채널 '${ch}' → webhooks.${webhook_key} 존재 확인"
done

# ── [3] 사용자 채널 오발송 방지 규칙 검증 ────────────────────────────────────
# guard_rules.block_user_channels_for_system 이 true인지 확인
block_rule=$(jq -r '.guard_rules.block_user_channels_for_system // false' "$CHANNEL_MAP" 2>/dev/null || echo "false")
if [[ "$block_rule" != "true" ]]; then
    _log "ERROR" "guard_rules.block_user_channels_for_system 이 true가 아님 — 사용자 채널 보호 규칙 없음"
    ERRORS=$((ERRORS + 1))
else
    [[ "$QUIET" -eq 0 ]] && _log "OK" "사용자 채널 보호 규칙 활성화 확인"
fi

# ── 최종 결과 ────────────────────────────────────────────────────────────────
if [[ "$ERRORS" -gt 0 ]]; then
    _log "ERROR" "검증 실패: ${ERRORS}건의 오설정 감지 — 전송 차단"
    exit 1
fi

_log "OK" "채널 맵 검증 통과 — 모든 severity→channel→webhook 일치"
exit 0
