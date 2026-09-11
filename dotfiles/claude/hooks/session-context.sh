#!/bin/bash
set -euo pipefail
# SessionStart hook: 세션 시작 시 유용한 컨텍스트 로딩
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

# active-work.json 로드 (resume 포함 모든 세션)
ACTIVE_WORK_CONTEXT=""
ACTIVE_WORK_PATH="${HOME}/.jarvis/state/active-work.json"
if [[ -f "$ACTIVE_WORK_PATH" ]]; then
    ACTIVE_WORK_CONTEXT=$(python3 - 2>/dev/null << 'AWEOF'
import json, os
from datetime import datetime, timezone

path = os.path.expanduser('~/.jarvis/state/active-work.json')
try:
    d = json.load(open(path))
    updated  = d.get('updated_at', '')
    files    = d.get('modified_files', [])
    last_req = d.get('last_user_request', '')
    last_sum = d.get('last_work_summary', '')

    # 세션 타입 필터: Discord 봇 세션에는 Discord 작업만, CLI 세션에는 CLI 작업만
    import os as _os
    _cwd = _os.environ.get('PWD', '')
    _current_type = 'discord' if 'claude-discord' in _cwd else 'cli'
    _saved_type = d.get('session_type', 'cli')
    if _current_type != _saved_type:
        print('')
        import sys as _sys; _sys.exit(0)

    dt = datetime.fromisoformat(updated.replace('Z', '+00:00')).astimezone()
    time_str = dt.strftime('%m/%d %H:%M')

    files_str = ', '.join(files[:5])
    if len(files) > 5:
        files_str += f' 외 {len(files)-5}개'

    parts = [f'\u26a1 이전 작업 미완료 ({time_str}) | 수정파일: {files_str}']
    if last_req:
        parts.append(f'마지막 요청: {last_req[:120]}')
    if last_sum:
        parts.append(f'진행상태: {last_sum[:120]}')

    print(' | '.join(parts))
except Exception:
    print('')
AWEOF
    )
fi

# resume이면 컨텍스트 간소화 (단, active-work는 항상 인젝션)
if [ "$SOURCE" = "resume" ]; then
    if [[ -n "$ACTIVE_WORK_CONTEXT" ]]; then
        python3 - "$ACTIVE_WORK_CONTEXT" << 'PYEOF'
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
PYEOF
    else
        echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"세션 재개됨. 이전 컨텍스트 유지."}}'
    fi
    exit 0
fi

# 세션 시작 타임스탬프 기록 (stop-changelog.sh가 변경 파일 탐지에 사용)
touch "${HOME}/.jarvis/state/.claude-session-start" 2>/dev/null || true

# doc-debt.json 새 세션 초기화 (이전 세션 빚은 pending-doc-updates.json이 담당)
python3 - "${HOME}/.jarvis/state/doc-debt.json" <<'PYEOF' 2>/dev/null || true
import json, sys, datetime
path = sys.argv[1]
with open(path, "w") as f:
    json.dump({"session_start": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "debts": {}}, f, indent=2, ensure_ascii=False)
PYEOF

# 현재 날짜/시간
NOW=$(date "+%Y-%m-%d %H:%M (%a)")

# Jarvis 최근 크론 상태 (마지막 5건)
CRON_LOG="$HOME/.jarvis/logs/cron.log"
CRON_STATUS="없음"
if [ -f "$CRON_LOG" ]; then
  TOTAL=$(grep -c "DONE\|SUCCESS" "$CRON_LOG" 2>/dev/null | tr -d ' ' || echo 0)
  FAILURES=$(grep -c "FAIL\|ERROR" "$CRON_LOG" 2>/dev/null | tr -d ' ' || echo 0)
  CRON_STATUS="${TOTAL}건 완료, ${FAILURES}건 실패"
fi

# Jarvis Discord bot 상태
BOT_STATUS="unknown"
if launchctl list ai.jarvis.discord-bot 2>/dev/null | grep -q "PID"; then
  BOT_STATUS="✅ running"
else
  BOT_STATUS="❌ down"
fi

# ── 세션 타입 판별 (이하 블록 전체에서 사용) ────────────────────────────────
_CURRENT_CWD=$(pwd 2>/dev/null || echo "")
_IS_DISCORD_SESSION=false
if [[ "$_CURRENT_CWD" == *"claude-discord"* ]]; then _IS_DISCORD_SESSION=true; fi

# pending lint 자동수정 체크 (CLI 세션 전용 — Discord 세션 오염 방지)
PENDING_LINT="${HOME}/.jarvis/state/pending-lint-fixes.txt"
LINT_CONTEXT=""
if [[ "$_IS_DISCORD_SESSION" == "false" ]] && [[ -f "$PENDING_LINT" ]]; then
  LINT_ERRORS=$(cat "$PENDING_LINT" | tr '\n' ' ')
  if [[ -n "$LINT_ERRORS" ]]; then
    LINT_CONTEXT=" | 🔧 이전 세션 lint 오류 자동수정 필요: ${LINT_ERRORS}— 해당 파일 즉시 수정 후 rm -f ${PENDING_LINT}"
  fi
  rm -f "$PENDING_LINT"
fi

# pending-doc-updates.json 체크 (CLI 세션 전용 — Discord 세션 오염 방지)
PENDING_UPDATES="${HOME}/.jarvis/state/pending-doc-updates.json"
PENDING_CONTEXT=""
if [[ "$_IS_DISCORD_SESSION" == "false" ]] && [[ -f "$PENDING_UPDATES" ]]; then
    pending_info=$(python3 "${HOME}/.jarvis/state/.session-pending-check.py" "$PENDING_UPDATES" 2>/dev/null || echo "")
    if [[ -n "$pending_info" ]]; then PENDING_CONTEXT=" | ${pending_info}"; fi
fi

# commitments.jsonl 체크 (CLI 세션 전용 — Discord 세션 오염 방지)
COMMITMENTS="${HOME}/.jarvis/state/commitments.jsonl"
COMMIT_CONTEXT=""
if [[ "$_IS_DISCORD_SESSION" == "false" ]] && [[ -f "$COMMITMENTS" ]]; then
    open_count=$(grep -c '"status":"open"' "$COMMITMENTS" 2>/dev/null || echo 0)
    if [[ "$open_count" -gt 0 ]]; then COMMIT_CONTEXT=" | 📋 미이행 약속 ${open_count}건 — commitments.jsonl 이행 필요"; fi
fi

# proposals.jsonl 체크 (CLI 세션 전용 — SRE/팀들이 올린 개발팀 제안 큐)
PROPOSALS="${HOME}/.jarvis/state/proposals.jsonl"
PROPOSAL_CONTEXT=""
if [[ "$_IS_DISCORD_SESSION" == "false" ]] && [[ -f "$PROPOSALS" ]]; then
    pending_count=$(awk '/"status":"pending"/{c++} END{print c+0}' "$PROPOSALS" 2>/dev/null || echo 0)
    if [[ "$pending_count" -gt 0 ]]; then
        pending_titles=$(awk '/"status":"pending"/' "$PROPOSALS" 2>/dev/null | jq -r '"[\(.from)] \(.title)"' 2>/dev/null | head -3 | tr '\n' ';' | sed 's/;$//' || echo "")
        PROPOSAL_CONTEXT=" | 🗂️ 대기 제안 ${pending_count}건 (${pending_titles}) — proposal-list.sh로 검토, --approve/--reject로 처리"
    fi
fi

# Discord 채널 히스토리 자동 주입 (Discord 봇 세션 전용)
DISCORD_HISTORY_CONTEXT=""
if [[ "$_IS_DISCORD_SESSION" == "true" ]]; then
    DISCORD_HISTORY_CONTEXT=$(python3 - 2>/dev/null << 'DHEOF'
import os, glob

history_dir = os.path.expanduser('~/.jarvis/context/discord-history')
pattern = os.path.join(history_dir, '2*.md')
files = sorted(glob.glob(pattern))
if not files:
    print('')
else:
    latest = files[-1]
    try:
        lines = open(latest, 'r').readlines()
        recent = ''.join(lines[-80:]).strip()
        if recent:
            preview = recent[:1200].replace('\n', ' ↩ ')
            print(f'📋 채널 히스토리 (최근): {preview}')
        else:
            print('')
    except Exception:
        print('')
DHEOF
    )
fi

# compact-summaries.md 마지막 요약 로드
COMPACT_CONTEXT=""
COMPACT_PATH="${HOME}/.jarvis/docs/compact-summaries.md"
if [[ -f "$COMPACT_PATH" ]]; then
    COMPACT_CONTEXT=$(python3 - 2>/dev/null << 'CSEOF'
import os, re

path = os.path.expanduser('~/.jarvis/docs/compact-summaries.md')
try:
    text = open(path, 'r').read()
    sections = re.split(r'(?=^## \d{4}-\d{2}-\d{2})', text, flags=re.MULTILINE)
    sections = [s.strip() for s in sections if s.strip()]
    if not sections:
        print('')
    else:
        last = sections[-1]
        header_match = re.match(r'^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2}).*session:(\S+)', last)
        header_str = header_match.group(1) if header_match else '?'
        body = re.sub(r'</?analysis>', '', last)
        body = re.sub(r'^## .+\n', '', body, count=1)
        body = body.strip()
        summary = body[:600].replace('\n', ' ').strip()
        if len(body) > 600:
            summary += '\u2026'
        print(f'\U0001f4dd 이전 세션 요약 ({header_str}): {summary}')
except Exception:
    print('')
CSEOF
)
fi

# 컨텍스트 구성
# active-work 컨텍스트를 맨 앞에 배치 (가장 중요한 정보)
COMPACT_SUFFIX=""
if [[ -n "$COMPACT_CONTEXT" ]]; then COMPACT_SUFFIX=" | ${COMPACT_CONTEXT}"; fi

DISCORD_SUFFIX=""
if [[ -n "$DISCORD_HISTORY_CONTEXT" ]]; then DISCORD_SUFFIX=" | ${DISCORD_HISTORY_CONTEXT}"; fi

# Phase 0.5: 오너 교정(corrections) 로드 — Discord에서 쌓인 교정도 CLI 프롬프트에 반영
# ~/.jarvis/bin → ~/.openclaw-data/jarvis/infra/bin 심링크
CORRECTIONS_CONTEXT=""
FEEDBACK_CLI="${HOME}/.jarvis/bin/feedback-loop-cli.mjs"
if [[ -x "$FEEDBACK_CLI" ]]; then
    CORRECTIONS_CONTEXT=$(node "$FEEDBACK_CLI" --dump-corrections 2>/dev/null || true)
fi
CORRECTIONS_SUFFIX=""
if [[ -n "$CORRECTIONS_CONTEXT" ]]; then CORRECTIONS_SUFFIX=" || ${CORRECTIONS_CONTEXT}"; fi

if [[ -n "$ACTIVE_WORK_CONTEXT" ]]; then
    CONTEXT="${ACTIVE_WORK_CONTEXT} || 현재: ${NOW} | Jarvis 크론: ${CRON_STATUS} | Discord bot: ${BOT_STATUS}${LINT_CONTEXT}${PENDING_CONTEXT}${COMMIT_CONTEXT}${PROPOSAL_CONTEXT}${COMPACT_SUFFIX}${DISCORD_SUFFIX}${CORRECTIONS_SUFFIX}"
else
    CONTEXT="현재: ${NOW} | Jarvis 크론: ${CRON_STATUS} | Discord bot: ${BOT_STATUS}${LINT_CONTEXT}${PENDING_CONTEXT}${COMMIT_CONTEXT}${PROPOSAL_CONTEXT}${COMPACT_SUFFIX}${DISCORD_SUFFIX}${CORRECTIONS_SUFFIX}"
fi

python3 - "$CONTEXT" <<'PYEOF'
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
PYEOF
exit 0
