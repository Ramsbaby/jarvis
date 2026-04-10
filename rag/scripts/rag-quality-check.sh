#!/usr/bin/env bash
# RAG Quality Check - 인덱서 상태 자동 감시
# 매시간 실행. 이상 감지 시 jarvis-system Discord 웹훅 알림.
# 쿨다운: 동일 이슈 4시간 내 재알림 금지.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
RAG_HOME="${JARVIS_RAG_HOME:-${INFRA_HOME}/rag}"
NODE="${NODE:-$(command -v node || command -v /opt/homebrew/bin/node)}"
RAG_LOG="$INFRA_HOME/logs/rag-index.log"
MONITORING_CONFIG="$INFRA_HOME/config/monitoring.json"
COOLDOWN_FILE="$INFRA_HOME/state/rag-quality-last-alert.txt"
COOLDOWN_SECONDS=14400  # 4시간
STALE_THRESHOLD=5400    # 90분 (초)
REBUILD_SENTINEL="$INFRA_HOME/state/rag-rebuilding.json"

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

# 이슈 타입별 쿨다운 — 1개 이슈가 다른 이슈 알림을 차단하지 않음
is_in_cooldown() {
    local issue_type="${1:-default}"
    local cooldown_path="${COOLDOWN_FILE%.txt}-${issue_type}.txt"
    if [[ ! -f "$cooldown_path" ]]; then
        return 1
    fi
    local last_time
    last_time=$(head -1 "$cooldown_path" 2>/dev/null || echo "0")
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
    local issue_type="${1:-default}"
    local cooldown_path="${COOLDOWN_FILE%.txt}-${issue_type}.txt"
    mkdir -p "$(dirname "$cooldown_path")"
    date +%s > "$cooldown_path"
}

append_incident() {
    local summary="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local incident_file="$RAG_HOME/incidents.md"
    echo "" >> "$incident_file"
    echo "- [$ts] **[rag-quality]** $summary" >> "$incident_file"
}

alert_and_exit() {
    local message="$1"
    local issue_type="${2:-default}"
    echo "$message"
    # incidents.md 자동 기록 (쿨다운 무관 — 항상 기록)
    local first_line
    first_line=$(echo "$message" | head -1)
    append_incident "$first_line"
    if is_in_cooldown "$issue_type"; then
        echo "Cooldown active ($issue_type), skipping Discord alert."
        return 0
    fi
    send_discord "$message"
    # [비활성화 2026-03-24] mq-cli.sh send 제거.
    # 이유: (1) message queue consumer가 없는 dead queue — 메시지가 쌓이기만 함.
    #       (2) 만약 consumer가 생기면 "degraded" 메시지 → cron-fix 에이전트 → claude -p Bash tool → rm -rf 실행 가능.
    #       (3) Discord alert 만으로 충분 — 사람이 보고 판단해야 할 문제.
    # /bin/bash "$BOT_HOME/scripts/mq-cli.sh" send rag-quality-check system \
    #     "{\"status\":\"degraded\",\"discord_sent\":true,...}" urgent >/dev/null 2>/dev/null || true
    set_cooldown "$issue_type"
}

# ============================================================================
# [핵심 보호] 리빌드 중 오탐 억제 — 함수 정의 이후에 배치 (alert_and_exit 사용)
# fresh rebuild는 3~4시간 소요. 이 기간 stale/schema/query 알람 →
# cron-fix 에이전트 기동 → DB 파기 사이클 방지 (2026-03-22 2차 사고 패턴)
# ============================================================================
if [[ -f "$REBUILD_SENTINEL" ]]; then
    # [버그수정 2026-03-24] Python dateutil 의존성 제거.
    # 이전 코드: dateutil 없으면 || echo "0" → sentinel_age = 현재timestamp (매우 큰 수) → 즉시 삭제됨.
    # 수정: JSON에서 started_at 추출 후 macOS date -j로 epoch 변환. 파싱 실패 시 sentinel 보존.
    _sentinel_ts=$(python3 -c "import json; print(json.load(open('$REBUILD_SENTINEL')).get('started_at',''))" 2>/dev/null || true)
    if [[ -z "$_sentinel_ts" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: sentinel JSON parse failed — keeping sentinel, skipping non-critical checks"
        exit 0
    fi
    # ISO 8601 서브초 및 Z 제거 → macOS date -j 파싱
    _sentinel_ts_clean=$(echo "$_sentinel_ts" | sed 's/\.[0-9]*Z$//' | sed 's/Z$//')
    sentinel_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$_sentinel_ts_clean" +%s 2>/dev/null || echo "0")
    if [[ "$sentinel_epoch" -eq 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: sentinel epoch parse failed ($sentinel_ts_clean) — keeping sentinel, skipping non-critical checks"
        exit 0
    fi
    sentinel_age=$(( $(date +%s) - sentinel_epoch ))
    if (( sentinel_age > 21600 )); then
        # 6시간 초과 → stale sentinel 자동 삭제
        rm -f "$REBUILD_SENTINEL"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rebuild sentinel expired (${sentinel_age}s) — removed"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAG rebuild in progress (${sentinel_age}s elapsed) — skipping non-critical checks"
        # 디스크 공간만 체크 (리빌드 중 디스크 full은 즉각 위험)
        disk_avail_mb=$(df -m "$INFRA_HOME" 2>/dev/null | tail -1 | awk '{print $4}')
        if (( ${disk_avail_mb:-99999} < 2000 )); then
            alert_and_exit "🔴 디스크 여유 공간 부족 (리빌드 중)
남은 공간: ${disk_avail_mb}MB (기준: 2GB 미만)
조치: du -sh ~/.jarvis/rag/lancedb/ 확인 후 불필요 파일 정리" disk-full
        fi
        exit 0
    fi
fi

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

# 2b~2d) 마지막 성공 이후 에러 분석
# 마지막 "RAG index:" 성공 라인 이후의 로그만 분석 — 이전 에러는 이미 해결된 것.
last_success_line=$(grep -n "RAG index:" "$RAG_LOG" | tail -1 | cut -d: -f1)
if [[ -n "$last_success_line" ]]; then
    total_lines=$(wc -l < "$RAG_LOG")
    tail_count=$(( total_lines - last_success_line ))
    recent_tail=$(tail -"${tail_count}" "$RAG_LOG" 2>/dev/null || true)
else
    # success line 없음 = 리빌드 중 또는 첫 실행.
    # tail -500은 수일 전 에러를 잡아 오탐을 유발 → tail -50으로 축소
    recent_tail=$(tail -50 "$RAG_LOG" 2>/dev/null || true)
fi

# 2b) 스키마 불일치 에러 감지 — 최근 500줄에서 패턴 검사
schema_errors=$(echo "$recent_tail" | grep -c "different schema" || true)
if (( schema_errors > 0 )); then
    alert_and_exit "$(cat <<MSG
🔴 RAG 스키마 불일치 감지
마지막 실행 이후 에러: ${schema_errors}건 (different schema)
원인: indexFile() records와 테이블 스키마 필드 불일치
조치: lib/rag-engine.mjs indexFile() records 필드 확인 필요
MSG
)"
    exit 0
fi

# 2c) 연속 에러 누적 감지 — 최근 500줄에서
consecutive_errors=$(echo "$recent_tail" | grep -c "Error indexing" || true)
if (( consecutive_errors >= 50 )); then
    alert_and_exit "$(cat <<MSG
🔴 RAG 인덱싱 연속 실패 감지
마지막 실행 이후 에러: ${consecutive_errors}건
조치: rag-index.log 에러 패턴 분석 필요
MSG
)"
    exit 0
fi

# 2d) 인덱싱 소스 파일 소실 감지 — 최근 2회 연속 "0 new + 0 unchanged"
# ※ "0 new/modified, N unchanged" = 변경 파일 없음 → 정상 (오탐 방지)
# ※ "0 new/modified, 0 unchanged" = 소스 파일 자체를 못 찾음 → 실제 이상
zero_results=$(grep -E 'RAG index: 0 new/modified, 0 unchanged' "$RAG_LOG" 2>/dev/null | tail -2 | wc -l | tr -d ' ') || zero_results=0
if (( zero_results >= 2 )); then
    last_nonzero=$(grep -E 'RAG index: [1-9]' "$RAG_LOG" 2>/dev/null | tail -1 || echo "없음")
    alert_and_exit "$(cat <<MSG
⚠️ RAG 소스 파일 소실 감지 (2회 연속 0건 처리)
마지막 정상: ${last_nonzero}
원인: 소스 디렉토리 접근 불가 또는 인덱싱 대상 파일 없음
조치: vault 마운트 상태 및 BOT_HOME 경로 확인
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
last_timestamp=$(echo "$last_success_line" | grep -oE '\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})' 2>/dev/null | tr -d '[' || true)

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
DB_PATH="$RAG_HOME/lancedb"
if [[ -d "$DB_PATH" ]]; then
    row_count=$(cd "$RAG_ROOT" && LANCEDB_DIR="$DB_PATH" "${NODE}" -e "
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

# 4b) 디스크 여유 공간 감시
disk_avail_mb=$(df -m "$INFRA_HOME" 2>/dev/null | tail -1 | awk '{print $4}')
if (( ${disk_avail_mb:-99999} < 2000 )); then
    alert_and_exit "$(cat <<MSG
🔴 디스크 여유 공간 부족
남은 공간: ${disk_avail_mb}MB (기준: 2GB 미만)
조치: du -sh ~/.jarvis/rag/lancedb/ 확인 후 rag-compact 또는 불필요 파일 정리
MSG
)"
    exit 0
fi

# 5) LanceDB 크기 및 deleted 비율 경고
if [[ -d "$DB_PATH" ]]; then
    db_mb=$(du -sm "$DB_PATH" 2>/dev/null | awk '{print $1}')

    # 5a) deleted 비율 감시 — soft-delete 누적 조기 감지
    deleted_ratio_pct=$(RAG_HOME="$RAG_HOME" NODE_PATH="$RAG_ROOT/node_modules" "${NODE}" --input-type=module <<'JSEOF' 2>/dev/null
import * as ldb from '@lancedb/lancedb';
try {
  const db = await ldb.connect(process.env.RAG_HOME+'/lancedb');
  const t = await db.openTable('documents').catch(() => null);
  if (!t) { console.log('0'); process.exit(0); }
  const total = await t.countRows();
  if (total === 0) { console.log('0'); process.exit(0); }
  const deleted = await t.countRows('deleted = true').catch(() => 0);
  console.log(Math.round(deleted * 100 / (total + deleted)));
} catch { console.log('0'); }
JSEOF
)
    if (( ${deleted_ratio_pct:-0} >= 40 )); then
        alert_and_exit "⚠️ LanceDB soft-delete 누적 경고
deleted 비율: ${deleted_ratio_pct}% (기준: 40%)
원인: soft-delete된 행이 compact 없이 쌓이는 중
조치: bash ~/.jarvis/scripts/rag-compact-safe.sh"
        exit 0
    fi

    # 5b) 물리 크기 경고 (3.5GB 이상) — 정상 운영 범위: 1.9~2.7GB (compact 후~다음 compact 직전)
    if (( ${db_mb:-0} > 3500 )); then
        alert_and_exit "⚠️ LanceDB 크기 경고
현재: ${db_mb}MB / deleted: ${deleted_ratio_pct}% (기준: 3.5GB)
조치: bash ~/.jarvis/scripts/rag-compact-safe.sh"
        exit 0
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAG quality check: OK (last index ${elapsed_min}min ago, DB query OK, size ${db_mb:-?}MB, deleted ${deleted_ratio_pct:-0}%)"

# 시각화 상태 카드 전송 — 6시간 쿨다운 (매시간 OK는 Discord 노이즈 방지)
VISUAL_SCRIPT="$INFRA_HOME/scripts/discord-visual.mjs"
VISUAL_COOLDOWN_FILE="$INFRA_HOME/state/rag-quality-visual-last.txt"
VISUAL_COOLDOWN_SEC=21600  # 6시간
_send_visual=0
if [[ -f "$VISUAL_COOLDOWN_FILE" ]]; then
    _last=$(cat "$VISUAL_COOLDOWN_FILE" 2>/dev/null || echo "0")
    if (( $(date +%s) - _last > VISUAL_COOLDOWN_SEC )); then _send_visual=1; fi
else
    _send_visual=1
fi

if [[ "$_send_visual" -eq 1 ]] && command -v node >/dev/null 2>&1 && [[ -f "$VISUAL_SCRIPT" ]]; then
    # 청크 수 조회 (node 재사용)
    _chunks=$(RAG_HOME="$RAG_HOME" NODE_PATH="$RAG_ROOT/node_modules" "${NODE}" --input-type=module <<'JSEOF' 2>/dev/null
import * as ldb from '@lancedb/lancedb';
try {
  const db = await ldb.connect(process.env.RAG_HOME+'/lancedb');
  const t = await db.openTable('documents').catch(() => null);
  if (!t) { console.log('0'); process.exit(0); }
  console.log(await t.countRows());
} catch { console.log('0'); }
JSEOF
)
    RAG_JSON="{\"chunks\":${_chunks:-0},\"elapsed_min\":${elapsed_min},\"db_mb\":${db_mb:-0},\"deleted_pct\":${deleted_ratio_pct:-0},\"status\":\"OK\",\"timestamp\":\"$(date '+%Y-%m-%d %H:%M')\"}"
    node "$VISUAL_SCRIPT" --type rag-health --data "$RAG_JSON" --channel jarvis-system \
        >> "$INFRA_HOME/logs/system-doctor.log" 2>&1 || true
    date +%s > "$VISUAL_COOLDOWN_FILE"
fi
