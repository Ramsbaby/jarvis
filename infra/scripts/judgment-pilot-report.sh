#!/usr/bin/env bash
# judgment-pilot-report.sh — 판결 엔진 파일럿 정밀도 리포트 (온디맨드, 크론 아님)
#
# 2026-07-10 신설 (자비스 진화 계획 기둥1 Step 1.2).
# stop-unverified-assertion-guard.sh가 로그전용으로 쌓은 would_block 판정을 집계한다.
# 목적: exit 2 차단(Step 1.3) 전환 전, "차단했을 것"의 오탐률을 1주 측정.
#   기준: would_block:true 중 '진짜 근거 없는 완료선언' 비율 ≥ 95% 확인 시 차단 전환 승인.
#
# 사용법: bash judgment-pilot-report.sh [일수(기본 7)]
#   would_block:true 항목을 날짜별로 집계하고, 수동 리뷰용 최근 표본을 출력.

set -euo pipefail

DAYS="${1:-7}"
LEDGER="${HOME}/jarvis/runtime/ledger/unverified-assertion.jsonl"

if [[ ! -f "$LEDGER" ]]; then
  echo "❌ ledger 없음: $LEDGER"
  exit 1
fi

python3 - "$LEDGER" "$DAYS" <<'PYEOF'
import json, sys, datetime
from collections import Counter

ledger, days = sys.argv[1], int(sys.argv[2])
cutoff = None  # 파일럿 시작 이후만 would_block 필드 존재하므로 필드 유무로 자연 필터

rows = []
for line in open(ledger, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    rows.append(d)

# would_block 필드가 있는 항목만 = 파일럿 도입 이후
pilot = [r for r in rows if "would_block" in r]
wb = [r for r in pilot if r.get("would_block") is True]

by_day = Counter()
for r in wb:
    ts = r.get("ts", "")
    day = ts[:10] if len(ts) >= 10 else "unknown"
    by_day[day] += 1

print("🧪 판결 엔진 파일럿 리포트 (would_block 집계)")
print(f"   전체 ledger 항목: {len(rows)}")
print(f"   파일럿(would_block 필드 존재) 항목: {len(pilot)}")
print(f"   would_block:true (차단 후보): {len(wb)}")
print()

if not pilot:
    print("   ⏳ 아직 파일럿 데이터 없음 — 훅이 몇 차례 발화한 뒤 다시 실행하세요.")
    raise SystemExit

print("   📅 날짜별 차단 후보:")
for day in sorted(by_day):
    print(f"      {day}: {by_day[day]}건")
print()

print("   🔍 수동 리뷰용 최근 차단 후보 표본 (최대 10건):")
print("      (각 항목이 '진짜 근거 없는 완료선언'인지 판정 → 정밀도 계산)")
for r in wb[-10:]:
    pats = ", ".join(r.get("patterns", [])[:3])
    print(f"      · {r.get('ts','?')[:19]}  hc={r.get('hc_count','?')}  [{pats}]")
print()

# 정밀도 판정 안내
n = len(wb)
if n >= 20:
    print(f"   ✅ 표본 {n}건 — 위 표본을 수동 리뷰해 오탐(진짜 검증했는데 잡힌 것) 수를 세십시오.")
    print(f"      정밀도 = (n - 오탐) / n.  ≥ 0.95 이면 Step 1.3(exit 2 차단) 전환 승인.")
else:
    print(f"   ⏳ 표본 {n}건 — 통계적 판정에 최소 20건 권장. 파일럿 계속 축적하세요.")
PYEOF
