#!/usr/bin/env bash
set -euo pipefail
# upgrade-v2.sh — Jarvis v1.x → v2.0.0 One-shot Upgrade
#
# A2 Runtime Migration: ~/.jarvis/ → ~/jarvis/runtime/
#
# Usage:
#   cd ~/jarvis && git pull && bash infra/scripts/upgrade-v2.sh
#
# 특징:
#   - Idempotent: 이미 마이그레이션됐으면 skip
#   - Defensive: 단계별 실패 시 자동 rollback
#   - Safe: 원본 데이터 절대 삭제 안 함 (~/.jarvis.backup-<date>로 보존)
#
# Failure modes:
#   1. 이미 migrated (~/.jarvis가 이미 심링크) → skip
#   2. Discord 봇 bootout 실패 → 계속 진행 (critical 아님)
#   3. plist rewrite 실패 → rollback
#   4. 봇 기동 실패 → rollback

HOME_DIR="${HOME}"
LEGACY="${HOME_DIR}/.jarvis"
BACKUP="${HOME_DIR}/.jarvis.backup-$(date '+%Y-%m-%d-%H%M%S')"

# REPO_ROOT 동적 감지 — 사용자가 ~/code/jarvis 등에 clone한 경우 지원
# 이 스크립트가 있는 디렉토리의 상위 2단계가 repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME="${REPO_ROOT}/runtime"
LOG="${RUNTIME}/logs/upgrade-v2.log"

# 플랫폼 체크 — macOS만 지원 (Linux는 별도 스크립트 필요)
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ upgrade-v2.sh 는 macOS 전용. Linux 사용자는 수동 마이그레이션 참조:"
    echo "   ${REPO_ROOT}/infra/docs/A2-MIGRATION.md"
    exit 1
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" 2>/dev/null || echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "❌ ERROR: $*"; exit 1; }

log "═══════════════════════════════════════════"
log "Jarvis v2.0.0 Upgrade — A2 Runtime Migration"
log "═══════════════════════════════════════════"

# ─── Pre-flight checks ──────────────────────────────────────────────

# 0a. git 레포 맞는지
if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    die "$REPO_ROOT is not a git repo. cd to your jarvis clone first."
fi

# 0b. 필수 스크립트 존재
for script in migrate-to-runtime.sh rewrite-plists-to-runtime.sh install-hooks.sh; do
    if [[ ! -x "${REPO_ROOT}/infra/scripts/${script}" ]]; then
        die "Missing: infra/scripts/${script}. git pull?"
    fi
done

# 0c. Idempotent check — 이미 마이그레이션됐나?
if [[ -L "$LEGACY" ]]; then
    TARGET=$(readlink "$LEGACY")
    if [[ "$TARGET" == "$RUNTIME" ]]; then
        log "✅ 이미 마이그레이션 완료 상태 (~/.jarvis → $RUNTIME)"
        log "  추가 조치 불필요. 봇 상태만 확인:"
        if pgrep -f "discord-bot.js" >/dev/null; then
            log "  ✅ Discord 봇 running (PID: $(pgrep -f discord-bot.js | head -1))"
        else
            log "  ⚠️ 봇 미실행. 수동 기동: launchctl kickstart -k gui/\$(id -u)/ai.jarvis.discord-bot"
        fi
        exit 0
    fi
    die "$LEGACY is a symlink to $TARGET (expected: $RUNTIME). 수동 확인 필요."
fi

# 0d. ~/.jarvis가 실제 디렉토리인지 (migrate 필요한 상태)
if [[ ! -d "$LEGACY" ]]; then
    log "⚠️ $LEGACY 없음 — 이건 신규 설치일 수 있음"
    log "   신규 설치자는 migrate 스크립트 대신 setup_infra.py 실행 권장"
    exit 0
fi

# ─── Phase 1: Stop bot ──────────────────────────────────────────────
UID_NUM=$(id -u)
log ""
log "━━━ Phase 1: 봇/watchdog 일시 정지 ━━━"
launchctl bootout "gui/${UID_NUM}/ai.jarvis.discord-bot" 2>/dev/null || log "  (봇 이미 미실행)"
launchctl bootout "gui/${UID_NUM}/ai.jarvis.watchdog" 2>/dev/null || log "  (watchdog 이미 미실행)"
sleep 2
log "  ✅ bootout 완료"

# ─── Phase 2: Data migration ────────────────────────────────────────
log ""
log "━━━ Phase 2: 데이터 이사 (~/.jarvis → ~/jarvis/runtime) ━━━"
# 크기 사전 안내 — RAG DB가 크면 몇 분 걸릴 수 있음
LEGACY_SIZE=$(du -sh "$LEGACY" 2>/dev/null | awk '{print $1}' || echo "?")
log "  전체 크기: $LEGACY_SIZE (큰 경우 RAG DB 때문 — 중단하지 말고 대기)"
log "  진행 중 메시지가 안 보여도 정상 — rsync 중..."
if bash "${REPO_ROOT}/infra/scripts/migrate-to-runtime.sh" --copy 2>&1 | tee -a "$LOG"; then
    log "  ✅ 복사 완료"
else
    die "migrate --copy 실패. 롤백 없음 (원본 안 건드림). 봇 재기동: launchctl kickstart -k gui/${UID_NUM}/ai.jarvis.discord-bot"
fi

# 검증
if ! bash "${REPO_ROOT}/infra/scripts/migrate-to-runtime.sh" --verify 2>&1 | tee -a "$LOG" | grep -q "전체 검증 통과"; then
    die "migrate --verify 실패. 원본은 안전. 로그: $LOG"
fi

# ─── Phase 3: Symlink redirect (atomic) ─────────────────────────────
log ""
log "━━━ Phase 3: 호환성 심링크 전환 (~/.jarvis → runtime) ━━━"
log "  백업: $BACKUP"
if ! mv "$LEGACY" "$BACKUP"; then
    die "mv $LEGACY → $BACKUP 실패. 권한 문제?"
fi

if ! ln -s "$RUNTIME" "$LEGACY"; then
    # Rollback
    log "  ❌ 심링크 생성 실패. 롤백 중..."
    mv "$BACKUP" "$LEGACY" || log "  롤백도 실패 — 수동 확인 필요: $BACKUP"
    die "심링크 생성 실패"
fi
log "  ✅ $LEGACY → $RUNTIME"

# ─── Phase 4: SSoT symlinks inside runtime/ ─────────────────────────
log ""
log "━━━ Phase 4: runtime/ 내부 SSoT 심링크 복구 ━━━"
for d in bin lib scripts infra; do
    target="${REPO_ROOT}/infra/${d}"
    if [[ "$d" == "infra" ]]; then target="${REPO_ROOT}/infra"; fi
    link="${RUNTIME}/${d}"
    if [[ -L "$link" ]]; then rm "$link"; fi
    if [[ -d "$link" && ! -L "$link" ]]; then rm -rf "$link"; fi
    ln -s "$target" "$link"
    log "  ✅ runtime/${d} → $target"
done

# ─── Phase 5: LaunchAgent plist rewrite ─────────────────────────────
log ""
log "━━━ Phase 5: LaunchAgent plist 경로 갱신 ━━━"
# rewrite 스크립트가 자체 백업 생성: ~/backup/plists-phase-d/<TS>/
# rollback 시 이 경로를 사용하기 위해 저장
PLIST_BACKUP_BEFORE=$(ls -1dt ~/backup/plists-phase-d/*/ 2>/dev/null | head -1 || echo "")
if bash "${REPO_ROOT}/infra/scripts/rewrite-plists-to-runtime.sh" --apply 2>&1 | tee -a "$LOG" | grep -q "✅ plist Phase D 치환"; then
    PLIST_BACKUP_AFTER=$(ls -1dt ~/backup/plists-phase-d/*/ 2>/dev/null | head -1 || echo "")
    log "  ✅ plist 치환 + 재등록 완료 (백업: $PLIST_BACKUP_AFTER)"
else
    log "  ⚠️ plist rewrite 결과 불확실 — 로그 확인: $LOG"
    PLIST_BACKUP_AFTER="$PLIST_BACKUP_BEFORE"
fi

# ─── Phase 6: Git hooks ─────────────────────────────────────────────
log ""
log "━━━ Phase 6: Git hooks 설치 ━━━"
bash "${REPO_ROOT}/infra/scripts/install-hooks.sh" 2>&1 | tee -a "$LOG" || log "  ⚠️ install-hooks 결과 불확실"

# ─── Phase 7: Start bot + verify ────────────────────────────────────
log ""
log "━━━ Phase 7: 봇 재기동 + 검증 ━━━"
launchctl bootstrap "gui/${UID_NUM}" "${HOME_DIR}/Library/LaunchAgents/ai.jarvis.discord-bot.plist" 2>/dev/null || \
    launchctl kickstart -k "gui/${UID_NUM}/ai.jarvis.discord-bot" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "${HOME_DIR}/Library/LaunchAgents/ai.jarvis.watchdog.plist" 2>/dev/null || \
    launchctl kickstart -k "gui/${UID_NUM}/ai.jarvis.watchdog" 2>/dev/null || true

# 봇 기동 대기 (최대 90초 — RAG 2GB 로딩 고려)
log "  봇 기동 대기... (최대 90초, 느린 시스템에서 RAG 로딩 시간 포함)"
for i in $(seq 1 90); do
    if pgrep -f "discord-bot.js" >/dev/null; then
        sleep 3  # 초기화 완료 대기
        # heartbeat 파일이 최근 업데이트됐는지 확인 (더 확실한 검증)
        if [[ -f "${RUNTIME}/state/bot-heartbeat" ]]; then
            hb_age=$(( $(date +%s) - $(stat -f %m "${RUNTIME}/state/bot-heartbeat" 2>/dev/null || echo 0) ))
            if (( hb_age < 60 )); then
                log "  ✅ Discord 봇 running (PID: $(pgrep -f discord-bot.js | head -1), heartbeat ${hb_age}s 전)"
                break
            fi
        fi
        log "  (PID 있지만 heartbeat 미확인, 대기 계속... ${i}s)"
    fi
    if (( i % 15 == 0 )); then log "  ... ${i}s 경과"; fi
    sleep 1
    if (( i == 90 )); then
        log "  ❌ 봇 기동 실패 (90초 대기). Rollback 중..."
        # Full Rollback: 봇 중지 + plist 복원 + 데이터 복원 + 봇 재기동
        launchctl bootout "gui/${UID_NUM}/ai.jarvis.discord-bot" 2>/dev/null || true
        launchctl bootout "gui/${UID_NUM}/ai.jarvis.watchdog" 2>/dev/null || true

        # plist 복원 (Phase 5에서 백업된 것) — cp만으론 launchd 반영 안 됨
        # → bootout → cp → bootstrap 순서 필수
        if [[ -n "${PLIST_BACKUP_AFTER:-}" ]] && [[ -d "$PLIST_BACKUP_AFTER" ]]; then
            log "  plist 복원 중 (from $PLIST_BACKUP_AFTER)"
            for pf in "$PLIST_BACKUP_AFTER"/*.plist; do
                [[ -f "$pf" ]] || continue
                svc_name=$(basename "$pf" .plist)
                launchctl bootout "gui/${UID_NUM}/${svc_name}" 2>/dev/null || true
                cp "$pf" "${HOME_DIR}/Library/LaunchAgents/"
            done
            log "  (launchctl bootstrap은 Phase 7 끝에서 일괄 수행)"
        fi

        # 심링크 → 원본 디렉토리
        rm -f "$LEGACY"
        mv "$BACKUP" "$LEGACY"

        # plist 재등록 (복원한 plist 전부)
        if [[ -n "${PLIST_BACKUP_AFTER:-}" ]] && [[ -d "$PLIST_BACKUP_AFTER" ]]; then
            for pf in "$PLIST_BACKUP_AFTER"/*.plist; do
                [[ -f "$pf" ]] || continue
                svc_name=$(basename "$pf" .plist)
                launchctl bootstrap "gui/${UID_NUM}" "${HOME_DIR}/Library/LaunchAgents/${svc_name}.plist" 2>/dev/null || true
            done
        else
            # plist 백업 없으면 핵심 2개라도 재기동
            for svc in ai.jarvis.discord-bot ai.jarvis.watchdog; do
                launchctl bootstrap "gui/${UID_NUM}" "${HOME_DIR}/Library/LaunchAgents/${svc}.plist" 2>/dev/null || true
            done
        fi

        die "봇 기동 실패 → 완전 롤백 (plist + 데이터). 원인 조사: ~/.jarvis/logs/discord-bot.err.log"
    fi
done

# ─── Success ────────────────────────────────────────────────────────
log ""
log "═══════════════════════════════════════════"
log "✅ A2 Migration 완료!"
log "═══════════════════════════════════════════"
log "  Runtime: $RUNTIME"
log "  Legacy backup: $BACKUP (7일 후 자동 삭제)"
log "  로그: $LOG"
log ""
log "  검증 명령:"
log "    cat ~/.jarvis/state/bot-heartbeat      # heartbeat 최신"
log "    launchctl list | grep jarvis           # LaunchAgents 상태"
log "    tail ~/.jarvis/logs/cron.log           # 크론 실행 로그"
log ""
log "  문제 시 롤백:"
log "    rm ~/.jarvis && mv $BACKUP ~/.jarvis"
log "    launchctl kickstart -k gui/${UID_NUM}/ai.jarvis.discord-bot"
