#!/usr/bin/env bash
set -euo pipefail

# board-meeting.sh — 자비스 컴퍼니 Board Meeting (단일 에이전트 + OKR/감사 연동)
# Usage: board-meeting.sh [daily|weekly|emergency]
# 크론: 0 8 * * * (아침) / 55 21 * * * (저녁)
# 기존 council-insight의 상위 호환. goals.json + decisions-audit.jsonl 연동.

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true
MEETING_TYPE="${1:-daily}"
TIMESTAMP="$(date +%F_%H%M)"
LOG_FILE="${BOT_HOME}/logs/board-meeting.log"
MINUTES_DIR="${BOT_HOME}/state/board-minutes"
DECISIONS_DIR="${BOT_HOME}/state/decisions"
RESULTS_DIR="${BOT_HOME}/results/board-meeting"
RESULT_FILE="${RESULTS_DIR}/${TIMESTAMP}.md"
STDERR_LOG="${BOT_HOME}/logs/claude-stderr-board-meeting.log"

for cmd in gtimeout claude jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found" >&2; exit 2; }
done

mkdir -p "$MINUTES_DIR" "$DECISIONS_DIR" "$RESULTS_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date -u +%FT%TZ)] board-meeting: $*" >> "$LOG_FILE"; }
log "Starting ${MEETING_TYPE} board meeting"

# --- Pre-collect data (bash 단계에서 수집, claude 토큰 절약) ---
TODAY="$(date +%F)"
# 최근 24시간 task-runner.jsonl 기반 성공률 계산 (stale cron.log 대신)
# cron.log 기반 성공률 계산 (최근 24시간, YYYY-MM-DD HH 형식 비교)
CRON_LOG="${BOT_HOME}/logs/cron.log"
CUTOFF_DATE=$(date -v-24H '+%Y-%m-%d %H' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%d %H')
CRON_SUCCESS=0
CRON_FAIL=0
if [[ -f "$CRON_LOG" ]]; then
    CRON_SUCCESS=$(awk -v cutoff="$CUTOFF_DATE" \
        'substr($0,2,13) >= cutoff && / SUCCESS/' "$CRON_LOG" | wc -l | tr -d ' ') || CRON_SUCCESS=0
    CRON_FAIL=$(awk -v cutoff="$CUTOFF_DATE" \
        'substr($0,2,13) >= cutoff && / (FAILED|ABORTED)/' "$CRON_LOG" | wc -l | tr -d ' ') || CRON_FAIL=0
fi
CRON_SUCCESS="${CRON_SUCCESS:-0}"
CRON_FAIL="${CRON_FAIL:-0}"
CRON_TOTAL=$(( CRON_SUCCESS + CRON_FAIL ))
if [[ "$CRON_TOTAL" -gt 0 ]]; then
    CRON_RATE=$(( CRON_SUCCESS * 100 / CRON_TOTAL ))
else
    CRON_RATE="N/A"
fi

DISK_PCT=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' || echo "?")
LOAD=$(uptime 2>/dev/null | sed 's/.*load averages: //' || echo "?")
LAUNCHD=$(launchctl list 2>/dev/null | grep -E 'jarvis' | awk '{printf "%s(pid:%s) ", $3, $1}' || echo "확인불가")

# Latest results snippets
read_latest() {
    local dir="$1" max_chars="${2:-500}"
    local f
    f=$(ls -t "${dir}/"*.md 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then head -c "$max_chars" "$f" 2>/dev/null; else echo "데이터 없음"; fi
}

HEALTH_SNAP=$(read_latest "${BOT_HOME}/results/system-health" 300)
TQQQ_SNAP=$(read_latest "${BOT_HOME}/results/tqqq-monitor" 500)
INFRA_SNAP=$(read_latest "${BOT_HOME}/results/infra-daily" 500)
NEWS_SNAP=$(read_latest "${BOT_HOME}/results/news-briefing" 300)

# OKR current values
GOALS_JSON=$(cat "${BOT_HOME}/config/goals.json" 2>/dev/null || echo '{}')

# Company DNA (core only)
DNA_CORE=$(sed -n '/^## 핵심 DNA/,/^## 일반 DNA/p' "${BOT_HOME}/config/company-dna.md" 2>/dev/null | head -30 || echo "없음")

# Previous context-bus
PREV_BUS=$(head -c 400 "${BOT_HOME}/state/context-bus.md" 2>/dev/null || echo "없음")

# Shared inbox
INBOX_FILES=$(ls "${BOT_HOME}/rag/teams/shared-inbox/"*.md 2>/dev/null | grep -v README || echo "")
INBOX_SUMMARY=""
if [[ -n "$INBOX_FILES" ]]; then
    INBOX_SUMMARY="미처리 메시지 $(echo "$INBOX_FILES" | wc -l | tr -d ' ')건: $(echo "$INBOX_FILES" | xargs -I{} basename {} | tr '\n' ', ')"
fi

# Previous decisions today
PREV_DECISIONS=""
if [[ -f "${DECISIONS_DIR}/${TODAY}.jsonl" ]]; then
    PREV_DECISIONS=$(cat "${DECISIONS_DIR}/${TODAY}.jsonl" 2>/dev/null)
fi

# Team scorecard (팀 성과표)
TEAM_SCORECARD=""
if [[ -f "${BOT_HOME}/state/team-scorecard.json" ]]; then
    TEAM_SCORECARD=$(SCORECARD_PATH="${BOT_HOME}/state/team-scorecard.json" python3 -c "
import json, os
with open(os.environ['SCORECARD_PATH']) as f:
    data = json.load(f)
lines = []
for name, t in data['teams'].items():
    status_mark = {'NORMAL':'', 'WARNING':'[!]', 'PROBATION':'[!!]', 'DISCIPLINARY':'[!!!]'}.get(t['status'], '')
    lines.append(f\"{name}: merit {t['merit']} / penalty {t['penalty']} {t['status']} {status_mark}\")
print('\n'.join(lines))
" 2>"${BOT_HOME}/logs/board-py.err" || echo "성과표 로드 실패 — $(tail -1 "${BOT_HOME}/logs/board-py.err" 2>/dev/null)")
fi

# Previous dispatch results
PREV_DISPATCH=""
PREV_DISPATCH_FILE="${BOT_HOME}/state/dispatch-results/${TODAY}.jsonl"
if [[ -f "$PREV_DISPATCH_FILE" ]]; then
    PREV_DISPATCH=$(cat "$PREV_DISPATCH_FILE" 2>/dev/null)
fi

# Load CEO profile (agents/ceo.md = SSoT for CEO behavior)
CEO_PROFILE=""
if [[ -f "${BOT_HOME}/agents/ceo.md" ]]; then
    CEO_PROFILE=$(cat "${BOT_HOME}/agents/ceo.md")
fi

# Load specialist profiles (역할+판정기준만 추출해 프롬프트 비대화 방지)
_load_agent_profile() {
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return; }
    # ## 역할 섹션 추출 (최대 5줄)
    awk '/^## 역할/{p=1} /^## 수집 항목|^## 보고 형식|^## 산출물/{p=0} p{print}' "$file" | head -5
    echo "---"
    # ## 판정 기준 섹션 추출 (최대 8줄)
    awk 'BEGIN{p=0} /^## 판정 기준/{p=1; print; next} p && /^## /{p=0} p{print}' "$file" | head -8
}
INFRA_PROFILE=""
if [[ -f "${BOT_HOME}/agents/infra-chief.md" ]]; then
    INFRA_PROFILE=$(_load_agent_profile "${BOT_HOME}/agents/infra-chief.md")
fi
STRATEGY_PROFILE=""
if [[ -f "${BOT_HOME}/agents/strategy-advisor.md" ]]; then
    STRATEGY_PROFILE=$(_load_agent_profile "${BOT_HOME}/agents/strategy-advisor.md")
fi
RECORD_PROFILE=""
if [[ -f "${BOT_HOME}/agents/record-keeper.md" ]]; then
    RECORD_PROFILE=$(_load_agent_profile "${BOT_HOME}/agents/record-keeper.md")
fi

# --- Build prompt ---
PROMPT="$(cat <<PROMPT_EOF
${CEO_PROFILE}

## 전문가 패널 관점 (CEO 판단의 참고 자료)

### 인프라 수석 관점
${INFRA_PROFILE}

### 전략 고문 관점
${STRATEGY_PROFILE}

### 기록 담당 관점
${RECORD_PROFILE}

아래 사전 수집 데이터를 종합 분석하고 산출물 4종을 작성해.

## 시간: $(date '+%Y-%m-%d %H:%M KST') / 유형: ${MEETING_TYPE}

## 사전 수집 데이터

### 인프라 현황
- 크론 성공률 (최근 24h): ${CRON_RATE}% (${CRON_SUCCESS}/${CRON_TOTAL}성공)
- 디스크: ${DISK_PCT} 사용 | 로드: ${LOAD}
- LaunchAgent: ${LAUNCHD}
- 시스템 헬스: ${HEALTH_SNAP}
- 인프라 보고: ${INFRA_SNAP}

### 시장/전략
- TQQQ 현황: ${TQQQ_SNAP}
- 뉴스: ${NEWS_SNAP}

### 내부 현황
- 공용 게시판(이전): ${PREV_BUS}
- 팀 인박스: ${INBOX_SUMMARY:-없음}
- 오늘 이전 결정: ${PREV_DECISIONS:-없음}
- 이전 결정 실행 결과: ${PREV_DISPATCH:-없음}

### 팀 성과표
${TEAM_SCORECARD:-데이터 없음}

### OKR
${GOALS_JSON}

### Company DNA (핵심)
${DNA_CORE}

## 판정 기준
- 시스템: GREEN(성공률 95%+) / YELLOW(70-95%) / RED(70% 미만)
- 시장: SAFE(TQQQ>\$50) / CAUTION(\$47-50) / CRITICAL(<\$47)
- 2주 연속 동일 이슈 → DNA 후보 등록 검토

## 산출물 (Write 도구로 반드시 작성)

### 1. context-bus.md 갱신
파일: ~/.jarvis/state/context-bus.md (덮어쓰기)
형식:
\`\`\`
# 자비스 컴퍼니 Context Bus
_업데이트: ${TODAY}T$(date +%H:%M) KST_

## 시스템 상태
크론 성공률: XX% — GREEN/YELLOW/RED
LaunchAgent: [상태 요약]

## 시장 신호
TQQQ: \$XX.XX — SAFE/CAUTION/CRITICAL
손절선(\$47) 대비: XX% 여유

## CEO 주목사항
[가장 중요한 발견/권고 1줄]
\`\`\`
500자 이내.

### 2. 회의록
파일: ~/.jarvis/state/board-minutes/${TODAY}.md
내용: 인프라 요약, 시장 요약, CEO 판단, OKR 진척 변경, 결정사항

### 3. 의사결정 감사 로그
파일: ~/.jarvis/state/decisions/${TODAY}.jsonl (append, 기존 내용 유지)
형식 (1줄 1결정):
{"ts":"$(date -u +%FT%TZ)","decision":"내용","rationale":"근거","team":"담당팀","okr":"KR ID","status":"confirmed"}

### 4. OKR 진척도 갱신 (측정 가능할 때만)
파일: ~/.jarvis/config/goals.json
keyResults의 current 값을 오늘 데이터 기반으로 업데이트. lastUpdated 갱신.
측정 불가능한 KR은 null 유지.

## 최종 출력 (stdout, Discord 전송용)
800자 이내. 형식:
[Board Meeting — ${TODAY} $(date +%H:%M)]
시스템: GREEN/YELLOW/RED | 크론 XX%
시장: SAFE/CAUTION/CRITICAL | TQQQ \$XX.XX
주목: [1줄]
결정: [1~2줄]

## Connections 도출 (필수)
오늘 분석된 주요 인사이트들 사이의 연관성을 최대 5개 찾아주세요.
응답 마지막에 반드시 아래 형식으로 출력:
CONNECTIONS_JSON:[{"from":"인사이트A 핵심 키워드","to":"인사이트B 핵심 키워드","relationship":"연관 이유 한 줄","strength":0.0}]
(한 줄에 전부, 줄바꿈 없이)
PROMPT_EOF
)"

# --- Prevent nested claude ---
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

# --- Consolidation skip check ---
# board-meeting이 수집하는 주요 결과 디렉토리 목록
TRACKED_DIRS=(
    "${BOT_HOME}/results/infra-daily"
    "${BOT_HOME}/results/news-briefing"
    "${BOT_HOME}/results/system-health"
    "${BOT_HOME}/results/tqqq-monitor"
    "${BOT_HOME}/state/context-bus.md"
)

# 마지막 board-meeting 실행 시점 (results/board-meeting 디렉토리의 최신 파일 mtime)
SKIP_STATE_FILE="${BOT_HOME}/state/board-meeting-skip.json"
LAST_RUN_MTIME=0
LAST_BOARD_FILE=$(ls -t "${RESULTS_DIR}/"*.md 2>/dev/null | head -1 || true)
if [[ -n "$LAST_BOARD_FILE" ]]; then
    LAST_RUN_MTIME=$(stat -f '%m' "$LAST_BOARD_FILE" 2>/dev/null || stat -c '%Y' "$LAST_BOARD_FILE" 2>/dev/null || echo 0)
fi

# 마지막 board-meeting 이후 변경된 추적 파일 수 계산
CHANGED_COUNT=0
for tracked in "${TRACKED_DIRS[@]}"; do
    if [[ -f "$tracked" ]]; then
        # 단일 파일 (context-bus.md 등)
        FILE_MTIME=$(stat -f '%m' "$tracked" 2>/dev/null || stat -c '%Y' "$tracked" 2>/dev/null || echo 0)
        if (( FILE_MTIME > LAST_RUN_MTIME )); then
            (( CHANGED_COUNT++ )) || true
        fi
    elif [[ -d "$tracked" ]]; then
        # 디렉토리 — 최신 파일 mtime 확인
        LATEST_IN_DIR=$(ls -t "${tracked}/"*.md 2>/dev/null | head -1 || true)
        if [[ -n "$LATEST_IN_DIR" ]]; then
            DIR_MTIME=$(stat -f '%m' "$LATEST_IN_DIR" 2>/dev/null || stat -c '%Y' "$LATEST_IN_DIR" 2>/dev/null || echo 0)
            if (( DIR_MTIME > LAST_RUN_MTIME )); then
                (( CHANGED_COUNT++ )) || true
            fi
        fi
    fi
done

SKIP_THRESHOLD=2

# 연속 스킵 횟수 읽기 (최대 2회 연속 스킵 시 강제 실행)
CONSECUTIVE_SKIPS=0
if [[ -f "$SKIP_STATE_FILE" ]]; then
    CONSECUTIVE_SKIPS=$(python3 -c "
import json, sys
try:
    with open('${SKIP_STATE_FILE}') as f:
        print(json.load(f).get('consecutive_skips', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
fi

MAX_CONSECUTIVE_SKIPS=2

if (( CHANGED_COUNT < SKIP_THRESHOLD && CONSECUTIVE_SKIPS < MAX_CONSECUTIVE_SKIPS )); then
    log "[board-meeting] 새 변경 ${CHANGED_COUNT}개 (임계값 ${SKIP_THRESHOLD}) — 통합 불필요, 스킵 (연속 ${CONSECUTIVE_SKIPS}회)"
    # 연속 스킵 카운터 증가
    python3 -c "
import json
try:
    with open('${SKIP_STATE_FILE}') as f:
        data = json.load(f)
except Exception:
    data = {}
data['consecutive_skips'] = ${CONSECUTIVE_SKIPS} + 1
data['last_skipped'] = '${TIMESTAMP}'
with open('${SKIP_STATE_FILE}', 'w') as f:
    json.dump(data, f)
" 2>/dev/null || true
    exit 0
fi

# 실행 시 연속 스킵 카운터 리셋
python3 -c "
import json
try:
    with open('${SKIP_STATE_FILE}') as f:
        data = json.load(f)
except Exception:
    data = {}
data['consecutive_skips'] = 0
data['last_run'] = '${TIMESTAMP}'
with open('${SKIP_STATE_FILE}', 'w') as f:
    json.dump(data, f)
" 2>/dev/null || true

if (( CONSECUTIVE_SKIPS >= MAX_CONSECUTIVE_SKIPS )); then
    log "[board-meeting] 연속 스킵 ${CONSECUTIVE_SKIPS}회 도달 — 변경 ${CHANGED_COUNT}개이지만 강제 실행"
else
    log "[board-meeting] 새 변경 ${CHANGED_COUNT}개 (임계값 ${SKIP_THRESHOLD}) — 통합 실행"
fi

# --- Lock ---
LOCK_FILE="/tmp/jarvis-board-meeting.lock"
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        log "Another board meeting running (PID $LOCK_PID), skipping"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

CAFFEINATE_PID=""
caffeinate -i -w $$ &
CAFFEINATE_PID=$!
trap 'rm -f "$LOCK_FILE"; kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

# --- Rate limit guard ---
RATE_FILE="${BOT_HOME}/state/rate-tracker.json"
if [[ -f "$RATE_FILE" ]]; then
    RATE_COUNT=$(RATE_PATH="$RATE_FILE" python3 -c "
import json, time, os
with open(os.environ['RATE_PATH']) as f: d = json.load(f)
cutoff = int(time.time()*1000) - 5*3600*1000
print(len([t for t in d if t > cutoff]))
" 2>"${BOT_HOME}/logs/board-py.err" || echo "0")
    if (( RATE_COUNT > 720 )); then
        log "Rate limit high (${RATE_COUNT}/900), skipping"
        exit 0
    fi
fi

# --- Execute (via LLM Gateway, ADR-006) ---
START_TIME=$(date +%s)

source "${BOT_HOME}/lib/llm-gateway.sh"

CLAUDE_EXIT=0
CLAUDE_OUTPUT_TMP="/tmp/board-meeting-$$.json"
llm_call \
    --prompt "$PROMPT" \
    --timeout 300 \
    --allowed-tools "Read,Bash,Write" \
    --max-budget "2.00" \
    --model "claude-sonnet-4-20250514" \
    --mcp-config "${BOT_HOME}/config/empty-mcp.json" \
    --output "$CLAUDE_OUTPUT_TMP" \
    2>"$STDERR_LOG" || CLAUDE_EXIT=$?

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    log "FAILED (exit $CLAUDE_EXIT, ${DURATION}s)"
    rm -f "$CLAUDE_OUTPUT_TMP"
    exit "$CLAUDE_EXIT"
fi

# --- Extract result ---
RESULT=""
COST="0"
if [[ -s "$CLAUDE_OUTPUT_TMP" ]]; then
    RESULT=$(jq -r '.result // empty' "$CLAUDE_OUTPUT_TMP" 2>/dev/null || echo "")
    COST=$(jq -r '.cost_usd // 0' "$CLAUDE_OUTPUT_TMP" 2>/dev/null || echo "0")
fi

if [[ -z "$RESULT" ]]; then
    log "ERROR: empty result (${DURATION}s)"
    rm -f "$CLAUDE_OUTPUT_TMP"
    exit 1
fi

# Save result
echo "$RESULT" > "$RESULT_FILE"
log "SUCCESS (${DURATION}s, cost \$${COST})"

# --- Extract and store insight connections ---
CONNECTIONS_FILE="${BOT_HOME}/state/connections.jsonl"
SESSION_LABEL=$(date +%H | awk '{print ($1+0 < 12) ? "am" : "pm"}')
python3 -c "
import sys, json, re
result = open('${RESULT_FILE}').read()
m = re.search(r'CONNECTIONS_JSON:(\[.+\])', result)
if not m:
    sys.exit(0)
conns = json.loads(m.group(1))
record = json.dumps({'date': '$(date +%Y-%m-%d)', 'session': '${SESSION_LABEL}', 'connections': conns}, ensure_ascii=False)
with open('${CONNECTIONS_FILE}', 'a') as f:
    f.write(record + '\n')
" 2>/dev/null || log "WARN: connections 파싱 실패 (결과에 CONNECTIONS_JSON 없을 수 있음)"

# --- Route to Discord (pm은 council-insight(23:00)가 담당하므로 스킵) ---
if [[ "$MEETING_TYPE" != "pm" ]]; then
    WEBHOOK=$(jq -r '.webhooks["jarvis-ceo"]' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || echo "")
    if [[ -n "$WEBHOOK" ]] && [[ "$WEBHOOK" != "null" ]]; then
        DISCORD_MSG=$(echo "$RESULT" | head -c 1950)
        curl -s -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg content "$DISCORD_MSG" '{content: $content}')" \
            >/dev/null 2>&1 || log "Discord send failed"
    fi
fi

# --- Update rate tracker ---
RATE_PATH="$RATE_FILE" python3 -c "
import json, time, fcntl, os
path = os.environ['RATE_PATH']
cutoff = int(time.time()*1000) - 5*3600*1000
now_ms = int(time.time()*1000)
try:
    with open(path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        data = json.load(f)
        data = [t for t in data if t > cutoff]
        data.append(now_ms)
        f.seek(0); f.truncate()
        json.dump(data, f)
except (FileNotFoundError, json.JSONDecodeError):
    with open(path, 'w') as f:
        json.dump([int(time.time()*1000)], f)
" 2>"${BOT_HOME}/logs/board-py.err" || log "WARN: rate tracker update failed"

# --- Rotate old results ---
find "$RESULTS_DIR" -name "*.md" -mtime +30 -delete 2>/dev/null || true
find "$MINUTES_DIR" -name "*.md" -mtime +90 -delete 2>/dev/null || true

# --- Cleanup ---
rm -f "$CLAUDE_OUTPUT_TMP"

# --- goals.json KR 자동 갱신 (bash 직접 측정) ---
if command -v python3 >/dev/null 2>&1; then
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

# --- KR1-2: 월간 다운타임 (health.json crash_count 기반) ---
health_path = os.path.expanduser('~/.jarvis/state/health.json')
crash_count = 0
try:
    with open(health_path) as f:
        health = json.load(f)
    crash_count = health.get('crash_count', 0)
except Exception:
    pass
downtime_str = f"약 {crash_count}분" if crash_count > 0 else "0분"

# --- KR1-3: E2E 테스트 통과율 ---
e2e_str = None
try:
    log_path = os.path.expanduser('~/.jarvis/logs/e2e-cron.log')
    with open(log_path) as f:
        lines = f.readlines()
    result_line = next((l for l in reversed(lines) if 'passed' in l), None)
    if result_line:
        m = re.search(r'(\d+)/(\d+)\s+passed', result_line)
        if m:
            passed, total = int(m.group(1)), int(m.group(2))
            pct = round(passed / total * 100, 1) if total > 0 else 0
            e2e_str = f"{pct}% ({passed}/{total})"
except Exception:
    pass

# --- KR3-1: TQQQ/손절선 모니터링 커버리지 (cron.log 기반) ---
tqqq_str = None
try:
    log_path = os.path.expanduser('~/.jarvis/logs/cron.log')
    with open(log_path) as f:
        content = f.read()
    tqqq_lines = [l for l in content.split('\n') if 'tqqq-monitor' in l]
    tqqq_ok = sum(1 for l in tqqq_lines if 'SUCCESS' in l)
    tqqq_total = sum(1 for l in tqqq_lines if 'SUCCESS' in l or 'FAIL' in l)
    if tqqq_total > 0:
        tqqq_pct = round(tqqq_ok / tqqq_total * 100)
        tqqq_str = f"{tqqq_pct}% ({tqqq_ok}/{tqqq_total})"
except Exception:
    pass

# --- KR4-2: 월간 운영 비용 (Claude Max 정액제 = $0 추가비용) ---
# Claude Max는 $100/월 정액 구독 — API 사용량과 무관하게 추가 비용 없음
# OpenAI API(RAG enrichment)는 ENABLE_RAG_ENRICHMENT=1일 때만 발생 (현재 비활성)
cost_str = "$0 (Claude Max 정액)"

# --- 수동측정 note 대상 키워드 ---
MANUAL_KEYWORDS = ('학습', '포트폴리오', '이력서', '알림', 'RAG')

# --- KR 순회 및 갱신 ---
for obj in goals.get('objectives', []):
    for kr in obj.get('keyResults', []):
        metric = kr.get('metric', '')
        kr_id = kr.get('id', '')

        if kr_id == 'KR1-1':
            cron_rate_val = '${CRON_RATE_VAL}'
            if re.match(r'^\d+$', cron_rate_val):
                kr['current'] = f"{cron_rate_val}%"
                kr['lastUpdated'] = today_iso
                updated = True

        elif '다운타임' in metric:
            kr['current'] = downtime_str
            kr['lastUpdated'] = today_iso
            updated = True

        elif 'E2E' in metric:
            if e2e_str is not None:
                kr['current'] = e2e_str
                kr['lastUpdated'] = today_iso
                updated = True

        elif '손절선' in metric or 'TQQQ' in metric:
            if tqqq_str is not None:
                kr['current'] = tqqq_str
                kr['lastUpdated'] = today_iso
                updated = True

        elif '비용' in metric:
            if cost_str is not None:
                kr['current'] = cost_str
                kr['lastUpdated'] = today_iso
                updated = True

        elif any(kw in metric for kw in MANUAL_KEYWORDS):
            kr.setdefault('note', '수동측정')

if updated:
    goals['lastUpdated'] = today_iso
    with open(path, 'w') as f:
        json.dump(goals, f, ensure_ascii=False, indent=2)
    print('updated')
PYEOF
fi

echo "$RESULT"

# --- Decision Dispatcher: 결정사항 자동 실행 + 팀 성과 평가 ---
DISPATCHER="${BOT_HOME}/bin/decision-dispatcher.sh"
if [[ -x "$DISPATCHER" ]]; then
    log "Running decision dispatcher..."
    DISPATCH_LOG="${BOT_HOME}/logs/decision-dispatcher.log"
    DISPATCH_OUTPUT=$("$DISPATCHER" 2>>"$DISPATCH_LOG" || true)
    if [[ -n "$DISPATCH_OUTPUT" ]]; then
        log "Dispatcher result: $(echo "$DISPATCH_OUTPUT" | head -1)"
        echo ""
        echo "$DISPATCH_OUTPUT"
    fi
fi
