#!/usr/bin/env bash
# PreToolUse hook: blocks dangerous bash commands
# Claude Code calls this with JSON on stdin: {"tool_name": "Bash", "tool_input": {"command": "..."}}

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
CMD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

if [[ "$TOOL" != "Bash" ]]; then exit 0; fi

# cl-602875a5289bba26: 비가역 작업 차단/우회 감사 원장. source 실패해도(부재/오류) 무해하게
# 이어지도록 항상 || true 로 감싼다 — 이 훅의 차단 판정 로직에는 어떤 경우에도 영향을 주지 않는다.
# shellcheck disable=SC1090
source "${HOME}/jarvis/infra/lib/irreversible-bypass-guard.sh" 2>/dev/null || true
_log_irreversible() {
    # log_irreversible_event가 정의되지 않았으면(source 실패) 조용히 무시
    declare -F log_irreversible_event >/dev/null 2>&1 && log_irreversible_event "$1" "$2" "$CMD" "$TOOL" "$PWD"
    return 0
}

# Block rm -rf on root or home
if echo "$CMD" | grep -qE 'rm\s+-[a-z]*r[a-z]*f|rm\s+-[a-z]*f[a-z]*r' && echo "$CMD" | grep -qE '(/\s*$|/\s*"|~\s*$|\$HOME\s*$)'; then
    _log_irreversible "rm_rf_root_home" "blocked"
    echo "BLOCKED: rm -rf on root/home directory detected. Use specific paths." >&2
    exit 2
fi

# Block force push to main/master
if echo "$CMD" | grep -qE 'git\s+push.*--force.*origin\s+(main|master)|git\s+push\s+-f.*origin\s+(main|master)'; then
    _log_irreversible "force_push_main" "blocked"
    echo "BLOCKED: force push to main/master. Explicitly confirm this action first." >&2
    exit 2
fi

# Block DROP TABLE / TRUNCATE only when executed via SQL client
if echo "$CMD" | grep -qiE '(mysql|psql|sqlite3|sqlcmd)\b.*DROP\s+TABLE|(mysql|psql|sqlite3|sqlcmd)\b.*TRUNCATE\s+TABLE'; then
    _log_irreversible "sql_drop_truncate" "blocked"
    echo "BLOCKED: DROP TABLE/TRUNCATE via SQL client detected. Explicitly confirm this destructive SQL action first." >&2
    exit 2
fi

# Block Claude Code CLI self-update (cl-602875a5289bba26: "claude update" 사전 미상의 재발 6건)
# 셸에서 실행되는 버전 변경은 되돌리기 어렵고(다운그레이드 경로 없음), 실행 중인 세션 자체를
# 뒤흔들 수 있는 비가역 작업이다. Bypass requires owner's explicit approval: JARVIS_SELFUPDATE_OK=1
if echo "$CMD" | grep -qiE '(^|[;&|]|[[:space:]])claude([[:space:]]+(code))?[[:space:]]+update([[:space:]]|$)|(^|[;&|]|[[:space:]])claude[[:space:]]+--update([[:space:]]|$)|npm[[:space:]]+(install|i|update)[[:space:]]+(-g|--global)[[:space:]]+.*@anthropic-ai/claude-code'; then
    if [[ "${JARVIS_SELFUPDATE_OK:-0}" != "1" ]]; then
        _log_irreversible "claude_cli_selfupdate" "blocked"
        echo "BLOCKED: Claude Code CLI self-update (irreversible version change, no downgrade path). Explicit owner approval required first." >&2
        echo "  Bypass (owner-only): JARVIS_SELFUPDATE_OK=1 <cmd>" >&2
        exit 2
    else
        _log_irreversible "claude_cli_selfupdate" "bypassed"
    fi
fi

# Block destructive GitHub repo actions without owner consent
# (visibility toggle, delete, archive — owner sovereignty per Iron Law 3)
# 2026-04-21: jarvis repo was silently switched to private, losing stars/forks.
# Bypass requires owner's explicit approval token in env: JARVIS_GH_DESTRUCTIVE_OK=1
if echo "$CMD" | grep -qiE 'gh\s+repo\s+edit\b.*--visibility\s*=?\s*private|gh\s+repo\s+edit\b.*--visibility\s*=?\s*internal'; then
    if [[ "${JARVIS_GH_DESTRUCTIVE_OK:-0}" != "1" ]]; then
        _log_irreversible "gh_repo_visibility" "blocked"
        echo "BLOCKED: gh repo visibility → private/internal. Owner consent required." >&2
        echo "  Bypass (owner-only): JARVIS_GH_DESTRUCTIVE_OK=1 <cmd>" >&2
        exit 2
    else
        _log_irreversible "gh_repo_visibility" "bypassed"
    fi
fi
if echo "$CMD" | grep -qiE 'gh\s+repo\s+(delete|archive)\b'; then
    if [[ "${JARVIS_GH_DESTRUCTIVE_OK:-0}" != "1" ]]; then
        _log_irreversible "gh_repo_delete_archive" "blocked"
        echo "BLOCKED: gh repo delete/archive. Owner consent required (irreversible)." >&2
        echo "  Bypass (owner-only): JARVIS_GH_DESTRUCTIVE_OK=1 <cmd>" >&2
        exit 2
    else
        _log_irreversible "gh_repo_delete_archive" "bypassed"
    fi
fi
if echo "$CMD" | grep -qiE 'gh\s+api\b.*(-X\s*DELETE|--method\s*DELETE).*repos/'; then
    if [[ "${JARVIS_GH_DESTRUCTIVE_OK:-0}" != "1" ]]; then
        _log_irreversible "gh_api_delete_repos" "blocked"
        echo "BLOCKED: gh api DELETE on repos/. Owner consent required." >&2
        echo "  Bypass (owner-only): JARVIS_GH_DESTRUCTIVE_OK=1 <cmd>" >&2
        exit 2
    else
        _log_irreversible "gh_api_delete_repos" "bypassed"
    fi
fi
# cl-19d6b30bf68b02db: 설정 실효성 검증 가드
# 크론/설정 변경 전 실제 프로세스 env와 설정 파일 실효값 강제 검증
_query_process_env() {
    local pid=$1
    local key=$2
    # macOS/Linux 호환: /proc/PID/environ 또는 ps 조회
    if [[ -r "/proc/$pid/environ" ]]; then
        tr '\0' '\n' < "/proc/$pid/environ" | grep "^$key=" | cut -d= -f2-
    elif command -v ps >/dev/null 2>&1; then
        ps eww "$pid" 2>/dev/null | grep -o " $key=[^ ]*" | cut -d= -f2- | head -1
    fi
}

_config_validate_check() {
    # tasks.json, cron 파일, env 변수 설정 명령 감지
    if echo "$CMD" | grep -qiE '(tasks\.json|cron-master\.sh|jarvis-cron\.sh|config\.sh|\.env)' || \
       echo "$CMD" | grep -qE '(export\s+[A-Z_]+=|JARVIS_|CRON_|BOT_)'; then

        mkdir -p "${HOME}/.jarvis/logs"
        local config_report="${HOME}/.jarvis/logs/preflight-config-check-$$.log"
        {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 설정 변경 감지 — 실효값 검증 (cl-19d6b30bf68b02db)"
            echo "======================================="
            echo "명령: $CMD"
            echo ""

            # 1. LaunchAgent 프로세스 실제 env 조회 (강제 검증)
            local la_pid=$(pgrep -f "bot-cron\.sh" | head -1)
            if [[ -n "$la_pid" ]]; then
                echo "실행 중 bot-cron 프로세스 (PID: $la_pid) 실제 환경 변수:"
                echo "  HOME = $(_query_process_env "$la_pid" "HOME")"
                echo "  PATH = $(_query_process_env "$la_pid" "PATH")"
                echo "  BOT_HOME = $(_query_process_env "$la_pid" "BOT_HOME")"
                echo "  USER = $(_query_process_env "$la_pid" "USER")"
                echo ""
            else
                echo "⚠️  경고: 실행 중인 bot-cron 프로세스 없음 (다음 스케줄에 LaunchAgent가 로드)"
                echo ""
            fi

            # 2. LaunchAgent plist 설정 검증
            local plist_path="${HOME}/Library/LaunchAgents/ai.jarvis.bot-cron.plist"
            if [[ -f "$plist_path" ]]; then
                echo "LaunchAgent plist 설정파일 ($plist_path):"
                # WorkingDirectory 확인
                local wd=$(grep -A 1 "<key>WorkingDirectory</key>" "$plist_path" 2>/dev/null | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
                [[ -n "$wd" ]] && echo "  WorkingDirectory = $wd" || echo "  WorkingDirectory = (미설정 — 기본값 사용)"
                # EnvironmentVariables 확인
                if grep -q "<key>EnvironmentVariables</key>" "$plist_path"; then
                    echo "  EnvironmentVariables:"
                    grep -A 100 "<key>EnvironmentVariables</key>" "$plist_path" | grep -E "<key>|<string>" | head -8 | sed 's/^/    /'
                else
                    echo "  EnvironmentVariables = (미설정)"
                fi
                echo ""
            else
                echo "❌ 오류: LaunchAgent plist 파일 없음: $plist_path"
                echo ""
            fi

            # 3. tasks.json 편집 시 schema 검증
            if echo "$CMD" | grep -q "tasks\.json"; then
                echo "tasks.json 변경 감지:"
                if [[ -f "${HOME}/jarvis/config/tasks.json" ]]; then
                    local total=$(jq '.tasks | length' "${HOME}/jarvis/config/tasks.json" 2>/dev/null || echo "?")
                    local disabled=$(jq '[.tasks[] | select(.enabled == false)] | length' "${HOME}/jarvis/config/tasks.json" 2>/dev/null || echo "?")
                    echo "  전체 태스크: $total개"
                    echo "  disabled 태스크: $disabled개"
                    if [[ "$total" != "?" ]] && [[ "$disabled" != "?" ]]; then
                        echo "  활성화: $((total - disabled))개"
                    fi
                    echo ""
                else
                    echo "❌ 오류: tasks.json 파일 없음"
                    echo ""
                fi
            fi

            # 4. 크론 파일 변경 감지
            if echo "$CMD" | grep -qE '(cron-master\.sh|jarvis-cron\.sh|bot-cron\.sh)'; then
                echo "크론 파일 변경 감지 — 다음 단계 필수:"
                echo "  1️⃣  파일 문법 검증: bash -n <파일명>"
                echo "  2️⃣  LaunchAgent 재시작: launchctl stop ai.jarvis.bot-cron && sleep 2 && launchctl start ai.jarvis.bot-cron"
                echo "  3️⃣  다음 스케줄 대기 후 로그 확인: tail -f ~/.jarvis/logs/cron-master.log"
                echo ""
            fi

            echo "🔍 변경 후 실효값 재검증:"
            echo "  • ps aux | grep bot-cron | grep -v grep"
            echo "  • launchctl list | grep ai.jarvis"
            echo "  • cat ~/.jarvis/logs/cron-master.log | tail -20"
            echo "======================================="
        } | tee "$config_report" >&2

        return 0
    fi
}

_config_validate_check

if echo "$CMD" | grep -qiE 'gh\s+api\b.*repos/.*--field\s+private=true|gh\s+api\b.*repos/.*-f\s+private=true'; then
    if [[ "${JARVIS_GH_DESTRUCTIVE_OK:-0}" != "1" ]]; then
        _log_irreversible "gh_api_set_private" "blocked"
        echo "BLOCKED: gh api set private=true on repos/. Owner consent required." >&2
        echo "  Bypass (owner-only): JARVIS_GH_DESTRUCTIVE_OK=1 <cmd>" >&2
        exit 2
    else
        _log_irreversible "gh_api_set_private" "bypassed"
    fi
fi

exit 0
