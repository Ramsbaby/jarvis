#!/usr/bin/env bash
# RAG 리빌딩 2분 모니터 — webhook curl 전송
INFRA_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
RAG_HOME="${JARVIS_RAG_HOME:-${INFRA_HOME}/rag}"
WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // .webhook.url' "$INFRA_HOME/config/monitoring.json" 2>/dev/null)
DONE_FLAG="$INFRA_HOME/state/rag-monitor.done"

# 이미 완료 표시면 종료
[[ -f "$DONE_FLAG" ]] && exit 0

# 상태 수집 (Python 단일 처리)
RESULT=$(python3 - "$INFRA_HOME" "$RAG_HOME" <<'PYEOF'
import json, re, subprocess, sys, time, os

home  = sys.argv[1]
rag_home = sys.argv[2]
state_f = f"{rag_home}/index-state.json"
log_f   = f"{home}/logs/rag-index.log"
queue_f = f"{home}/state/rag-write-queue.jsonl"

pid = subprocess.run(["pgrep","-f","rag-index.mjs"], capture_output=True, text=True).stdout.strip()

try:
    d = json.load(open(state_f))
    files  = len(d)
    chunks = sum(v.get("chunks",0) for v in d.values() if isinstance(v,dict))
except: files,chunks = 0,0

try:
    lines = open(log_f).readlines()
    prog  = next((l for l in reversed(lines) if "indexed" in l.lower() and "skipped" in l.lower()), "")
    idx   = int(re.search(r"(\d+)\s+indexed", prog).group(1)) if re.search(r"(\d+)\s+indexed", prog) else 0
    skp   = int(re.search(r"(\d+)\s+skipped", prog).group(1)) if re.search(r"(\d+)\s+skipped", prog) else 0
    tot   = int(re.search(r"(\d+)\s+total",   prog).group(1)) if re.search(r"(\d+)\s+total",   prog) else 11195
except: idx,skp,tot = 0,0,11195

try: q = sum(1 for _ in open(queue_f))
except: q = 0

done = idx + skp
pct  = done * 100 // tot if tot else 0
bar  = "█" * (pct // 5) + "░" * (20 - pct // 5)
est  = chunks * tot // files if files else 0
ts   = time.strftime("%H:%M")

actually_done = not pid and files >= 10000
if pid or not actually_done:
    print(f"RUNNING|{ts}|{bar}|{pct}|{done}|{tot}|{chunks}|{est}|{idx}|{skp}|{q}")
else:
    print(f"DONE|{ts}|{bar}|{pct}|{done}|{tot}|{chunks}|{est}|{idx}|{skp}|{q}|{files}")
PYEOF
)

STATUS=$(echo "$RESULT" | cut -d'|' -f1)
TS=$(echo "$RESULT"     | cut -d'|' -f2)
BAR=$(echo "$RESULT"    | cut -d'|' -f3)
PCT=$(echo "$RESULT"    | cut -d'|' -f4)
DONE=$(echo "$RESULT"   | cut -d'|' -f5)
TOT=$(echo "$RESULT"    | cut -d'|' -f6)
CHUNKS=$(echo "$RESULT" | cut -d'|' -f7)
EST=$(echo "$RESULT"    | cut -d'|' -f8)
IDX=$(echo "$RESULT"    | cut -d'|' -f9)
SKP=$(echo "$RESULT"    | cut -d'|' -f10)
Q=$(echo "$RESULT"      | cut -d'|' -f11)
FILES=$(echo "$RESULT"  | cut -d'|' -f12)

if [[ "$STATUS" == "RUNNING" ]]; then
    MSG="🔄 **RAG 리빌딩** [${TS}]
\`${BAR}\` **${PCT}%** (${DONE}/${TOT} 파일)
📦 청크: **${CHUNKS}개** | 완료 예상: ~**${EST}개**
📄 신규: ${IDX}개 | 스킵: ${SKP}개
🗂 큐 잔여: ${Q}줄"
else
    MSG="✅ **RAG 리빌딩 완료!** [${TS}]
📦 최종 청크: **${CHUNKS}개** | 파일: **${FILES}개**
🎉 Snowflake Arctic Embed 인덱싱 완료"
    echo "$TS" > "$DONE_FLAG"
fi

PAYLOAD=$(jq -n --arg content "$MSG" '{"content":$content,"flags":4}')
echo "[$(date '+%Y-%m-%d %H:%M:%S')] rag-monitor 실행 (PID:$$, STATUS:$STATUS)" >&2
curl -s -o /dev/null -X POST "$WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"
