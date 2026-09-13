#!/usr/bin/env bash
# list-monitors.sh — 기존 감시 인프라 전수 조회 (cl-ea9810ebd3a98d01 가드)
#
# 사용: ./list-monitors.sh [--json] [--fp-check]
#   --json      JSON 형식 출력
#   --fp-check  거짓양성 체크리스트 출력 후 종료
#
# 용도: 새 감시 규칙·도구 제안 전 반드시 실행 — 기존 감시 중복·누락 방지

set -eo pipefail

JARVIS_HOME="${HOME}/projects/jarvis"
MONITORING_JSON="${JARVIS_HOME}/infra/config/monitoring.json"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
INFRA_SCRIPTS="${JARVIS_HOME}/infra/scripts"

JSON_MODE=false
FP_CHECK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     JSON_MODE=true ;;
        --fp-check) FP_CHECK=true ;;
        *) ;;
    esac
    shift
done

# ============================================================
# 거짓양성(False Positive) 체크리스트 모드
# ============================================================
if [[ "$FP_CHECK" == "true" ]]; then
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 거짓양성(False Positive) 체크리스트 — 규칙 설계 전 확인
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

□ 1. 동일 조건을 탐지하는 기존 경보가 있는가?
      → list-monitors.sh 실행 후 중복 확인

□ 2. 탐지 조건이 정상 운영 중에도 발생하는가?
      → 임계값을 "최악 정상 수치" 기준으로 설정했는가?

□ 3. 일시적 스파이크(자연 변동)를 경보로 처리하는가?
      → 연속 N회 초과 시에만 경보 트리거하도록 설계

□ 4. 동일 사건이 여러 채널로 중복 발송될 수 있는가?
      → 경보 중복 억제(dedup key/cooldown) 설정 여부 확인

□ 5. 복구 시 경보가 자동 해제(auto-resolve)되는가?
      → 미해제 시 알림 피로(alert fatigue) 유발

□ 6. 테스트 환경에서 의도치 않게 경보가 발생하는가?
      → 환경 변수 또는 태그로 프로덕션 전용 필터 적용

□ 7. 야간/주말 등 저활동 시간대에 발생해 오경보 가능성이 있는가?
      → 시간대별 임계값 차등 적용 또는 묵음 구간 설정

□ 8. 이 경보는 기존 경보보다 신호/잡음 비율이 개선되는가?
      → 기존 대비 개선 근거 없으면 신규 도구 추가 재고

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ⚠️  위 항목 중 하나라도 미확인 시 새 경보 규칙 추가 보류
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    exit 0
fi

# ============================================================
# 섹션 1: Crontab 인벤토리
# ============================================================
crontab_total=0
crontab_jarvis=0
cron_entries=""

if crontab -l &>/dev/null; then
    crontab_total=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | wc -l | tr -d ' ')
    crontab_jarvis=$(crontab -l 2>/dev/null | grep -v '^#' | grep -i 'jarvis\|monitor\|alert\|health\|watch' | wc -l | tr -d ' ')
    cron_entries=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | head -30 || true)
fi

# ============================================================
# 섹션 2: LaunchAgents 인벤토리
# ============================================================
plist_total=0
plist_loaded=0
plist_monitor_names=""

if [[ -d "$LAUNCHD_DIR" ]]; then
    plist_total=$(ls -1 "${LAUNCHD_DIR}"/*.plist 2>/dev/null | wc -l | tr -d ' ')
    plist_loaded=$(launchctl list 2>/dev/null | grep -c 'ai\.jarvis\.' || true)
    plist_monitor_names=$(ls "${LAUNCHD_DIR}"/*.plist 2>/dev/null | \
        xargs -I{} basename {} .plist 2>/dev/null | \
        grep -i 'monitor\|alert\|health\|watch\|disk\|audit' | head -20 || true)
fi

# ============================================================
# 섹션 3: monitoring.json 웹훅 채널 요약
# ============================================================
webhook_channels=""
ntfy_topic=""

if [[ -f "$MONITORING_JSON" ]]; then
    webhook_channels=$(python3 -c "
import json, sys
with open('$MONITORING_JSON') as f:
    d = json.load(f)
channels = []
wh = d.get('webhooks', {})
if isinstance(wh, dict):
    for k, v in wh.items():
        status = '설정됨' if v else '비어있음'
        channels.append(f'  {k}: {status}')
# legacy top-level webhook
top = d.get('webhook', {})
if isinstance(top, dict):
    top_url = top.get('url', '')
    status = '설정됨' if top_url else '비어있음'
    channels.append(f'  webhook(legacy): {status}')
print('\n'.join(channels))
" 2>/dev/null || echo "  (파싱 실패)")

    ntfy_topic=$(python3 -c "
import json
with open('$MONITORING_JSON') as f:
    d = json.load(f)
ntfy = d.get('ntfy', {})
topic = ntfy.get('topic', '') if isinstance(ntfy, dict) else ''
print(topic if topic else '(미설정)')
" 2>/dev/null || echo "(파싱 실패)")
fi

# ============================================================
# 섹션 4: 기존 알림·감시 스크립트 목록
# ============================================================
existing_scripts=$(ls "${JARVIS_HOME}/scripts/"*monitor* \
                      "${JARVIS_HOME}/scripts/"*alert* \
                      "${JARVIS_HOME}/scripts/"*watch* \
                      "${JARVIS_HOME}/scripts/"*health* \
                      "${INFRA_SCRIPTS}/"*monitor* \
                      "${INFRA_SCRIPTS}/"*alert* \
                      "${INFRA_SCRIPTS}/"*check* \
                      2>/dev/null | \
    grep -v '\.bak\|\.disabled\|DEPRECATED' | \
    xargs -I{} basename {} 2>/dev/null | sort -u | head -30 || true)

# ============================================================
# 출력
# ============================================================
if [[ "$JSON_MODE" == "true" ]]; then
    python3 -c "
import json, subprocess, os

result = {
    'crontab': {
        'total_entries': $crontab_total,
        'jarvis_related': $crontab_jarvis
    },
    'launchd': {
        'plist_total': $plist_total,
        'loaded_count': $plist_loaded,
        'monitor_agents': '''$plist_monitor_names'''.strip().splitlines()
    },
    'monitoring_json': {
        'path': '$MONITORING_JSON',
        'exists': os.path.isfile('$MONITORING_JSON'),
        'webhook_channels': '''$webhook_channels'''.strip(),
        'ntfy_topic': '''$ntfy_topic'''.strip()
    },
    'existing_scripts_count': len([s for s in '''$existing_scripts'''.strip().splitlines() if s])
}
print(json.dumps(result, ensure_ascii=False, indent=2))
"
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 📡 기존 감시 인프라 인벤토리 (cl-ea9810ebd3a98d01)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "▸ 1. Crontab"
    echo "   전체 항목: ${crontab_total}개 | 감시 관련: ${crontab_jarvis}개"
    if [[ -n "$cron_entries" ]]; then
        echo "   주요 항목 (최대 30개):"
        echo "$cron_entries" | while IFS= read -r line; do
            echo "     $line"
        done
    fi
    echo ""

    echo "▸ 2. LaunchAgents"
    echo "   전체 plist: ${plist_total}개 | 현재 로드됨: ${plist_loaded}개"
    if [[ -n "$plist_monitor_names" ]]; then
        echo "   감시 관련 에이전트:"
        echo "$plist_monitor_names" | while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            loaded_mark=""
            if launchctl list 2>/dev/null | grep -q "$name"; then
                loaded_mark=" [로드됨]"
            else
                loaded_mark=" [미로드]"
            fi
            echo "     • ${name}${loaded_mark}"
        done
    else
        echo "   감시 관련 에이전트: 없음"
    fi
    echo ""

    echo "▸ 3. monitoring.json 웹훅 채널"
    if [[ -f "$MONITORING_JSON" ]]; then
        echo "$webhook_channels"
        echo "   ntfy 토픽: ${ntfy_topic}"
    else
        echo "   ⚠️  monitoring.json 미존재: ${MONITORING_JSON}"
    fi
    echo ""

    echo "▸ 4. 기존 감시·알림 스크립트"
    if [[ -n "$existing_scripts" ]]; then
        echo "$existing_scripts" | while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            echo "   • $s"
        done
    else
        echo "   없음"
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ⚠️  새 감시 규칙 제안 전 위 목록 확인 필수"
    echo "    거짓양성 체크: list-monitors.sh --fp-check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
