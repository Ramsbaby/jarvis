#!/usr/bin/env bash
# RAG Quality Check - 인덱서 상태 자동 감시
# 매시간 실행. 이상 감지 시 jarvis-system Discord 웹훅 알림.
# 쿨다운: 동일 이슈 4시간 내 재알림 금지.

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
RAG_LOG="$BOT_HOME/logs/rag-index.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
COOLDOWN_FILE="$BOT_HOME/state/rag-quality-last-alert.txt"
COOLDOWN_SECONDS=14400  # 4시간
STALE_THRESHOLD=5400    # 90분 (초)

# ============================================================================
# Discord 웹훅 URL 로드
# ============================================================================
if [[ ! -f "$MONITORING_CONFIG" ]]; then
    echo "ERROR: monitoring.json not found at $MONITORING_CONFIG" >&2
    exit 1
fi

WEBHOOK_URL=$(CFG_PATH="$MONITORING_CONFIG" python3 -c "import json,os; print(json.load(open(os.environ['CFG_PATH']))['webhooks']['jarvis-system'])")

# ============================================================================
# 함수
# ============================================================================

send_discord() {
    local message="$1"
    local payload
    payload=$(python3 -c "import json,sys; print(json.dumps({'content': sys.stdin.read()}))" <<< "$message" 2>/dev/null)
    if [[ -z "$payload" ]]; then
        payload='{"content":"RAG alert (message encoding error)"}'
    fi
    curl -s -m 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        > /dev/null 2>&1 || echo "WARN: Discord webhook send failed" >&2
}

is_in_cooldown() {
    if [[ ! -f "$COOLDOWN_FILE" ]]; then
        return 1
    fi
    local last_time
    last_time=$(head -1 "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    if [[ ! "$last_time" =~ ^[0-9]+$ ]]; then
        last_time=0
    fi
    local now
    now=$(date +%s)
    local elapsed=$((now - last_time))
    if [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
        return 0
    fi
    return 1
}

set_cooldown() {
    mkdir -p "$(dirname "$COOLDOWN_FILE")"
    date +%s > "$COOLDOWN_FILE"
}

append_incident() {
    local summary="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local incident_file="$BOT_HOME/rag/incidents.md"
    echo "" >> "$incident_file"
    echo "- [$ts] **[rag-quality]** $summary" >> "$incident_file"
}

alert_and_exit() {
    local message="$1"
    echo "$message"
    # incidents.md 자동 기록 (쿨다운 무관 — 항상 기록)
    local first_line
    first_line=$(echo "$message" | head -1)
    append_incident "$first_line"
    if is_in_cooldown; then
        echo "Cooldown active, skipping Discord alert."
        return 0
    fi
    send_discord "$message"
    # Publish to orchestrator event bus (discord_sent=true → orchestrator skips re-send)
    /bin/bash "$BOT_HOME/scripts/mq-cli.sh" send rag-quality-check system \
        "{\"status\":\"degraded\",\"discord_sent\":true,\"reason\":$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$message")}" \
        urgent 2>/dev/null || true
    set_cooldown
}

# ============================================================================
# 감지 로직
# ============================================================================

# 1) 로그 파일 존재 여부
if [[ ! -f "$RAG_LOG" ]]; then
    alert_and_exit "$(cat <<'MSG'
🔴 RAG 인덱서 이상 감지
상태: rag-index.log 파일 없음
조치: rag-index.mjs 크론 등록 및 최초 실행 확인 필요
MSG
)"
    exit 0
fi

# 2) 마지막 줄에서 에러 감지
last_line=$(tail -1 "$RAG_LOG")
if echo "$last_line" | grep -q "RAG indexer failed"; then
    error_detail=$(echo "$last_line" | head -c 200)
    alert_and_exit "$(cat <<MSG
🔴 RAG 인덱서 에러 감지
마지막 로그: $error_detail
조치: OPENAI_API_KEY 등 환경 변수 및 rag-index.mjs 설정 확인 필요
MSG
)"
    exit 0
fi

# 3) 마지막 성공 인덱싱 시각 추출 및 stale 체크
# 로그 형식: [2026-03-03T14:00:05.303Z] RAG index: ...
last_success_line=$(grep -E '^\[.*\] RAG index:' "$RAG_LOG" | tail -1 || true)

if [[ -z "$last_success_line" ]]; then
    alert_and_exit "$(cat <<'MSG'
🔴 RAG 인덱서 이상 감지
상태: 성공적인 인덱싱 로그를 찾을 수 없음
조치: rag-index.mjs 정상 동작 확인 필요
MSG
)"
    exit 0
fi

# ISO 타임스탬프 추출: [2026-03-03T14:00:05.303Z]
last_timestamp=$(echo "$last_success_line" | grep -oE '\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})' | tr -d '[')

if [[ -z "$last_timestamp" ]]; then
    echo "WARN: Could not parse timestamp from last success line"
    exit 0
fi

# macOS date: ISO → epoch (UTC 기준으로 파싱 — rag-index.mjs 로그는 Z 타임스탬프)
last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$last_timestamp" +%s 2>/dev/null || echo "0")
now_epoch=$(date +%s)

if [[ "$last_epoch" -eq 0 ]]; then
    echo "WARN: Failed to convert timestamp to epoch: $last_timestamp"
    exit 0
fi

elapsed=$((now_epoch - last_epoch))
elapsed_min=$((elapsed / 60))

if [[ $elapsed -gt $STALE_THRESHOLD ]]; then
    hours=$((elapsed_min / 60))
    mins=$((elapsed_min % 60))
    alert_and_exit "$(cat <<MSG
🔴 RAG 인덱서 이상 감지
마지막 실행: ${hours}시간 ${mins}분 전
기준: 90분 초과
조치: crontab에서 rag-index.mjs 등록 확인 필요
MSG
)"
    exit 0
fi

# 4) LanceDB 실제 쿼리 검증 — 행 수 0이면 FAIL
DB_PATH="$BOT_HOME/rag/lancedb"
if [[ -d "$DB_PATH" ]]; then
    row_count=$(cd "$BOT_HOME/lib" && LANCEDB_DIR="$DB_PATH" /opt/homebrew/bin/node -e "
      const lancedb = require('@lancedb/lancedb');
      (async () => {
        try {
          const db = await lancedb.connect(process.env.LANCEDB_DIR);
          const t = await db.openTable('documents');
          const rows = await t.query().limit(1).toArray();
          console.log(rows.length > 0 ? 'OK' : '0');
        } catch(e) { console.log('ERROR:' + e.message.slice(0,200)); }
      })();
    " 2>/dev/null || echo "ERROR:node-exec-failed")

    if [[ "$row_count" == "0" ]]; then
        alert_and_exit "$(cat <<'MSG'
🔴 RAG 데이터 이상 감지
상태: LanceDB 테이블에 데이터 0행 (인덱싱은 작동하나 실제 데이터 없음)
조치: rag-index.mjs 로그 확인 및 OpenAI Embedding API 상태 점검
MSG
)"
        exit 0
    fi

    if [[ "$row_count" == ERROR:* ]]; then
        alert_and_exit "$(cat <<MSG
🔴 RAG LanceDB 쿼리 실패
에러: ${row_count#ERROR:}
조치: LanceDB 파일 손상 여부 확인 (rm -rf $DB_PATH 후 rag-index 재실행)
MSG
)"
        exit 0
    fi
fi

# 5) LanceDB 크기 경고 (1GB 이상 → compact 권장)
if [[ -d "$DB_PATH" ]]; then
    db_mb=$(du -sm "$DB_PATH" 2>/dev/null | awk '{print $1}')
    if (( db_mb > 1000 )); then
        alert_and_exit "$(cat <<MSG
⚠️ LanceDB 크기 경고
현재: ${db_mb}MB (기준: 1GB)
조치: rag-compact 실행 권장 (cd ${JARVIS_HOME:-$HOME/.jarvis}/discord && BOT_HOME=${JARVIS_HOME:-$HOME/.jarvis} node --input-type=module -e "import {RAGEngine} from '${JARVIS_HOME:-$HOME/.jarvis}/lib/rag-engine.mjs'; const r=new RAGEngine(); await r.init(); await r.compact(); process.exit(0)")
MSG
)"
        exit 0
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAG quality check: OK (last index ${elapsed_min}min ago, DB query OK, size ${db_mb:-?}MB)"
