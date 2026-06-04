#!/usr/bin/env bash
# prompt-bloat-sentinel.sh — 디스코드 봇 시스템 프롬프트 비대화 상시 감시 (재발 방지)
#
# 배경: 2026-06-04 hot-events.json(783건/261KB)이 단일 섹션 70K 토큰으로 프롬프트를 점령 →
#       budget(prompt-harness.js enforceBudget)이 92%를 절단하며 핵심 검색 지시까지 탈락 → 답변 품질 저하.
# 목적: "또 다른 hot-events류 무cap 주입 + 무한성장 파일"을 자동 감지. 두 축을 본다.
#   (1) 주입측 폭주  — drop 원장(prompt-budget-drops.jsonl) 최근 N시간에서
#                      originalTokens > budget×배수 || 단일 dropped 섹션 tokens > 임계 || 거대 unnamed.
#   (2) 작성측 비대  — injection-watch.json 매니페스트의 파일 byte 크기 임계 초과.
# DRY: drop 원장은 봇이 매 응답 자동 적재 → 신규 수집 비용 0. 기존 데이터 위에 감시만 얹는다.
# 확장: 새 주입 파일은 injection-watch.json files[]에 1줄 등록 → 자동 감시 편입.
#
# 사용: bash prompt-bloat-sentinel.sh            (위반 시에만 #jarvis-system 경보, 0건이면 조용히 exit 0)
#       DRYRUN=1 bash prompt-bloat-sentinel.sh   (경보 대신 stdout 출력 — 1주 시뮬용)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
JARVIS_HOME="${HOME}/jarvis"
LEDGER="$BOT_HOME/state/prompt-budget-drops.jsonl"
MANIFEST="$BOT_HOME/context/injection-watch.json"
LOG="${BOT_HOME}/logs/prompt-bloat-sentinel.log"
DRYRUN="${DRYRUN:-0}"

mkdir -p "$(dirname "$LOG")"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

[ -f "$LEDGER" ] || { log "ledger 없음, skip"; exit 0; }
[ -f "$MANIFEST" ] || { log "manifest 없음, skip"; exit 0; }

# 위반 분석은 python3 (JSON 안전 파싱). 위반 요약 텍스트를 stdout으로 반환, 위반 0건이면 빈 출력.
REPORT=$(python3 - "$LEDGER" "$MANIFEST" "$BOT_HOME" <<'PY'
import json, sys, os, datetime

ledger_path, manifest_path, bot_home = sys.argv[1], sys.argv[2], sys.argv[3]
mani = json.load(open(manifest_path))
th = mani.get("thresholds", {})
mult = th.get("budgetMultiplierAlert", 3.0)
sec_max = th.get("sectionTokenMaxAlert", 8000)
unnamed_max = th.get("unnamedTokenMaxAlert", 5000)
lookback_h = th.get("ledgerLookbackHours", 24)

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(hours=lookback_h)

violations = []

# (1) 주입측 — 원장 최근 N시간 스캔
try:
    lines = open(ledger_path, encoding="utf-8").read().splitlines()
except Exception:
    lines = []
recent = []
for ln in lines[-2000:]:
    try:
        d = json.loads(ln)
        ts = d.get("ts", "")
        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None
        if t and t >= cutoff:
            recent.append(d)
    except Exception:
        continue

over_budget = [d for d in recent if d.get("originalTokens", 0) > d.get("budget", 7000) * mult]
big_sections = []
for d in recent:
    for x in d.get("dropped", []):
        tok = x.get("tokens", 0)
        nm = x.get("name", "")
        if tok > sec_max or (nm.startswith(("unnamed-", "unknown")) and tok > unnamed_max):
            big_sections.append({"name": nm, "tokens": tok, "ch": d.get("channelId"),
                                 "preview": x.get("preview", "")[:80]})

if over_budget:
    worst = max(over_budget, key=lambda d: d.get("originalTokens", 0))
    violations.append(f"주입 폭주: 최근 {lookback_h}h에 originalTokens>budget×{mult} 엔트리 {len(over_budget)}건 "
                      f"(최대 {worst.get('originalTokens')}tok, budget {worst.get('budget')}, ch={worst.get('channelId')})")
if big_sections:
    worst = max(big_sections, key=lambda x: x["tokens"])
    uniq = {}
    for s in big_sections:
        uniq.setdefault(s["name"], 0)
        uniq[s["name"]] = max(uniq[s["name"]], s["tokens"])
    top = sorted(uniq.items(), key=lambda kv: -kv[1])[:3]
    detail = ", ".join(f"{n}={t}tok" for n, t in top)
    violations.append(f"거대 섹션: 단일 섹션 >{sec_max}tok 발생 {len(big_sections)}건 — {detail}"
                      + (f" | 최대 preview: {worst['preview']}" if worst.get("preview") else ""))

# (2) 작성측 — 매니페스트 파일 byte 크기
for f in mani.get("files", []):
    p = os.path.join(bot_home, f["path"])
    cap = f.get("byteCapAlert", 0)
    try:
        sz = os.path.getsize(p)
    except OSError:
        continue
    if cap and sz > cap:
        ret = f.get("writeRetention", "?")
        violations.append(f"파일 비대: {f['path']} = {sz//1024}KB > cap {cap//1024}KB (retention: {ret})")

if violations:
    print(json.dumps({"count": len(violations), "lines": violations}, ensure_ascii=False))
PY
)

if [ -z "$REPORT" ]; then
  log "위반 0건 — 정상"
  exit 0
fi

COUNT=$(printf '%s' "$REPORT" | python3 -c "import json,sys;print(json.load(sys.stdin)['count'])")
BODY=$(printf '%s' "$REPORT" | python3 -c "import json,sys;print(chr(10).join('• '+l for l in json.load(sys.stdin)['lines']))")
log "위반 ${COUNT}건 감지: $BODY"

if [ "$DRYRUN" = "1" ]; then
  echo "🚨 prompt-bloat-sentinel 위반 ${COUNT}건 (DRYRUN — 경보 미발송)"
  echo "$BODY"
  exit 0
fi

# 경보 발송 (discord-route severity=critical → #jarvis-system)
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
if command -v discord_route_payload >/dev/null 2>&1; then
  PAYLOAD=$(jq -nc \
    --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M KST')" \
    --arg cnt "${COUNT}건" \
    --arg body "$BODY" \
    '{title: "🚨 프롬프트 비대화 감지 (sentinel)", data: {"위반 수": $cnt, "상세": $body, "조치": "injection-watch.json 임계·해당 섹션 read cap 점검"}, timestamp: $ts}')
  discord_route_payload critical "$PAYLOAD" 2>&1 | tee -a "$LOG" || true
else
  log "discord_route_payload 미가용 — 로그만 기록"
fi
exit 0
