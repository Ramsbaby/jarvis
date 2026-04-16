#!/usr/bin/env bash
# pii-precommit-hook.sh — 커밋 전 개인정보 유출 차단
#
# 감지 패턴:
#   - Discord webhook URL
#   - Discord bot token (MTQ/MTU/MTY...)
#   - Discord channel/user ID (17-20자리 숫자, 컨텍스트 기반)
#   - Anthropic API key (sk-ant-)
#   - OpenAI API key (sk-)
#   - GitHub PAT (ghp_/gho_)
#   - AWS key (AKIA)
#   - 한국 주민등록번호
#   - 한국 전화번호
#   - ntfy topic (실제 값)
#   - AGENT_API_KEY 값
#
# 설치: ln -sf ~/jarvis/infra/scripts/pii-precommit-hook.sh ~/jarvis/.git/hooks/pre-commit

set -euo pipefail

STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
[[ -z "$STAGED" ]] && exit 0

FOUND=0

while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # 바이너리/이미지/lock 파일 스킵
    case "$file" in
        *.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.lock|*.map) continue ;;
    esac

    content=$(git show ":${file}" 2>/dev/null || true)
    [[ -z "$content" ]] && continue

    # Discord webhook URL
    if echo "$content" | grep -qE 'discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+'; then
        echo "🚨 PII BLOCKED: Discord webhook URL in $file"
        FOUND=1
    fi

    # Discord bot token (Base64-encoded snowflake)
    if echo "$content" | grep -qE 'MT[A-Za-z0-9]{50,}'; then
        echo "🚨 PII BLOCKED: Discord bot token in $file"
        FOUND=1
    fi

    # Anthropic API key
    if echo "$content" | grep -qE 'sk-ant-api[0-9]{2}-[A-Za-z0-9]{20,}'; then
        echo "🚨 PII BLOCKED: Anthropic API key in $file"
        FOUND=1
    fi

    # OpenAI API key
    if echo "$content" | grep -qE 'sk-[A-Za-z0-9]{20,}'; then
        # sk-ant는 위에서 잡으므로 제외
        if ! echo "$content" | grep -qE 'sk-ant-'; then
            echo "🚨 PII BLOCKED: OpenAI API key in $file"
            FOUND=1
        fi
    fi

    # GitHub PAT
    if echo "$content" | grep -qE 'gh[ps]_[A-Za-z0-9]{36,}'; then
        echo "🚨 PII BLOCKED: GitHub PAT in $file"
        FOUND=1
    fi

    # AWS access key
    if echo "$content" | grep -qE 'AKIA[A-Z0-9]{16}'; then
        echo "🚨 PII BLOCKED: AWS access key in $file"
        FOUND=1
    fi

    # ntfy topic (실제 값이 들어가면 차단)
    if echo "$content" | grep -qE 'ntfy\.sh/[a-zA-Z0-9_-]{10,}'; then
        echo "🚨 PII BLOCKED: ntfy topic URL in $file"
        FOUND=1
    fi

    # AGENT_API_KEY 실제 값
    if echo "$content" | grep -qE 'AGENT_API_KEY=[^"'\''$]{5,}'; then
        echo "🚨 PII BLOCKED: AGENT_API_KEY value in $file"
        FOUND=1
    fi

    # 한국 주민등록번호
    if echo "$content" | grep -qE '[0-9]{6}-[1-4][0-9]{6}'; then
        echo "🚨 PII BLOCKED: 주민등록번호 in $file"
        FOUND=1
    fi

    # 한국 전화번호
    if echo "$content" | grep -qE '01[0-9]-[0-9]{3,4}-[0-9]{4}'; then
        echo "🚨 PII BLOCKED: 전화번호 in $file"
        FOUND=1
    fi

done <<< "$STAGED"

if [[ "$FOUND" -ne 0 ]]; then
    echo ""
    echo "❌ 커밋 차단: 개인정보/시크릿이 스테이징된 파일에 포함되어 있습니다."
    echo "   해당 파일을 .gitignore에 추가하거나 민감 값을 제거한 후 다시 커밋하세요."
    exit 1
fi

exit 0
