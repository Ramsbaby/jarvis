#!/usr/bin/env bash
# docs-freshness-audit.sh — 자동 생성 사전 문서 vs 원본 mtime 비교, stale 시 자동 재생성 + 알림
#
# 출처: 주인님 지시 (2026-05-08) "사전 문서 stale 발견 시 알림 + 재생성"
# 매주 월요일 09:10 KST 실행 (ai.jarvis.docs-freshness-audit LaunchAgent)
#
# 비교 매트릭스 (원본 → 생성 문서):
#   runtime/config/tasks.json        → infra/docs/cron-matrix.json + tasks-index.json
#   ~/Library/LaunchAgents/*.plist   → infra/docs/launchagent-catalog.json
#   infra/config/models.json         → infra/docs/discord-channels.json

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/.openclaw-data/jarvis}"
LA_DIR="$HOME/Library/LaunchAgents"
SCRIPTS_DIR="$JARVIS_HOME/infra/scripts"
DOCS_DIR="$JARVIS_HOME/infra/docs"
LOG_FILE="$JARVIS_HOME/runtime/logs/docs-freshness-audit.log"
# 서술형(손으로 쓴) 문서가 코드보다 며칠 이상 뒤처지면 보고할지. 기본 30일.
DOC_DRIFT_DAYS="${DOC_DRIFT_DAYS:-30}"
DISCORD_VISUAL="$HOME/.openclaw-data/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "docs-freshness-audit"

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# 가장 최근 plist mtime
LA_LATEST=0
for f in "$LA_DIR"/ai.jarvis.*.plist "$LA_DIR"/com.jarvis.*.plist; do
    [ -f "$f" ] || continue
    m=$(mtime "$f")
    [ "$m" -gt "$LA_LATEST" ] && LA_LATEST=$m
done

declare -a STALE
declare -a REGEN_CMDS

check() {
    local source_mtime="$1" doc="$2" regen="$3" label="$4"
    [ -f "$doc" ] || { STALE+=("$label (문서 없음)"); REGEN_CMDS+=("$regen"); return; }
    local doc_mtime; doc_mtime=$(mtime "$doc")
    if [ "$source_mtime" -gt "$doc_mtime" ]; then
        local age_hours=$(( (source_mtime - doc_mtime) / 3600 ))
        STALE+=("$label (${age_hours}h 뒤처짐)")
        REGEN_CMDS+=("$regen")
    fi
}

# 1. cron-matrix
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/cron-matrix.json" \
      "node $SCRIPTS_DIR/gen-cron-matrix.mjs" \
      "cron-matrix"

# 2. tasks-index (기존 자동 생성 문서)
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/tasks-index.json" \
      "node $SCRIPTS_DIR/gen-tasks-index.mjs" \
      "tasks-index"

# 3. launchagent-catalog
check "$LA_LATEST" \
      "$DOCS_DIR/launchagent-catalog.json" \
      "node $SCRIPTS_DIR/gen-launchagent-catalog.mjs" \
      "launchagent-catalog"

# 4. discord-channels
MODELS_JSON_MTIME=$(mtime "$JARVIS_HOME/infra/config/models.json")
TASKS_JSON_MTIME=$(mtime "$JARVIS_HOME/runtime/config/tasks.json")
NEWER=$MODELS_JSON_MTIME
[ "$TASKS_JSON_MTIME" -gt "$NEWER" ] && NEWER=$TASKS_JSON_MTIME
check "$NEWER" \
      "$DOCS_DIR/discord-channels.json" \
      "node $SCRIPTS_DIR/gen-discord-channels.mjs" \
      "discord-channels"

# ── Cache Content Validation (구멍 3 — 2026-05-08) ─────────────────
# mtime 비교만으로는 gen 스크립트 버그를 못 잡음. 핵심 카운트/분포 정합성 직접 비교.
crosscheck() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        STALE+=("$label (mismatch: 원본=$expected, 사전=$actual)")
        REGEN_CMDS+=("$4")
    fi
}

# C1. tasks.json 총 task 수 vs cron-matrix.json
if [ -f "$DOCS_DIR/cron-matrix.json" ]; then
    SRC_COUNT=$(jq '.tasks | length' "$JARVIS_HOME/runtime/config/tasks.json" 2>/dev/null || echo 0)
    CACHE_COUNT=$(jq '.totalTasks' "$DOCS_DIR/cron-matrix.json" 2>/dev/null || echo -1)
    crosscheck "cron-matrix.totalTasks" "$SRC_COUNT" "$CACHE_COUNT" \
               "node $SCRIPTS_DIR/gen-cron-matrix.mjs"
fi

# C2. plist 수 vs launchagent-catalog.json
if [ -f "$DOCS_DIR/launchagent-catalog.json" ]; then
    # 생성기(gen-launchagent-catalog.mjs:83)는 ai.jarvis.* + com.jarvis.* 둘 다 센다.
    # ai.jarvis.* 만 세던 탓에 74 vs 177 영구 오탐이 매 실행 재생성을 유발했다 (2026-08-25 수정).
    SRC_LA=$(ls "$LA_DIR"/ai.jarvis.*.plist "$LA_DIR"/com.jarvis.*.plist 2>/dev/null | wc -l | tr -d ' ')
    CACHE_LA=$(jq '.totalLaunchAgents' "$DOCS_DIR/launchagent-catalog.json" 2>/dev/null || echo -1)
    crosscheck "launchagent-catalog.totalLaunchAgents" "$SRC_LA" "$CACHE_LA" \
               "node $SCRIPTS_DIR/gen-launchagent-catalog.mjs"
fi

# C3. tasks.json discordChannel 고유 수 vs discord-channels.json
if [ -f "$DOCS_DIR/discord-channels.json" ]; then
    # 생성기(gen-discord-channels.mjs:29)는 `t.discordChannel || '<no-channel>'` 이라
    # 빈 문자열도 <no-channel> 로 접는다. jq 의 // 는 null 만 처리해 17 vs 16 오탐이 났다 (2026-08-25 수정).
    SRC_CH=$(jq -r '[.tasks[] | (if (.discordChannel // "") == "" then "<no-channel>" else .discordChannel end)] | unique | length' "$JARVIS_HOME/runtime/config/tasks.json" 2>/dev/null || echo 0)
    CACHE_CH=$(jq '.totalChannels' "$DOCS_DIR/discord-channels.json" 2>/dev/null || echo -1)
    crosscheck "discord-channels.totalChannels" "$SRC_CH" "$CACHE_CH" \
               "node $SCRIPTS_DIR/gen-discord-channels.mjs"
fi

# ── 마크다운 산출물 (구멍 4 — 2026-08-25) ──────────────────────
# 지금까지 감시 대상이 JSON 캐시 4종뿐이었다. 같은 생성기가 .md 도 함께 뱉는데
# .md 만 실패해도 아무도 몰랐다. 실제로 SYSTEM-OVERVIEW.md 가 126일간 방치됐다.
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/CRON-MATRIX.md" \
      "node $SCRIPTS_DIR/gen-cron-matrix.mjs" \
      "CRON-MATRIX.md"

check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/TASKS-INDEX.md" \
      "node $SCRIPTS_DIR/gen-tasks-index.mjs" \
      "TASKS-INDEX.md"

check "$LA_LATEST" \
      "$DOCS_DIR/LAUNCHAGENT-CATALOG.md" \
      "node $SCRIPTS_DIR/gen-launchagent-catalog.mjs" \
      "LAUNCHAGENT-CATALOG.md"

check "$NEWER" \
      "$DOCS_DIR/DISCORD-CHANNELS.md" \
      "node $SCRIPTS_DIR/gen-discord-channels.mjs" \
      "DISCORD-CHANNELS.md"

# SYSTEM-OVERVIEW.md 정본은 runtime/docs (로컬 전용, gitignore). 2026-08-25 경로 일원화.
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$JARVIS_HOME/runtime/docs/SYSTEM-OVERVIEW.md" \
      "bash $SCRIPTS_DIR/gen-system-overview.sh" \
      "SYSTEM-OVERVIEW.md"

# ── 서술형 문서 드리프트 (구멍 5 — 2026-08-25) ──────────────────
# 생성기가 없는 손으로 쓴 문서는 재생성이 불가하니 '보고'만 한다.
# 근거는 doc-map.json — 코드→문서 매핑의 SSoT 를 그대로 재사용한다.
DRIFT_REPORT=$(python3 - "$JARVIS_HOME" "$DOC_DRIFT_DAYS" <<'PYDRIFT' 2>/dev/null || true
import json, os, sys, time

repo = sys.argv[1]
threshold_days = int(sys.argv[2])
home = os.path.expanduser("~")
doc_map = os.path.join(repo, "runtime/config/doc-map.json")

try:
    patterns = json.load(open(doc_map)).get("patterns", [])
except Exception:
    sys.exit(0)

def newest(fragment):
    """match_glob 조각이 가리키는 실제 파일들 중 가장 최근 mtime."""
    base = home if fragment.startswith(".claude/") else repo
    target = os.path.join(base, fragment)
    if os.path.isfile(target):
        return os.path.getmtime(target)
    if os.path.isdir(target):
        best = 0.0
        for root, dirs, files in os.walk(target):
            dirs[:] = [d for d in dirs if d != "node_modules"]
            for f in files:
                try:
                    best = max(best, os.path.getmtime(os.path.join(root, f)))
                except OSError:
                    pass
        return best
    # config/tasks.json 처럼 접두어가 생략된 조각
    alt = os.path.join(repo, "runtime", fragment)
    return os.path.getmtime(alt) if os.path.isfile(alt) else 0.0

now = time.time()
rows = []
for pat in patterns:
    frag = pat.get("match_glob", "")
    if not frag:
        continue
    code_m = newest(frag)
    if not code_m:
        continue
    for doc in pat.get("docs", []):
        dp = os.path.join(repo, "infra", doc)
        if not os.path.isfile(dp):
            rows.append((10**9, doc, frag, "문서 없음"))
            continue
        gap = (code_m - os.path.getmtime(dp)) / 86400.0
        if gap > threshold_days:
            rows.append((gap, doc, frag, "%d일 뒤처짐" % int(gap)))

seen, out = set(), []
for gap, doc, frag, why in sorted(rows, reverse=True):
    if doc in seen:
        continue
    seen.add(doc)
    out.append("%s (%s ← %s)" % (doc, why, frag))
print("\n".join(out))
PYDRIFT
)

if [ -n "$DRIFT_REPORT" ]; then
    DRIFT_COUNT=$(printf '%s\n' "$DRIFT_REPORT" | grep -c . || true)
    _log "DRIFT: 서술형 문서 ${DRIFT_COUNT}건이 코드보다 ${DOC_DRIFT_DAYS}일 이상 뒤처짐 (재생성 불가 — 수동 갱신 필요)"
    printf '%s\n' "$DRIFT_REPORT" | while IFS= read -r line; do [ -n "$line" ] && _log "  · $line"; done
else
    DRIFT_COUNT=0
    _log "DRIFT: 서술형 문서 드리프트 없음"
fi

if [ "${#STALE[@]}" -eq 0 ]; then
    _log "PASS: 자동 생성 문서 최신 + 정합성 통과"
    # 재생성 대상은 없어도 서술형 드리프트는 사람이 고쳐야 하므로 조용히 끝내지 않는다.
    if [ "${DRIFT_COUNT:-0}" -gt 0 ] && [ -f "$DISCORD_VISUAL" ]; then
        TS=$(date +"%Y-%m-%d %H:%M KST")
        DRIFT_SUMMARY=$(printf '%s\n' "$DRIFT_REPORT" | head -5 | tr '\n' '|' | sed 's/|$//')
        PAYLOAD=$(cat <<EOF
{"title":"📝 서술형 문서 드리프트","data":{"드리프트 건수":"${DRIFT_COUNT}","임계값":"${DOC_DRIFT_DAYS}일","대상":"$DRIFT_SUMMARY","조치":"생성기 없음 — 수동 갱신 필요"},"timestamp":"$TS"}
EOF
)
        discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    exit 0
fi

_log "STALE: ${#STALE[@]}건 발견 — 자동 재생성"
for s in "${STALE[@]}"; do _log "  - $s"; done

REGEN_OK=0
REGEN_FAIL=0
# bash 3.x 호환: associative array 대신 sort -u로 중복 제거
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    if eval "$cmd" >>"$LOG_FILE" 2>&1; then
        REGEN_OK=$((REGEN_OK + 1))
    else
        REGEN_FAIL=$((REGEN_FAIL + 1))
    fi
done < <(printf '%s\n' "${REGEN_CMDS[@]}" | sort -u)
_log "재생성: 성공 $REGEN_OK / 실패 $REGEN_FAIL"

# Discord 알림
if [ -f "$DISCORD_VISUAL" ]; then
    TS=$(date +"%Y-%m-%d %H:%M KST")
    STALE_SUMMARY=$(printf '%s\n' "${STALE[@]}" | head -5 | tr '\n' '|' | sed 's/|$//')
    PAYLOAD=$(cat <<EOF
{"title":"📚 사전 문서 갱신","data":{"stale 건수":"${#STALE[@]}","stale":"$STALE_SUMMARY","재생성 성공":"$REGEN_OK","재생성 실패":"$REGEN_FAIL","서술형 드리프트":"${DRIFT_COUNT:-0}건"},"timestamp":"$TS"}
EOF
)
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
