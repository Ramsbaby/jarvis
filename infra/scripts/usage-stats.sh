#!/usr/bin/env bash
set -euo pipefail

# usage-stats.sh — Discord 활용도 주간 통계
# Usage: usage-stats.sh [DAYS]
# DAYS 기본값: 7

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
JSONL="$BOT_HOME/logs/discord-bot.jsonl"
DAYS="${1:-7}"

if [[ ! -f "$JSONL" ]]; then
  echo "로그 없음: $JSONL"
  exit 0
fi

python3 - "$JSONL" "$DAYS" <<'PYEOF'
import sys, json
from datetime import datetime, timedelta, timezone
from collections import defaultdict

jsonl_path, days = sys.argv[1], int(sys.argv[2])
cutoff = datetime.now(timezone.utc) - timedelta(days=days)

# 사람 메시지 (bot:false)
human_msgs = 0
# 봇 메시지 (bot:true)
bot_msgs = 0
# 슬래시 커맨드 (msg에 '/' 포함 또는 interaction 이벤트)
slash_cmds = 0
# 에러
errors = 0
# 일별 사람 메시지
daily_human = defaultdict(int)
# 저자별 사람 메시지
author_counts = defaultdict(int)
# 채널별 사람 메시지
channel_counts = defaultdict(int)

with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue

        ts_str = entry.get('ts') or entry.get('time') or ''
        try:
            ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        except Exception:
            continue

        if ts < cutoff:
            continue

        level = entry.get('level', '')
        msg = entry.get('msg', '')

        # messageCreate 이벤트 집계
        if msg == 'messageCreate received':
            is_bot = entry.get('bot', True)
            ch = entry.get('channelId', 'unknown')
            author = entry.get('author', 'unknown')
            day = ts.strftime('%Y-%m-%d')

            if not is_bot:
                human_msgs += 1
                daily_human[day] += 1
                author_counts[author] += 1
                channel_counts[ch] += 1
            else:
                bot_msgs += 1

        # 슬래시 커맨드 집계 (/doctor, /brief 등이 interactionCreate로 기록되는 경우)
        if 'interactionCreate' in msg or 'slash' in msg.lower() or '/doctor' in msg or '/brief' in msg:
            slash_cmds += 1

        if level == 'error':
            errors += 1

total_msgs = human_msgs + bot_msgs

print(f"=== Discord 활용도 통계 (최근 {days}일) ===")
print(f"총 메시지: {total_msgs}건  (사람: {human_msgs}건 / 봇: {bot_msgs}건)")
print(f"슬래시 커맨드: {slash_cmds}건 | 에러: {errors}건")
if days > 0 and human_msgs > 0:
    print(f"사람 일평균: {human_msgs/days:.1f}건/일")
print()

if daily_human:
    print("일별 사람 메시지:")
    for day in sorted(daily_human.keys())[-7:]:
        bar = '█' * min(daily_human[day], 20)
        print(f"  {day}: {daily_human[day]:3d}건 {bar}")
    print()

if author_counts:
    print("사용자별 메시지:")
    for author, cnt in sorted(author_counts.items(), key=lambda x: -x[1])[:5]:
        print(f"  {author}: {cnt}건")

print(f"\n총 대화: {human_msgs}건")
PYEOF
