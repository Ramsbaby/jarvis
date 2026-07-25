#!/usr/bin/env bash
# owner-state-engine.sh — 참견 v3 메인 오케스트레이터
#
# 체인: 1층 collect → 2층 insight(LLM) → 3층 gate → 발송(또는 DRYRUN)
# 통찰 0개면 침묵(정상). DRYRUN=true(기본)면 1주 검증용으로 실발송 없이 기록만.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
OS_LIB="${BOT_HOME}/lib/owner-state"
DIR="${BOT_HOME}/state/owner-state"
LOG="${BOT_HOME}/logs/owner-state-engine.log"
DRYRUN="${OSE_DRYRUN:-true}"   # 기본 DRYRUN — 1주 검증 후 false로 전환
mkdir -p "$DIR/dryrun" "$(dirname "$LOG")"

log() { printf '[%s] [ose] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
log "=== 시작 (DRYRUN=$DRYRUN) ==="

# ── 1층 통합 뷰 ──
node "$OS_LIB/collect-snapshot.mjs" >> "$LOG" 2>&1 || { log "collect 실패"; exit 1; }
# ── 1층 값싼 눈: 결정론적 fact-signals (LLM 0, 비결정성 하한선) ──
node "$OS_LIB/fact-signals.mjs" >> "$LOG" 2>&1 || log "fact-signals 경고(계속 진행)"

# ── 능동 트리거: 상태 변화 없으면 침묵 (정기 발화 안티패턴 제거 — "필요한 순간"에만) ──
# 변화 = fact-signals / 답글(open_insights) / 일정 변동. 같으면 LLM 안 돌고 침묵.
STATE_HASH=$(BOT_HOME="$BOT_HOME" node --input-type=module -e '
import { readFileSync } from "node:fs"; import { createHash } from "node:crypto";
const d = process.env.BOT_HOME + "/state/owner-state"; let s = "";
try { s += readFileSync(d + "/fact-signals.json", "utf8"); } catch {}
try { const snap = JSON.parse(readFileSync(d + "/snapshot-latest.json", "utf8")); s += JSON.stringify(snap.open_insights || []); s += JSON.stringify((snap.calendar || []).map(e => e.summary + e.date + e.dday)); } catch {}
process.stdout.write(createHash("sha1").update(s).digest("hex").slice(0, 16));
')
PREV_HASH=$(cat "$DIR/.state-hash" 2>/dev/null || echo "none")
if [ "$STATE_HASH" = "$PREV_HASH" ] && [ "${OSE_FORCE:-}" != "1" ]; then
  log "상태 변화 없음 (hash=$STATE_HASH) — 침묵, LLM 스킵"
  echo "[ose] 변화 없음 — 침묵 (능동 트리거: 챙길 새 변화 없음)"
  exit 0
fi
echo "$STATE_HASH" > "$DIR/.state-hash"
# 2026-07-25: 화살표(→)가 변수명에 이어붙어 "PREV_HASH→" 라는 없는 변수로 해석됐고,
#   set -u 때문에 매번 이 줄에서 즉시 종료됐다. 중괄호로 변수 경계를 명시한다.
log "상태 변화 감지 (${PREV_HASH}→${STATE_HASH}) — 통찰 진행"

# ── 2층 비싼 머리: LLM 통찰 ──
bash "$OS_LIB/insight-llm.sh" >> "$LOG" 2>&1 || { log "insight 실패"; exit 1; }
# ── 3층 노이즈 게이트 ──
node "$OS_LIB/noise-gate.mjs" >> "$LOG" 2>&1 || { log "gate 실패"; exit 1; }

GATED="$DIR/insights-gated.json"
COUNT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$GATED','utf8')).length)" 2>/dev/null || echo 0)

# ── 침묵 기본값 ──
if [ "$COUNT" -eq 0 ]; then
  log "통찰 0개 — 침묵 (정상)"
  echo "[ose] 통찰 0 — 침묵"
  exit 0
fi

# ── 메시지 구성 ──
export GATED
MSG=$(node --input-type=module -e '
import { readFileSync } from "node:fs";
const g = JSON.parse(readFileSync(process.env.GATED, "utf8"));
const icon = { "모순":"⚖️", "맹점":"🔍", "리스크":"⚠️" };
const lines = g.map(x => {
  let s = `${icon[x.type] || "•"} **${x.type}**\n${x.insight}`;
  if (x.action) s += `\n\n→ **무엇을**: ${x.action}`;
  if (x.question && x.question.length > 3) s += `\n❓ **여쭙니다**: ${x.question}`;
  return s;
});
process.stdout.write("🎩 주인님, 오늘 깊이 짚어드릴 것이 있습니다.\n\n" + lines.join("\n\n━━━\n\n"));
')

# ── 발송 (DRYRUN이면 기록만) ──
if [ "$DRYRUN" = "true" ]; then
  OUT="$DIR/dryrun/$(date '+%Y%m%d-%H%M').md"
  printf '%s\n' "$MSG" > "$OUT"
  log "[DRYRUN] 발송 안 함 — $OUT (${COUNT}개 통찰)"
  echo "[ose] DRYRUN: ${COUNT}개 통찰 → $(basename "$OUT") (실발송 X)"
else
  # 통찰 영속(id 부여) → webhook ?wait=true 발송(메시지 id 회수) → id 매핑(양방향 다리)
  WEBHOOK=$(node -e "try{console.log(require('$BOT_HOME/config/monitoring.json').webhooks['jarvis']||'')}catch(e){console.log('')}")
  if [ -n "$WEBHOOK" ]; then
    MSG="$MSG" WEBHOOK="$WEBHOOK" GATED="$GATED" node --input-type=module -e '
    import { persistInsights, linkDiscordMessage } from "'"$OS_LIB"'/insight-store.mjs";
    import { recordSent } from "'"$OS_LIB"'/feedback-loop.mjs";
    import { readFileSync } from "node:fs";
    import https from "node:https";
    const g = JSON.parse(readFileSync(process.env.GATED, "utf8"));
    const saved = persistInsights(g);  // id 부여
    recordSent(g);
    const ids = saved.map(x => x.id);
    const url = new URL(process.env.WEBHOOK); url.searchParams.set("wait", "true");  // 메시지 객체 회수
    const body = JSON.stringify({ content: (process.env.MSG || "").slice(0, 1900) });
    const req = https.request(url, { method: "POST", headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } }, r => {
      let data = ""; r.on("data", c => data += c);
      r.on("end", () => {
        if (r.statusCode === 200) { try { const m = JSON.parse(data); linkDiscordMessage(m.id, ids); console.log("[discord] sent+linked msg=" + m.id + " ("+ids.length+"통찰)"); } catch (e) { console.log("[discord] link 실패 " + e.message); } }
        else console.log("[discord] status " + r.statusCode);
      });
    });
    req.on("error", e => console.error("[discord] err " + e.message));
    req.write(body); req.end();
    ' && log "발송+매핑 완료" || log "발송 실패"
  else
    log "jarvis webhook 없음 — 발송 스킵"; echo "[ose] webhook 없음"
    node --input-type=module -e 'import { persistInsights } from "'"$OS_LIB"'/insight-store.mjs"; import { readFileSync } from "node:fs"; persistInsights(JSON.parse(readFileSync(process.env.GATED,"utf8")));'
  fi
  log "발송 완료 — ${COUNT}개 통찰"
  echo "[ose] 발송: ${COUNT}개"
fi
