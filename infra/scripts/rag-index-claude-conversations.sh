#!/usr/bin/env bash
# rag-index-claude-conversations.sh
# Claude Code CLI 대화(.jsonl) → 마크다운 변환 → LanceDB 인덱싱
#
# 흐름:
#   1. ~/.claude/projects/**/*.jsonl (서브에이전트 제외) 스캔
#   2. 최근 DAYS_BACK일 이내 수정된 파일만 처리
#   3. human/assistant 턴 추출 → 대화 마크다운 생성
#   4. ~/.jarvis/context/claude-code-sessions/{project}/{session}.md 저장
#   5. rag-index.mjs 실행 (증분 인덱싱)
#
# Cron: 매 6시간 (bot-cron.sh rag-conv 태스크)

set -euo pipefail

# Homebrew PATH 설정 (크론 환경에서 node 명령어 사용 위함)
export PATH="/opt/homebrew/bin:$PATH"

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLAUDE_PROJECTS="${HOME}/.claude/projects"
OUT_BASE="${BOT_HOME}/context/claude-code-sessions"
LOG="${BOT_HOME}/logs/rag-conversations.log"
DAYS_BACK="${DAYS_BACK:-14}"
# /tmp/bot-work 같은 단명 태스크 경로는 제외, 실제 프로젝트만 인덱싱
PROJECT_PATTERN="${PROJECT_PATTERN:--Users-$(whoami)}"  # 현재 사용자 홈 디렉토리 프로젝트만

mkdir -p "$OUT_BASE" "$(dirname "$LOG")"
log() { printf '[%s] [rag-conv] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

if [[ ! -d "$CLAUDE_PROJECTS" ]]; then
  log "WARN ~/.claude/projects 없음"
  exit 0
fi

# ── JSONL → 마크다운 변환 (Python3) ──────────────────────────────────────────
# Claude Code JSONL 포맷:
#   type=="user":      message는 직접 string (또는 {content: string})
#   type=="assistant": message.content는 [{type:"text"|"thinking", text:"..."}, ...]
CONVERTER=$(cat <<'PYEOF'
import sys, json, os
from pathlib import Path
from datetime import datetime

def extract_user_text(message):
    """user 턴: message가 string이거나 {content: string}"""
    if isinstance(message, str):
        return message.strip()
    if isinstance(message, dict):
        content = message.get('content', '')
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            parts = [b.get('text', '') for b in content
                     if isinstance(b, dict) and b.get('type') == 'text']
            return '\n'.join(parts).strip()
    return ''

def extract_assistant_text(message):
    """assistant 턴: message.content는 [{type:"text"|"thinking", text:...}, ...]"""
    if not isinstance(message, dict):
        return ''
    content = message.get('content', [])
    if isinstance(content, list):
        parts = [b.get('text', '') for b in content
                 if isinstance(b, dict) and b.get('type') == 'text']
        return '\n'.join(parts).strip()
    return ''

def convert_session(jsonl_path, out_path):
    """JSONL 세션 → 마크다운"""
    turns = []
    session_ts = None

    with open(jsonl_path, encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = d.get('timestamp', '')
            if ts and not session_ts:
                session_ts = ts

            t = d.get('type', '')
            msg = d.get('message', '')

            if t == 'user':
                text = extract_user_text(msg)
            elif t == 'assistant':
                text = extract_assistant_text(msg)
            else:
                continue

            if not text or len(text) < 10:
                continue

            # 긴 텍스트 자르기 (첫 2000자)
            if len(text) > 2000:
                text = text[:2000] + '\n... (이하 생략)'

            turns.append((t, text))

    # 사용자 턴이 최소 1개 없으면 스킵
    user_turns = [x for x in turns if x[0] == 'user']
    if len(user_turns) < 1:
        return False

    # 사용자 입력 총 길이 100자 미만이면 스킵 (극히 짧은 단발 명령 제외)
    if sum(len(txt) for role, txt in turns if role == 'user') < 100:
        return False

    # 프로젝트명: 경로에서 추출
    proj_dir = Path(jsonl_path).parent.parent.name
    proj_name = proj_dir.lstrip('-').replace('-', '/')
    # 날짜 추출
    if session_ts:
        try:
            dt = datetime.fromisoformat(session_ts.replace('Z', '+00:00'))
            date_str = dt.strftime('%Y-%m-%d %H:%M')
        except Exception:
            date_str = session_ts[:10]
    else:
        stat = os.stat(jsonl_path)
        date_str = datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M')

    session_id = Path(jsonl_path).stem[:8]

    # 마크다운 작성
    lines = [
        f'# Claude Code 대화 — {proj_name}',
        f'날짜: {date_str} | 세션: {session_id}',
        '',
    ]

    for role, text in turns:
        if role == 'user':
            lines.append('## [대표] 요청')
            lines.append(text)
            lines.append('')
        else:
            lines.append('## [Claude] 응답')
            lines.append(text)
            lines.append('')

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text('\n'.join(lines), encoding='utf-8')
    return True

# CLI: convert_session <jsonl_path> <out_path>
if len(sys.argv) == 3:
    ok = convert_session(sys.argv[1], sys.argv[2])
    sys.exit(0 if ok else 1)
PYEOF
)

# ── 세션 파일 수집 및 변환 ────────────────────────────────────────────────────
CONVERTED=0
SKIPPED=0

while IFS= read -r jsonl_file; do
  # subagents/ 경로 제외
  if echo "$jsonl_file" | grep -q "/subagents/"; then
    continue
  fi
  # /tmp/ 경로 제외 (bot 단명 태스크)
  if echo "$jsonl_file" | grep -q "/-private-\|/-tmp-\|/tmp"; then
    continue
  fi

  # 프로젝트명 / 세션 ID 추출
  project_dir=$(dirname "$jsonl_file" | xargs dirname | xargs basename)
  session_id=$(basename "$jsonl_file" .jsonl | cut -c1-8)
  out_dir="$OUT_BASE/$project_dir"
  out_file="$out_dir/${session_id}.md"

  # 이미 변환됐고 JSONL보다 최신이면 스킵
  if [[ -f "$out_file" ]] && [[ "$out_file" -nt "$jsonl_file" ]]; then
    (( SKIPPED++ )) || true
    continue
  fi

  # Python으로 변환
  if python3 -c "$CONVERTER" "$jsonl_file" "$out_file" 2>/dev/null; then
    (( CONVERTED++ )) || true
  fi
done < <(find "$CLAUDE_PROJECTS" -name "*.jsonl" -mtime -"${DAYS_BACK}" -path "*${PROJECT_PATTERN}*" 2>/dev/null | sort)

log "INFO 변환 완료 — converted:${CONVERTED} skipped:${SKIPPED}"

if [[ "$CONVERTED" -eq 0 ]]; then
  exit 0
fi

# ── rag-index 실행 (증분) — cron-safe-wrapper 경유 (동시 실행 방지) ────────────
RAG_INDEX="${BOT_HOME}/bin/rag-index.mjs"
if [[ -f "$RAG_INDEX" ]]; then
  log "INFO rag-index 트리거 (cron-safe-wrapper 경유)"
  BOT_HOME="$BOT_HOME" OMP_NUM_THREADS=2 ORT_NUM_THREADS=2 \
    /bin/bash "${BOT_HOME}/bin/cron-safe-wrapper.sh" rag-index 2700 \
    /bin/bash "${BOT_HOME}/bin/rag-index-safe.sh" >> "$LOG" 2>&1 || true
fi

log "INFO 완료"
