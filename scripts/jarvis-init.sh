#!/usr/bin/env bash
# jarvis-init.sh — Jarvis 개인 환경 초기화 검증기
#
# 역할: 새 머신 또는 경로 변경 시 Jarvis 실행 환경을 검증하고 초기 구조를 구성.
#   - Node.js 22.5+ 필수 조건 확인 (node:sqlite)
#   - $JARVIS_HOME 환경변수 적용 여부 확인
#   - 필수 디렉토리 생성 (rag, state, logs, results)
#   - tasks.db 초기화
#   - 실행 권한 일괄 설정
#
# 사용법:
#   JARVIS_HOME=/custom/path bash jarvis-init.sh
#   bash ~/.jarvis/scripts/jarvis-init.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
NODE_SQLITE="node --experimental-sqlite --no-warnings"

ok()   { echo "  ✅  $*"; }
warn() { echo "  ⚠️  $*"; }
err()  { echo "  ❌  $*" >&2; exit 1; }
step() { echo ""; echo "▶ $*"; }

# ── 1. JARVIS_HOME 확인 ───────────────────────────────────────────────────────
step "JARVIS_HOME 확인"
if [[ ! -d "$JARVIS_HOME" ]]; then
    err "디렉토리 없음: $JARVIS_HOME — git clone 위치를 JARVIS_HOME으로 지정하세요."
fi
ok "JARVIS_HOME = $JARVIS_HOME"

# 환경변수 미설정 경고 (셸 프로파일에 없으면 크론에서 경로 오류 발생)
if [[ -z "${JARVIS_HOME+x}" ]]; then
    warn "JARVIS_HOME 환경변수가 셸 프로파일에 없습니다."
    warn "~/.zshrc 또는 ~/.bashrc에 추가하세요:"
    warn "  export JARVIS_HOME=\"${JARVIS_HOME}\""
    warn "  export BOT_HOME=\"\$JARVIS_HOME\""
fi

# ── 2. Node.js 버전 검증 ─────────────────────────────────────────────────────
step "Node.js 버전 검증"
if ! command -v node &>/dev/null; then
    err "node 없음 — https://nodejs.org 에서 22.5+ 설치 후 재실행"
fi
NODE_MAJOR=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
NODE_MINOR=$(node -e "process.stdout.write(process.versions.node.split('.')[1])")
NODE_VER=$(node --version)
if (( NODE_MAJOR < 22 )) || { (( NODE_MAJOR == 22 )) && (( NODE_MINOR < 5 )); }; then
    err "Node.js ${NODE_VER} 감지 — node:sqlite는 22.5+ 필요"
fi
ok "Node.js ${NODE_VER}"

# ── 3. 필수 디렉토리 생성 ────────────────────────────────────────────────────
step "디렉토리 구조 확인"
for d in logs state rag results config adr docs context; do
    mkdir -p "${JARVIS_HOME}/${d}"
done
ok "logs/ state/ rag/ results/ config/ adr/ docs/ context/ 확인 완료"

# ── 4. 실행 권한 일괄 설정 ───────────────────────────────────────────────────
step "실행 권한 설정"
find "${JARVIS_HOME}/scripts" "${JARVIS_HOME}/bin" -type f \
    \( -name "*.sh" -o -name "*.mjs" \) 2>/dev/null \
    -exec chmod +x {} \;
ok "scripts/ bin/ 실행 권한 완료"

# ── 5. tasks.db 초기화 ───────────────────────────────────────────────────────
step "tasks.db 초기화"
DB_PATH="${JARVIS_HOME}/state/tasks.db"
if ${NODE_SQLITE} "${JARVIS_HOME}/lib/task-store.mjs" count-queued > /dev/null 2>&1; then
    ok "tasks.db 정상 ($DB_PATH)"
else
    warn "tasks.db 초기화 실패 — lib/task-store.mjs 수동 확인 필요"
fi

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Jarvis 환경 초기화 완료"
if grep -qsE "JARVIS_HOME|BOT_HOME" "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null; then
    echo "  셸 프로파일: JARVIS_HOME 설정 감지됨 ✅"
else
    echo ""
    echo "  ⚠️  셸 프로파일에 추가 필요:"
    echo "    export JARVIS_HOME=\"${JARVIS_HOME}\""
    echo "    export BOT_HOME=\"\$JARVIS_HOME\""
fi
echo "═══════════════════════════════════════════════════════"
