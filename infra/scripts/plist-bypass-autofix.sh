#!/usr/bin/env bash
# plist-bypass-autofix.sh — output:discord BYPASS plist 자동 복구 가드
#
# 배경: 2026-04-22 daily-usage-check가 4일 침묵. plist ProgramArguments가 bot-cron.sh를
#       우회해 Discord 파이프 자체가 끊겼으나 cron-auditor는 감지만 하고 자동 복구 없음.
#
# 동작: tasks.json에서 output:['discord'] 태스크 중 plist가 bot-cron.sh를 경유하지 않는
#       항목을 자동으로 정상 패턴(/bin/bash BOT_HOME/bin/bot-cron.sh <task-id>)으로 재작성
#       + launchctl unload→load. 원본은 .bak-<타임스탬프>로 보존.
#
# 안전장치:
#   - DRY_RUN=1 이면 실제 수정 없이 리포트만.
#   - 대상 plist는 반드시 .bak-<ts> 로 사전 백업.
#   - StartCalendarInterval / StandardOutPath / EnvironmentVariables 기존 값 보존.
#   - Label / plist 파일명 불일치 시 건너뛰고 경고.

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
TASKS_JSON="${BOT_HOME}/config/tasks.json"
LA_DIR="${HOME}/Library/LaunchAgents"
LEDGER="${BOT_HOME}/state/plist-bypass-autofix.jsonl"
DRY_RUN="${DRY_RUN:-0}"
TS="$(date '+%Y%m%d-%H%M%S')"

mkdir -p "$(dirname "$LEDGER")"

log_json() {
  # KST 로컬 타임으로 기록 (cron-master-ledger와 일관성 유지, 리포트가 KST 날짜로 파싱)
  printf '{"ts":"%s","action":"%s","task":"%s","detail":%s}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" >> "$LEDGER"
}

FIX_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

while IFS=$'\t' read -r TID SCRIPT; do
  [[ -z "$TID" ]] && continue
  PLIST=""
  for PREFIX in com.jarvis. ai.jarvis.; do
    CAND="${LA_DIR}/${PREFIX}${TID}.plist"
    [[ -f "$CAND" ]] && PLIST="$CAND" && break
  done
  [[ -z "$PLIST" ]] && { SKIP_COUNT=$((SKIP_COUNT+1)); continue; }

  LABEL=$(basename "$PLIST" .plist)

  # 이미 정상 경로면 skip (이중 안전)
  if grep -q 'bot-cron\.sh' "$PLIST"; then
    SKIP_COUNT=$((SKIP_COUNT+1))
    continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY] ${TID}  ${PLIST}  → bot-cron.sh 경유로 수정 필요"
    log_json "dry_run" "$TID" "{\"plist\":\"$PLIST\"}"
    continue
  fi

  # 기존 StartCalendarInterval·StandardOutPath·StandardErrorPath 추출
  SCI_BLOCK=$(awk '/<key>StartCalendarInterval<\/key>/,/<\/dict>/' "$PLIST" | head -100 || true)
  STDOUT_PATH=$(awk -F'[<>]' '/<key>StandardOutPath<\/key>/{getline; print $3}' "$PLIST" | head -1)
  STDERR_PATH=$(awk -F'[<>]' '/<key>StandardErrorPath<\/key>/{getline; print $3}' "$PLIST" | head -1)
  : "${STDOUT_PATH:=${BOT_HOME}/logs/${TID}.log}"
  : "${STDERR_PATH:=${BOT_HOME}/logs/${TID}-err.log}"

  BACKUP="${PLIST}.bak-${TS}"
  cp "$PLIST" "$BACKUP"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BOT_HOME}/bin/bot-cron.sh</string>
    <string>${TID}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>${BOT_HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  ${SCI_BLOCK}
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${STDOUT_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_PATH}</string>
</dict>
</plist>
EOF

  # reload
  if launchctl unload "$PLIST" 2>/dev/null; launchctl load "$PLIST" 2>/dev/null; then
    FIX_COUNT=$((FIX_COUNT+1))
    echo "[FIX] ${TID}  backup=${BACKUP}"
    log_json "fixed" "$TID" "{\"plist\":\"$PLIST\",\"backup\":\"$BACKUP\"}"
  else
    FAIL_COUNT=$((FAIL_COUNT+1))
    echo "[FAIL] ${TID}  reload 실패 — 백업 유지"
    log_json "reload_failed" "$TID" "{\"plist\":\"$PLIST\",\"backup\":\"$BACKUP\"}"
  fi

done < <(
  python3 - "$TASKS_JSON" "$LA_DIR" <<'PYEOF' 2>/dev/null
import json, os, re, sys
tasks_path, la_dir = sys.argv[1], sys.argv[2]
try:
    with open(tasks_path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
tasks = data.get('tasks', []) if isinstance(data, dict) else data
for t in tasks:
    if 'discord' not in (t.get('output') or []):
        continue
    if t.get('disabled'):
        continue
    tid = t.get('id') or ''
    plist_path = None
    for prefix in ('com.jarvis.', 'ai.jarvis.'):
        p = os.path.join(la_dir, f"{prefix}{tid}.plist")
        if os.path.exists(p):
            plist_path = p
            break
    if not plist_path:
        continue
    content = open(plist_path).read()
    if 'bot-cron.sh' in content:
        continue
    m = re.search(r'<key>ProgramArguments</key>\s*<array>(.*?)</array>', content, re.S)
    args = re.findall(r'<string>(.*?)</string>', m.group(1)) if m else []
    script = next((a for a in args if a.endswith(('.sh', '.mjs', '.py'))), '')
    if not script:
        continue
    body = open(script, errors='ignore').read() if os.path.exists(script) else ''
    # 주석 제거 후 "실제 네트워크 호출 패턴"만 스킵 판정 (false positive 차단, 2026-04-22)
    # 기존 로직은 주석 내 키워드만으로 스킵 → wiki-reference-report.mjs가 설계상 stdout 경유인데도 주석 때문에 스킵되던 버그.
    if script.endswith(('.mjs', '.js')):
        stripped = re.sub(r'/\*[\s\S]*?\*/', '', body)
        stripped = re.sub(r'(?m)^\s*\*.*$', '', stripped)  # JSDoc 블록 내부 라인
        stripped = re.sub(r'(?m)//[^\n]*$', '', stripped)
    elif script.endswith(('.sh', '.py')):
        # 첫 줄 shebang은 유지, 이후 # 주석만 제거
        lines = body.splitlines()
        kept = [lines[0]] if lines else []
        for ln in lines[1:]:
            kept.append(re.sub(r'#.*$', '', ln))
        stripped = '\n'.join(kept)
    else:
        stripped = body
    # 실제 네트워크·디스패치 호출 패턴만 스킵 조건
    if re.search(r'\bfetch\s*\(|axios\.(post|get|put)|https?\.request|WebhookClient|'
                 r'curl\s+[^#\n]*?(webhook|discord)|bash\s+[^#\n]*route-result\.sh|'
                 r'execSync\([^)]*(curl|webhook)', stripped, re.I):
        continue
    print(f"{tid}\t{script}")
PYEOF
)

echo ""
echo "[plist-bypass-autofix] FIX=${FIX_COUNT} SKIP=${SKIP_COUNT} FAIL=${FAIL_COUNT} ts=$(date '+%F %T %Z')"
log_json "summary" "-" "{\"fix\":${FIX_COUNT},\"skip\":${SKIP_COUNT},\"fail\":${FAIL_COUNT}}"
