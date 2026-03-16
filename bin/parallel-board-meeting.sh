#!/usr/bin/env bash
# parallel-board-meeting.sh — 병렬화 Board Meeting (~10min, 기존 ~18min 대비)
#
# Call A (fast): context-bus.md 운영 스냅샷 갱신 (~4min)
# Call B (deep): 회의록 + 결정 + OKR 분석 (~10min)
# 동시 실행 → 총 ~10min
#
# Usage: parallel-board-meeting.sh [daily|weekly|emergency]
# 크론: 0 8 * * * / 55 21 * * *

source "${JARVIS_HOME:-${BOT_HOME:-$HOME/.jarvis}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)}"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

MEETING_TYPE="${1:-daily}"
TIMESTAMP="$(date +%F_%H%M)"
LOG_FILE="${BOT_HOME}/logs/board-meeting.log"
MINUTES_DIR="${BOT_HOME}/state/board-minutes"
DECISIONS_DIR="${BOT_HOME}/state/decisions"
RESULTS_DIR="${BOT_HOME}/results/board-meeting"
RESULT_FILE="${RESULTS_DIR}/${TIMESTAMP}.md"
STDERR_LOG_A="${BOT_HOME}/logs/claude-stderr-board-meeting-a.log"
STDERR_LOG_B="${BOT_HOME}/logs/claude-stderr-board-meeting-b.log"

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

for cmd in claude jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found" >&2; exit 2; }
done

mkdir -p "$MINUTES_DIR" "$DECISIONS_DIR" "$RESULTS_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date -u +%FT%TZ)] board-meeting(parallel): $*" >> "$LOG_FILE"; }
log "Starting ${MEETING_TYPE} parallel board meeting"

# ─── Data Collection (동일: board-meeting.sh 기반) ───────────────────────
TODAY="$(date +%F)"

CRON_LOG="${BOT_HOME}/logs/cron.log"
# shellcheck disable=SC2086
SEVEN_DAYS_PATTERN=$(for i in $(seq 0 6); do \
    date -v-${i}d '+%Y-%m-%d' 2>/dev/null || date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null; \
done | tr '\n' '|' | sed 's/|$//')
CRON_SUCCESS=0; CRON_FAIL=0
if [[ -f "$CRON_LOG" ]]; then
    CRON_SUCCESS=$(grep -E "^\[($SEVEN_DAYS_PATTERN)" "$CRON_LOG" 2>/dev/null | awk '/ SUCCESS/' | wc -l | tr -d ' \n') || CRON_SUCCESS=0
    CRON_FAIL=$(grep -E "^\[($SEVEN_DAYS_PATTERN)" "$CRON_LOG" 2>/dev/null | awk '/ (FAILED|ABORTED)/' | wc -l | tr -d ' \n') || CRON_FAIL=0
fi
CRON_SUCCESS=$(printf '%d' "${CRON_SUCCESS:-0}" 2>/dev/null || echo 0)
CRON_FAIL=$(printf '%d' "${CRON_FAIL:-0}" 2>/dev/null || echo 0)
CRON_TOTAL=$(( CRON_SUCCESS + CRON_FAIL ))
CRON_RATE=$( [[ "$CRON_TOTAL" -gt 0 ]] && echo $(( CRON_SUCCESS * 100 / CRON_TOTAL )) || echo "N/A" )

DISK_PCT=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' || echo "?")
LOAD=$(uptime 2>/dev/null | sed 's/.*load averages: //' || echo "?")
LAUNCHD=$($IS_MACOS && launchctl list 2>/dev/null | grep -E 'jarvis' | awk '{printf "%s(pid:%s) ", $3, $1}' || echo "확인불가")

read_latest() {
    local dir="$1" max_chars="${2:-500}"
    local f; f=$(ls -t "${dir}/"*.md 2>/dev/null | head -1)
    [[ -n "$f" ]] && head -c "$max_chars" "$f" 2>/dev/null || echo "데이터 없음"
}

HEALTH_SNAP=$(read_latest "${BOT_HOME}/results/system-health" 200)
TQQQ_SNAP=$(read_latest "${BOT_HOME}/results/tqqq-monitor" 350)
INFRA_SNAP=$(read_latest "${BOT_HOME}/results/infra-daily" 350)
NEWS_SNAP=$(read_latest "${BOT_HOME}/results/news-briefing" 200)
GOALS_JSON=$(cat "${BOT_HOME}/config/goals.json" 2>/dev/null || echo '{}')
DNA_CORE=$(sed -n '/^## 핵심 DNA/,/^## 일반 DNA/p' "${BOT_HOME}/config/company-dna.md" 2>/dev/null | head -30 || echo "없음")
PREV_BUS=$(head -c 400 "${BOT_HOME}/state/context-bus.md" 2>/dev/null || echo "없음")
INBOX_FILES=$(find "${BOT_HOME}/rag/teams/shared-inbox/" -maxdepth 1 -name "*.md" ! -name "README*" 2>/dev/null || true)
INBOX_SUMMARY=""
if [[ -n "$INBOX_FILES" ]]; then
    INBOX_SUMMARY="미처리 메시지 $(echo "$INBOX_FILES" | wc -l | tr -d ' ')건: $(echo "$INBOX_FILES" | xargs -I{} basename {} | tr '\n' ', ')"
fi
PREV_DECISIONS=""
if [[ -f "${DECISIONS_DIR}/${TODAY}.jsonl" ]]; then
    PREV_DECISIONS=$(cat "${DECISIONS_DIR}/${TODAY}.jsonl" 2>/dev/null)
fi
TEAM_SCORECARD=""
if [[ -f "${BOT_HOME}/state/team-scorecard.json" ]]; then
    TEAM_SCORECARD=$(SCORECARD_PATH="${BOT_HOME}/state/team-scorecard.json" python3 -c "
import json, os
with open(os.environ['SCORECARD_PATH']) as f: data = json.load(f)
lines = []
for name, t in data['teams'].items():
    m = {'NORMAL':'','WARNING':'[!]','PROBATION':'[!!]','DISCIPLINARY':'[!!!]'}.get(t['status'],'')
    lines.append(f\"{name}: merit {t['merit']} / penalty {t['penalty']} {t['status']} {m}\")
print('\n'.join(lines))
" 2>/dev/null || echo "성과표 없음")
fi
PREV_DISPATCH=""
if [[ -f "${BOT_HOME}/state/dispatch-results/${TODAY}.jsonl" ]]; then
    PREV_DISPATCH=$(cat "${BOT_HOME}/state/dispatch-results/${TODAY}.jsonl" 2>/dev/null)
fi
CEO_PROFILE=""
if [[ -f "${BOT_HOME}/agents/ceo.md" ]]; then
    CEO_PROFILE=$(awk '/^## 판정 순서|^## 팀장 관리/{p=1} /^## 출력 형식|^## 산출물/{p=0} p{print}' "${BOT_HOME}/agents/ceo.md")
fi

# ─── Skip / Lock / Rate-limit (board-meeting.sh와 동일) ──────────────────
SKIP_STATE_FILE="${BOT_HOME}/state/board-meeting-skip.json"
LAST_RUN_MTIME=0
LAST_BOARD_FILE=$(ls -t "${RESULTS_DIR}/"*.md 2>/dev/null | head -1 || true)
if [[ -n "$LAST_BOARD_FILE" ]]; then
    LAST_RUN_MTIME=$(stat -f '%m' "$LAST_BOARD_FILE" 2>/dev/null || stat -c '%Y' "$LAST_BOARD_FILE" 2>/dev/null || echo 0)
fi

TRACKED_DIRS=( "${BOT_HOME}/results/infra-daily" "${BOT_HOME}/results/news-briefing"
               "${BOT_HOME}/results/system-health" "${BOT_HOME}/results/tqqq-monitor"
               "${BOT_HOME}/state/context-bus.md" )
CHANGED_COUNT=0
for tracked in "${TRACKED_DIRS[@]}"; do
    if [[ -f "$tracked" ]]; then
        FILE_MTIME=$(stat -f '%m' "$tracked" 2>/dev/null || stat -c '%Y' "$tracked" 2>/dev/null || echo 0)
        (( FILE_MTIME > LAST_RUN_MTIME )) && (( CHANGED_COUNT++ )) || true
    elif [[ -d "$tracked" ]]; then
        LATEST_IN_DIR=$(ls -t "${tracked}/"*.md 2>/dev/null | head -1 || true)
        if [[ -n "$LATEST_IN_DIR" ]]; then
            DIR_MTIME=$(stat -f '%m' "$LATEST_IN_DIR" 2>/dev/null || stat -c '%Y' "$LATEST_IN_DIR" 2>/dev/null || echo 0)
            (( DIR_MTIME > LAST_RUN_MTIME )) && (( CHANGED_COUNT++ )) || true
        fi
    fi
done

CONSECUTIVE_SKIPS=0
if [[ -f "$SKIP_STATE_FILE" ]]; then
    CONSECUTIVE_SKIPS=$(python3 -c "import json; print(json.load(open('${SKIP_STATE_FILE}')).get('consecutive_skips',0))" 2>/dev/null || echo 0)
fi

if (( CHANGED_COUNT < 2 && CONSECUTIVE_SKIPS < 2 )); then
    log "새 변경 ${CHANGED_COUNT}개 — 스킵 (연속 ${CONSECUTIVE_SKIPS}회)"
    python3 -c "
import json
try: data=json.load(open('${SKIP_STATE_FILE}'))
except: data={}
data['consecutive_skips']=${CONSECUTIVE_SKIPS}+1; data['last_skipped']='${TIMESTAMP}'
json.dump(data,open('${SKIP_STATE_FILE}','w'))
" 2>/dev/null || true
    exit 0
fi
python3 -c "
import json
try: data=json.load(open('${SKIP_STATE_FILE}'))
except: data={}
data['consecutive_skips']=0; data['last_run']='${TIMESTAMP}'
json.dump(data,open('${SKIP_STATE_FILE}','w'))
" 2>/dev/null || true

LOCK_FILE="/tmp/jarvis-board-meeting.lock"
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
    kill -0 "$LOCK_PID" 2>/dev/null && { log "Another board meeting running (PID $LOCK_PID), skipping"; exit 0; }
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
CAFFEINATE_PID=""
$IS_MACOS && { caffeinate -i -w $$ & CAFFEINATE_PID=$!; }
trap 'rm -f "$LOCK_FILE"; $IS_MACOS && ${CAFFEINATE_PID:+kill "$CAFFEINATE_PID" 2>/dev/null || true}' EXIT

RATE_FILE="${BOT_HOME}/state/rate-tracker.json"
if [[ -f "$RATE_FILE" ]]; then
    RATE_COUNT=$(RATE_PATH="$RATE_FILE" python3 -c "
import json,time,os
with open(os.environ['RATE_PATH']) as f: d=json.load(f)
cutoff=int(time.time()*1000)-5*3600*1000
print(len([t for t in d if t>cutoff]))
" 2>/dev/null || echo "0")
    if (( RATE_COUNT > 720 )); then
        log "Rate limit high (${RATE_COUNT}/900), skipping"
        exit 0
    fi
fi

# ─── LLM Gateway ─────────────────────────────────────────────────────────
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
source "${BOT_HOME}/lib/llm-gateway.sh"

# ─── Prompt A: Context Bus (운영 스냅샷, 빠른 출력) ──────────────────────
PROMPT_A="$(cat <<PROMPT_EOF
# 자비스 컴퍼니 CEO — Context Bus 갱신

${CEO_PROFILE}

## 시간: $(date '+%Y-%m-%d %H:%M KST') / 유형: ${MEETING_TYPE}

## 운영 데이터
- 크론 성공률: ${CRON_RATE}% (${CRON_SUCCESS}/${CRON_TOTAL})
- 디스크: ${DISK_PCT} | 로드: ${LOAD}
- LaunchAgent: ${LAUNCHD}
- 헬스: ${HEALTH_SNAP}
- 인프라: ${INFRA_SNAP}
- TQQQ: ${TQQQ_SNAP}
- 뉴스: ${NEWS_SNAP}
- 팀 성과표: ${TEAM_SCORECARD:-데이터 없음}
- 이전 context-bus: ${PREV_BUS}
- 오늘 결정: ${PREV_DECISIONS:-없음}

## 판정
- 시스템: GREEN(95%+) / YELLOW(70-95%) / RED(<70%)
- 시장: SAFE(TQQQ>\$50) / CAUTION(\$47-50) / CRITICAL(<\$47)

## 산출물 (Write 도구로 작성)
파일: ~/.jarvis/state/context-bus.md (덮어쓰기)
\`\`\`
# 자비스 컴퍼니 Context Bus
_업데이트: ${TODAY}T$(date +%H:%M) KST_
## 시스템 상태
크론 성공률: XX% — GREEN/YELLOW/RED
주요 실패 태스크: [없으면 '없음']
LaunchAgent: [상태 요약]
## 시장 신호
TQQQ: \$XX.XX — SAFE/CAUTION/CRITICAL
손절선(\$47) 대비: +\$X.XX (XX% 여유)
## 이번 주 중요 신호
[핵심 트렌드/변화 2~3개, 수치 포함]
## 팀별 핵심 현황
[각 팀 1줄. GREEN/YELLOW/RED + 핵심 이슈]
## CEO 주목사항
[가장 중요한 발견/권고 1~2줄]
\`\`\`

## stdout 출력
"✅ Context Bus 갱신 완료 — 시스템 XX%/시장 XX" 한 줄만.
PROMPT_EOF
)"

# ─── Prompt B: 회의록 + 결정 + OKR (심층 분석) ──────────────────────────
PROMPT_B="$(cat <<PROMPT_EOF
# 자비스 컴퍼니 CEO — Board Meeting (회의록/결정/OKR)

${CEO_PROFILE}

## 시간: $(date '+%Y-%m-%d %H:%M KST') / 유형: ${MEETING_TYPE}

## 사전 수집 데이터
### 인프라
- 크론 성공률: ${CRON_RATE}% (${CRON_SUCCESS}/${CRON_TOTAL}) | 디스크: ${DISK_PCT} | 로드: ${LOAD}
- 헬스: ${HEALTH_SNAP} | 인프라: ${INFRA_SNAP}
### 시장
- TQQQ: ${TQQQ_SNAP} | 뉴스: ${NEWS_SNAP}
### 내부
- 공용게시판: ${PREV_BUS}
- 팀 인박스: ${INBOX_SUMMARY:-없음}
- 오늘 이전 결정: ${PREV_DECISIONS:-없음}
- 결정 실행 결과: ${PREV_DISPATCH:-없음}
### 팀 성과표
${TEAM_SCORECARD:-데이터 없음}
### OKR
${GOALS_JSON}
### Company DNA
${DNA_CORE}

## 판정
- 시스템: GREEN(95%+) / YELLOW(70-95%) / RED(<70%)
- 시장: SAFE(TQQQ>\$50) / CAUTION(\$47-50) / CRITICAL(<\$47)

## 산출물 (Write 도구로 작성)

### 1. 회의록
파일: ~/.jarvis/state/board-minutes/${TODAY}.md
내용: 인프라/시장 분석(수치+원인), CEO 판단 근거, OKR 진척, 결정사항

### 2. 의사결정 감사 로그
파일: ~/.jarvis/state/decisions/${TODAY}.jsonl (append)
형식: {"ts":"$(date -u +%FT%TZ)","decision":"내용","rationale":"근거","team":"담당팀","okr":"KR ID","status":"confirmed"}

### 3. OKR 진척도 갱신 (측정 가능할 때만)
파일: ~/.jarvis/config/goals.json — current 값 업데이트, lastUpdated 갱신. 측정 불가 KR은 null 유지.

### 4. Connections (내부용)
Write → ~/.jarvis/state/connections-draft.json (stdout 출력 금지)
형식: [{"from":"A","to":"B","relationship":"이유","strength":0.0}] 최대 5개.

## 최종 stdout (Discord 전송용, 800자 이내)
placeholder(XX%) 금지, 실수치 필수.

📋 **이사회 보고 — ${TODAY} $(date +%H:%M)**
🟢/🟡/🔴 **시스템** · 크론 XX% (목표 95%) — GREEN/YELLOW/RED
📈 **시장** · TQQQ \$XX.XX — 손절선(\$47) 대비 +\$X.XX (SAFE/CAUTION/CRITICAL)
🎯 **OKR** · [가장 진척/위험 KR 1줄]
⚡ **주목** · [오늘 가장 중요한 발견 1줄]
✅ **결정**
- [결정사항] (담당팀 명시)
PROMPT_EOF
)"

# ─── 병렬 실행 ────────────────────────────────────────────────────────────
TMP_A="/tmp/board-parallel-$$-a.json"
TMP_B="/tmp/board-parallel-$$-b.json"
START_TIME=$(date +%s)

log "Call A (context-bus) 시작"
llm_call \
    --prompt "$PROMPT_A" \
    --timeout 240 \
    --allowed-tools "Read,Bash,Write" \
    --max-budget "0.40" \
    --model "claude-sonnet-4-6" \
    --mcp-config "${BOT_HOME}/config/empty-mcp.json" \
    --output "$TMP_A" \
    2>"$STDERR_LOG_A" &
PID_A=$!

log "Call B (회의록+결정+OKR) 시작"
llm_call \
    --prompt "$PROMPT_B" \
    --timeout 360 \
    --allowed-tools "Read,Bash,Write" \
    --max-budget "0.80" \
    --model "claude-sonnet-4-6" \
    --mcp-config "${BOT_HOME}/config/empty-mcp.json" \
    --output "$TMP_B" \
    2>"$STDERR_LOG_B" &
PID_B=$!

# 두 call 완료 대기
EXIT_A=0; EXIT_B=0
wait "$PID_A" || EXIT_A=$?
wait "$PID_B" || EXIT_B=$?

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log "병렬 실행 완료 — ${DURATION}s (A: exit=${EXIT_A}, B: exit=${EXIT_B})"

# ─── 결과 수집 ────────────────────────────────────────────────────────────
RESULT_A=""; COST_A="0"
if [[ $EXIT_A -eq 0 && -s "$TMP_A" ]]; then
    RESULT_A=$(jq -r '.result // empty' "$TMP_A" 2>/dev/null || echo "")
    COST_A=$(jq -r '.cost_usd // 0' "$TMP_A" 2>/dev/null || echo "0")
fi

RESULT_B=""; COST_B="0"
if [[ $EXIT_B -eq 0 && -s "$TMP_B" ]]; then
    RESULT_B=$(jq -r '.result // empty' "$TMP_B" 2>/dev/null || echo "")
    COST_B=$(jq -r '.cost_usd // 0' "$TMP_B" 2>/dev/null || echo "0")
fi

# 양쪽 다 실패 시 종료
if [[ -z "$RESULT_A" && -z "$RESULT_B" ]]; then
    log "FAILED: 양쪽 call 모두 실패 (A:${EXIT_A}, B:${EXIT_B}, ${DURATION}s)"
    rm -f "$TMP_A" "$TMP_B"
    exit 1
fi

# Call B 실패 시 단독 보고 (A만 성공)
if [[ -z "$RESULT_B" ]]; then
    log "WARN: Call B 실패 (exit=${EXIT_B}) — A 결과만 사용"
    RESULT_B="⚠️ 회의록/결정 생성 실패 (Call B exit=${EXIT_B}). Context Bus는 갱신됐습니다."
fi

# 최종 결과 = B (Discord 전송용) + A 상태 앞붙임
TOTAL_COST=$(python3 -c "print(round(${COST_A}+${COST_B},4))" 2>/dev/null || echo "0")
RESULT="${RESULT_A:+${RESULT_A}
}${RESULT_B}"

# ─── 결과 저장 ────────────────────────────────────────────────────────────
echo "$RESULT" > "$RESULT_FILE"
log "SUCCESS (${DURATION}s, cost \$${TOTAL_COST}, A:\$${COST_A} B:\$${COST_B})"

# ─── goals.json bash 자동 갱신 (B 완료 후) ───────────────────────────────
GOALS_PATH="${BOT_HOME}/config/goals.json"
CRON_RATE_VAL="${CRON_RATE}"
TODAY_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - <<PYEOF 2>/dev/null && log "goals.json KR 자동 갱신 완료" || log "WARN: goals.json KR 갱신 부분 실패"
import json, re, os

path = '${GOALS_PATH}'
with open(path) as f:
    goals = json.load(f)

today_iso = '${TODAY_ISO}'
updated = False

health_path = os.path.expanduser('~/.jarvis/state/health.json')
crash_count = 0
try:
    with open(health_path) as f: health = json.load(f)
    crash_count = health.get('crash_count', 0)
except Exception:
    pass
downtime_str = f"약 {crash_count}분" if crash_count > 0 else "0분"

e2e_str = None
try:
    log_path = os.path.expanduser('~/.jarvis/logs/e2e-cron.log')
    with open(log_path) as f: lines = f.readlines()
    result_line = next((l for l in reversed(lines) if 'passed' in l), None)
    if result_line:
        m = re.search(r'(\d+)/(\d+)\s+passed', result_line)
        if m:
            passed, total = int(m.group(1)), int(m.group(2))
            e2e_str = f"{round(passed/total*100,1) if total>0 else 0}% ({passed}/{total})"
except Exception:
    pass

tqqq_str = None
try:
    log_path = os.path.expanduser('~/.jarvis/logs/cron.log')
    with open(log_path) as f: content = f.read()
    tqqq_lines = [l for l in content.split('\n') if 'tqqq-monitor' in l]
    tqqq_ok = sum(1 for l in tqqq_lines if 'SUCCESS' in l)
    tqqq_total = sum(1 for l in tqqq_lines if 'SUCCESS' in l or 'FAIL' in l)
    if tqqq_total > 0:
        tqqq_str = f"{round(tqqq_ok/tqqq_total*100)}% ({tqqq_ok}/{tqqq_total})"
except Exception:
    pass

cost_str = "\$0 (Claude Max 정액)"
MANUAL_KEYWORDS = ('학습','포트폴리오','이력서','알림','RAG')

cron_rate_val = '${CRON_RATE_VAL}'
for obj in goals.get('objectives', []):
    for kr in obj.get('keyResults', []):
        metric = kr.get('metric', '')
        kr_id  = kr.get('id', '')
        if kr_id == 'KR1-1':
            if re.match(r'^\d+$', cron_rate_val):
                kr['current'] = f"{cron_rate_val}%"; kr['lastUpdated'] = today_iso; updated = True
        elif '다운타임' in metric:
            kr['current'] = downtime_str; kr['lastUpdated'] = today_iso; updated = True
        elif 'E2E' in metric:
            if e2e_str: kr['current'] = e2e_str; kr['lastUpdated'] = today_iso; updated = True
        elif '손절선' in metric or 'TQQQ' in metric:
            if tqqq_str: kr['current'] = tqqq_str; kr['lastUpdated'] = today_iso; updated = True
        elif '비용' in metric:
            kr['current'] = cost_str; kr['lastUpdated'] = today_iso; updated = True
        elif any(kw in metric for kw in MANUAL_KEYWORDS):
            kr.setdefault('note', '수동측정')

if updated:
    goals['lastUpdated'] = today_iso
    with open(path, 'w') as f:
        json.dump(goals, f, ensure_ascii=False, indent=2)
    print('updated')
PYEOF

# ─── Connections 추출 ─────────────────────────────────────────────────────
CONNECTIONS_FILE="${BOT_HOME}/state/connections.jsonl"
CONNECTIONS_DRAFT="${BOT_HOME}/state/connections-draft.json"
SESSION_LABEL=$(date +%H | awk '{print ($1+0 < 12) ? "am" : "pm"}')
python3 - <<PYEOF 2>/dev/null || true
import json, re, os
conns = None
draft = '${CONNECTIONS_DRAFT}'
if os.path.exists(draft):
    try:
        conns = json.load(open(draft))
        os.remove(draft)
    except Exception: pass
if not conns:
    result = open('${RESULT_FILE}').read()
    m = re.search(r'CONNECTIONS_JSON:(\[.+\])', result)
    if m:
        try: conns = json.loads(m.group(1))
        except Exception: pass
if not conns:
    import sys; sys.exit(0)
record = json.dumps({'date':'${TODAY}','session':'${SESSION_LABEL}','connections':conns}, ensure_ascii=False)
with open('${CONNECTIONS_FILE}','a') as f:
    f.write(record+'\n')
PYEOF

# ─── Rate tracker 업데이트 ────────────────────────────────────────────────
if [[ -f "$RATE_FILE" ]]; then
    python3 -c "
import json, time
path = '${RATE_FILE}'
try:
    with open(path) as f: d = json.load(f)
except Exception: d = []
d.append(int(time.time()*1000))
with open(path, 'w') as f: json.dump([t for t in d if t > int(time.time()*1000)-5*3600*1000], f)
" 2>/dev/null || true
fi

# ─── Rotate old results ───────────────────────────────────────────────────
find "$RESULTS_DIR" -name "*.md" -mtime +30 -delete 2>/dev/null || true
find "$MINUTES_DIR" -name "*.md" -mtime +90 -delete 2>/dev/null || true

# ─── Cleanup ──────────────────────────────────────────────────────────────
rm -f "$TMP_A" "$TMP_B"

# ─── stdout 출력 (Discord 전송용) ─────────────────────────────────────────
echo "$RESULT_B" | sed '/^CONNECTIONS_JSON:/d'

# ─── Decision Dispatcher ──────────────────────────────────────────────────
DISPATCHER="${BOT_HOME}/bin/decision-dispatcher.sh"
if [[ -x "$DISPATCHER" ]]; then
    log "Running decision dispatcher..."
    DISPATCH_OUTPUT=$("$DISPATCHER" 2>>"${BOT_HOME}/logs/decision-dispatcher.log" || true)
    if [[ -n "$DISPATCH_OUTPUT" ]]; then
        log "Dispatcher result: $(echo "$DISPATCH_OUTPUT" | head -1)"
        echo ""
        echo "$DISPATCH_OUTPUT"
    fi
fi
