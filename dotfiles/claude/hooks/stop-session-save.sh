#!/usr/bin/env bash
# stop-session-save.sh — Claude Code 세션 종료 시 대화 내용을 마크다운으로 저장
# context-extractor.mjs가 다음 날 새벽에 이 파일을 읽어 도메인별로 분류함
# Stop hook (async)

set -euo pipefail

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)
CWD=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

SESSIONS_DIR="${HOME}/.jarvis/context/claude-code-sessions"
LOG="${HOME}/.jarvis/logs/session-save.log"

log() { echo "[$(date '+%F %T')] [session-save] $1" >> "$LOG" 2>/dev/null || true; }

# 디버그: transcript_path 상태 기록
log "INPUT: transcript_path=${TRANSCRIPT_PATH:-EMPTY} cwd=${CWD:-EMPTY}"
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  log "  transcript exists: $(test -f "$TRANSCRIPT_PATH" && echo YES || echo NO)"
  [[ -f "$TRANSCRIPT_PATH" ]] && log "  transcript size: $(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ') bytes"
fi

[[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && { log "SKIP: transcript 없음"; exit 0; }

# 프로젝트명 (cwd 기반)
PROJECT=$(basename "${CWD:-unknown}" | tr ' ' '-' | tr '/' '-')
[[ -z "$PROJECT" || "$PROJECT" == "-" ]] && PROJECT="unknown"

mkdir -p "${SESSIONS_DIR}/${PROJECT}"

# [2026-08-04] 세션당 파일 1개로 고정 — 매 턴 새 파일을 만들던 방식 폐기.
#   종전에는 Stop 훅이 돌 때마다 "그 시점까지의 대화 전체"를 새 타임스탬프 파일로 저장했다.
#   100턴 대화 → 파일 100개, 100번째가 앞 99개를 전부 포함 = 저장량이 제곱으로 증가.
#   실측 2026-08-04: 11,244파일 / 718MB, 대부분이 서로의 부분집합.
#   → 파일명에 세션 ID를 넣고 덮어쓴다. 소비처 3곳은 모두 mtime 기준이라 영향 없다.
#     (wiki-ingest findLatestSession=mtime정렬 / stop-wiki-ingest=ls -t + 60초 age
#      / context-extractor=파일명 date 접두사 → 접두사는 그대로 유지)
SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl | tr -cd 'a-zA-Z0-9-' | cut -c1-8)
if [[ -z "$SESSION_ID" ]]; then SESSION_ID="unknown"; fi
OUT="${SESSIONS_DIR}/${PROJECT}/$(date '+%Y-%m-%d')-${SESSION_ID}.md"

# 2,000자 초과 메시지 전문 보관소 (2026-08-04 신설)
# 세션 .md는 RAG 인덱싱 효율상 2,000자에서 자르나, 원문은 여기에 온전히 남긴다.
# 내용 해시를 파일명으로 쓰므로 스냅샷이 반복 저장돼도 중복이 쌓이지 않는다.
RAW_DIR="${SESSIONS_DIR}-raw/${PROJECT}"
mkdir -p "$RAW_DIR"

# JSONL → 마크다운 변환 (human/assistant 텍스트만, tool use 제외)
python3 - "$TRANSCRIPT_PATH" "$OUT" "$CWD" "$RAW_DIR" << 'PYEOF'
import sys, json, os, hashlib

transcript_path, out_path, cwd, raw_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

messages = []
try:
    with open(transcript_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            # 최신 포맷: {type: 'user'|'assistant', message: {role, content: [...]}}
            # 구 포맷 호환: {role: 'user'|'assistant'|'human', content: [...] or str}
            role = obj.get('role', '')
            msg_type = obj.get('type', '')
            message = obj.get('message') if isinstance(obj.get('message'), dict) else None

            # 유효 role 결정 (신 포맷 우선, 구 포맷 fallback)
            if message and message.get('role'):
                eff_role = message.get('role')
            elif msg_type in ('user', 'assistant', 'human'):
                eff_role = 'user' if msg_type == 'human' else msg_type
            elif role in ('user', 'assistant', 'human'):
                eff_role = 'user' if role == 'human' else role
            else:
                continue  # 메타 레코드(queue-operation/attachment/last-prompt 등) 스킵

            # 유효 content 결정 (신 포맷: message.content / 구 포맷: obj.content)
            content = message.get('content') if message else obj.get('content', '')

            if isinstance(content, list):
                text = ' '.join(
                    c.get('text', '') for c in content
                    if isinstance(c, dict) and c.get('type') == 'text'
                )
            elif isinstance(content, str):
                text = content
            else:
                continue
            text = text.strip()
            if text and len(text) > 10 and eff_role in ('user', 'assistant'):
                messages.append((eff_role, text))

except Exception as e:
    sys.exit(0)

if len(messages) < 2:
    sys.exit(0)

from datetime import datetime
date_str = datetime.now().strftime('%Y-%m-%d %H:%M KST')

LIMIT = 2000

def stash(text):
    """2,000자 초과 원문을 내용 해시 파일로 보관하고 파일명을 돌려준다."""
    h = hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]
    fname = f"{h}.txt"
    path = os.path.join(raw_dir, fname)
    if not os.path.exists(path):
        with open(path, 'w', encoding='utf-8') as rf:
            rf.write(text)
    return fname

lines = [f"# Claude Code 세션 — {date_str}", f"\n> 프로젝트: {cwd}\n"]
for role, text in messages:
    prefix = "**사용자**" if role == 'user' else "**Claude**"
    # 세션 .md는 2,000자에서 자르되, 원문은 -raw/ 에 남기고 경로를 적어둔다.
    # (2026-08-04: 통화 녹취 19,803자 중 17,803자가 소실된 사고 재발 방지)
    if len(text) > LIMIT:
        try:
            body = f"{text[:LIMIT]}\n\n…(전문 {len(text):,}자 → raw/{stash(text)})"
        except Exception:
            body = text[:LIMIT] + '...(생략)'
    else:
        body = text
    lines.append(f"\n{prefix}: {body}")

with open(out_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))

print(f"saved: {out_path} ({len(messages)} messages)")
PYEOF

# 저장 후 파일 존재 확인
if [[ -f "$OUT" ]]; then
  SIZE=$(wc -c < "$OUT" | tr -d ' ')
  log "저장 완료: ${OUT} (${SIZE} bytes)"
else
  log "저장 실패! 파일 없음: ${OUT}"
  log "  transcript_path: ${TRANSCRIPT_PATH}"
  log "  cwd: ${CWD}"
  log "  PROJECT: ${PROJECT}"
fi
exit 0
