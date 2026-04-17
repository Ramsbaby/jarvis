#!/usr/bin/env bash
# lint-gate.sh — 파일 단위 문법/참조 검증 (SSoT)
#
# 사용처: pre-commit hook, PostToolUse hook, run_syntax_gate()
# 사용법: source lint-gate.sh; lint_file "/path/to/file.sh"
# 반환: 0=통과, 1=에러 (에러 내용은 stdout 출력)

_LINT_ESLINT_CONFIG="${_LINT_ESLINT_CONFIG:-${BOT_HOME:-${HOME}/jarvis/runtime}/config/eslint-gate.config.mjs}"
_LINT_BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

lint_file() {
    local full_path="$1"
    [[ -f "$full_path" ]] || return 0

    local ext="${full_path##*.}"
    local _out="" _errors=0 _messages=""

    case "$ext" in
        sh|bash)
            # Phase 1: 기본 문법 (fi 중복, 괄호 불일치 등)
            if ! _out=$(bash -n "$full_path" 2>&1); then
                _messages="${_messages}[bash -n] ${full_path}: ${_out}\n"
                _errors=$((_errors + 1))
            fi

            # Phase 2: set -e 환경에서 [[ ]] && cmd 안티패턴
            if grep -qE '^[[:space:]]*set -[a-zA-Z]*e' "$full_path" 2>/dev/null; then
                local bad_lines
                bad_lines=$(grep -nE '\[\[.*\]\]\s*&&\s*[^|]' "$full_path" 2>/dev/null \
                    | grep -v '^[0-9]*:[[:space:]]*#' \
                    | grep -v '^[0-9]*:[[:space:]]*if ' \
                    | grep -v '^[0-9]*:[[:space:]]*elif ' \
                    | grep -v '||[[:space:]]*true' || true)
                if [[ -n "$bad_lines" ]]; then
                    _messages="${_messages}[set-e-pattern] ${full_path}:\n${bad_lines}\nFIX: if [[ cond ]]; then cmd; fi\n"
                    _errors=$((_errors + 1))
                fi
            fi
            ;;

        js|mjs|cjs)
            # Phase 1: Node.js 구문 검사
            if ! _out=$(node --check "$full_path" 2>&1); then
                _messages="${_messages}[node --check] ${full_path}: ${_out}\n"
                _errors=$((_errors + 1))
            else
                # Phase 2: ESLint no-undef (ReferenceError 사전 차단)
                if command -v eslint >/dev/null 2>&1 && [[ -f "$_LINT_ESLINT_CONFIG" ]]; then
                    if ! _out=$(cd "$_LINT_BOT_HOME" && eslint --config "$_LINT_ESLINT_CONFIG" "$full_path" 2>&1); then
                        # error 레벨만 블로킹 (warn은 통과)
                        if echo "$_out" | grep -q " error "; then
                            _messages="${_messages}[eslint] ${full_path}: ${_out:0:300}\n"
                            _errors=$((_errors + 1))
                        fi
                    fi
                fi
            fi
            ;;

        py)
            if ! _out=$(python3 -m py_compile "$full_path" 2>&1); then
                _messages="${_messages}[py_compile] ${full_path}: ${_out:0:300}\n"
                _errors=$((_errors + 1))
            fi
            ;;

        json)
            if ! _out=$(node -e "
                try { JSON.parse(require('fs').readFileSync(0, 'utf8')); }
                catch(e) { console.error(e.message); process.exit(1); }
            " < "$full_path" 2>&1); then
                _messages="${_messages}[json] ${full_path}: ${_out:0:300}\n"
                _errors=$((_errors + 1))
            fi
            ;;
    esac

    if (( _errors > 0 )); then
        printf '%b' "$_messages"
        return 1
    fi
    return 0
}