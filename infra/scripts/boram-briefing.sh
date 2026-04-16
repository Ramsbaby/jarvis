#!/usr/bin/env bash
# boram-briefing.sh — 보람님 채널 아침 브리핑 (오늘 Preply 수업 일정 + 수입)
# Usage: boram-briefing.sh [YYYY-MM-DD]
# 매일 07:30 launchd(ai.jarvis.boram-briefing)에서 자동 실행

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
TARGET_DATE="${1:-$(TZ=Asia/Seoul date +%Y-%m-%d)}"
WEBHOOK=$(jq -r '.webhooks["jarvis-boram"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null)
[[ -z "$WEBHOOK" ]] && { echo "ERROR: jarvis-boram webhook not found in monitoring.json" >&2; exit 1; }
LOGFILE="$BOT_HOME/logs/cron.log"

log() { echo "[$(TZ=Asia/Seoul date '+%F %T')] boram-briefing: $*" >> "$LOGFILE"; }

source "${BOT_HOME}/lib/discord-notify-bash.sh"

# Preply API 조회 (금액 포함 실시간 데이터)
RAW=$(bash "$BOT_HOME/scripts/preply-today.sh" "$TARGET_DATE" 2>/dev/null \
  || echo '{"error":"preply-today failed"}')

# 빈 응답 가드: preply-today.sh가 exit 0이지만 빈 출력 반환 시
if [[ -z "$RAW" ]]; then
  RAW='{"error":"preply-today returned empty response"}'
fi

# 에러 체크
ERR=$(echo "$RAW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "parse_error")
if [[ -n "$ERR" ]]; then
  send_discord "📅 오늘 수업 일정 조회 실패 😅 ($ERR)"
  log "FAIL — $ERR"
  exit 1
fi

# 메시지 빌드
# 환율 조회 (캐시 우선 — get-exchange-rate.sh가 1h TTL 캐시 관리)
USD_KRW=$(bash "$BOT_HOME/scripts/get-exchange-rate.sh" 2>/dev/null || echo "")

MSG=$(echo "$RAW" | python3 "$BOT_HOME/scripts/_boram_briefing_fmt.py" "$TARGET_DATE" "${USD_KRW:-}" 2>/dev/null \
  || echo "📅 일정 파싱 실패 😅")

send_discord "$MSG"
log "SUCCESS — $TARGET_DATE"

# ── 브리핑 캐시 저장 (봇이 후속 대화에서 참조) ──────────────────────────────
# RAW/MSG를 임시 파일로 전달 — heredoc 내 변수 보간 시 따옴표·특수문자 파괴 방지
STATE_DIR="$BOT_HOME/state"
mkdir -p "$STATE_DIR"
_TMP_RAW=$(mktemp)
_TMP_MSG=$(mktemp)
printf '%s' "$RAW" > "$_TMP_RAW"
printf '%s' "$MSG" > "$_TMP_MSG"
python3 - "$_TMP_RAW" "$_TMP_MSG" "$TARGET_DATE" "$STATE_DIR" << 'PYEOF'
import json, sys, os, datetime, pathlib

raw_path, msg_path, target_date, state_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    data = json.loads(pathlib.Path(raw_path).read_text())
    msg  = pathlib.Path(msg_path).read_text()
    lessons   = data.get('scheduledLessons', [])
    totals    = data.get('totalsByCurrency', {})
    total_usd = totals.get('USD', sum(l.get('amount', 0) for l in lessons if l.get('currency') == 'USD'))
    cache = {
        'date':        target_date,
        'sentAt':      datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).isoformat(),
        'message':     msg.strip(),
        'lessonCount': len(lessons),
        'totalUsd':    round(total_usd, 2),
        'lessons': [
            {'time': l.get('startAt',''), 'student': l.get('student',''), 'amount': l.get('amount',0)}
            for l in lessons
        ],
    }
    cache_path = os.path.join(state_dir, 'boram-last-briefing.json')
    with open(cache_path, 'w') as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)
except Exception as e:
    print(f'[boram-briefing] cache save failed: {e}', file=sys.stderr)
PYEOF
rm -f "$_TMP_RAW" "$_TMP_MSG"
