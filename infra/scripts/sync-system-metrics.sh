#!/bin/bash
# sync-system-metrics.sh — Mac mini 시스템 메트릭 전체를 자비스보드 DB에 push
# launchd: ai.jarvis.sync-system-metrics (5분마다 실행)
set -euo pipefail

# LaunchAgent 환경에서 PATH 설정
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Node.js 경로 확정 (LaunchAgent 환경에서 which가 작동 안 할 수 있으므로 직접 경로 우선)
if [[ -x "/opt/homebrew/bin/node" ]]; then
  NODE_BIN="/opt/homebrew/bin/node"
elif [[ -x "/usr/local/bin/node" ]]; then
  NODE_BIN="/usr/local/bin/node"
elif command -v node &>/dev/null; then
  NODE_BIN="$(command -v node)"
else
  echo "[sync-system-metrics] FATAL: node binary not found in common paths" >&2
  exit 127
fi

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
MONITORING="$BOT_HOME/config/monitoring.json"

# ── board URL (SSoT: monitoring.json > env > default localhost) ──
if [[ -z "${BOARD_URL:-}" ]]; then
  BOARD_URL=$(jq -r '.boardUrl // empty' "$MONITORING" 2>/dev/null || true)
fi
BOARD_URL="${BOARD_URL:-http://localhost:3100}"

# ── agent key ──
API_KEY="${AGENT_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  API_KEY=$(jq -r '.agentKey // empty' "$MONITORING" 2>/dev/null || true)
fi
if [[ -z "$API_KEY" ]]; then
  echo "[sync-system-metrics] ERROR: AGENT_API_KEY 없음" >&2
  exit 1
fi

SYNCED_AT=$(date -u +%FT%TZ)
LOG_DIR="$BOT_HOME/logs"
STATE_DIR="$BOT_HOME/state"

# ══════════════════════════════════════════════════════
# 1. 디스크 (macOS df: 512-byte blocks)
# ══════════════════════════════════════════════════════
DF_LINE=$(df / | tail -1)
DISK_BLOCKS_TOTAL=$(echo "$DF_LINE" | awk '{print $2}')
DISK_BLOCKS_AVAIL=$(echo "$DF_LINE" | awk '{print $4}')
DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_BLOCKS_TOTAL / 2097152}")
DISK_FREE_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_BLOCKS_AVAIL / 2097152}")
DISK_USED_PCT=$(df -h / | tail -1 | awk '{gsub(/%/,"",$5); print int($5)}')

# ══════════════════════════════════════════════════════
# 1-b. 메모리 (macOS: sysctl + vm_stat)
# ══════════════════════════════════════════════════════
MEM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_TOTAL_BYTES / 1073741824}")
VM_STAT_OUT=$(vm_stat 2>/dev/null || echo "")
MEM_PAGE_SIZE=16384
MEM_ACTIVE=$(echo "$VM_STAT_OUT" | awk '/Pages active/{gsub(/\./,"",$NF); print $NF+0}')
MEM_WIRED=$(echo "$VM_STAT_OUT" | awk '/Pages wired down/{gsub(/\./,"",$NF); print $NF+0}')
MEM_COMPRESSED=$(echo "$VM_STAT_OUT" | awk '/Pages occupied by compressor/{gsub(/\./,"",$NF); print $NF+0}')
MEM_USED_PAGES=$(( ${MEM_ACTIVE:-0} + ${MEM_WIRED:-0} + ${MEM_COMPRESSED:-0} ))
MEM_USED_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_USED_PAGES * $MEM_PAGE_SIZE / 1073741824}")
MEM_USED_PCT=0
if [[ "$MEM_TOTAL_BYTES" -gt 0 ]]; then
  MEM_USED_PCT=$(awk "BEGIN {printf \"%d\", ($MEM_USED_PAGES * $MEM_PAGE_SIZE / $MEM_TOTAL_BYTES) * 100}")
fi

# ══════════════════════════════════════════════════════
# 1-c. CPU (macOS: sysctl + ps)
# ══════════════════════════════════════════════════════
CPU_LOAD_AVG=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{printf "%.2f", $1}' || echo "0")
CPU_N_CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "1")
CPU_USED_PCT=$(awk "BEGIN {v=$CPU_LOAD_AVG/$CPU_N_CORES*100; printf \"%d\", (v>100?100:v)}")

# ══════════════════════════════════════════════════════
# 2. health.json
# ══════════════════════════════════════════════════════
HEALTH_FILE="$STATE_DIR/health.json"
HEALTH_JSON="null"
if [[ -f "$HEALTH_FILE" ]]; then
  HEALTH_JSON=$(cat "$HEALTH_FILE")
fi

# ══════════════════════════════════════════════════════
# 3. team-scorecard.json
# ══════════════════════════════════════════════════════
SCORECARD_FILE="$STATE_DIR/team-scorecard.json"
SCORECARD_JSON="null"
if [[ -f "$SCORECARD_FILE" ]]; then
  SCORECARD_JSON=$(cat "$SCORECARD_FILE")
fi

# ══════════════════════════════════════════════════════
# 4. cron 통계 (최근 7일 cron.log 파싱)
# ══════════════════════════════════════════════════════
CRON_LOG="$LOG_DIR/cron.log"
CRON_STATS_JSON="null"
if [[ -f "$CRON_LOG" ]]; then
  CRON_STATS_JSON=$("$NODE_BIN" -e "
    const fs = require('fs');
    const text = fs.readFileSync('$CRON_LOG', 'utf8');
    const lines = text.split('\n');
    const cutoff = new Date(); cutoff.setDate(cutoff.getDate() - 7);
    const todayStr = new Date().toISOString().slice(0,10);
    const dailyMap = {};
    const errMap = {};
    const taskStatus = {};

    for (const line of lines) {
      const dm = line.match(/^\[(\d{4}-\d{2}-\d{2})\s/);
      if (!dm || new Date(dm[1]) < cutoff) continue;
      const date = dm[1];
      const task = line.match(/\]\s*\[([^\]]+)\]/)?.[1] ?? 'unknown';
      const ts = line.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/)?.[1] ?? date;
      if (!dailyMap[date]) dailyMap[date] = { ok: 0, fail: 0 };
      const isOk = / SUCCESS | OK /.test(line);
      const isFail = /FAILED|ERROR/.test(line);
      if (isOk) { dailyMap[date].ok++; if (!taskStatus[task]) taskStatus[task]={lastRun:ts,lastStatus:'OK',failCount:0}; taskStatus[task].lastStatus='OK'; }
      if (isFail) {
        dailyMap[date].fail++;
        if (!taskStatus[task]) taskStatus[task]={lastRun:ts,lastStatus:'FAILED',failCount:0};
        taskStatus[task].lastStatus='FAILED'; taskStatus[task].failCount=(taskStatus[task].failCount||0)+1;
        if (!errMap[task]) errMap[task]={count:0,lastAt:ts};
        errMap[task].count++; if (ts > errMap[task].lastAt) errMap[task].lastAt=ts;
      }
      if (ts > (taskStatus[task]?.lastRun ?? '')) { if(taskStatus[task]) taskStatus[task].lastRun=ts; }
    }

    const daily = Array.from({length:7},(_,i)=>{
      const d=new Date(); d.setDate(d.getDate()-(6-i));
      const date=d.toISOString().slice(0,10);
      return {date, ok:dailyMap[date]?.ok??0, fail:dailyMap[date]?.fail??0};
    });
    const ok7 = daily.reduce((s,d)=>s+d.ok,0);
    const fail7 = daily.reduce((s,d)=>s+d.fail,0);
    const total7 = ok7+fail7;
    const rate = total7>0 ? Math.round(ok7/total7*100) : 0;
    const topErrors = Object.entries(errMap).map(([t,v])=>({task:t,...v})).sort((a,b)=>b.count-a.count).slice(0,5);
    const recentFailed = Object.entries(taskStatus).filter(([,s])=>s.lastStatus==='FAILED').map(([t,s])=>({task:t,...s})).sort((a,b)=>b.lastRun.localeCompare(a.lastRun)).slice(0,5);
    process.stdout.write(JSON.stringify({rate,ok7,fail7,total7,daily,topErrors,recentFailed}));
  " 2>/dev/null || echo "null")
fi

# ══════════════════════════════════════════════════════
# 5. discord-bot.jsonl 통계
# ══════════════════════════════════════════════════════
DISCORD_JSONL="$LOG_DIR/discord-bot.jsonl"
DISCORD_STATS_JSON="null"
if [[ -f "$DISCORD_JSONL" ]]; then
  DISCORD_STATS_JSON=$("$NODE_BIN" -e "
    const fs = require('fs');
    const today = new Date().toISOString().slice(0,10);
    const lines = fs.readFileSync('$DISCORD_JSONL','utf8').split('\n').filter(Boolean);
    const CH = {
      '1468386844621144065':'jarvis','1469905074661757049':'jarvis-dev',
      '1471694919339868190':'jarvis-blog','1469190688083280065':'jarvis-system',
      '1469190686145384513':'jarvis-market','1470559565258162312':'jarvis-lite',
      '1474650972310605886':'jarvis-news-webhook','1475786634510467186':'jarvis-ceo',
      '1469999923633328279':'jarvis-family','1470011814803935274':'jarvis-preply-tutor',
      '1472965899790061680':'jarvis-boram','1484008782853050483':'workgroup-board'
    };
    const channelActivity = {};
    const claudeElapseds = [];
    const stopReasons = {};
    let lastHealth = null;
    let restartCount = 0;
    let botErrors = 0;

    for (const line of lines) {
      let e; try { e=JSON.parse(line); } catch { continue; }
      const ts = e.ts ?? '';
      const msg = e.msg ?? '';
      if (msg==='Health check') lastHealth={wsPing:e.wsPing??0,memMB:e.memMB??0,uptimeSec:e.uptimeSec??0,silenceSec:e.silenceSec??0,ts};
      if (!ts.startsWith(today)) continue;
      if (msg==='messageCreate received') {
        const ch=e.channelId??'unknown';
        if(!channelActivity[ch]) channelActivity[ch]={human:0,bot:0,claudes:0,totalElapsed:0};
        if(e.bot) channelActivity[ch].bot++; else channelActivity[ch].human++;
      }
      if (msg==='Claude completed') {
        const el=parseFloat((e.elapsed??'0s').replace('s',''));
        claudeElapseds.push(el);
        const ch=e.threadId??'unknown';
        if(!channelActivity[ch]) channelActivity[ch]={human:0,bot:0,claudes:0,totalElapsed:0};
        channelActivity[ch].claudes++; channelActivity[ch].totalElapsed+=el;
        const sr=e.stopReason??'unknown';
        stopReasons[sr]=(stopReasons[sr]??0)+1;
      }
      if (msg==='Bot restarted') restartCount++;
      if (e.level==='error') botErrors++;
    }
    const count=claudeElapseds.length;
    const sorted=[...claudeElapseds].sort((a,b)=>a-b);
    const avg=count>0?Math.round(sorted.reduce((s,v)=>s+v,0)/count):0;
    const p95=count>0?Math.round(sorted[Math.floor(sorted.length*0.95)]??0):0;
    const chSorted=Object.entries(channelActivity).map(([id,v])=>({id,name:CH[id]??id.slice(-5),...v})).sort((a,b)=>(b.human+b.claudes)-(a.human+a.claudes)).slice(0,8);
    const totalHuman=Object.values(channelActivity).reduce((s,v)=>s+v.human,0);
    process.stdout.write(JSON.stringify({claudeCount:count,avgElapsed:avg,p95Elapsed:p95,stopReasons,lastHealth,restartCount,botErrors,totalHuman,channelActivity:chSorted}));
  " 2>/dev/null || echo "null")
fi

# ══════════════════════════════════════════════════════
# 6. RAG 상태
# ══════════════════════════════════════════════════════
RAG_LOG="$LOG_DIR/rag-index.log"
RAG_DB="$BOT_HOME/rag/lancedb"
RAG_INBOX="$BOT_HOME/inbox"
RAG_STATS_JSON="null"

RAG_DB_SIZE=$(du -sh "$RAG_DB" 2>/dev/null | cut -f1 || echo "?")
RAG_INBOX_COUNT=$(ls "$RAG_INBOX" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
RAG_STUCK="false"
RAG_LAST_LINE=""
RAG_CHUNKS=0

if [[ -f "$RAG_LOG" ]]; then
  # stuck 판정: rag-index 프로세스가 살아있고 마지막 완료 로그가 90분 이상 없을 때만
  RAG_PID=$(pgrep -f 'rag-index' | head -1 || true)
  if [[ -n "$RAG_PID" ]]; then
    LAST_DONE_TS=$(grep -oE '\[2[0-9]{3}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' "$RAG_LOG" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$LAST_DONE_TS" ]]; then
      LAST_DONE_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M" "$LAST_DONE_TS" +%s 2>/dev/null || echo "0")
      NOW_EPOCH=$(date +%s)
      DIFF=$(( NOW_EPOCH - LAST_DONE_EPOCH ))
      if [[ "$DIFF" -gt 5400 ]]; then RAG_STUCK="true"; fi  # 90분 = 5400초
    fi
  fi
  RAG_LAST_LINE=$(tail -1 "$RAG_LOG" 2>/dev/null | sed 's/"/\\"/g' || echo "")
  # 현재 rebuild 세션 청크 수 집계
  REBUILD_START_LINE=$(grep -n "Fresh rebuild" "$RAG_LOG" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")
  if [[ "$REBUILD_START_LINE" -gt 0 ]]; then
    RAG_CHUNKS=$(tail -n "+$REBUILD_START_LINE" "$RAG_LOG" | grep -oE 'Batch add: [0-9]+' | grep -oE '[0-9]+$' | awk '{s+=$1}END{print s+0}' || echo "0")
  fi
fi

RAG_REBUILDING_JSON="null"
if [[ -f "$STATE_DIR/rag-rebuilding.json" ]]; then
  RAG_REBUILDING_JSON=$(cat "$STATE_DIR/rag-rebuilding.json")
fi

RAG_STATS_JSON=$("$NODE_BIN" -e "
process.stdout.write(JSON.stringify({
  dbSize: '$(echo "$RAG_DB_SIZE")',
  inboxCount: parseInt('$RAG_INBOX_COUNT')||0,
  stuck: $RAG_STUCK,
  lastLine: '$(echo "$RAG_LAST_LINE" | head -c 200)',
  chunks: parseInt('$RAG_CHUNKS')||0,
  rebuilding: $RAG_REBUILDING_JSON
}));
" 2>/dev/null || echo "null")

# ══════════════════════════════════════════════════════
# 7. LaunchAgent 상태 (launchctl list)
# ══════════════════════════════════════════════════════
SERVICES=("ai.jarvis.discord-bot" "ai.jarvis.orchestrator" "ai.jarvis.watchdog" "ai.jarvis.rag-watcher" "ai.jarvis.dashboard" "ai.jarvis.webhook-listener" "ai.jarvis.event-watcher" "ai.jarvis.dashboard-tunnel" "ai.jarvis.sync-system-metrics")
LAUNCHCTL_OUT=$(launchctl list 2>/dev/null || echo "")
LAUNCH_AGENTS_JSON=$("$NODE_BIN" -e "
const out = $(echo "$LAUNCHCTL_OUT" | "$NODE_BIN" -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(d)))");
const services = $(printf '"%s"\n' "${SERVICES[@]}" | /usr/bin/jq -s -R 'split("\n")|map(select(length>0))|map(ltrimstr("\"\""))|map(gsub("^\"|\"$";""))' 2>/dev/null || echo '[]');
const result = services.map(name => {
  const line = out.split('\n').find(l=>l.includes(name));
  if (!line) return {name,pid:null,exitCode:null,loaded:false};
  const parts = line.trim().split(/\s+/);
  return {name,pid:parts[0]==='-'?null:parts[0],exitCode:parseInt(parts[1]??'0',10),loaded:true};
});
process.stdout.write(JSON.stringify(result));
" 2>/dev/null || echo "null")

# ══════════════════════════════════════════════════════
# 8. 서킷브레이커
# ══════════════════════════════════════════════════════
CB_DIR="$STATE_DIR/circuit-breaker"
CB_JSON="[]"
if [[ -d "$CB_DIR" ]]; then
  CB_JSON=$("$NODE_BIN" -e "
    const fs=require('fs'), path=require('path');
    const dir='$CB_DIR';
    try {
      const files=fs.readdirSync(dir).filter(f=>f.endsWith('.json'));
      const items=files.flatMap(f=>{try{return[JSON.parse(fs.readFileSync(path.join(dir,f),'utf8'))]}catch{return[]}});
      process.stdout.write(JSON.stringify(items.sort((a,b)=>b.last_fail_ts-a.last_fail_ts)));
    } catch { process.stdout.write('[]'); }
  " 2>/dev/null || echo "[]")
fi

# ══════════════════════════════════════════════════════
# 9. 오늘의 결정
# ══════════════════════════════════════════════════════
TODAY=$(date +%F)
DECISIONS_FILE="$STATE_DIR/decisions/${TODAY}.jsonl"
DECISIONS_JSON="[]"
if [[ -f "$DECISIONS_FILE" ]]; then
  DECISIONS_JSON=$("$NODE_BIN" -e "
    const fs=require('fs');
    const lines=fs.readFileSync('$DECISIONS_FILE','utf8').split('\n').filter(Boolean);
    const items=lines.flatMap(l=>{try{return[JSON.parse(l)]}catch{return[]}}).slice(-20);
    process.stdout.write(JSON.stringify(items));
  " 2>/dev/null || echo "[]")
fi

# ══════════════════════════════════════════════════════
# 10. 개발 큐 (pending)
# ══════════════════════════════════════════════════════
DEV_QUEUE_FILE="$STATE_DIR/dev-queue.json"
DEV_QUEUE_JSON="[]"
if [[ -f "$DEV_QUEUE_FILE" ]]; then
  DEV_QUEUE_JSON=$("$NODE_BIN" -e "
    const fs=require('fs');
    const raw=JSON.parse(fs.readFileSync('$DEV_QUEUE_FILE','utf8'));
    const items=Array.isArray(raw)?raw:Object.values(raw);
    const pending=items.filter(i=>i.status==='pending').sort((a,b)=>(b.priority??0)-(a.priority??0)).slice(0,8);
    process.stdout.write(JSON.stringify(pending));
  " 2>/dev/null || echo "[]")
fi

# ══════════════════════════════════════════════════════
# payload 최종 조합 및 POST
# ══════════════════════════════════════════════════════
PAYLOAD=$("$NODE_BIN" -e "
const p = {
  synced_at: '$SYNCED_AT',
  disk: {
    used_pct: parseInt('$DISK_USED_PCT')||0,
    free_gb: parseFloat('$DISK_FREE_GB')||0,
    total_gb: parseFloat('$DISK_TOTAL_GB')||0
  },
  memory: {
    used_pct: parseInt('$MEM_USED_PCT')||0,
    used_gb: parseFloat('$MEM_USED_GB')||0,
    total_gb: parseFloat('$MEM_TOTAL_GB')||0
  },
  cpu: {
    used_pct: parseInt('$CPU_USED_PCT')||0,
    load_avg: parseFloat('$CPU_LOAD_AVG')||0,
    n_cores: parseInt('$CPU_N_CORES')||1
  },
  health: $HEALTH_JSON,
  scorecard: $SCORECARD_JSON,
  cron_stats: $CRON_STATS_JSON,
  discord_stats: $DISCORD_STATS_JSON,
  rag_stats: $RAG_STATS_JSON,
  launch_agents: $LAUNCH_AGENTS_JSON,
  circuit_breakers: $CB_JSON,
  decisions_today: $DECISIONS_JSON,
  dev_queue: $DEV_QUEUE_JSON
};
process.stdout.write(JSON.stringify(p));
" 2>/dev/null)

if [[ -z "$PAYLOAD" ]]; then
  echo "[$(date '+%F %T')] sync FAILED — payload 생성 실패" >&2
  exit 1
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$BOARD_URL/api/system-metrics" \
  -H "Content-Type: application/json" \
  -H "x-agent-key: $API_KEY" \
  -d "$PAYLOAD")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "[$(date '+%F %T')] sync OK — disk=${DISK_USED_PCT}% | mem=${MEM_USED_PCT}% (${MEM_USED_GB}/${MEM_TOTAL_GB}GB) | cpu=${CPU_USED_PCT}% load=${CPU_LOAD_AVG} | cron=$(echo "$CRON_STATS_JSON" | "$NODE_BIN" -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const r=JSON.parse(d);process.stdout.write(r.rate+'%')}catch{process.stdout.write('?')}})" 2>/dev/null)%"
else
  echo "[$(date '+%F %T')] sync FAILED — HTTP $HTTP_CODE" >&2
  exit 1
fi