#!/usr/bin/env bash
# rag-stale-scan.sh — RAG 청크 스테일(접근 이력 없음) 스캔
#
# 목적: access-log.json을 분석하여 30일 이상 미참조 청크를 보고.
#       자동 삭제 없음 — 수동 검토 후 결정.
#       매주 일요일 03:00 KST 실행 (rag-lancedb-compact 04:15 이전).
#
# 출력: ~/jarvis/runtime/rag/teams/reports/rag-stale-YYYY-MM-DD.md
#       50건 초과 시 Discord #jarvis-system 경고 전송

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="${BOT_HOME}/logs/rag-stale-scan.log"
REPORT_DIR="${BOT_HOME}/rag/teams/reports"
ACCESS_LOG="${BOT_HOME}/rag/access-log.json"
ALERT_SCRIPT="${HOME}/jarvis/runtime/scripts/alert.sh"

ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [rag-stale-scan] $*" | tee -a "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")" "$REPORT_DIR"
log "=== RAG 스테일 스캔 시작 ==="

# access-log.json 없으면 건너뜀
if [[ ! -f "$ACCESS_LOG" ]]; then
  log "access-log.json 없음 — 첫 실행 또는 접근 기록 아직 없음. 정상 종료."
  exit 0
fi

REPORT="${REPORT_DIR}/rag-stale-$(date +%F).md"

# Node.js로 스테일 후보 분석
RESULT=$(node --input-type=module << 'NODEJS'
import { readFileSync } from 'node:fs';
import path from 'node:path';

const BOT_HOME = process.env.BOT_HOME || path.join(process.env.HOME, 'jarvis/runtime');
const ACCESS_LOG_PATH = path.join(BOT_HOME, 'rag', 'access-log.json');
const CUTOFF_MS = Date.now() - 30 * 24 * 3600 * 1000; // 30일

let log = {};
try {
  log = JSON.parse(readFileSync(ACCESS_LOG_PATH, 'utf-8'));
} catch {
  process.stdout.write(JSON.stringify({ staleCount: 0, stale: [], totalTracked: 0, neverAccessed: 0 }));
  process.exit(0);
}

const totalTracked = Object.keys(log).length;

// 30일 이상 미참조 또는 접근 기록 초기화된 항목
const stale = Object.entries(log)
  .filter(([, val]) => {
    const lastMs = new Date(val.lastAccessed || 0).getTime();
    return lastMs < CUTOFF_MS;
  })
  .map(([key, val]) => ({
    key,
    count: val.count ?? 0,
    lastAccessed: val.lastAccessed || 'unknown',
  }))
  .sort((a, b) => new Date(a.lastAccessed) - new Date(b.lastAccessed));

// 한 번도 참조되지 않은 항목 (count=0)
const neverAccessed = stale.filter(s => s.count === 0).length;

process.stdout.write(JSON.stringify({
  staleCount: stale.length,
  stale: stale.slice(0, 50), // 최대 50건 출력
  totalTracked,
  neverAccessed,
}));
NODEJS
)

STALE_COUNT=$(echo "$RESULT" | jq '.staleCount')
TOTAL=$(echo "$RESULT" | jq '.totalTracked')
NEVER=$(echo "$RESULT" | jq '.neverAccessed')

log "추적 청크: $TOTAL / 30일 미참조: $STALE_COUNT (그 중 한 번도 참조 없음: $NEVER)"

# 보고서 생성
{
  echo "# RAG 스테일 청크 스캔 — $(date '+%Y-%m-%d %H:%M KST')"
  echo ""
  echo "## 요약"
  echo "- 📦 접근 기록 총 청크: **${TOTAL}**"
  echo "- 🕰️ 30일 미참조 후보: **${STALE_COUNT}**"
  echo "- ❓ 한 번도 참조 없음: **${NEVER}**"
  echo ""

  if [[ "$STALE_COUNT" -gt 0 ]]; then
    echo "## 스테일 후보 목록 (최대 50건, 오래된 순)"
    echo ""
    echo "$RESULT" | jq -r '.stale[] | "- `\(.key)` — 참조 \(.count)회 | 마지막: \(.lastAccessed)"'
    echo ""
    echo "---"
    echo "> ⚠️ **자동 삭제 없음.** 수동 검토 후 \`rag_search\`로 해당 청크 내용 확인 뒤 삭제 여부 결정."
    echo "> 삭제 시: LanceDB soft-delete (\`deleted=true\`) 또는 source 파일 제거 후 \`rag-index\` 재실행."
  else
    echo "✅ 스테일 후보 없음 — 모든 추적 청크가 30일 이내 참조됨."
  fi
} > "$REPORT"

log "보고서 저장: $REPORT"

# 50건 초과 시 Discord #jarvis-system 경고 (noise 방지)
if [[ "$STALE_COUNT" -gt 50 ]] && [[ -f "$ALERT_SCRIPT" ]]; then
  bash "$ALERT_SCRIPT" \
    "🧠 RAG 스테일 스캔: 30일 미참조 청크 ${STALE_COUNT}건 발견. 검토 권장." \
    "jarvis-system" || true
fi

log "=== RAG 스테일 스캔 완료 ==="
exit 0
