#!/usr/bin/env bash
# update-usage-cache.sh — Claude API 사용량 캐시 30분 갱신
# ~/.claude/scripts/update-usage-cache.py 를 호출해 ~/.claude/usage-cache.json 갱신
# Usage: update-usage-cache.sh
set -euo pipefail

SCRIPT="$HOME/.claude/scripts/update-usage-cache.py"
CACHE="$HOME/.claude/usage-cache.json"

if [[ ! -f "$SCRIPT" ]]; then
    echo "update-usage-cache.py 없음: $SCRIPT"
    exit 1
fi

python3 "$SCRIPT"

# 갱신 결과 확인
if [[ -f "$CACHE" ]]; then
    OK=$(python3 -c "import json,sys; d=json.load(open('$CACHE')); print('ok' if d.get('ok') else 'fail: '+str(d.get('error','')))" 2>/dev/null || echo "parse error")
    echo "usage-cache 갱신 완료: $OK"
else
    echo "usage-cache 갱신 실패: 파일 없음"
    exit 1
fi
