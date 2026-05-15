#!/usr/bin/env bash
set -euo pipefail

# followup-sync.sh — gog tasks → follow-ups.json 자동 동기화 v1.0
# 하루 1회 실행 (08:30 KST)
#
# gog tasks에서 면접·시험·인터뷰 키워드 미완료 항목을 감지하여
# follow-ups.json에 없는 항목이면 자동 추가한다.
# 이미 등록된 항목(id 중복 또는 제목 유사)은 스킵.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
FOLLOW_UPS="$BOT_HOME/context/owner/follow-ups.json"
LOG="$BOT_HOME/logs/followup-sync.log"

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [followup-sync] $*" | tee -a "$LOG"; }

log "=== followup-sync 시작 ==="

python3 - \
    "$FOLLOW_UPS" \
    "${GOOGLE_ACCOUNT:-}" \
    "$LOG" << 'PYEOF'

import json
import sys
import subprocess
import re
from datetime import date, datetime

follow_ups_file = sys.argv[1]
google_account = sys.argv[2]
log_file = sys.argv[3]

today = date.today()
today_str = today.strftime('%Y-%m-%d')

GOOGLE_TASKS_LIST_ID = "MDE3MjE5NzU0MjA3NTAxOTg4ODc6MDow"

# 면접·시험·전형 관련 키워드 (너무 광범위하면 오탐 → 구체적으로)
KEYWORDS = ['면접', '인터뷰', '시험', '코딩테스트', '라이브코딩', '과제 제출', 'SAA', 'SAP', 'AIF', '전형', '합격', '탈락', '결과 확인']


def plog(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open(log_file, 'a') as f:
        f.write(f"[{ts}] [py] {msg}\n")


def load_follow_ups():
    try:
        with open(follow_ups_file) as f:
            return json.load(f)
    except Exception:
        return {
            "_comment": "proactive-engine이 추적할 이벤트 레지스트리",
            "items": []
        }


def save_follow_ups(data):
    with open(follow_ups_file, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def slugify(s):
    """제목을 안전한 ID 문자열로 변환"""
    s = re.sub(r'[^\w\s-]', '', s, flags=re.UNICODE)
    s = re.sub(r'\s+', '-', s.strip())
    return s[:40].rstrip('-').lower()


def parse_date_from_title(title):
    """제목에서 날짜 추출. 없으면 오늘 날짜 반환."""
    patterns = [
        (r'(\d{4}-\d{2}-\d{2})', '%Y-%m-%d'),
        (r'(\d{4}\.\d{2}\.\d{2})', '%Y.%m.%d'),
        (r'(\d{1,2}/\d{1,2})', None),  # 5/6, 05/06 → 연도 보완 필요
    ]
    for pat, fmt in patterns:
        m = re.search(pat, title)
        if m:
            ds = m.group(1)
            if fmt:
                try:
                    return datetime.strptime(ds, fmt).date().strftime('%Y-%m-%d')
                except ValueError:
                    continue
            else:
                # MM/DD 형식 — 올해 기준
                try:
                    parts = ds.split('/')
                    d = date(today.year, int(parts[0]), int(parts[1]))
                    return d.strftime('%Y-%m-%d')
                except (ValueError, IndexError):
                    continue
    return today_str


# ── gog tasks 조회 ────────────────────────────────────────────────────────

plog("gog tasks 조회 중...")
try:
    cmd = ["gog", "tasks", "list", GOOGLE_TASKS_LIST_ID]
    if google_account:
        cmd += ["--account", google_account]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    if result.returncode != 0:
        plog(f"gog tasks 실패 (exit {result.returncode}) — 종료")
        sys.exit(0)

except FileNotFoundError:
    plog("gog 명령 없음 — 종료")
    sys.exit(0)
except Exception as e:
    plog(f"gog 실행 오류: {e}")
    sys.exit(0)

# ── follow-ups.json 로드 ──────────────────────────────────────────────────

fu_data = load_follow_ups()
existing_ids = {item.get('id', '') for item in fu_data.get('items', [])}
# 기존 subject 앞 20자 기준 유사도 체크용
existing_subject_prefixes = {item.get('subject', '')[:20] for item in fu_data.get('items', [])}

added = 0
lines = result.stdout.split('\n')

for line in lines:
    line = line.strip()
    if not line:
        continue

    # 완료된 항목 제외 ([x], ✅, completed)
    line_lower = line.lower()
    if '[x]' in line_lower or '✅' in line or 'completed' in line_lower:
        continue

    # 키워드 매칭
    if not any(kw in line for kw in KEYWORDS):
        continue

    # 제목 정제 (리스트 마커 제거)
    title = re.sub(r'^\[[ ]\]\s*', '', line).strip()
    title = title.lstrip('- ').strip()
    if len(title) < 4:
        continue

    event_date = parse_date_from_title(title)

    # ID 생성 및 중복 체크
    auto_id = f"auto-{slugify(title)}"
    if auto_id in existing_ids:
        plog(f"SKIP (id 중복): {title[:50]}")
        continue

    # 제목 유사도 체크 (기존 subject 앞 20자와 비교)
    title_prefix = title[:20]
    if title_prefix in existing_subject_prefixes:
        plog(f"SKIP (유사 subject): {title[:50]}")
        continue

    # follow-ups.json에 신규 추가
    new_item = {
        "id": auto_id,
        "subject": title[:80],
        "event_date": event_date,
        "follow_up_after_days": 7,
        "message": f"📋 **{title[:50]}** — {'{days}'}일 지났습니다. 어떻게 됐나요?",
        "resolved": False,
        "resolved_date": "",
        "max_follow_ups": 3,
        "auto_added": True,
        "auto_added_date": today_str
    }

    fu_data.setdefault('items', []).append(new_item)
    existing_ids.add(auto_id)
    existing_subject_prefixes.add(title_prefix)
    added += 1
    plog(f"추가됨: {title[:50]} (event_date={event_date})")

if added > 0:
    save_follow_ups(fu_data)
    plog(f"총 {added}건 follow-ups.json에 추가됨")
else:
    plog("신규 추가 항목 없음 — follow-ups.json 변경 없음")

plog("=== followup-sync 완료 ===")
PYEOF

EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    log "ERROR: Python 블록 실패 (exit $EXIT_CODE)"
    exit 1
fi

log "=== followup-sync 종료 ==="
