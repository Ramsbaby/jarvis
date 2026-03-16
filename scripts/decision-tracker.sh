#!/usr/bin/env bash
# decision-tracker.sh — OKR 기반 자율 결정 실행율 추적 (META-1)
#
# 역할:
#   1. board-meeting 결과 파일에서 결정사항 파싱 → state/decisions/YYYY-MM-DD.jsonl 저장
#   2. 기존 decisions.jsonl의 executed 여부를 cron.log와 매칭해 자동 판정
#   3. 자율처리율(executed/total × 100) 집계 후 state/autonomy-rate.json 저장
#
# 실행: bash ~/.jarvis/scripts/decision-tracker.sh [--dry-run]
# Cron: kpi-weekly 또는 weekly-kpi 태스크에서 호출 가능

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESULTS_DIR="${BOT_HOME}/results/board-meeting"
DECISIONS_DIR="${BOT_HOME}/state/decisions"
CRON_LOG="${BOT_HOME}/logs/cron.log"
AUTONOMY_STATE="${BOT_HOME}/state/autonomy-rate.json"

DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# ── 1. board-meeting 결과 파싱 → decisions/YYYY-MM-DD.jsonl 갱신 ─────────────
parse_board_meeting_results() {
    local today
    today=$(date +%Y-%m-%d)
    local decisions_file="${DECISIONS_DIR}/${today}.jsonl"

    if [[ ! -d "$RESULTS_DIR" ]]; then
        echo "[decision-tracker] WARN: board-meeting results dir not found: $RESULTS_DIR" >&2
        return 0
    fi

    # 오늘 날짜 파일만 대상 (YYYY-MM-DD_HHMM.md 형식)
    local new_count=0
    while IFS= read -r result_file; do
        if [[ -z "$result_file" ]]; then continue; fi

        # 파일 내에서 결정/조치/실행/action 키워드 포함 줄 추출
        python3 - "$result_file" "$decisions_file" "$today" "$DRY_RUN" << 'PYEOF'
import json, sys, os, re
from datetime import datetime, timezone

result_path  = sys.argv[1]
dec_path     = sys.argv[2]
date_str     = sys.argv[3]
dry_run      = sys.argv[4] == "true"

# 결과 파일명에서 시각 추출 (예: 2026-03-13_0810.md → 08:10)
fname = os.path.basename(result_path)
m = re.match(r'(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})', fname)
if m:
    file_ts = f"{m.group(1)}T{m.group(2)}:{m.group(3)}:00Z"
else:
    file_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(result_path, encoding="utf-8") as f:
    content = f.read()

# 이미 기록된 결정사항 로드 (중복 방지)
existing_decisions = set()
if os.path.exists(dec_path):
    with open(dec_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    d = json.loads(line)
                    existing_decisions.add(d.get("decision", ""))
                except json.JSONDecodeError:
                    pass

# 결정사항 추출 패턴
DECISION_PATTERNS = [
    # "결정:" 또는 "✅ 결정" 이후 항목들 (리스트 형식)
    r'(?:결정|✅\s*\*\*결정\*\*).*?(?:\n)((?:[-•*]\s*.+\n?)+)',
    # "결정:" 인라인 형식
    r'결정:\s*(.+?)(?:\n|$)',
    # action 키워드
    r'[Aa]ction(?:\s*항목)?[:：]\s*(.+?)(?:\n|$)',
    # "조치" 키워드
    r'조치(?:\s*사항)?[:：]\s*(.+?)(?:\n|$)',
    # "실행" 키워드
    r'실행(?:\s*항목)?[:：]\s*(.+?)(?:\n|$)',
]

extracted = []

# 패턴 1: 블록 형식 결정 (리스트)
block_pattern = re.compile(
    r'(?:✅\s*\*\*결정\*\*|결정(?:\s*사항)?[:：])\s*\n((?:[-•*]\s*.+(?:\n|$))+)',
    re.MULTILINE
)
for match in block_pattern.finditer(content):
    block = match.group(1)
    for item in re.findall(r'[-•*]\s*(.+)', block):
        item = item.strip()
        if item and len(item) > 5:
            extracted.append(item)

# 패턴 2: 인라인 형식 결정 (결정: X, Y 또는 결정: X\n결정: Y)
inline_pattern = re.compile(
    r'^결정:\s*(.+)$',
    re.MULTILINE
)
for match in inline_pattern.finditer(content):
    line = match.group(1).strip()
    # 쉼표로 여러 결정이 나열된 경우 분리
    for item in re.split(r',\s*(?=[가-힣A-Za-z])', line):
        item = item.strip()
        if item and len(item) > 5:
            extracted.append(item)

# 패턴 3: action/조치/실행 키워드
misc_pattern = re.compile(
    r'(?:[Aa]ction\s*항목?|조치\s*사항?|실행\s*항목?)[:：]\s*(.+?)(?:\n|$)',
    re.MULTILINE
)
for match in misc_pattern.finditer(content):
    item = match.group(1).strip()
    if item and len(item) > 5:
        extracted.append(item)

# OKR 키워드 → okr 태그 추출
OKR_MAP = {
    "크론": "KR1-1", "성공률": "KR1-1", "인프라": "KR1-2",
    "모니터링": "KR3-1", "TQQQ": "KR3-1", "tqqq": "KR3-1",
    "시장": "KR3-1", "brand": "KR2-1", "브랜드": "KR2-1",
    "RAG": "KR4-1", "rag": "KR4-1", "council": "KR3-2",
}
TEAM_MAP = {
    "크론": "infra", "성공률": "infra", "인프라": "infra",
    "TQQQ": "council", "tqqq": "council", "시장": "council",
    "모니터링": "council", "brand": "brand", "브랜드": "brand",
    "RAG": "record", "rag": "record",
}

new_records = []
for item in extracted:
    if item in existing_decisions:
        continue  # 중복 스킵

    # OKR / 팀 추론
    okr = "KR0-0"
    team = "system"
    for kw, kr in OKR_MAP.items():
        if kw in item:
            okr = kr
            break
    for kw, tm in TEAM_MAP.items():
        if kw in item:
            team = tm
            break

    record = {
        "ts": file_ts,
        "source": fname,
        "decision": item,
        "okr": okr,
        "team": team,
        "executed": False,
        "executed_ts": None,
        "status": "pending",
    }
    new_records.append(record)

if not dry_run and new_records:
    os.makedirs(os.path.dirname(dec_path), exist_ok=True)
    with open(dec_path, "a", encoding="utf-8") as f:
        for rec in new_records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

print(f"[parse] {fname}: {len(new_records)} new decisions parsed (dry_run={dry_run})")
PYEOF
        new_count=$((new_count + 1))
    done < <(ls "${RESULTS_DIR}/${today}_"*.md 2>/dev/null || true)

    echo "[decision-tracker] board-meeting files processed: ${new_count}"
}

# ── 2. cron.log SUCCESS 기록으로 executed 판정 ─────────────────────────────────
mark_executed_by_cron_log() {
    if [[ ! -f "$CRON_LOG" ]]; then
        echo "[decision-tracker] WARN: cron.log not found: $CRON_LOG" >&2
        return 0
    fi

    python3 - "$DECISIONS_DIR" "$CRON_LOG" "$DRY_RUN" << 'PYEOF'
import json, sys, os, re
from datetime import datetime, timezone

decisions_dir = sys.argv[1]
cron_log_path = sys.argv[2]
dry_run       = sys.argv[3] == "true"

# cron.log에서 SUCCESS 기록 수집: {task_id: [timestamp, ...]}
cron_success = {}
cron_pattern = re.compile(
    r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[([^\]]+)\] SUCCESS'
)
with open(cron_log_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = cron_pattern.search(line)
        if m:
            ts_str, task_id = m.group(1), m.group(2)
            cron_success.setdefault(task_id, []).append(ts_str)

# 결정 → 담당 태스크 ID 매핑 (키워드 기반)
TASK_KEYWORDS = {
    "infra-daily":      ["인프라", "크론", "성공률", "LaunchAgent", "재시작"],
    "system-health":    ["시스템", "헬스", "health"],
    "tqqq-monitor":     ["TQQQ", "tqqq", "손절", "시장", "모니터링"],
    "council-insight":  ["council", "경영", "이사회"],
    "board-meeting":    ["이사회", "board"],
    "weekly-kpi":       ["KPI", "kpi", "주간"],
    "security-scan":    ["보안", "security"],
    "github-monitor":   ["github", "GitHub"],
}

# 각 decisions 파일 처리
updated_total = 0
for fname in sorted(os.listdir(decisions_dir)):
    if not fname.endswith(".jsonl"):
        continue
    fpath = os.path.join(decisions_dir, fname)

    records = []
    changed = False
    with open(fpath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            records.append(rec)

    for rec in records:
        # 이미 executed 판정된 경우 스킵
        if rec.get("executed") is True:
            continue

        decision_text = rec.get("decision", "")
        team = rec.get("team", "")
        dec_ts_str = rec.get("ts", "")

        # 결정 시각 파싱
        try:
            dec_ts = datetime.strptime(dec_ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            dec_ts = None

        # 매칭 태스크 ID 결정
        matched_tasks = []
        for task_id, keywords in TASK_KEYWORDS.items():
            for kw in keywords:
                if kw.lower() in decision_text.lower():
                    matched_tasks.append(task_id)
                    break

        # team → 태스크 ID 직접 매핑
        TEAM_TO_TASK = {
            "infra": ["infra-daily", "system-health"],
            "council": ["tqqq-monitor", "council-insight"],
            "brand": ["brand-weekly"],
            "record": ["record-daily"],
            "academy": ["academy-support"],
        }
        for tm_task in TEAM_TO_TASK.get(team, []):
            if tm_task not in matched_tasks:
                matched_tasks.append(tm_task)

        # cron.log에서 결정 이후 SUCCESS 기록 탐색
        executed = False
        executed_ts = None
        for task_id in matched_tasks:
            for ts_str in cron_success.get(task_id, []):
                try:
                    cron_ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if dec_ts is None or cron_ts >= dec_ts:
                    executed = True
                    executed_ts = ts_str
                    break
            if executed:
                break

        if executed:
            rec["executed"] = True
            rec["executed_ts"] = executed_ts
            rec["status"] = "executed"
            changed = True
            updated_total += 1

    if changed and not dry_run:
        with open(fpath, "w", encoding="utf-8") as f:
            for rec in records:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")

print(f"[mark_executed] updated {updated_total} decisions as executed (dry_run={dry_run})")
PYEOF
}

# ── 3. 자율처리율 집계 → state/autonomy-rate.json ──────────────────────────────
aggregate_autonomy_rate() {
    python3 - "$DECISIONS_DIR" "$AUTONOMY_STATE" "$DRY_RUN" << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta

decisions_dir  = sys.argv[1]
output_path    = sys.argv[2]
dry_run        = sys.argv[3] == "true"

now = datetime.now(timezone.utc)
week_ago = now - timedelta(days=7)

total = 0
executed = 0
pending = 0
by_team = {}
by_okr = {}
recent_decisions = []

for fname in sorted(os.listdir(decisions_dir)):
    if not fname.endswith(".jsonl"):
        continue
    fpath = os.path.join(decisions_dir, fname)
    with open(fpath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue

            # 최근 7일 이내 결정만 집계
            try:
                rec_ts = datetime.strptime(rec.get("ts",""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            except (ValueError, TypeError):
                rec_ts = None

            if rec_ts and rec_ts < week_ago:
                continue

            total += 1
            team = rec.get("team", "unknown")
            okr  = rec.get("okr", "KR0-0")

            by_team.setdefault(team, {"total": 0, "executed": 0})
            by_okr.setdefault(okr,  {"total": 0, "executed": 0})
            by_team[team]["total"] += 1
            by_okr[okr]["total"] += 1

            if rec.get("executed") is True:
                executed += 1
                by_team[team]["executed"] += 1
                by_okr[okr]["executed"] += 1
            else:
                pending += 1

            recent_decisions.append({
                "ts": rec.get("ts"),
                "source": rec.get("source", ""),
                "decision": rec.get("decision", "")[:80],
                "team": team,
                "okr": okr,
                "executed": rec.get("executed", False),
            })

autonomy_rate = round(executed / total * 100, 1) if total > 0 else 0.0

# 팀별 자율처리율
team_rates = {
    t: round(v["executed"] / v["total"] * 100, 1) if v["total"] > 0 else 0.0
    for t, v in by_team.items()
}
okr_rates = {
    o: round(v["executed"] / v["total"] * 100, 1) if v["total"] > 0 else 0.0
    for o, v in by_okr.items()
}

result = {
    "generated_ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "window": "7d",
    "autonomy_rate": autonomy_rate,
    "total_decisions": total,
    "executed": executed,
    "pending": pending,
    "by_team": {t: {"rate": team_rates[t], **by_team[t]} for t in by_team},
    "by_okr":  {o: {"rate": okr_rates[o],  **by_okr[o]}  for o in by_okr},
    "recent_decisions": sorted(recent_decisions, key=lambda x: x["ts"] or "", reverse=True)[:20],
}

# JSON 유효성 검증
json_str = json.dumps(result, ensure_ascii=False, indent=2)
json.loads(json_str)  # 파싱 가능 여부 확인

if not dry_run:
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(json_str + "\n")

# 요약 출력
print(f"[aggregate] 자율처리율: {autonomy_rate}% ({executed}/{total}) — 최근 7일")
print(f"[aggregate] 팀별: { {t: f'{r}%' for t, r in team_rates.items()} }")
print(f"[aggregate] OKR별: { {o: f'{r}%' for o, r in okr_rates.items()} }")
if dry_run:
    print(f"[aggregate] DRY-RUN: {output_path} 미저장")
else:
    print(f"[aggregate] 저장: {output_path}")
PYEOF
}

# ── 메인 실행 ──────────────────────────────────────────────────────────────────
echo "[decision-tracker] 시작 $(date '+%Y-%m-%d %H:%M:%S') (dry_run=${DRY_RUN})"
echo "---"

parse_board_meeting_results
echo "---"
mark_executed_by_cron_log
echo "---"
aggregate_autonomy_rate
echo "---"
echo "[decision-tracker] 완료"
