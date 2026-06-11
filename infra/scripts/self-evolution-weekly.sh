#!/usr/bin/env bash
# self-evolution-weekly.sh — 학습 루프 주간 자기평가 (자율 증류 사다리 관측 지표)
#
# 매주 월 09:30 KST cron 실행. 최근 7일의 학습 루프 핵심 수치 4종을 기계 집계만으로 모아
# Discord retro 채널(안 봐도 되는 자가 기록)로 1회 송출한다. LLM 호출 0회.
#
#   ① 재발     : mistake-recurrence.log 최근 7일 측정 라인 파싱 (재발 건수 합 + 클러스터 추이)
#                + mistake-recurrence.json 최신 스냅샷으로 재발률(재발/고유 패턴) 보강
#   ② 승격 이력 : promoter-ledger.jsonl 주간 집계 (원장 미생성 시 0 — 승격기 도입 전 단계 허용)
#   ③ 자동룰    : ~/.claude/rules/jarvis-autolearn.md 활성 블록(## 헤딩) 수 (미생성 시 0)
#   ④ 랄프     : ralph-rounds.jsonl 최근 7일 라운드 수·문항당 평균 초·성공률 + 전주 평균 대비 추이
#
# 사용(cron):
#   30 9 * * 1 BOT_HOME=$HOME/jarvis/runtime /bin/bash $HOME/jarvis/infra/scripts/self-evolution-weekly.sh \
#     >> $HOME/jarvis/runtime/logs/self-evolution-weekly.log 2>&1
#
# 정책: Discord 송출은 discord-route.sh(discord_route)만 사용 · 송출 실패해도 exit 0 · 시간 표기는 KST.
set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
RECUR_LOG="$BOT_HOME/logs/mistake-recurrence.log"
RECUR_JSON="$BOT_HOME/state/mistake-recurrence.json"
RALPH_FILE="$BOT_HOME/state/ralph-rounds.jsonl"
AUTOLEARN_FILE="$HOME/.claude/rules/jarvis-autolearn.md"
# 승격 원장 — 아직 미생성 단계라 설계상 후보 경로 2곳을 모두 본다 (state 우선, ledger 차선)
PROMOTER_CANDIDATES=("$BOT_HOME/state/promoter-ledger.jsonl" "$BOT_HOME/ledger/promoter-ledger.jsonl")

# Discord 라우터 (severity → 채널 매핑 + 1h 중복 차단 내장)
# shellcheck source=/dev/null
source "$HOME/jarvis/infra/lib/discord-route.sh"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')] $*"; }

command -v jq >/dev/null 2>&1 || { log "❌ jq 없음 — 집계 불가" >&2; exit 1; }

TODAY_KST="$(TZ=Asia/Seoul date '+%Y-%m-%d')"
CUT7_KST="$(TZ=Asia/Seoul date -v-7d '+%Y-%m-%d')"   # 재발 로그·승격 원장 비교용 (KST 날짜 문자열)
CUT7_UTC="$(date -u -v-7d '+%Y-%m-%dT%H:%M:%S')"     # 랄프 ts(UTC ISO) 비교용
CUT14_UTC="$(date -u -v-14d '+%Y-%m-%dT%H:%M:%S')"   # 랄프 전주 구간 시작점

log "🧬 자기진화 주간 자기평가 시작 (구간: $CUT7_KST ~ $TODAY_KST)"

# ---------- ① 재발 — mistake-recurrence.log 최근 7일 라인 파싱 ----------
RECUR_SUM=0        # 7일간 재발 패턴 건수 합
RECUR_DAYS=0       # 측정된 일수 (로그 라인 수)
CLUSTER_FIRST=""   # 구간 첫 측정의 클러스터 수
CLUSTER_LAST=""    # 구간 마지막 측정의 클러스터 수
if [ -f "$RECUR_LOG" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    r="$(sed -E 's/.*재발 패턴 ([0-9]+)건.*/\1/' <<<"$line")"
    c="$(sed -E 's/.*cluster ([0-9]+)건.*/\1/' <<<"$line")"
    if [[ "$r" =~ ^[0-9]+$ ]]; then
      RECUR_SUM=$((RECUR_SUM + r))
      RECUR_DAYS=$((RECUR_DAYS + 1))
    fi
    if [[ "$c" =~ ^[0-9]+$ ]]; then
      if [ -z "$CLUSTER_FIRST" ]; then CLUSTER_FIRST="$c"; fi
      CLUSTER_LAST="$c"
    fi
  # 로그 타임스탬프는 "[YYYY-MM-DDT..+0900]" — 앞 10자(날짜)를 잘라 KST 컷오프와 문자열 비교
  done < <(grep '재발 패턴' "$RECUR_LOG" 2>/dev/null | awk -v cut="$CUT7_KST" 'substr($0,2,10) >= cut' || true)
else
  log "⚠️ 재발 로그 부재: $RECUR_LOG"
fi

# 재발률 = 최신 스냅샷의 재발 패턴 / 고유 패턴 (mistake-recurrence.json, 매일 03:30 갱신)
RECUR_RATE="데이터 없음"
if [ -f "$RECUR_JSON" ]; then
  RECUR_RATE="$(jq -r 'if (.total_unique_patterns // 0) > 0
      then "\(.recurring_count // 0)/\(.total_unique_patterns)건 (\((.recurring_count // 0) * 1000 / .total_unique_patterns | round / 10)%)"
      else "데이터 없음" end' "$RECUR_JSON" 2>/dev/null || echo "데이터 없음")"
fi

# 클러스터 추이 문구 (감소 = 실수 묶음이 줄어드는 중 = 좋은 신호)
if [ -n "$CLUSTER_FIRST" ] && [ -n "$CLUSTER_LAST" ]; then
  CLUSTER_TREND="${CLUSTER_LAST}개 (7일 전 ${CLUSTER_FIRST} → ${CLUSTER_LAST})"
else
  CLUSTER_TREND="측정 없음"
fi
log "① 재발: 7일 합 ${RECUR_SUM}건 · 측정 ${RECUR_DAYS}일 · 재발률 ${RECUR_RATE} · 클러스터 ${CLUSTER_TREND}"

# ---------- ② 승격 이력 — promoter-ledger.jsonl 주간 집계 (없으면 0) ----------
PROM_WEEK=0
PROM_NOTE="원장 미생성"
for p in "${PROMOTER_CANDIDATES[@]}"; do
  if [ -f "$p" ]; then
    # ts(또는 date) 필드 앞 10자를 KST 컷오프와 비교 — 깨진 라인은 fromjson?이 조용히 건너뜀
    PROM_WEEK="$(jq -R --arg cut "$CUT7_KST" \
      'fromjson? | objects | select(((.ts // .date // "") | tostring)[:10] >= $cut) | 1' \
      "$p" 2>/dev/null | wc -l | tr -d ' ')"
    PROM_NOTE="누적 $(wc -l < "$p" | tr -d ' ')건"
    break
  fi
done
log "② 승격: 주간 ${PROM_WEEK}건 (${PROM_NOTE})"

# ---------- ③ 자동룰 활성 수 — jarvis-autolearn.md 블록(## 헤딩) 수 (없으면 0) ----------
# 강등 룰은 설계상 rules 밖(wiki/meta/autolearn-archive.md)으로 이동되므로 파일 내 블록 = 활성
AUTOLEARN_ACTIVE=0
AUTOLEARN_NOTE="파일 미생성"
if [ -f "$AUTOLEARN_FILE" ]; then
  AUTOLEARN_ACTIVE="$(grep -Ec '^## ' "$AUTOLEARN_FILE" || true)"
  AUTOLEARN_ACTIVE="${AUTOLEARN_ACTIVE:-0}"
  AUTOLEARN_NOTE="활성"
fi
log "③ 자동룰: ${AUTOLEARN_ACTIVE}개 (${AUTOLEARN_NOTE})"

# ---------- ④ 랄프 라운드 — 최근 7일 평균 + 전주 대비 추이 ----------
RALPH_STATS='{"cur_n":0,"cur_avg":0,"cur_q":0,"cur_ok":0,"prev_n":0,"prev_avg":0,"ok_pct":0}'
if [ -f "$RALPH_FILE" ]; then
  # 라인이 매우 커서(라운드당 결과 배열 포함) 필요한 필드만 추려 집계한다
  RALPH_STATS="$(jq -R -n --arg c7 "$CUT7_UTC" --arg c14 "$CUT14_UTC" '
    [inputs | fromjson? | objects | select(.ts != null)
      | {ts, avg: (.avgSec // 0), q: (.questionsCount // 0), ok: (.okCount // 0)}] as $all
    | ([$all[] | select(.ts >= $c7)]) as $cur
    | ([$all[] | select(.ts >= $c14 and .ts < $c7)]) as $prev
    | {
        cur_n: ($cur | length),
        cur_avg: (if ($cur | length) > 0 then (([$cur[].avg] | add) / ($cur | length) * 10 | round / 10) else 0 end),
        cur_q: ([$cur[].q] | add // 0),
        cur_ok: ([$cur[].ok] | add // 0),
        prev_n: ($prev | length),
        prev_avg: (if ($prev | length) > 0 then (([$prev[].avg] | add) / ($prev | length) * 10 | round / 10) else 0 end)
      }
    | . + {ok_pct: (if .cur_q > 0 then ((.cur_ok * 1000 / .cur_q) | round / 10) else 0 end)}
  ' "$RALPH_FILE" 2>/dev/null)" || RALPH_STATS='{"cur_n":0,"cur_avg":0,"cur_q":0,"cur_ok":0,"prev_n":0,"prev_avg":0,"ok_pct":0}'
else
  log "⚠️ 랄프 라운드 파일 부재: $RALPH_FILE"
fi

RALPH_N="$(jq -r '.cur_n' <<<"$RALPH_STATS")"
RALPH_AVG="$(jq -r '.cur_avg' <<<"$RALPH_STATS")"
RALPH_Q="$(jq -r '.cur_q' <<<"$RALPH_STATS")"
RALPH_OK="$(jq -r '.cur_ok' <<<"$RALPH_STATS")"
RALPH_OKPCT="$(jq -r '.ok_pct' <<<"$RALPH_STATS")"
RALPH_PREV_N="$(jq -r '.prev_n' <<<"$RALPH_STATS")"
RALPH_PREV_AVG="$(jq -r '.prev_avg' <<<"$RALPH_STATS")"

# 전주 대비 추이 문구 (전주 데이터 없으면 비교 생략)
if [ "$RALPH_PREV_N" -gt 0 ]; then
  RALPH_TREND="문항당 ${RALPH_AVG}초 (전주 ${RALPH_PREV_AVG}초 · ${RALPH_PREV_N}회)"
else
  RALPH_TREND="문항당 ${RALPH_AVG}초 (전주 라운드 없음)"
fi
log "④ 랄프: 라운드 ${RALPH_N}회 · ${RALPH_TREND} · 성공률 ${RALPH_OKPCT}% (${RALPH_OK}/${RALPH_Q}문항)"

# ---------- Discord retro 송출 (1회 · 수치 위주 · 쉬운말) ----------
# 제목에 날짜 포함 — discord-route의 1h 동일 제목 중복 차단과 주간 주기가 겹치지 않도록 함
TITLE="🧬 자기진화 주간 자기평가 — ${TODAY_KST}"
# 값에 쉼표 금지(라우터가 쉼표로 k=v를 분리) — 구분은 가운뎃점(·) 사용
DATA_KV="같은실수 재발률=${RECUR_RATE}"
DATA_KV+=",재발 건수(7일)=합 ${RECUR_SUM}건 · 측정 ${RECUR_DAYS}일"
DATA_KV+=",실수 묶음(클러스터)=${CLUSTER_TREND}"
DATA_KV+=",룰 승격(7일)=${PROM_WEEK}건 (${PROM_NOTE})"
DATA_KV+=",자동룰 활성=${AUTOLEARN_ACTIVE}개 (${AUTOLEARN_NOTE})"
DATA_KV+=",면접 자가훈련 랄프(7일)=${RALPH_N}회 · 성공률 ${RALPH_OKPCT}%"
DATA_KV+=",랄프 라운드 평균=${RALPH_TREND}"

log "📤 Discord retro 송출 시도"
discord_route retro "$TITLE" "$DATA_KV" || true   # 송출 실패해도 리포트 자체는 성공 처리 (정책)

log "✅ 주간 자기평가 완료"
exit 0
