#!/usr/bin/env bash
# user-memory-monitor.sh — 전체 사용자 user-memory 오염 감지 크론 (얇은 래퍼)
#
# 역할 분담 (2026-04-23 /verify 감사관 지적 반영):
#   - 실측·비교·경보 생성: user-memory-monitor-scan.mjs (SSoT = user-memory.mjs)
#   - 이 스크립트: webhook URL 로드 + scan 호출 + Discord POST
#
# 교체 이력:
#   2026-04-21: boram-memory-monitor.sh 폐기 → 통합
#   2026-04-23: 하드코딩 임계치 제거, SSoT(MONITOR_SOFT_LIMITS) 동적 참조로 리팩터

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/runtime}"
WEBHOOK_FILE="$BOT_HOME/config/monitoring.json"
NODE="${NODE_BIN:-/opt/homebrew/bin/node}"
SCAN_SCRIPT="$HOME/projects/jarvis/infra/scripts/user-memory-monitor-scan.mjs"

# ── 전제 조건 체크 (조용한 실패 금지) ──────────────────────────────────────
if [[ ! -x "$NODE" ]]; then
  echo "[memory-monitor] ERROR: node binary not found at $NODE" >&2
  exit 1
fi
if [[ ! -f "$SCAN_SCRIPT" ]]; then
  echo "[memory-monitor] ERROR: scan script not found: $SCAN_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$WEBHOOK_FILE" ]]; then
  echo "[memory-monitor] ERROR: monitoring.json not found: $WEBHOOK_FILE" >&2
  exit 1
fi

# ── webhook URL 로드 (에러 은폐 금지 — S1 대응) ────────────────────────────
WEBHOOK_URL="$("$NODE" -e "
  const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const url = d.webhooks?.['jarvis-system'];
  if (!url) { process.stderr.write('webhook key missing\n'); process.exit(2); }
  process.stdout.write(url);
" "$WEBHOOK_FILE")" || {
  echo "[memory-monitor] ERROR: webhook URL 로드 실패" >&2
  exit 1
}

# ── 스캐너 실행 (SSoT 기반 동적 감시) ─────────────────────────────────────
SCAN_OUTPUT="$("$NODE" "$SCAN_SCRIPT")" || {
  echo "[memory-monitor] ERROR: scan script 실행 실패 (exit=$?)" >&2
  exit 1
}

# 스캐너는 한 줄 JSON을 'SCAN_RESULT_JSON=' 마커 뒤에 출력
SCAN_JSON="${SCAN_OUTPUT#SCAN_RESULT_JSON=}"
if [[ "$SCAN_JSON" == "$SCAN_OUTPUT" ]]; then
  echo "[memory-monitor] ERROR: scan 출력에 SCAN_RESULT_JSON 마커 없음" >&2
  echo "$SCAN_OUTPUT" >&2
  exit 1
fi

# 사용자별 요약 라인 출력 (기존 로그 포맷 유지 — 관측성 회귀 방지)
echo "$SCAN_JSON" | "$NODE" -e "
  let buf=''; process.stdin.on('data', c => buf+=c); process.stdin.on('end', () => {
    const r = JSON.parse(buf);
    for (const line of (r.lines||[])) console.log(line);
  });
"

# allOk 판정
ALL_OK="$(echo "$SCAN_JSON" | "$NODE" -e "
  let buf=''; process.stdin.on('data', c => buf+=c); process.stdin.on('end', () => {
    const r = JSON.parse(buf);
    process.stdout.write(r.allOk ? 'true' : 'false');
  });
")"

if [[ "$ALL_OK" == "true" ]]; then
  echo "[memory-monitor] OK — 모든 사용자 정상"
  exit 0
fi

# ── 경보 페이로드 생성 + Discord POST ─────────────────────────────────────
KST_NOW="$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M')"
PAYLOAD="$(echo "$SCAN_JSON" | "$NODE" -e "
  let buf=''; process.stdin.on('data', c => buf+=c); process.stdin.on('end', () => {
    const r = JSON.parse(buf);
    const now = process.argv[1];
    let desc = '하나 이상의 사용자 메모리가 임계치를 초과했습니다.\n\n';
    for (const a of (r.alerts||[])) {
      desc += '### 👤 ' + a.name + ' (userId: ' + a.userId + ')\n';
      desc += '- 📊 전체: ' + a.total + '개\n';
      for (const w of a.warnings) desc += w + '\n';
      desc += '\n';
    }
    desc += '메모리 파일을 확인하고 정리하세요.';
    const payload = {
      content: null,
      embeds: [{
        title: '⚠️ user-memory 오염 경보',
        description: desc,
        color: 15548997,
        footer: { text: 'user-memory-monitor · ' + now },
      }],
    };
    process.stdout.write(JSON.stringify(payload));
  });
" "$KST_NOW")"

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  --max-time 10)"

if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
  echo "[memory-monitor] ALERT sent (http=$HTTP_CODE)"
else
  echo "[memory-monitor] ALERT send failed (http=$HTTP_CODE)" >&2
  exit 1
fi
