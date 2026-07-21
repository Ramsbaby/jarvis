#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# jarvis-verify-independent.sh — 자비스의 "첫 독립 검증자" (재사용 CLI)
# ------------------------------------------------------------------------------
# 무엇인가:
#   어떤 "주장(claim)" 또는 "방금 한 작업"을 입력받아, 자비스 본체와 격리된
#   검증 에이전트(별도 컨텍스트·저비용 모델)를 소환해 적대적으로 검증하고
#   판정(CONFIRMED / REFUTED / UNCERTAIN)과 실측 근거를 돌려준다.
#
# 왜 필요한가 (설계 출처):
#   ~/jarvis/runtime/wiki/meta/how-to-become-jarvis-20260719.md
#     · 원리 A — 검증자는 생성자와 격리되어야 한다(coherence trap 방지)
#     · 원리 B — 실측 신호(파일 존재·exit code·grep·launchctl)가 있을 때만 판정
#     · 섹션 6 실행 흐름 — [블라인드 검증자] 노드의 "명령으로 부르는" 첫 버전
#   자비스는 자기 결론을 자기가 채점하면 편향에 빠진다(오늘 자가진단 4번 오판).
#   해법은 "자비스를 더 똑똑하게"가 아니라 "자비스 밖에 독립 검증자를 세우는 것".
#
# LLM 호출 규약 (실측 확인 — 2026-07-19):
#   ~/jarvis/infra/bin/ask-claude.sh 를 표준 경유로 사용한다.
#   인자 순서:  TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET] [RETENTION] [MODEL]
#   격리 장수명 토큰(setup-token, 1년)은 llm-gateway._llm_claude_cli 가 자동 주입.
#   결과는 ask-claude.sh 가 최종 `echo "$RESULT"` 로 stdout 출력 → 여기서 캡처.
#   ⚠️ 실측(2026-07-20): ask-claude 는 후처리(레지스트리 갱신 등)가 exit≠0 로 끝나면
#      최종 stdout echo 에 도달 못 해 빈 출력을 낼 수 있다. 판정은 결과 파일에 이미
#      영속되므로 결과 파일 폴백 + 무응답 시 fresh task-id 재시도로 회수한다(아래).
#   기본 검증 모델: claude-sonnet-5 (L67 참조). 검증관이 피검증자보다 약하면 미묘한
#      오류를 못 잡으므로 기본은 Sonnet. 단순 결정론 실측만 필요하면 --model 로 haiku 다운시프트.
#
# 사용법:
#   jarvis-verify-independent.sh "<검증할 주장>" [옵션]
#     --context "<추가 맥락>"    검증 에이전트에게 줄 배경(선택)
#     --model   <모델>          기본 claude-sonnet-5 (결정론 실측만이면 haiku 로 다운 가능)
#     --tools   <도구목록>      기본 "Bash,Read" (결정론 실측용)
#     --timeout <초>            기본 120
#     --budget  <USD>           기본 0.50
#     --task-id <id>            기본 independent-verify (매 호출마다 고유 접미사 자동 부여)
#     --team                    검증관 3명(결정론·재현·반증 렌즈) 병렬 소환 후 다수결
#                               (비용 ~3배 · 고위험/명시 요청 전용 · 기본은 단일)
#
# 종료 코드:
#   0 = CONFIRMED   3 = REFUTED   4 = UNCERTAIN   1 = 검증 자체 실패(LLM 무응답)
#   2 = 사용법 오류
#
# 원장(ledger): ~/jarvis/runtime/ledger/independent-verify.jsonl (append-only)
#
# 자동 트리거 확장 방향 (다음 단계 — 이번 스코프 제외):
#   Claude Code Stop 훅 또는 ask-claude.sh 완료 직전에서 "완료/성공/존재" 선언을
#   감지하면, 그 RESULT를 claim으로 이 스크립트를 자동 호출해 REFUTED면 재작업 유도.
# ==============================================================================

# --- HOME/PATH 보증 (cron 환경 방어) ---
export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
ASK_CLAUDE="${BOT_HOME}/bin/ask-claude.sh"
LEDGER_FILE="${HOME}/jarvis/runtime/ledger/independent-verify.jsonl"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# --- 의존성 확인 ---
for cmd in jq gtimeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ ERROR: '$cmd' 를 PATH에서 찾지 못했습니다" >&2; exit 2; }
done
[[ -x "$ASK_CLAUDE" ]] || { echo "❌ ERROR: ask-claude.sh 실행 파일 없음: $ASK_CLAUDE" >&2; exit 2; }

# --- 인자 파싱 ---
CLAIM=""
CONTEXT=""
# 검증관은 피검증자(자비스=Opus/Sonnet)보다 약하면 미묘한 오류를 못 잡는다 → 기본 Sonnet-5.
# 검증은 최후 방어선이라 여기서 비용을 아끼지 않는다. 단순 결정론 실측만 필요하면 --model 로 haiku 다운 가능.
MODEL="claude-sonnet-5"
TOOLS="Bash,Read"
TIMEOUT="120"
BUDGET="0.50"
TASK_ID="independent-verify"
TEAM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --context) CONTEXT="${2:?}"; shift 2 ;;
        --model)   MODEL="${2:?}";   shift 2 ;;
        --tools)   TOOLS="${2:?}";   shift 2 ;;
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        --budget)  BUDGET="${2:?}";  shift 2 ;;
        --task-id) TASK_ID="${2:?}"; shift 2 ;;
        --team)    TEAM=true;        shift 1 ;;
        -h|--help)
            sed -n '2,50p' "$0"; exit 0 ;;
        --) shift; CLAIM="${CLAIM:-${1:-}}"; break ;;
        -*)
            echo "❌ ERROR: 알 수 없는 옵션: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$CLAIM" ]]; then CLAIM="$1"; else CLAIM="$CLAIM $1"; fi
            shift ;;
    esac
done

if [[ -z "$CLAIM" ]]; then
    echo "❌ ERROR: 검증할 주장(claim)이 비어 있습니다." >&2
    echo "   사용법: jarvis-verify-independent.sh \"<주장>\" [--context ...] [--model ...]" >&2
    exit 2
fi

# --- 적대적 검증 프롬프트 구성 ---
# 검증 에이전트는 자비스 원본 추론을 모르고(블라인드), 주장을 믿지 않고 반박을 시도한다.
CONTEXT_BLOCK=""
if [[ -n "$CONTEXT" ]]; then
    CONTEXT_BLOCK="

[추가 맥락 — 참고만, 사실로 신뢰 금지]
${CONTEXT}"
fi

read -r -d '' PROMPT <<EOF || true
너는 자비스와 완전히 분리된 **독립 검증관(independent adversarial verifier)**이다.
너의 임무는 아래 "주장"을 믿는 것이 아니라 **반박하는 것**이다. 생성한 쪽의 논리를
재확인하지 말고, 처음부터 다시 의심하라.

[검증할 주장]
${CLAIM}${CONTEXT_BLOCK}

[검증 규칙 — 반드시 준수]
1. 가능한 모든 것을 **결정론적 실측**으로 직접 확인하라. 추론·기억·추측 금지.
   - 파일/디렉토리 존재: Bash로 \`ls -la <경로>\` 또는 \`test -e <경로>; echo \$?\`
   - 명령 성공 여부: 실제 실행 후 exit code 확인
   - 텍스트/패턴 존재: \`grep -n <패턴> <파일>\`
   - 서비스/에이전트 가동: \`launchctl list | grep <이름>\`, \`pgrep -fl <이름>\`
2. **실측 근거가 없으면 CONFIRMED를 절대 쓰지 마라.** 확인 불가·근거 부재는 REFUTED.
   주장 자체가 상태로 판정 불가능한 주관/의견이면 UNCERTAIN.
3. 실제로 실행한 명령과 그 출력만 근거로 인정한다. "아마", "보통", "일반적으로" 금지.

[출력 형식 — 정확히 이 형식으로 끝맺어라]
먼저 실행한 명령과 관측 결과를 3줄 이내로:
EVIDENCE: <실행한 명령> → <관측된 실제 출력/exit code>
그리고 마지막 줄에 판정을 정확히 다음 중 하나로:
VERDICT: CONFIRMED
또는
VERDICT: REFUTED
또는
VERDICT: UNCERTAIN
EOF

if [[ "$TEAM" == true ]]; then MODE_LABEL="팀"; else MODE_LABEL="단일"; fi
log "🔎 독립 검증 시작 — 주장 길이 ${#CLAIM}자, 모델 ${MODEL}, 도구 ${TOOLS}, 모드 ${MODE_LABEL}"

# 외부 하드캡: ask-claude 내부 timeout + 45초 버퍼로 행(hang) 방어.
HARD_CAP=$(( TIMEOUT + 45 ))
RUNNER_LOG="${BOT_HOME}/logs/task-runner.jsonl"

# ==============================================================================
# 공통 유틸 함수 (단일·팀 모드 공유)
# ==============================================================================

# 렌즈 지시를 base PROMPT 뒤에 얹어 최종 프롬프트를 만든다(렌즈 없으면 PROMPT 그대로).
build_prompt() {
    local lens="$1"
    if [[ -n "$lens" ]]; then
        printf '%s\n\n[이번 검증관 전용 렌즈 — 우선 이 각도로 접근하라]\n%s\n' "$PROMPT" "$lens"
    else
        printf '%s\n' "$PROMPT"
    fi
}

# 무응답(stdout 빈 출력) 회수 — 이번 실행이 방금 만든 결과 파일/오류 아티팩트에서 판정 텍스트를 되살린다.
# 근거: ask-claude 는 후처리(레지스트리 갱신 등)가 exit≠0 로 끝나 최종 stdout echo 에 도달 못 할 수 있으나
#       판정은 결과 파일에 이미 영속된다(실측 2026-07-19~20). baseline 실측에서도 ask_exit=1 인데 폴백으로 회수됨.
# 유형 A 누수 차단: date +%s(정수) vs 파일 mtime 반올림 레이스로 정상 결과를 놓치던 문제를 mtime 경계에 3초
#       안전마진을 둬 해소. '## Result' 가 없으면(=후처리 이전 실패) -error.json/-raw.txt 의 .result 도 폴백.
# 위조 금지: 결과 파일이 없거나 판정 텍스트가 없으면 아무것도 살리지 않고 실패로 남긴다(return 1).
# 전역 출력: _RAW, _RESULT_SOURCE
recover_raw() {
    local run_tid="$1" start_epoch="$2" raw="$3"
    _RAW="$raw"; _RESULT_SOURCE="stdout"
    if [[ -n "$_RAW" ]]; then return 0; fi
    local rdir="${BOT_HOME}/results/${run_tid}" newest mtime
    newest=$(ls -t "${rdir}"/*.md 2>/dev/null | head -1 || true)
    if [[ -n "$newest" && -f "$newest" ]]; then
        mtime=$(stat -f %m "$newest" 2>/dev/null || echo 0)
        if [[ "$mtime" -ge $(( start_epoch - 3 )) ]]; then
            _RAW=$(awk '/^## Result$/{flag=1; next} flag' "$newest")
            if [[ -n "$_RAW" ]]; then
                _RESULT_SOURCE="result_file"
                log "ℹ️  stdout 비어있음 → 결과 파일 폴백 채택: $newest"
                return 0
            fi
        fi
    fi
    local artifact extracted
    artifact=$(ls -t "${rdir}"/*-error.json "${rdir}"/*-raw.txt 2>/dev/null | head -1 || true)
    if [[ -n "$artifact" && -f "$artifact" ]]; then
        mtime=$(stat -f %m "$artifact" 2>/dev/null || echo 0)
        if [[ "$mtime" -ge $(( start_epoch - 3 )) ]]; then
            extracted=$(jq -r '.result // empty' "$artifact" 2>/dev/null || true)
            if [[ -n "$extracted" ]]; then
                _RAW="$extracted"; _RESULT_SOURCE="error_artifact"
                log "ℹ️  stdout 비어있음 → 오류 아티팩트 폴백 채택: $artifact"
                return 0
            fi
        fi
    fi
    return 1
}

# RAW 에서 마지막 VERDICT 라인만 취한다(프롬프트 에코 없음 → 안내 예시 오염 없음).
parse_verdict() {
    local raw="$1"
    if [[ -z "$raw" ]]; then printf ''; return 0; fi
    printf '%s\n' "$raw" \
        | grep -oiE 'VERDICT:[[:space:]]*(CONFIRMED|REFUTED|UNCERTAIN)' \
        | tail -1 \
        | grep -oiE '(CONFIRMED|REFUTED|UNCERTAIN)' \
        | tr '[:lower:]' '[:upper:]' || true
}

# 무응답 원인 분류 — 판정이 아니라 "왜 회수 못 했나"를 원장에 남긴다(위조 금지).
classify_fail() {
    local ask_exit="$1" run_tid="$2" last status
    case "$ask_exit" in
        124) printf 'timeout(하드캡 %ss 초과)' "$HARD_CAP"; return 0 ;;
        99)  printf 'circuit_open(연속실패 차단)';          return 0 ;;
        98)  printf 'duplicate_blocked(중복요청가드)';       return 0 ;;
        2)   printf 'auth/budget/deps(비재시도 대상)';       return 0 ;;
    esac
    last=$(grep -F "\"task\":\"${run_tid}\"" "$RUNNER_LOG" 2>/dev/null | tail -1 || true)
    status=$(printf '%s' "$last" | jq -r '.status // "?"' 2>/dev/null || echo '?')
    case "$status" in
        blocked) printf 'guard_blocked:%s' "$(printf '%s' "$last" | jq -r '.msg // ""' 2>/dev/null | head -c 80)" ;;
        skip)    printf 'skipped(circuit/idempotency)' ;;
        timeout) printf 'timeout' ;;
        error)   printf 'error:%s' "$(printf '%s' "$last" | jq -r '.msg // ""' 2>/dev/null | head -c 80)" ;;
        start)   printf 'died_before_completion(set-e/guard, exit=%s)' "$ask_exit" ;;
        success) printf 'post_ok_but_stdout_empty_no_artifact(회수실패)' ;;
        *)       printf 'unknown(exit=%s)' "$ask_exit" ;;
    esac
    return 0
}

# 단일 검증 실행 (1회 + 무응답 시 조건부 재시도 1회).
# 유형 B 근본수정: 매 시도 고유 task-id 로 소환 → 중복/멱등/서킷 가드가 claude 실행 전
#   조기종료(빈 출력)시키던 간섭을 제거. VERA 호출은 본질적으로 매번 별개 검증이므로 정당.
# 출력(stdout 1줄 컴팩트 JSON): {verdict, source, ask_exit, raw_bytes, duration_ms, fail_reason, evidence, run_id}
#   (모든 로그는 log() 로 stderr 로만 나가므로 stdout 오염 없음 → 병렬 팀 모드에서 파일 캡처 안전)
run_verification() {
    local lens="$1" label="$2"
    local prompt; prompt=$(build_prompt "$lens")
    local verdict='' raw='' source='stdout' ask_exit=0 fail='' evid=''
    local run_tid start_epoch start_ms end_ms dur_ms=0 n
    for n in 1 2; do
        run_tid="${TASK_ID}-${label}$(date +%s)-$$-a${n}"
        start_epoch=$(date +%s)
        start_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
        ask_exit=0
        raw=$(gtimeout "${HARD_CAP}s" "$ASK_CLAUDE" \
                "$run_tid" "$prompt" "$TOOLS" "$TIMEOUT" "$BUDGET" "1" "$MODEL" \
                2>/dev/null) || ask_exit=$?
        end_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
        dur_ms=$(( end_ms - start_ms ))
        _RAW=''; _RESULT_SOURCE='stdout'
        recover_raw "$run_tid" "$start_epoch" "$raw" || true
        raw="$_RAW"; source="$_RESULT_SOURCE"
        if [[ -n "$raw" ]]; then break; fi
        # 무응답 — 원인 분류 후 재시도 판단.
        fail=$(classify_fail "$ask_exit" "$run_tid")
        # 인증/예산(exit 2)은 재시도 무의미. 그 외 무응답은 fresh task-id 로 1회 재시도.
        if [[ "$n" -ge 2 || "$ask_exit" == "2" ]]; then break; fi
        log "↻ 무응답(${fail}) → 재시도 (fresh task-id)"
    done
    verdict=$(parse_verdict "$raw")
    # 판정 위조 금지: RAW 가 끝내 비면 실패로 남긴다. RAW 는 있으나 판정 라인이 없으면 UNCERTAIN.
    if [[ -z "$raw" ]]; then
        verdict="VERIFY_FAILED"
    elif [[ -z "$verdict" ]]; then
        verdict="UNCERTAIN"; fail="no_verdict_line(RAW 존재하나 판정 라인 없음)"
    fi
    # 근거 발췌 (EVIDENCE 라인 우선, 없으면 원문 앞부분)
    evid=$(printf '%s\n' "$raw" | grep -iE '(^|\*\*|[[:space:]])EVIDENCE:' | sed 's/^[[:space:]*]*//' | head -3 || true)
    if [[ -z "$evid" ]]; then evid=$(printf '%s' "$raw" | head -c 500); fi
    local raw_bytes evid_trunc
    raw_bytes=$(printf '%s' "$raw" | wc -c | tr -d ' ')
    evid_trunc=$(printf '%s' "$evid" | head -c 800)
    # 컴팩트 JSON 1줄로 출력. jq 가 탭·개행·따옴표를 안전하게 이스케이프하므로
    # 빈 필드 붕괴(탭=IFS 공백문자로 인한 read 오정렬)나 구분자 충돌이 원천적으로 없다.
    jq -cn \
        --arg verdict "$verdict" \
        --arg source "$source" \
        --argjson ask_exit "${ask_exit:-0}" \
        --argjson raw_bytes "${raw_bytes:-0}" \
        --argjson duration_ms "${dur_ms:-0}" \
        --arg fail_reason "$fail" \
        --arg evidence "$evid_trunc" \
        --arg run_id "$run_tid" \
        '{verdict:$verdict, source:$source, ask_exit:$ask_exit, raw_bytes:$raw_bytes,
          duration_ms:$duration_ms, fail_reason:$fail_reason, evidence:$evidence, run_id:$run_id}'
}

# 판정 → 아이콘 + 종료코드 (echo 로 개행 포함 → set -e 하에서 read 안전)
verdict_icon_exit() {
    case "$1" in
        CONFIRMED) echo "✅ 0" ;;
        REFUTED)   echo "❌ 3" ;;
        UNCERTAIN) echo "❔ 4" ;;
        *)         echo "⚠️ 1" ;;  # VERIFY_FAILED
    esac
}

# ==============================================================================
CLAIM_TRUNC=$(printf '%s' "$CLAIM" | head -c 400)
if [[ -n "$CONTEXT" ]]; then CONTEXT_PRESENT="true"; else CONTEXT_PRESENT="false"; fi
mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || true

if [[ "$TEAM" != true ]]; then
    # ===== 단일 모드 (기본 · 하위호환) =====
    RJSON=$(run_verification "" "")
    VERDICT=$(printf '%s' "$RJSON" | jq -r '.verdict')
    RESULT_SOURCE=$(printf '%s' "$RJSON" | jq -r '.source')
    ASK_EXIT=$(printf '%s' "$RJSON" | jq -r '.ask_exit')
    DURATION_MS=$(printf '%s' "$RJSON" | jq -r '.duration_ms')
    FAIL_REASON=$(printf '%s' "$RJSON" | jq -r '.fail_reason')
    EVIDENCE=$(printf '%s' "$RJSON" | jq -r '.evidence')

    # 원장: run_verification 이 낸 JSON 에 호출 메타를 덧붙여 1줄 기록.
    printf '%s' "$RJSON" | jq -c \
        --arg ts "$(date -u +%FT%TZ)" \
        --arg tool "jarvis-verify-independent" \
        --arg task "$TASK_ID" \
        --arg mode "single" \
        --arg claim "$CLAIM_TRUNC" \
        --arg context_present "$CONTEXT_PRESENT" \
        --arg model "$MODEL" \
        --arg tools "$TOOLS" \
        '{ts:$ts, tool:$tool, task:$task, run_id:.run_id, mode:$mode, claim:$claim,
          context_present:$context_present, model:$model, tools:$tools, verdict:.verdict,
          evidence:.evidence, source:.source, fail_reason:.fail_reason,
          ask_exit:.ask_exit, raw_bytes:.raw_bytes, duration_ms:.duration_ms}' \
        >> "$LEDGER_FILE" 2>/dev/null || log "⚠️  ledger 기록 실패(비차단): $LEDGER_FILE"

    read -r ICON EXIT_CODE < <(verdict_icon_exit "$VERDICT")
    echo ""
    echo "${ICON} 독립 검증 판정: ${VERDICT}"
    echo "   주장: ${CLAIM_TRUNC}"
    echo "   모델: ${MODEL} · 소요 ${DURATION_MS}ms · 판정소스=${RESULT_SOURCE} · ask-claude exit=${ASK_EXIT}"
    if [[ "$VERDICT" == "VERIFY_FAILED" && -n "$FAIL_REASON" ]]; then echo "   무응답 원인: ${FAIL_REASON}"; fi
    echo "   근거:"
    printf '%s\n' "$EVIDENCE" | sed 's/^/     /'
    echo "   원장: ${LEDGER_FILE}"
    echo ""
    exit "$EXIT_CODE"
fi

# ===== 팀 모드 (--team · 다각도 다수결 · 비용 ~3배) =====
log "👥 팀 검증 — 3개 렌즈 병렬 소환 (비용 약 3배 · 고위험/명시 요청 전용)"
TEAM_TMP=$(mktemp -d)
trap 'rm -rf "$TEAM_TMP"' EXIT

LENS_A="결정론 상태 실측 렌즈. 오직 파일 존재(test -e; echo \$?), 명령 exit code, grep 패턴 일치, launchctl/pgrep 가동 여부만으로 판정하라. 해석·추론·문맥은 배제한다."
LENS_B="재현·역추적 렌즈. 주장이 만들어졌을 경로를 역으로 재현하라. 산출물(파일·커밋)이 있으면 직접 열어 내용까지 대조하고, git log·수정시각으로 시점을 역추적해 주장과 맞대어라."
LENS_C="반증 시도 렌즈. 먼저 주장이 '거짓'이라 가정하고 거짓임을 입증할 반례를 적극적으로 찾아라. 반례를 끝내 못 찾았을 때만 CONFIRMED 를 허용한다."

run_verification "$LENS_A" "tA-" > "${TEAM_TMP}/a" & PID_A=$!
run_verification "$LENS_B" "tB-" > "${TEAM_TMP}/b" & PID_B=$!
run_verification "$LENS_C" "tC-" > "${TEAM_TMP}/c" & PID_C=$!
wait "$PID_A" "$PID_B" "$PID_C" 2>/dev/null || true

M_LENS=("결정론실측" "재현역추적" "반증시도")
M_FILE=("${TEAM_TMP}/a" "${TEAM_TMP}/b" "${TEAM_TMP}/c")
nC=0; nR=0; nU=0; nF=0
BREAKDOWN="[]"
for i in 0 1 2; do
    mjson=$(cat "${M_FILE[$i]}" 2>/dev/null || true)
    mlens="${M_LENS[$i]}"
    # 멤버 서브셸이 아무 출력도 못 냈으면(비정상 종료) 실패로 간주하는 안전 기본값.
    if ! printf '%s' "$mjson" | jq -e . >/dev/null 2>&1; then
        mjson='{"verdict":"VERIFY_FAILED","source":"none","ask_exit":0,"raw_bytes":0,"duration_ms":0,"fail_reason":"no_output(member subshell)","evidence":"","run_id":""}'
    fi
    mv=$(printf '%s' "$mjson" | jq -r '.verdict // "VERIFY_FAILED"')
    case "$mv" in
        CONFIRMED) nC=$((nC+1)) ;;
        REFUTED)   nR=$((nR+1)) ;;
        UNCERTAIN) nU=$((nU+1)) ;;
        *)         nF=$((nF+1)) ;;
    esac
    member=$(printf '%s' "$mjson" | jq -c --arg lens "$mlens" \
        '{lens:$lens, verdict, source, ask_exit, raw_bytes, duration_ms, fail_reason, evidence:(.evidence[0:300])}')
    BREAKDOWN=$(printf '%s' "$BREAKDOWN" | jq -c --argjson mem "$member" '. + [$mem]')
done

# 다수결 (3표 중 과반 = 2표). 갈리거나 과반 미달이면 UNCERTAIN.
if   [[ "$nR" -ge 2 ]]; then TEAM_VERDICT="REFUTED"
elif [[ "$nC" -ge 2 ]]; then TEAM_VERDICT="CONFIRMED"
else TEAM_VERDICT="UNCERTAIN"; fi

jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg tool "jarvis-verify-independent" \
    --arg task "$TASK_ID" \
    --arg mode "team" \
    --arg claim "$CLAIM_TRUNC" \
    --arg context_present "$CONTEXT_PRESENT" \
    --arg model "$MODEL" \
    --arg tools "$TOOLS" \
    --arg verdict "$TEAM_VERDICT" \
    --argjson breakdown "$BREAKDOWN" \
    --argjson n_confirmed "$nC" \
    --argjson n_refuted "$nR" \
    --argjson n_uncertain "$nU" \
    --argjson n_failed "$nF" \
    '{ts:$ts, tool:$tool, task:$task, mode:$mode, claim:$claim, context_present:$context_present,
      model:$model, tools:$tools, verdict:$verdict,
      tally:{confirmed:$n_confirmed, refuted:$n_refuted, uncertain:$n_uncertain, failed:$n_failed},
      team_breakdown:$breakdown}' \
    >> "$LEDGER_FILE" 2>/dev/null || log "⚠️  ledger 기록 실패(비차단): $LEDGER_FILE"

read -r ICON EXIT_CODE < <(verdict_icon_exit "$TEAM_VERDICT")
echo ""
echo "${ICON} 팀 독립 검증 판정(다수결): ${TEAM_VERDICT}"
echo "   주장: ${CLAIM_TRUNC}"
echo "   집계: CONFIRMED=${nC} · REFUTED=${nR} · UNCERTAIN=${nU} · FAILED=${nF} (3표 중 과반=2)"
echo "   렌즈별:"
printf '%s' "$BREAKDOWN" | jq -r '.[] | "     - \(.lens): \(.verdict)" + (if .fail_reason != "" then "  [" + .fail_reason + "]" else "" end)'
echo "   원장: ${LEDGER_FILE}"
echo ""
exit "$EXIT_CODE"
