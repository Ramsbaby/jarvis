#!/usr/bin/env bash
# diagnose-context-overflow.sh — 세션 크기 초과 오진단 방지 진단 스크립트
#
# 클러스터 가드: cl-6bfbff665fd9f99a (표면 증상 진단 / 근본 원인 누락)
# 반복 실수: "세션 크기 초과"를 증상으로 보고 근본 원인인
#            1M 컨텍스트 강제 활성화(contextWindow 설정)를 간과
#
# 목적:
#   세션 크기 초과 오류 발생 시 컨텍스트 관련 설정 값을 읽어
#   stdout에 출력한다. 이 스크립트는 'TOO_LONG / 세션 크기 초과'
#   진단 루틴의 첫 번째 단계로 의무 실행되어야 한다.
#
# 사용법:
#   diagnose-context-overflow.sh [TASK_ID] [STDERR_FILE]
#
# 출력 (stdout):
#   [CONTEXT-DIAG] 섹션으로 구분된 설정 값 + 근본 원인 힌트
#
# 종료 코드:
#   0 — 항상 성공 (진단 도구이므로 오류로 중단하지 않음)
#
# 설계 원칙:
#   - 읽기 전용 (설정 변경 없음)
#   - 실패해도 exit 0 (호출 워크플로를 중단시키지 않음)
#   - 기존 크론·태스크 스크립트에 영향 없음
#
# 추가일: 2026-06-14 (cl-6bfbff665fd9f99a 가드)

set -uo pipefail

TASK_ID="${1:-UNKNOWN}"
STDERR_FILE="${2:-}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

# ── 유틸 ──────────────────────────────────────────────────────────────────────

_diag_log() {
    printf '[CONTEXT-DIAG] %s\n' "$1"
}

_diag_section() {
    printf '\n[CONTEXT-DIAG] ══════ %s ══════\n' "$1"
}

_diag_kv() {
    local key="$1" val="$2" source="$3"
    printf '[CONTEXT-DIAG]   %-30s = %-20s  (출처: %s)\n' "$key" "$val" "$source"
}

# ── 시작 ──────────────────────────────────────────────────────────────────────

_diag_section "컨텍스트 오버플로 근본 원인 진단 시작"
_diag_log "태스크 ID : ${TASK_ID}"
_diag_log "실행 시각 : $(date '+%F %H:%M:%S %Z')"

# ── 1. model-router.mjs 에서 contextWindow 설정 읽기 ─────────────────────────

_diag_section "1) model-router.mjs — contextWindow 설정"

MODEL_ROUTER="${BOT_HOME}/lib/model-router.mjs"
if [[ ! -f "$MODEL_ROUTER" ]]; then
    MODEL_ROUTER="${HOME}/jarvis/infra/lib/model-router.mjs"
fi

if [[ -f "$MODEL_ROUTER" ]]; then
    # contextWindow 값 추출
    while IFS= read -r line; do
        if [[ "$line" =~ contextWindow ]]; then
            _diag_log "  $line"
        fi
    done < "$MODEL_ROUTER"

    # 모델별 contextWindow 요약
    _diag_log ""
    _diag_log "  [모델 contextWindow 요약]"
    # python3로 contextWindow 추출 (node 의존 없이)
    python3 - "$MODEL_ROUTER" <<'PYEOF' 2>/dev/null || true
import re, sys
src = open(sys.argv[1]).read()
# 각 모델 블록에서 key + contextWindow 추출
entries = re.findall(r"'([^']+)':\s*\{[^}]*contextWindow:\s*([\d_]+)", src)
for key, cw_raw in entries:
    cw = int(cw_raw.replace('_', ''))
    label = "WARNING: 1M (세션 크기 과소평가 위험)" if cw >= 1_000_000 else "200K"
    print(f"[CONTEXT-DIAG]   {key:<22} | contextWindow={cw:>10,} | {label}")
PYEOF
else
    _diag_log "  WARN: model-router.mjs 를 찾을 수 없음 (경로: ${MODEL_ROUTER})"
fi

# ── 2. llm-gateway.sh — 활성 모델 및 context 관련 플래그 ─────────────────────

_diag_section "2) llm-gateway.sh — 활성 컨텍스트 설정"

LLM_GATEWAY="${BOT_HOME}/lib/llm-gateway.sh"
if [[ ! -f "$LLM_GATEWAY" ]]; then
    LLM_GATEWAY="${HOME}/jarvis/infra/lib/llm-gateway.sh"
fi

if [[ -f "$LLM_GATEWAY" ]]; then
    # 1M 컨텍스트 관련 주석/설정 출력
    grep -n "1M\|1_000_000\|1000000\|contextWindow\|context.window\|CONTEXT_WINDOW\|maxContext\|MAX_CONTEXT" \
        "$LLM_GATEWAY" 2>/dev/null | head -20 | \
        while IFS= read -r ln; do printf '[CONTEXT-DIAG]   %s\n' "$ln"; done || true
else
    _diag_log "  WARN: llm-gateway.sh 를 찾을 수 없음"
fi

# ── 3. context-loader.sh — JARVIS_CONTEXT_MODE 현재 값 ───────────────────────

_diag_section "3) context-loader.sh — JARVIS_CONTEXT_MODE"

_diag_kv "JARVIS_CONTEXT_MODE" "${JARVIS_CONTEXT_MODE:-(미설정=full)}" "환경변수"

CTX_LOADER="${BOT_HOME}/lib/context-loader.sh"
if [[ ! -f "$CTX_LOADER" ]]; then
    CTX_LOADER="${HOME}/jarvis/infra/lib/context-loader.sh"
fi

if [[ -f "$CTX_LOADER" ]]; then
    _diag_log "  context-loader.sh 컨텍스트 예산 관련 설정:"
    grep -n "CTX_BUDGET\|CONTEXT_MODE\|ctx_mode\|none\|minimal\|maxContext\|contextWindow\|MAX_CTX\|max_ctx\|CTX_MAX" \
        "$CTX_LOADER" 2>/dev/null | head -15 | \
        while IFS= read -r ln; do printf '[CONTEXT-DIAG]   %s\n' "$ln"; done || true
fi

# ── 4. tasks.json — 태스크별 maxContext / model 설정 ─────────────────────────

_diag_section "4) tasks.json — 태스크 컨텍스트 설정"

TASKS_JSON="${BOT_HOME}/config/tasks.json"
if [[ -f "$TASKS_JSON" && "$TASK_ID" != "UNKNOWN" ]]; then
    # python3로 태스크 설정 추출
    python3 - "$TASKS_JSON" "$TASK_ID" <<'PYEOF' 2>/dev/null || true
import json, sys
tasks_file, task_id = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(tasks_file))
    # tasks.json은 {"tasks": [...]} 또는 [...] 두 형태를 모두 지원
    tasks = data.get('tasks', data) if isinstance(data, dict) else data
    task = next((t for t in tasks if isinstance(t, dict) and t.get('id') == task_id), None)
    if task:
        keys = ['id', 'model', 'timeout', 'maxBudget', 'contextBudget',
                'contextFile', 'contextWindow', 'maxContext', 'maxContextTokens']
        print('[CONTEXT-DIAG]   태스크 컨텍스트 관련 설정:')
        for k in keys:
            if k in task:
                print(f'[CONTEXT-DIAG]   {k:<28} = {task[k]}')
    else:
        print(f'[CONTEXT-DIAG]   태스크 "{task_id}" 를 tasks.json에서 찾을 수 없음')
except Exception as e:
    print(f'[CONTEXT-DIAG]   tasks.json 파싱 실패: {e}')
PYEOF
else
    _diag_log "  WARN: tasks.json 없음 또는 TASK_ID 미지정"
fi

# ── 5. stderr 내용 분석 — 표면 증상 vs 근본 원인 ────────────────────────────

_diag_section "5) 에러 패턴 분석 (표면 증상 → 근본 원인 매핑)"

if [[ -n "$STDERR_FILE" && -f "$STDERR_FILE" ]]; then
    # 세션 크기 관련 패턴 감지
    if grep -qiE "context_length|too.long|too.large|session.*size|세션.*크기|prompt.{0,20}too" "$STDERR_FILE" 2>/dev/null; then
        _diag_log "  ⚠️  표면 증상 감지: '세션 크기 초과' / 'context too long'"
        _diag_log ""
        _diag_log "  ┌─ 근본 원인 체크리스트 ──────────────────────────────────┐"
        _diag_log "  │ [?] 사용 모델의 contextWindow가 200K인가 1M인가?         │"
        _diag_log "  │     → 위 1) 항목에서 실제 contextWindow 값 확인          │"
        _diag_log "  │ [?] 1M 컨텍스트 모델(Gemini/DeepSeek)로 라우팅됐는가?   │"
        _diag_log "  │     → 1M 설정이 '세션 크기 과소평가'의 근본 원인일 수 있음│"
        _diag_log "  │ [?] JARVIS_CONTEXT_MODE=minimal/none 적용됐는가?         │"
        _diag_log "  │     → 위 3) 항목에서 현재 모드 확인                      │"
        _diag_log "  └──────────────────────────────────────────────────────────┘"
        _diag_log ""
        _diag_log "  ⛔ 진단 원칙: '세션 크기 초과' = 표면 증상"
        _diag_log "      contextWindow·모델 설정을 먼저 확인하지 않고"
        _diag_log "      '2.xMB 파일로 200K 초과'로 단정하는 것은 오진단임."

        # 관련 stderr 줄 출력
        _diag_log ""
        _diag_log "  [stderr 관련 줄]"
        grep -iE "context_length|too.long|too.large|session.*size|세션.*크기|prompt.{0,20}too" \
            "$STDERR_FILE" 2>/dev/null | head -5 | \
            while IFS= read -r ln; do printf '[CONTEXT-DIAG]   STDERR> %s\n' "$ln"; done || true
    else
        _diag_log "  stderr에서 컨텍스트 초과 패턴 미감지 (파일: $STDERR_FILE)"
    fi
else
    _diag_log "  STDERR_FILE 미지정 또는 파일 없음 — 에러 패턴 분석 스킵"
fi

# ── 6. 최근 retry 분류 확인 ──────────────────────────────────────────────────

_diag_section "6) retry.jsonl — 최근 TOO_LONG 이벤트"

RETRY_LOG="${BOT_HOME}/logs/retry.jsonl"
if [[ -f "$RETRY_LOG" ]]; then
    python3 - "$RETRY_LOG" "$TASK_ID" <<'PYEOF' 2>/dev/null || true
import json, sys
retry_log, task_id = sys.argv[1], sys.argv[2]
events = []
try:
    with open(retry_log) as f:
        for line in f:
            try:
                obj = json.loads(line)
                if (obj.get('failure_class') in ('TOO_LONG', 'CONTEXT_TOO_LONG') or
                        obj.get('classification') == 'TOO_LONG'):
                    events.append(obj)
            except Exception:
                pass
except Exception as e:
    print(f'[CONTEXT-DIAG]   retry.jsonl 읽기 실패: {e}')
    sys.exit(0)

recent = events[-5:] if events else []
if recent:
    print(f'[CONTEXT-DIAG]   최근 TOO_LONG 이벤트 {len(events)}건 중 최신 {len(recent)}건:')
    for ev in recent:
        tid = ev.get('task_id', '?')
        ts = ev.get('timestamp', '?')
        fc = ev.get('failure_class', ev.get('classification', '?'))
        print(f'[CONTEXT-DIAG]   [{ts}] task={tid} class={fc}')
else:
    print('[CONTEXT-DIAG]   최근 TOO_LONG 이벤트 없음')
PYEOF
else
    _diag_log "  retry.jsonl 없음"
fi

# ── 마무리 ────────────────────────────────────────────────────────────────────

_diag_section "진단 완료"
_diag_log "위 항목을 확인 후 근본 원인(contextWindow/모델 설정)을 먼저 파악할 것."
_diag_log "표면 증상(세션 파일 크기)만으로 원인을 단정하지 말 것."
_diag_log ""

exit 0
