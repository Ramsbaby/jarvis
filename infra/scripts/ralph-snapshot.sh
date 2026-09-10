#!/usr/bin/env bash
# ralph-snapshot.sh — Ralph runner state snapshot (A/B 비교용)
# 사용: bash ralph-snapshot.sh <label>
#   예: bash ralph-snapshot.sh r1-baseline-serial
#       bash ralph-snapshot.sh r2-concurrency3-hybrid
#
# 백업 대상:
#   - ralph-forbid-list.json
#   - ralph-insights-block.json
#   - ralph-insights.jsonl
#   - ralph-rounds.jsonl
#   - ralph-followups.jsonl
#   - ralph-dynamic-questions.json
#   - openai-ledger.jsonl
#   - interview-curated/ 디렉토리 전체 (md sidecars)
#
# 출력: ~/.openclaw-data/jarvis/runtime/state/snapshots/<label>-<YYYYMMDD-HHMM>/
#   manifest.json + 위 파일/tarball
#
# 2026-04-28 비서실장 3차 (옵션 A+C 동시 적용 준비)

set -euo pipefail

LABEL="${1:-untitled}"
TS="$(TZ=Asia/Seoul date +%Y%m%d-%H%M)"
SNAP_DIR="${HOME}/.openclaw-data/jarvis/runtime/state/snapshots/${LABEL}-${TS}"
STATE_DIR="${HOME}/.openclaw-data/jarvis/runtime/state"
CURATED_DIR="${HOME}/.openclaw-data/jarvis/runtime/wiki/05-career/interview-curated"

mkdir -p "$SNAP_DIR"

# 1. ralph state files (존재하는 것만)
for f in ralph-forbid-list.json ralph-insights-block.json ralph-insights.jsonl \
         ralph-rounds.jsonl ralph-followups.jsonl ralph-dynamic-questions.json \
         openai-ledger.jsonl; do
  if [ -f "$STATE_DIR/$f" ]; then
    cp "$STATE_DIR/$f" "$SNAP_DIR/"
  fi
done

# 2. curated md sidecars (gzipped tarball)
if [ -d "$CURATED_DIR" ]; then
  tar -czf "$SNAP_DIR/answer-sidecars.tar.gz" -C "$CURATED_DIR" . 2>/dev/null || true
fi

# 3. ralph runner PID + git HEAD + manifest
RALPH_PID="$(pgrep -f interview-ralph-runner || echo none)"
GIT_HEAD="$(cd "${HOME}/.openclaw-data/jarvis" && git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(cd "${HOME}/.openclaw-data/jarvis" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# 4. ralph-rounds.jsonl 마지막 라인 → 라운드 메트릭 추출
LAST_ROUND_METRICS="{}"
if [ -f "$STATE_DIR/ralph-rounds.jsonl" ]; then
  LAST_ROUND_METRICS="$(tail -1 "$STATE_DIR/ralph-rounds.jsonl" 2>/dev/null || echo '{}')"
fi

cat > "$SNAP_DIR/manifest.json" <<EOF
{
  "label": "$LABEL",
  "timestamp_kst": "$(TZ=Asia/Seoul date -Iseconds)",
  "ralph_pid": "$RALPH_PID",
  "git_head": "$GIT_HEAD",
  "git_branch": "$GIT_BRANCH",
  "files": [
$(ls -1 "$SNAP_DIR" | grep -v manifest.json | awk '{printf "    \"%s\"", $0}' | paste -sd ',\n' -)
  ],
  "last_round_metrics_inline": $LAST_ROUND_METRICS
}
EOF

# 5. emoji-rich CLI report
echo "✅ Snapshot saved: $SNAP_DIR"
echo "   📦 files: $(ls -1 "$SNAP_DIR" | wc -l | tr -d ' ')"
echo "   🏷  label: $LABEL"
echo "   ⏰ timestamp: $TS KST"
echo "   🐍 ralph_pid: $RALPH_PID"
echo "   🌿 git: $GIT_BRANCH @ ${GIT_HEAD:0:7}"

# 6. 옵션: comparison 자동 호출 시 사용할 latest symlink
ln -sfn "$SNAP_DIR" "${HOME}/.openclaw-data/jarvis/runtime/state/snapshots/latest-${LABEL}"
echo "   🔗 latest-${LABEL} → $(basename "$SNAP_DIR")"
