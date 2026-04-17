#!/usr/bin/env bash
# windows-compat-check.sh — macOS-only 패턴 정적 분석기
#
# Usage:
#   windows-compat-check.sh [--fix-hints] [--dirs "dir1 dir2"]
#
# Options:
#   --fix-hints   각 이슈별 Linux/Windows 대체 방법 출력
#   --dirs "..."  스캔 디렉터리 지정 (공백 구분, 기본: scripts/ bin/ lib/)
#
# Exit:
#   0  — 이슈 없음
#   1  — macOS-only 패턴 발견
#
# Jarvis 명명 규칙: [도메인]-[대상]-[동작] → windows-compat-check

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}"

# ============================================================================
# 색상 정의
# ============================================================================
if [[ -t 1 ]]; then
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[1;34m'
  C_GREEN='\033[1;32m'
  C_CYAN='\033[1;36m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_YELLOW='' C_BLUE='' C_GREEN='' C_CYAN='' C_BOLD='' C_RESET=''
fi

# ============================================================================
# 인자 파싱
# ============================================================================
FIX_HINTS=false
CUSTOM_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-hints) FIX_HINTS=true ;;
    --dirs)      shift; read -ra CUSTOM_DIRS <<< "$1" ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# 스캔 디렉터리 결정
if [[ ${#CUSTOM_DIRS[@]} -gt 0 ]]; then
  SCAN_DIRS=("${CUSTOM_DIRS[@]}")
else
  SCAN_DIRS=(
    "$JARVIS_HOME/scripts"
    "$JARVIS_HOME/bin"
    "$JARVIS_HOME/lib"
  )
fi

# ============================================================================
# 패턴 정의 (4개 병렬 배열 — regex에 | 포함 가능, IFS 분리 없음)
# P_REGEX[i]  : grep -E 정규식
# P_LABEL[i]  : 표시할 패턴 이름
# P_SEV[i]    : warn(노란색) | info(파란색)
# P_HINT[i]   : --fix-hints 시 출력할 Linux 대체 방법
# ============================================================================
P_REGEX=()
P_LABEL=()
P_SEV=()
P_HINT=()

_add() {
  P_REGEX+=("$1")
  P_LABEL+=("$2")
  P_SEV+=("$3")
  P_HINT+=("$4")
}

# 1. stat -f : macOS BSD stat 옵션
_add 'stat[[:space:]]+-f[[:space:]]' \
     'stat -f' \
     'warn' \
     "Linux 대체: stat -c '%s' file  (또는 wc -c < file)"

# 2. sed -i '' : macOS BSD sed (빈 suffix 필수)
_add "sed[[:space:]]+-i[[:space:]]*''" \
     "sed -i ''" \
     'warn' \
     "Linux 대체: sed -i 's/old/new/' file  (suffix 없이)"

# 3. gtimeout : macOS Homebrew GNU coreutils 래퍼
_add '\bgtimeout\b' \
     'gtimeout' \
     'warn' \
     'Linux 대체: timeout  (GNU coreutils 기본 포함)'

# 4. gdate : macOS GNU date 래퍼
_add '\bgdate\b' \
     'gdate' \
     'warn' \
     'Linux 대체: date  (GNU date 기본 포함)'

# 5. gfind : macOS GNU find 래퍼
_add '\bgfind\b' \
     'gfind' \
     'warn' \
     'Linux 대체: find  (GNU find 기본 포함)'

# 6. gsed : macOS GNU sed 래퍼
_add '\bgsed\b' \
     'gsed' \
     'warn' \
     'Linux 대체: sed  (GNU sed 기본 포함)'

# 7. gawk : macOS GNU awk 래퍼
_add '\bgawk\b' \
     'gawk' \
     'warn' \
     'Linux 대체: awk  (GNU awk 기본 포함)'

# 8. /usr/local/bin/ : Homebrew Intel 경로 (Linux에 없음)
_add '/usr/local/bin/' \
     '/usr/local/bin/' \
     'info' \
     'Linux 대체: 경로 하드코딩 대신 command -v <cmd> 로 동적 감지 권장'

# 9. brew : Homebrew 명령
_add '\bbrew[[:space:]]' \
     'brew' \
     'warn' \
     'Linux 대체: apt-get / yum / pacman 등 (패키지 매니저 분기 필요)'

# 10. launchctl / launchd : macOS 서비스 관리
_add '\blaunchctl\b|\blaunchd\b' \
     'launchctl/launchd' \
     'warn' \
     'Linux 대체: systemctl / pm2  (lib/compat.sh 래퍼 활용: launchctl_load/unload)'

# 11. osascript : macOS AppleScript
_add '\bosascript\b' \
     'osascript' \
     'warn' \
     'Linux 대체: 없음. GUI 자동화는 xdotool / wmctrl (X11) 또는 제거'

# 12. open : macOS 파일/URL 열기 명령
_add '\bopen[[:space:]]' \
     'open' \
     'info' \
     'Linux 대체: xdg-open (X11) 또는 제거. Docker/서버 환경에서는 불필요'

# 13. pbcopy / pbpaste : macOS 클립보드
_add '\bpbcopy\b|\bpbpaste\b' \
     'pbcopy/pbpaste' \
     'warn' \
     'Linux 대체: xclip / xsel (X11), 또는 파이프로 파일 저장'

PATTERN_COUNT=${#P_REGEX[@]}

# ============================================================================
# 카운터
# ============================================================================
TOTAL_FILES=0
TOTAL_ISSUES=0
FILES_WITH_ISSUES=0

# ============================================================================
# 출력 헬퍼
# ============================================================================
print_header() {
  echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}  Jarvis macOS-only 패턴 호환성 검사${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"
  echo -e "  대상 디렉터리:"
  for d in "${SCAN_DIRS[@]}"; do
    echo -e "    ${C_BLUE}${d}${C_RESET}"
  done
  echo ""
}

print_issue() {
  local severity="$1"
  local file="$2"
  local lineno="$3"
  local label="$4"
  local matched="$5"
  local hint="$6"

  local color tag
  if [[ "$severity" == "info" ]]; then
    color="$C_BLUE"; tag="INFO"
  else
    color="$C_YELLOW"; tag="WARN"
  fi

  local trimmed
  trimmed=$(printf '%s' "$matched" | sed 's/^[[:space:]]*//' | cut -c1-80)

  echo -e "  ${color}[${tag}]${C_RESET} ${C_BOLD}${file}:${lineno}${C_RESET}: ${color}[${label}]${C_RESET} ${trimmed}"

  if [[ "$FIX_HINTS" == true && -n "$hint" ]]; then
    echo -e "         ${C_GREEN}↳ ${hint}${C_RESET}"
  fi
}

# ============================================================================
# 파일 스캔
# ============================================================================

# 파일 최상단(1~25줄)에 macOS-only early-exit 선언이 있으면 파일 전체가 macOS-only
# e.g.  $IS_MACOS || exit 0   /   if ! $IS_MACOS; then exit 0; fi
is_macos_only_file() {
  local filepath="$1"
  # 패턴: $IS_MACOS || exit  /  if ! $IS_MACOS; then ... exit  /  IS_MACOS 단독 early-return
  head -25 "$filepath" 2>/dev/null \
    | grep -qE '\$IS_MACOS\s*\|\|\s*exit|if\s*!\s*\$IS_MACOS|uname.*Darwin.*exit|\bIS_MACOS\b.*\|\|\s*exit' 2>/dev/null
}

# 매칭 라인이 IS_MACOS guard 블록 안에 있는지 휴리스틱 검사
# - 파일 최상단 early-exit guard OR 매칭 라인 기준 앞 50줄 안에 IS_MACOS 조건문 → "가드됨"
is_guarded() {
  local filepath="$1"
  local lineno="$2"

  # 파일 전체가 macOS-only인 경우
  if is_macos_only_file "$filepath"; then
    return 0
  fi

  local start=$(( lineno > 50 ? lineno - 50 : 1 ))
  sed -n "${start},${lineno}p" "$filepath" 2>/dev/null \
    | grep -qE '\$\{?IS_MACOS[^}]*\}?|\bIS_MACOS\b|uname -s.*Darwin|Darwin.*uname' 2>/dev/null
}

scan_file() {
  local filepath="$1"
  local display_path="${filepath#"$JARVIS_HOME/"}"
  local i=0

  while [[ $i -lt $PATTERN_COUNT ]]; do
    local regex="${P_REGEX[$i]}"
    local label="${P_LABEL[$i]}"
    local severity="${P_SEV[$i]}"
    local hint="${P_HINT[$i]}"

    # 주석 라인(#) 제외 후 패턴 매칭
    local matches
    matches=$(grep -nE "$regex" "$filepath" 2>/dev/null \
              | grep -v '^[0-9]*:[[:space:]]*#' \
              || true)

    if [[ -n "$matches" ]]; then
      while IFS= read -r match_line; do
        local lineno matched_text
        lineno=$(printf '%s' "$match_line" | cut -d: -f1)
        matched_text=$(printf '%s' "$match_line" | cut -d: -f2-)

        # IS_MACOS 가드 안에 있으면 skip (false positive 방지)
        if is_guarded "$filepath" "$lineno"; then
          continue
        fi

        # 동일 원본 라인에 Linux 대체 패턴이 있으면 skip (이미 fallback 처리됨)
        # stat -f ... || stat -c '%Y'  /  command -v gtimeout || command -v timeout
        local raw_line
        raw_line=$(sed -n "${lineno}p" "$filepath" 2>/dev/null || true)
        if printf '%s' "$raw_line" | grep -qE 'stat -c|command -v timeout'; then
          continue
        fi

        # 문자열 리터럴 또는 echo/log/heredoc 안의 패턴은 skip (실제 실행 아님)
        # e.g. log "launchd 스팸 방지..."  /  echo "  brew install jq"  /  heredoc 안 설명문
        if printf '%s' "$raw_line" | grep -qE \
          '^\s*(log|echo|warn|err|printf|#|"[^"]+").*\b(launchctl|launchd|brew|gtimeout)\b' \
          2>/dev/null; then
          continue
        fi
        # 홑따옴표 문자열 리터럴 (패턴 배열 정의 등) skip
        if printf '%s' "$raw_line" | grep -qE "^[[:space:]]+'[^']+'" 2>/dev/null; then
          continue
        fi

        print_issue "$severity" "$display_path" "$lineno" "$label" "$matched_text" "$hint"

        (( TOTAL_ISSUES++ )) || true
      done <<< "$matches"
    fi

    (( i++ )) || true
  done
}

# ============================================================================
# 메인
# ============================================================================
print_header

# 중복 파일 추적용 임시 파일 (bash 3.x 호환: declare -A 미사용)
SEEN_FILES_TMP=$(mktemp)
trap 'rm -f "$SEEN_FILES_TMP"' EXIT

for scan_dir in "${SCAN_DIRS[@]}"; do
  if [[ ! -d "$scan_dir" ]]; then
    echo -e "  ${C_YELLOW}[SKIP]${C_RESET} 디렉터리 없음: ${scan_dir}"
    continue
  fi

  while IFS= read -r -d '' filepath; do
    # 이 스크립트 자신은 건너뜀 (패턴 정의 문자열이 false positive 유발)
    real_path=$(realpath "$filepath" 2>/dev/null || echo "$filepath")
    if [[ "$real_path" == "$(realpath "$0" 2>/dev/null || echo "$0")" ]]; then
      continue
    fi
    # 중복 파일 건너뜀 (심볼릭 링크 등)
    if grep -qxF "$real_path" "$SEEN_FILES_TMP" 2>/dev/null; then
      continue
    fi
    echo "$real_path" >> "$SEEN_FILES_TMP"

    (( TOTAL_FILES++ )) || true

    before=$TOTAL_ISSUES
    scan_file "$filepath"
    after=$TOTAL_ISSUES

    if (( after > before )); then
      (( FILES_WITH_ISSUES++ )) || true
    fi

  done < <(find "$scan_dir" \( -name "*.sh" -o -name "*.bash" \) -type f -print0 2>/dev/null)
done

# ============================================================================
# 요약
# ============================================================================
echo ""
echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"
echo -e "${C_BOLD}  검사 요약${C_RESET}"
echo -e "${C_CYAN}=====================================================${C_RESET}"
echo -e "  총 검사 파일: ${C_BOLD}${TOTAL_FILES}개${C_RESET}"
echo -e "  이슈 발견 파일: ${C_BOLD}${FILES_WITH_ISSUES}개${C_RESET}"
echo -e "  총 이슈 수: ${C_BOLD}${TOTAL_ISSUES}개${C_RESET}"

if [[ $TOTAL_ISSUES -eq 0 ]]; then
  echo ""
  echo -e "  ${C_GREEN}✓ macOS-only 패턴 없음 — Linux/Windows 호환 가능${C_RESET}"
  echo ""
  exit 0
else
  echo ""
  echo -e "  ${C_YELLOW}⚠ macOS-only 패턴 ${TOTAL_ISSUES}개 발견${C_RESET}"
  if [[ "$FIX_HINTS" == false ]]; then
    echo -e "  ${C_BLUE}→ 수정 방법은: $0 --fix-hints${C_RESET}"
  fi
  echo ""
  exit 1
fi