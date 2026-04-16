#!/usr/bin/env bash
set -euo pipefail

# trajectory-weekly-report.sh — 주간 궤적 분석 리포트
# 매주 일요일 수동 실행 (크론 미등록)
# 입력: ~/.jarvis/logs/trajectory.jsonl
# 출력: 마크다운 (stdout, Discord 전송 가능)

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
TRAJECTORY_FILE="${BOT_HOME}/logs/trajectory.jsonl"

if [[ ! -f "$TRAJECTORY_FILE" ]]; then
    echo "trajectory.jsonl 파일 없음: ${TRAJECTORY_FILE}"
    exit 1
fi

# 이번 주 범위 (월요일~일요일, KST 기준)
_today=$(TZ=Asia/Seoul date '+%Y-%m-%d')
_dow=$(TZ=Asia/Seoul date '+%u')  # 1=Monday, 7=Sunday
_week_start=$(TZ=Asia/Seoul date -v-"$(( _dow - 1 ))"d '+%Y-%m-%d' 2>/dev/null || \
              TZ=Asia/Seoul date -d "$_today - $(( _dow - 1 )) days" '+%Y-%m-%d' 2>/dev/null || \
              echo "$_today")
_week_end="$_today"

python3 - "$TRAJECTORY_FILE" "$_week_start" "$_week_end" <<'PYEOF'
import json, sys
from collections import defaultdict
from datetime import datetime

traj_file, week_start, week_end = sys.argv[1], sys.argv[2], sys.argv[3]

starts = {}  # task_id -> last start event
ends = []    # completed (paired) events

with open(traj_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts_str = ev.get("ts", "")[:10]
        if ts_str < week_start or ts_str > week_end:
            continue
        if ev.get("event") == "start":
            starts[ev["task_id"]] = ev
        elif ev.get("event") == "end":
            task_id = ev["task_id"]
            start_ev = starts.pop(task_id, {})
            ev["model"] = start_ev.get("model", ev.get("model", "unknown"))
            ends.append(ev)

total = len(ends)
if total == 0:
    print(f"## Trajectory 주간 리포트 ({week_start} ~ {week_end})")
    print()
    print("이번 주 실행 데이터 없음.")
    sys.exit(0)

successes = sum(1 for e in ends if e.get("status") == "success")
failures = total - successes
success_rate = round(successes / total * 100, 1) if total > 0 else 0

# 태스크별 집계
task_stats = defaultdict(lambda: {
    "count": 0, "success": 0, "fail": 0,
    "total_duration_ms": 0, "total_cost": 0.0,
    "durations": []
})
model_counts = defaultdict(int)

for ev in ends:
    tid = ev["task_id"]
    s = task_stats[tid]
    s["count"] += 1
    dur = ev.get("duration_ms", 0)
    s["total_duration_ms"] += dur
    s["durations"].append(dur)
    cost = ev.get("cost_usd", 0) or 0
    s["total_cost"] += cost
    if ev.get("status") == "success":
        s["success"] += 1
    else:
        s["fail"] += 1
    model = ev.get("model", "unknown")
    model_counts[model] += 1

# --- 출력 ---
print(f"## Trajectory 주간 리포트 ({week_start} ~ {week_end})")
print()
print("### 총괄")
print(f"| 항목 | 값 |")
print(f"|------|---:|")
print(f"| 총 실행 | {total}회 |")
print(f"| 성공 | {successes}회 |")
print(f"| 실패 | {failures}회 |")
print(f"| 성공률 | {success_rate}% |")
print()

# 가장 비싼 태스크 TOP 5
cost_ranking = sorted(task_stats.items(), key=lambda x: x[1]["total_cost"], reverse=True)[:5]
has_cost = any(s["total_cost"] > 0 for _, s in cost_ranking)
if has_cost:
    print("### 비용 TOP 5 (cost_usd 합계)")
    print("| 순위 | 태스크 | 비용($) | 실행수 |")
    print("|:----:|--------|--------:|-------:|")
    for i, (tid, s) in enumerate(cost_ranking, 1):
        if s["total_cost"] > 0:
            print(f"| {i} | `{tid}` | {s['total_cost']:.4f} | {s['count']} |")
    print()

# 가장 느린 태스크 TOP 5 (평균 duration)
dur_ranking = sorted(
    [(tid, s) for tid, s in task_stats.items() if s["durations"]],
    key=lambda x: sum(x[1]["durations"]) / len(x[1]["durations"]),
    reverse=True
)[:5]
print("### 소요시간 TOP 5 (평균 duration)")
print("| 순위 | 태스크 | 평균(초) | 최대(초) | 실행수 |")
print("|:----:|--------|--------:|---------:|-------:|")
for i, (tid, s) in enumerate(dur_ranking, 1):
    avg_s = round(sum(s["durations"]) / len(s["durations"]) / 1000, 1)
    max_s = round(max(s["durations"]) / 1000, 1)
    print(f"| {i} | `{tid}` | {avg_s} | {max_s} | {s['count']} |")
print()

# 실패율 TOP 5
fail_ranking = sorted(
    [(tid, s) for tid, s in task_stats.items() if s["fail"] > 0],
    key=lambda x: x[1]["fail"] / x[1]["count"],
    reverse=True
)[:5]
if fail_ranking:
    print("### 실패율 TOP 5")
    print("| 순위 | 태스크 | 실패율 | 실패/전체 |")
    print("|:----:|--------|-------:|----------:|")
    for i, (tid, s) in enumerate(fail_ranking, 1):
        rate = round(s["fail"] / s["count"] * 100, 1)
        print(f"| {i} | `{tid}` | {rate}% | {s['fail']}/{s['count']} |")
    print()

# 모델별 사용 비율
print("### 모델별 사용 비율")
print("| 모델 | 실행수 | 비율 |")
print("|------|-------:|-----:|")
for model, cnt in sorted(model_counts.items(), key=lambda x: -x[1]):
    pct = round(cnt / total * 100, 1)
    print(f"| `{model}` | {cnt} | {pct}% |")
print()

print(f"---")
print(f"*Generated: {datetime.now().strftime('%Y-%m-%d %H:%M KST')}*")
PYEOF
