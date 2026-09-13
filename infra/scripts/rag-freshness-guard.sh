#!/usr/bin/env bash
# rag-freshness-guard.sh — RAG 인덱스 신선도 감시 + 자가 치유
# 매일 08:30 KST
#
# DRYRUN 의무 (자비스 자동화 표준):
#   RAG_FRESHNESS_GUARD_DRYRUN=1 default → 알림·인덱싱 트리거 X, ledger만
#   RAG_FRESHNESS_GUARD_DRYRUN=0 → production
#   첫 1주 시뮬 후 dryrun-auto-activate가 결과 OK 시 0으로 전환.
#
# Why: "그날 저장한 사실이 그날 검색되지 않는" 상태를 5일간 아무도 모른 사고를 막는다.
#      (2026-08-07 심링크 정합화로 stop-rag-sync.sh 의 find 가 항상 0건 반환 → 08-11까지 증분 동기화 정지)
#
# Existing 검토: rag-health 는 인덱스 크기·조각수만, rag-stale-scan 은 30일 미참조 청크만 본다.
#      "인덱스가 소스보다 얼마나 뒤처졌는가"를 보는 감시는 이것이 유일하다. (DRY 위반 아님 — 2026-08-11 확인)
#
# 설계 원칙 — 이 스크립트는 LLM 을 호출하지 않는다:
#      감시 크론 대부분이 ask-claude.sh 를 경유하는데 그 경로가 깨지면 감시자와 대상이 동시에 죽는다.
#      (2026-08-11 확인: system-health·rag-health 등 감시 크론 6개가 서킷브레이커에 갇혀 있었음)
#      순수 셸로 두어 LLM 경로 장애와 독립적으로 살아남게 한다.

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/projects/jarvis}"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
BOT_HOME="${BOT_HOME:-$JARVIS_RUNTIME}"      # 심링크(~/.jarvis) 아닌 실경로 기본값
LOG_FILE="$JARVIS_RUNTIME/logs/rag-freshness-guard.log"
LEDGER="$JARVIS_RUNTIME/state/rag-freshness-guard-ledger.jsonl"
STATE_FILE="$BOT_HOME/rag/index-state.json"
INDEXER="$BOT_HOME/bin/rag-index-safe.sh"
LOCK="/tmp/rag-freshness-guard.lock"

# discord-route 사용 (채널 분산 wrapper)
# shellcheck source=/dev/null
source "$JARVIS_HOME/infra/lib/discord-route.sh" 2>/dev/null || true

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LEDGER")"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [rag-freshness-guard] $*" | tee -a "$LOG_FILE"; }
_ledger() { echo "{\"ts\":\"$(date -u +%FT%TZ)\",$1}" >> "$LEDGER"; }

# DRYRUN 가드
DRYRUN="${RAG_FRESHNESS_GUARD_DRYRUN:-1}"

# 임계 (환경변수로 조정 가능)
WARN_H="${RAG_FRESHNESS_WARN_H:-12}"       # 이 시간 이상 뒤처지면 경고
CRIT_H="${RAG_FRESHNESS_CRIT_H:-36}"       # 이 시간 이상이면 심각 + 강제 인덱싱

# --- 중복 실행 방지 (mkdir 원자성) ---
# flock 은 macOS 기본 제공이 아니다(2026-08-11 확인: command not found).
# bot-cron.sh 가 쓰는 것과 같은 디렉터리 락 방식을 따른다.
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        _log "[WARN] 묵은 락 회수 (30분 초과)"
        rmdir "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null || { _log "락 획득 실패 — 건너뜀"; exit 0; }
    else
        _log "이미 실행 중 — 건너뜀"
        exit 0
    fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

_notify() {
    local severity="$1" title="$2" detail="$3"
    if [ "$DRYRUN" = "0" ]; then
        if command -v discord_route >/dev/null 2>&1; then
            discord_route "$severity" "$title" "$detail" || _log "[WARN] discord_route 전송 실패"
        else
            _log "[WARN] discord_route 사용 불가 — 알림 생략"
        fi
    else
        _log "DRYRUN — 알림 생략 ($severity: $title)"
    fi
}

# === 1. 데이터 수집 ===
if [ ! -f "$STATE_FILE" ]; then
    _log "[CRITICAL] index-state.json 없음 — RAG 인덱스가 초기화되지 않았다"
    _ledger "\"status\":\"critical\",\"reason\":\"no_state_file\""
    _notify critical "RAG 인덱스 없음" "state=missing,path=$STATE_FILE"
    exit 1
fi

NOW=$(date +%s)
STATE_M=$(stat -f %m "$STATE_FILE" 2>/dev/null || echo "$NOW")
INDEX_AGE_H=$(( (NOW - STATE_M) / 3600 ))

# 인덱싱 대상 중 state 파일보다 최신인 것
# -L 필수: BOT_HOME 이 심링크로 지정돼 들어올 수 있다. 이 한 글자가 빠져 5일간 사고가 났다.
NEWEST_SRC=$(find -L "$BOT_HOME" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/rag/lancedb/*" \
    -not -path "*/logs/*" \
    \( -name "*.md" -o -name "*.mjs" -o -name "*.js" -o -name "*.sh" \) \
    -newer "$STATE_FILE" -print 2>/dev/null | head -1)

# === 2. 분석 ===
if [ -z "$NEWEST_SRC" ]; then
    _log "정상 — 인덱스 이후 변경된 소스 없음 (인덱스 경과 ${INDEX_AGE_H}h)"
    _ledger "\"status\":\"ok\",\"lag_h\":0,\"index_age_h\":$INDEX_AGE_H"
    exit 0
fi

SRC_M=$(stat -f %m "$NEWEST_SRC" 2>/dev/null || echo "$NOW")
LAG_H=$(( (NOW - SRC_M) / 3600 ))
SRC_NAME=$(basename "$NEWEST_SRC")

_log "미반영 변경 감지: $SRC_NAME (변경 후 ${LAG_H}h, 인덱스 경과 ${INDEX_AGE_H}h)"

# === 3. 액션 (DRYRUN 가드) ===
if [ "$LAG_H" -ge "$CRIT_H" ]; then
    _log "[CRITICAL] ${LAG_H}h 미반영 (임계 ${CRIT_H}h)"
    _ledger "\"status\":\"critical\",\"lag_h\":$LAG_H,\"index_age_h\":$INDEX_AGE_H,\"newest\":\"$SRC_NAME\",\"dryrun\":$DRYRUN"
    _notify critical "RAG 인덱스 지연" "lag=${LAG_H}h,임계=${CRIT_H}h,미반영=$SRC_NAME,조치=자동인덱싱"
    if [ "$DRYRUN" = "0" ]; then
        if [ -f "$INDEXER" ]; then
            nohup timeout 2700 bash "$INDEXER" >> "$LOG_FILE" 2>&1 &
            _log "인덱싱 백그라운드 시작 (PID $!)"
        else
            _log "[ERROR] 인덱서 없음: $INDEXER"
            _notify critical "RAG 인덱서 실종" "path=$INDEXER,자동복구=실패"
            exit 1
        fi
    else
        _log "DRYRUN — 인덱싱 트리거 생략"
    fi
elif [ "$LAG_H" -ge "$WARN_H" ]; then
    _log "[WARN] ${LAG_H}h 미반영 (임계 ${WARN_H}h) — 다음 세션 종료 시 동기화 예정"
    _ledger "\"status\":\"warn\",\"lag_h\":$LAG_H,\"index_age_h\":$INDEX_AGE_H,\"newest\":\"$SRC_NAME\",\"dryrun\":$DRYRUN"
    _notify info "RAG 인덱스 지연 경고" "lag=${LAG_H}h,임계=${WARN_H}h,미반영=$SRC_NAME"
else
    _log "정상 범위 — ${LAG_H}h 미반영 (경고 임계 ${WARN_H}h 미만)"
    _ledger "\"status\":\"ok\",\"lag_h\":$LAG_H,\"index_age_h\":$INDEX_AGE_H"
fi

exit 0
