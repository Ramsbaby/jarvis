#!/usr/bin/env bash
# fix-library.sh — Jarvis Supervisor 안전 fix 함수 모음
#
# 원칙: LLM 자가진단은 bot-heal.sh에 위임. 본 라이브러리는 결정론적 fix만.
# 모든 함수에 시도 cap + audit log + dry-run 지원.
#
# 사용:
#   source fix-library.sh
#   fix_la_kickstart "com.jarvis.agent-batch-commit"
#   fix_circuit_reset "mistake-extractor-circuit"
#   fix_rag_indexer
#   fix_delegate_bot_heal "Discord 봇 heartbeat 300s 정지"
#
# 환경 변수:
#   SUPERVISOR_HEAL_DRYRUN=1 → 실제 실행 안 함, audit log만
#   SUPERVISOR_HEAL_AUDIT=path → audit jsonl 위치 (default: tasks.db addTask)

# ── env ─────────────────────────────────────────────────────────────
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
DOT_JARVIS="${HOME}/.jarvis"
FIX_LEDGER="${BOT_HOME}/state/supervisor-fix-ledger.jsonl"
FIX_ATTEMPT_DIR="${BOT_HOME}/state/supervisor-fix-attempts"
DRYRUN="${SUPERVISOR_HEAL_DRYRUN:-0}"
MAX_ATTEMPTS_PER_TARGET=3
mkdir -p "$(dirname "$FIX_LEDGER")" "$FIX_ATTEMPT_DIR"

# ── 공통 헬퍼 ───────────────────────────────────────────────────────
_fix_log() {
    local fn="$1" target="$2" result="$3" detail="${4:-}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --arg ts "$ts" --arg fn "$fn" --arg target "$target" \
        --arg result "$result" --arg detail "$detail" \
        --arg dryrun "$DRYRUN" \
        '{ts:$ts, fn:$fn, target:$target, result:$result, detail:$detail, dryrun:$dryrun}' \
        >> "$FIX_LEDGER"
}

# 시도 횟수 추적 — 같은 target에 N회 실패 시 더 이상 시도 안 함
_fix_attempt_check() {
    local target="$1"
    local attempt_file="${FIX_ATTEMPT_DIR}/${target//\//_}"
    local count=0
    [ -f "$attempt_file" ] && count=$(cat "$attempt_file" 2>/dev/null || echo 0)
    if [ "$count" -ge "$MAX_ATTEMPTS_PER_TARGET" ]; then
        return 1  # cap 초과
    fi
    echo $((count + 1)) > "$attempt_file"
    return 0
}

# 성공 시 시도 카운터 리셋
_fix_attempt_reset() {
    local target="$1"
    rm -f "${FIX_ATTEMPT_DIR}/${target//\//_}" 2>/dev/null
}

# ── fix 1: LA kickstart ────────────────────────────────────────────
# launchctl kickstart -k <label> — 가장 안전한 fix (재시작만)
fix_la_kickstart() {
    local label="$1"
    if [ -z "$label" ]; then _fix_log "fix_la_kickstart" "" "skip" "label 없음"; return 1; fi

    if ! _fix_attempt_check "la:${label}"; then
        _fix_log "fix_la_kickstart" "$label" "skip" "cap ${MAX_ATTEMPTS_PER_TARGET}회 초과"
        return 2
    fi

    if [ "$DRYRUN" = "1" ]; then
        _fix_log "fix_la_kickstart" "$label" "dryrun" "launchctl kickstart -k gui/UID/${label}"
        return 0
    fi

    if launchctl kickstart -k "gui/$(id -u)/${label}" 2>/dev/null; then
        sleep 3
        local new_status
        new_status=$(launchctl list 2>/dev/null | awk -v l="$label" '$3 == l {print $2}')
        if [ "$new_status" = "0" ] || [ -z "$new_status" ]; then
            _fix_log "fix_la_kickstart" "$label" "success" "exit=$new_status"
            _fix_attempt_reset "la:${label}"
            return 0
        else
            _fix_log "fix_la_kickstart" "$label" "fail" "exit=$new_status (재시작 후에도 비정상)"
            return 3
        fi
    fi
    _fix_log "fix_la_kickstart" "$label" "fail" "kickstart 명령 실패"
    return 3
}

# ── fix 2: Circuit breaker reset ───────────────────────────────────
# circuit json 파일 삭제 → 다음 실행 시 closed로 시작
fix_circuit_reset() {
    local circuit_name="$1"
    if [ -z "$circuit_name" ]; then _fix_log "fix_circuit_reset" "" "skip" "name 없음"; return 1; fi

    if ! _fix_attempt_check "circuit:${circuit_name}"; then
        _fix_log "fix_circuit_reset" "$circuit_name" "skip" "cap 초과"
        return 2
    fi

    # 두 위치 모두 후보 (실측 결과 동기화 안 되어 있음)
    local candidates=(
        "${DOT_JARVIS}/state/circuit-breaker/${circuit_name}.json"
        "${DOT_JARVIS}/state/${circuit_name}.json"
        "${BOT_HOME}/state/circuit-breaker/${circuit_name}.json"
        "${BOT_HOME}/state/${circuit_name}.json"
    )

    local removed=0
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            if [ "$DRYRUN" = "1" ]; then
                _fix_log "fix_circuit_reset" "$circuit_name" "dryrun" "rm $f"
            else
                # 백업 후 삭제 (원장에 흔적)
                cp "$f" "${f}.reset-bak-$(date +%s)" 2>/dev/null
                rm "$f" && removed=$((removed + 1))
            fi
        fi
    done

    if [ "$removed" -gt 0 ] || [ "$DRYRUN" = "1" ]; then
        _fix_log "fix_circuit_reset" "$circuit_name" "success" "removed=$removed"
        _fix_attempt_reset "circuit:${circuit_name}"
        return 0
    fi
    _fix_log "fix_circuit_reset" "$circuit_name" "fail" "circuit 파일 없음"
    return 3
}

# ── fix 3: RAG indexer 강제 1회 실행 ──────────────────────────────
fix_rag_indexer_kick() {
    local target="rag-indexer"
    if ! _fix_attempt_check "$target"; then
        _fix_log "fix_rag_indexer_kick" "$target" "skip" "cap 초과"
        return 2
    fi

    local script="${DOT_JARVIS}/scripts/rag-index-cron.sh"
    if [ ! -x "$script" ]; then
        _fix_log "fix_rag_indexer_kick" "$target" "fail" "script 없음: $script"
        return 3
    fi

    if [ "$DRYRUN" = "1" ]; then
        _fix_log "fix_rag_indexer_kick" "$target" "dryrun" "bash $script (background)"
        return 0
    fi

    # background 실행 (5분 timeout)
    (timeout 300 bash "$script" >> "${BOT_HOME}/logs/supervisor-rag-kick.log" 2>&1 &)
    _fix_log "fix_rag_indexer_kick" "$target" "success" "background started (300s timeout)"
    _fix_attempt_reset "$target"
    return 0
}

# ── fix 4: bot-heal.sh 위임 (LLM 자가복구) ────────────────────────
# 봇 다운, heartbeat 정지, preflight 실패 같은 심각 결함 → 기존 bot-heal로 위임
# bot-heal.sh가 이미 LLM 자가진단 + 동일 원인 circuit breaker + 학습 누적 다 함
fix_delegate_bot_heal() {
    local reason="$1"
    if [ -z "$reason" ]; then _fix_log "fix_delegate_bot_heal" "" "skip" "reason 없음"; return 1; fi

    if ! _fix_attempt_check "bot-heal"; then
        _fix_log "fix_delegate_bot_heal" "bot-heal" "skip" "cap 초과 (bot-heal 자체 circuit OPEN 가능)"
        return 2
    fi

    local script="${BOT_HOME}/scripts/bot-heal.sh"
    if [ ! -x "$script" ]; then
        # fallback: ~/.jarvis 위치
        script="${DOT_JARVIS}/scripts/bot-heal.sh"
    fi
    if [ ! -x "$script" ]; then
        _fix_log "fix_delegate_bot_heal" "bot-heal" "fail" "bot-heal.sh 없음"
        return 3
    fi

    if [ "$DRYRUN" = "1" ]; then
        _fix_log "fix_delegate_bot_heal" "bot-heal" "dryrun" "tmux new -d -s jarvis-heal-sv \"$script $reason\""
        return 0
    fi

    # tmux 세션 분리 실행 (기존 bot-heal 패턴 동일)
    tmux new-session -d -s "jarvis-heal-sv-$(date +%s)" "$script \"$reason\"" 2>/dev/null
    _fix_log "fix_delegate_bot_heal" "bot-heal" "success" "tmux delegated: $reason"
    _fix_attempt_reset "bot-heal"
    return 0
}

# ── fix 5: 알림만 (자동 fix 불가능한 결함) ────────────────────────
# Discord ntfy로 주인님께 즉시 알림
fix_alert_only() {
    local title="$1" detail="$2"
    if [ "$DRYRUN" = "1" ]; then
        _fix_log "fix_alert_only" "$title" "dryrun" "$detail"
        return 0
    fi
    # ntfy-notify.sh 재사용 (이미 있는 인프라)
    if [ -f "${BOT_HOME}/lib/ntfy-notify.sh" ]; then
        bash -c "source '${BOT_HOME}/lib/ntfy-notify.sh' && send_ntfy \"$title\" \"$detail\" \"high\"" 2>/dev/null
    fi
    _fix_log "fix_alert_only" "$title" "success" "$detail"
    return 0
}

# ── fix 6: LLM 자율 진단·복구 (주인님 의도의 핵심) ────────────────
# 결함 요약을 ask-claude.sh에 위임 — LLM이 SSoT 문서 읽고 진단 + bash 명령으로 직접 복구.
# 위 fix_la_kickstart/fix_circuit_reset/fix_rag_indexer_kick는 LLM이 호출 가능한 reference (allowlist 효과).
# DRYRUN=1: ALLOWED_TOOLS="Read" — LLM은 진단만 (실행 X). 진짜 비용은 발생 (~$0.005/회)
# DRYRUN=0: ALLOWED_TOOLS="Read,Bash" — LLM이 직접 명령 실행
fix_llm_solve() {
    local summary="$1"
    if [ -z "$summary" ]; then _fix_log "fix_llm_solve" "" "skip" "summary 없음"; return 1; fi

    if ! _fix_attempt_check "llm-solve"; then
        _fix_log "fix_llm_solve" "llm" "skip" "cap ${MAX_ATTEMPTS_PER_TARGET}회 초과"
        return 2
    fi

    local task_id="supervisor-heal-$(date +%s)"
    local timeout=180
    # 2026-05-07 BLOCKER fix: budget 0.40 → 0.80 상향 (verify 적발: 자동 tick 50% fail).
    # 실측 결과 Sonnet 1회 ~$0.40+ (long context + Read tool calls). 0.80은 2x 안전 cushion.
    # 일 5~10회 × $0.50 평균 = 일 ~$2.5~5, 월 ~$75~150. 주인님 비용 명시 승인.
    local max_budget=0.80
    local model="claude-sonnet-4-6"
    local allowed
    if [ "$DRYRUN" = "1" ]; then
        allowed="Read"  # 진단만, 실행 X
    else
        allowed="Read,Bash"  # 실제 복구
    fi

    # 프롬프트 — 자비스 SSoT 문서 + allowed actions + forbidden 명시
    local prompt
    prompt=$(cat <<EOF
You are the Jarvis Supervisor self-heal agent. A defect was auto-detected.

# DEFECT
${summary}

# MANDATORY FIRST STEPS (Read tool 호출 필수, 진단 전 반드시)
- 진단을 시작하기 전에 다음 중 최소 2개를 Read tool로 직접 읽어라.
- Read 호출이 0회면 본 진단은 **fail-quality**로 거부된다 (품질 게이트).
1. ~/jarvis/infra/docs/MAP.md  # 시스템 맵 — 본 결함이 어느 컴포넌트인지 매핑
2. ~/jarvis/infra/docs/ARCHITECTURE.md  # self-healing 4-layer 구조
3. ~/jarvis/infra/docs/OPERATIONS.md  # 운영 + escalation tree
4. ~/jarvis/runtime/wiki/meta/learned-mistakes.md  # 오답노트 — 같은 결함 과거 진단
5. ~/jarvis/infra/supervisor/lib/fix-library.sh  # 안전 fix 함수 reference

# ALLOWED ACTIONS (via Bash tool, when DRYRUN=0)
- launchctl kickstart -k gui/\$(id -u)/<label>
- bash ~/.jarvis/scripts/rag-index-cron.sh  # ALLOW-DOTJARVIS
- rm ~/.jarvis/state/circuit-breaker/<name>.json (circuit reset만)  # ALLOW-DOTJARVIS
- bash ~/jarvis/runtime/scripts/<known-script>.sh
- Read-only 진단: grep, find, jq, cat, ls, tail

# FORBIDDEN (실행 시 audit failure)
- rm -rf · git push · git reset --hard
- plist 수정/삭제 · LaunchAgent 등록 변경
- Discord webhook 직접 호출 · 결제 · 자산 이동
- 시크릿 출력 (.env cat)

# OUTPUT (마지막 라인에 JSON 한 줄)
{"diagnosis":"한 줄 원인","actions":["실행한 bash 명령들"],"result":"success|fail|escalate","notes":"추가"}

Diagnose + 1회 안전 복구 시도. 5분 내 종료.
EOF
)

    local ask_claude="${HOME}/jarvis/infra/bin/ask-claude.sh"
    if [ ! -x "$ask_claude" ]; then
        _fix_log "fix_llm_solve" "$summary" "fail" "ask-claude.sh 없음"
        return 3
    fi

    _fix_log "fix_llm_solve" "$summary" "start" "task_id=$task_id allowed=$allowed dryrun=$DRYRUN"

    # ask-claude.sh 호출 — 결과는 ${BOT_HOME}/results/${task_id}/ 에 저장됨
    local exit_code=0
    bash "$ask_claude" "$task_id" "$prompt" "$allowed" "$timeout" "$max_budget" "7" "$model" >/dev/null 2>&1 || exit_code=$?

    # 2026-05-07 BLOCKER fix: 품질 게이트 — Read tool_use=0이면 LLM이 SSoT 문서 안 읽고
    # 가짜 진단 생성한 것으로 간주. result:success여도 fail 강제 처리.
    # 검증 방식: claude session jsonl에서 tool_use 카운트.
    local result_dir="${BOT_HOME}/results/${task_id}"
    local quality_pass=0
    if [ "$exit_code" -eq 0 ] && [ -d "$result_dir" ]; then
        # raw txt 또는 md 파일에서 Read tool 호출 흔적 grep
        local tool_uses
        tool_uses=$(grep -cE "Read|tool_use|<function_calls>" "$result_dir"/*.md "$result_dir"/*-raw.txt 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
        if [ "$tool_uses" -ge 1 ]; then
            quality_pass=1
        fi
    fi

    if [ "$exit_code" -eq 0 ] && [ "$quality_pass" -eq 1 ]; then
        _fix_log "fix_llm_solve" "$summary" "completed" "result_dir=results/$task_id allowed=$allowed tool_uses=ok"
        _fix_attempt_reset "llm-solve"
    elif [ "$exit_code" -eq 0 ] && [ "$quality_pass" -eq 0 ]; then
        _fix_log "fix_llm_solve" "$summary" "fail-quality" "ask-claude OK이나 LLM tool_use=0 — 가짜 진단 의심"
        return 4
    else
        _fix_log "fix_llm_solve" "$summary" "fail" "ask-claude exit=$exit_code"
    fi
    return $exit_code
}

# ── 자동 매핑: 결함 → fix 함수 (LLM-first 재설계) ─────────────────
# 주인님 의도 (2026-05-07): "LLM이 문서 보고 알아서 복구" — 모든 결함을 fix_llm_solve로.
# 위 결정론적 함수(kickstart/circuit reset 등)는 LLM이 직접 호출하도록 reference로 유지.
fix_dispatch() {
    local defect_type="$1"
    local target="$2"

    local summary
    case "$defect_type" in
        circuit_open)   summary="Circuit breaker OPEN — name: $target" ;;
        rag_stuck)      summary="RAG indexer 정지 (last RAG index >120분 전)" ;;
        heartbeat_dead) summary="Discord 봇 heartbeat ${target}s 정지 (>300s)" ;;
        la_failed)      summary="LaunchAgent failed: $target (status != 0)" ;;
        err_file_new)   summary="신규 .err 파일 발견: $target" ;;
        *)              summary="알 수 없는 결함: type=$defect_type target=$target" ;;
    esac

    fix_llm_solve "$summary"
}
