#!/usr/bin/env bash
# symlink-topology-audit.sh
#
# ~/.openclaw-data/runtime 하위 토폴로지 정합성 감사 + 자동 복구.
#
# Check:
#   1. ~/.openclaw-data/runtime/{infra,bin,lib,scripts} 가 심링크인가 (실제 디렉토리로 변했으면 파괴)
#   2. 그 심링크들이 SSoT(~/projects/jarvis/infra/*)를 가리키는가
#   3. ~/.openclaw-data/runtime 하위 다른 절대 심링크가 SSoT 외부를 가리키는가
#   4. .bak-* / .ghost-* 잔해
#
# Auto-recovery: Check 1·2 위반은 즉시 자동 복구 (파일 백업 후 심링크 재생성).
#   복구 로그는 원장 + Discord 알림.
#
# Discord 알림 스로틀: 같은 (code, path)로 24시간 내 반복 알림 차단.
#
# 2026-04-16 2차 장애 이후 auto-recovery + 스로틀 추가.
set -euo pipefail

# 주의: DOT_JARVIS 라는 이름과 달리 값은 런타임 폴더(~/.openclaw-data/runtime)다.
#   이 감사가 원래 지키는 대상은 runtime/{infra,bin,lib,scripts} 심링크이며 그 동작은 정상이다.
#   (2026-07-25 확인 — 이름 때문에 "~/.jarvis 를 검사한다"고 오해하기 쉬우니 여기 명시)
DOT_JARVIS="${HOME}/.openclaw-data/runtime"
SSOT="${HOME}/projects/jarvis/infra"
# 2026-07-25 추가: 옛 경로(~/.jarvis) 호환 심링크는 그동안 어떤 감사도 보지 않는
#   사각지대였다. 그 사이 bin·scripts·config·discord 링크가 사라져, 이 경로를
#   BOT_HOME 으로 주입받는 LaunchAgent 102개 중 다수가 조용히 실패했다
#   (모닝브리핑·뉴스·커리어·봇 기동 등). 여기에 포함해 함께 지킨다.
COMPAT_HOME="${HOME}/.jarvis"   # ALLOW-DOTJARVIS (옛 경로 호환 계층 — 의도적 참조)
LEDGER_DIR="${DOT_JARVIS}/state"
LEDGER="${LEDGER_DIR}/symlink-audit.jsonl"
THROTTLE_DIR="${LEDGER_DIR}/audit-throttle"
BACKUP_DIR="${HOME}/backup/jarvis-topology/auto-recovery"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
EPOCH="$(date +%s)"

mkdir -p "$LEDGER_DIR" "$THROTTLE_DIR" "$BACKUP_DIR"

# Canonical symlink mapping (bash 3.2 호환 — 평행 배열)
#
# 2026-08-07 — "그림자 폴더 통합분"(2026-07-27 추가, COMPAT_HOME/{prompts,adr,watchdog,
#   tmp,archive,teams,backups,work,docs,data,wiki,ledger,results,context,runtime,
#   logs,inbox,state} + COMPAT_HOME/{config,discord})을 통째로 제거했다.
#   COMPAT_HOME(~/.jarvis)이 DOT_JARVIS(~/.openclaw-data/runtime)를 가리키는 심링크인 이상,
#   "${COMPAT_HOME}/X" 는 항상 "${DOT_JARVIS}/X" 와 물리적으로 동일한 경로로 풀린다.
#   그런데 이 블록의 expected_target 도 항상 "${HOME}/.openclaw-data/runtime/X" — 즉 자기 자신.
#   COMPAT_HOME이 정상일 때조차 "X가 X를 가리키는 심링크인가"를 묻는 구조라 X가
#   조금이라도 실디렉토리인 순간(늘 그렇다 — X는 runtime의 진짜 하위 데이터) 무조건
#   "유령 디렉토리"로 오판해 정본 데이터를 스태시로 옮기고 자기참조 심링크로 덮어썼다.
#   L86 COMPAT_HOME 드리프트 가드가 무력화됐던 유일한 이유는 COMPAT_HOME 자체가
#   드리프트해 있었기 때문일 뿐 — 2026-08-07 드리프트를 고치자마자 이 블록이 20개
#   항목 전부를 파괴했다(정본 runtime/ 자체 포함, CLI auto-memory 전역 ELOOP 원인).
#   COMPAT_HOME이 ~/.jarvis 전체를 가리키는 단일 심링크인 이상, 그 하위 항목은
#   이미 자동으로 올바르게 해석된다 — 개별 항목 등재는 애초에 불필요했다.
#   보호가 필요한 대상은 DOT_JARVIS/{infra,bin,lib,scripts}(SSoT 참조, 자기참조 아님)
#   뿐이며, COMPAT_HOME 쪽은 그 4개만 중복 확인해도 충분하다.
EXPECTED_LINK_PATHS=(
  "${DOT_JARVIS}/infra"
  "${DOT_JARVIS}/bin"
  "${DOT_JARVIS}/lib"
  "${DOT_JARVIS}/scripts"
  "${COMPAT_HOME}/bin"
  "${COMPAT_HOME}/lib"
  "${COMPAT_HOME}/scripts"
)
EXPECTED_LINK_TARGETS=(
  "${SSOT}"
  "${SSOT}/bin"
  "${SSOT}/lib"
  "${SSOT}/scripts"
  "${SSOT}/bin"
  "${SSOT}/lib"
  "${SSOT}/scripts"
)

# Ledger emitter
emit() {
  local level="$1" code="$2" path="$3" detail="$4"
  printf '{"ts":"%s","level":"%s","code":"%s","path":"%s","detail":"%s"}\n' \
    "$TS" "$level" "$code" "$path" "$detail" >> "$LEDGER"
}

# Discord alert with 24h throttle per (code,path)
alert_throttled() {
  local code="$1" path="$2" title="$3" detail="$4"
  local key
  key="$(printf '%s|%s' "$code" "$path" | shasum -a 1 | awk '{print $1}')"
  local marker="${THROTTLE_DIR}/${key}"
  if [[ -f "$marker" ]]; then
    local last
    last=$(cat "$marker" 2>/dev/null || echo 0)
    if (( EPOCH - last < 86400 )); then
      return 0
    fi
  fi
  if [[ -x "${HOME}/.openclaw-data/runtime/scripts/discord-visual.mjs" || -f "${HOME}/.openclaw-data/runtime/scripts/discord-visual.mjs" ]]; then
    /opt/homebrew/bin/node "${HOME}/.openclaw-data/runtime/scripts/discord-visual.mjs" \
      --type stats \
      --data "{\"title\":\"${title}\",\"data\":{\"path\":\"${path}\",\"detail\":\"${detail}\",\"ledger\":\"${LEDGER}\"},\"timestamp\":\"${TS}\"}" \
      --channel jarvis-system 2>/dev/null || true
  fi
  echo "$EPOCH" > "$marker"
}

# Auto-recovery: 심링크가 깨졌거나 디렉토리로 변한 경우 복구
recover_link() {
  local link_path="$1" expected_target="$2"
  local recovery_stash
  recovery_stash="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)-$(basename "$link_path")"

  # ── 자기참조 가드 (2026-08-23 신설 — 1차 방어선) ───────────────────────────
  # expected_target 이 link_path 자신으로 풀리면 이 함수가 하는 모든 일이 파괴다:
  #   심링크면 "X를 X로 교체", 실디렉토리면 "정본을 스태시로 옮기고 자기참조 링크로 덮어쓰기".
  # 아래 ghost-dir 가드(L132)는 정본 '루트'만 봐서 그 하위(runtime/logs 등)를 못 막았고,
  # 그 구멍으로 08-06(7개) · 08-07(15개) · 08-23(20개, 약 3.6GB) 세 번 파괴가 났다.
  # 등재 목록을 고치는 건 증상 치료다 — 어떤 등재가 들어와도 여기서 먼저 끊는다.
  # 양쪽 모두 물리 경로로 정규화한다 — 한쪽만 풀면 경로에 심링크가 끼는 순간
  # 같은 곳인데 다르다고 판정해 가드가 조용히 새어나간다(회귀 테스트로 실제 확인).
  local lp_dir lp_abs et_dir et_abs
  lp_dir="$(cd -P "$(dirname "$link_path")" 2>/dev/null && pwd || true)"
  et_dir="$(cd -P "$(dirname "$expected_target")" 2>/dev/null && pwd || true)"
  et_abs="$expected_target"
  if [[ -n "$et_dir" ]]; then
    et_abs="${et_dir}/$(basename "$expected_target")"
  fi
  if [[ -n "$lp_dir" ]]; then
    lp_abs="${lp_dir}/$(basename "$link_path")"
    if [[ "$lp_abs" == "$et_abs" ]]; then
      emit "error" "self-reference-guard-blocked" "$link_path" "expected_target 이 자기 자신 (${expected_target}) — 복구 거부"
      alert_throttled "self-reference-guard-blocked" "$link_path" "🔴 자기참조 복구 차단" "expected_target=${expected_target} 이 link_path 와 동일 — 등재 오류다. 데이터는 건드리지 않았다."
      return 1
    fi
  fi
  # ──────────────────────────────────────────────────────────────────────────

  if [[ -L "$link_path" ]]; then
    local current_target
    current_target="$(readlink "$link_path" 2>/dev/null || echo '')"
    if [[ "$current_target" == "$expected_target" ]]; then
      return 0  # 정상
    fi
    # 잘못된 타겟을 가리키는 심링크 → 교체
    rm -f "$link_path"
    ln -s "$expected_target" "$link_path"
    emit "info" "recovered-wrong-target" "$link_path" "was=${current_target} now=${expected_target}"
    alert_throttled "recovered-wrong-target" "$link_path" "🔧 심링크 자동 복구" "was=${current_target} → now=${expected_target}"
    return 1  # 복구 발생
  fi

  if [[ -d "$link_path" && ! -L "$link_path" ]]; then
    # 2026-08-07 추가 — 2차 방어선. link_path 의 물리 경로가 정본 루트(DOT_JARVIS)나
    #   레포 루트 자체로 풀리면 절대 옮기지 않는다. 위 COMPAT_HOME 가드가 뚫려도
    #   여기서 한 번 더 막는다 — "유령 디렉토리"로 오판해 정본 데이터를 통째로
    #   스태시 이동시키는 사고(2026-08-06)를 어떤 경로로든 재발시키지 않기 위함.
    local link_real
    link_real="$(cd -P "$link_path" 2>/dev/null && pwd || true)"
    if [[ -n "$link_real" ]] && { [[ "$link_real" == "$DOT_JARVIS" ]] || [[ "$link_real" == "${HOME}/projects/jarvis" ]]; }; then
      emit "error" "ghost-dir-guard-blocked" "$link_path" "resolved=${link_real} — 정본 루트와 동일, 이동 거부"
      alert_throttled "ghost-dir-guard-blocked" "$link_path" "🔴 유령 디렉토리 복구 차단됨" "resolved=${link_real} 이 정본 루트와 동일 — 수동 확인 필요"
      return 1
    fi
    # 2026-09-03 추가 — 3차 방어선. 내용물이 있는 실디렉토리는 자동으로 옮기지 않는다.
    #   세 번의 파괴(08-06·08-07·08-23) 모두 "내용물이 있는 실디렉토리를 유령으로 오판해
    #   스태시로 이동"이었고, 08-23 스태시분은 11일간 아무도 되돌리지 않아 크론 94%
    #   실패·봇 다운·wiki-slots 무력화로 이어졌다. 자동 이동이 실제로 필요했던 비어있지
    #   않은 디렉토리는 한 번도 없었다. 빈 디렉토리만 자동 교체하고, 내용물이 있으면
    #   원장·알림만 남기고 사람이 결정한다. 우회는 JARVIS_TOPOLOGY_STASH_OK=1 명시 시에만.
    local file_count
    file_count=$(find "$link_path" -type f -o -type l 2>/dev/null | wc -l | tr -d ' ')
    if (( file_count > 0 )) && [[ "${JARVIS_TOPOLOGY_STASH_OK:-0}" != "1" ]]; then
      emit "error" "ghost-dir-nonempty-blocked" "$link_path" "files=${file_count} — 내용물 있는 실디렉토리, 자동 이동 거부 (수동: JARVIS_TOPOLOGY_STASH_OK=1)"
      alert_throttled "ghost-dir-nonempty-blocked" "$link_path" "🔴 실디렉토리 자동 이동 차단" "files=${file_count} — 심링크여야 할 경로가 내용물 있는 실디렉토리. 데이터는 건드리지 않았다. 확인 후 JARVIS_TOPOLOGY_STASH_OK=1 로 재실행"
      return 1
    fi
    # 비어있거나 명시 승인됨 → 백업 후 제거 + 심링크 재생성
    mv "$link_path" "$recovery_stash"
    ln -s "$expected_target" "$link_path"
    emit "error" "recovered-ghost-dir" "$link_path" "stashed=${recovery_stash} files=${file_count}"
    alert_throttled "recovered-ghost-dir" "$link_path" "🚨 유령 디렉토리 자동 복구" "stashed at ${recovery_stash} (files: ${file_count})"
    return 1
  fi

  if [[ ! -e "$link_path" ]]; then
    # 심링크도 없음 → 생성
    ln -s "$expected_target" "$link_path"
    emit "warn" "recovered-missing" "$link_path" "created symlink to ${expected_target}"
    alert_throttled "recovered-missing" "$link_path" "🔧 누락 심링크 복구" "created → ${expected_target}"
    return 1
  fi

  return 0
}

# 2026-08-07 추가 — COMPAT_HOME 드리프트 가드.
#   COMPAT_HOME(~/.jarvis)이 DOT_JARVIS(~/.openclaw-data/runtime)가 아닌 다른 곳(예: ~/projects/jarvis
#   레포 루트)을 가리키면, 아래 COMPAT_HOME 기반 항목들의 물리 경로가 정본 데이터
#   디렉토리 자체로 풀려버린다. 그 상태에서 recover_link 의 "유령 디렉토리" 분기가
#   돌면 실데이터를 스태시로 옮기고 자기참조 심링크를 만든다 — 2026-08-06 실제 발생,
#   ~/.openclaw-data/runtime 자체가 깨져 CLI auto-memory 가 전역 ELOOP 로 무너졌다.
#   L50-55 주석이 DOT_JARVIS 쪽 자기참조는 미리 막았지만, COMPAT_HOME 쪽 드리프트는
#   막지 못했다. 여기서 COMPAT_HOME 이 실제로 DOT_JARVIS 를 가리키는지 먼저 검증하고,
#   아니면 COMPAT_HOME 기반 항목은 전부 건너뛴다(추측 복구보다 스킵이 안전하다).
COMPAT_HOME_REAL="$(cd -P "$COMPAT_HOME" 2>/dev/null && pwd || true)"
# 2026-09-10 정정: 기대값도 실경로로 풀어서 비교한다.
#   전에는 해석된 경로(cd -P)를 리터럴 문자열($DOT_JARVIS)과 견줬다. 그 비교는
#   ~/projects/jarvis 가 심링크가 아닐 때만 맞다 — 오픈클로 이관으로 ~/projects/jarvis 가 심링크가 되자
#   물리적으로 동일한 디렉토리인데도 드리프트로 오판했다(실측 20:28).
#   양쪽을 같은 방법으로 풀면 트리가 어디로 가든 이 검사는 계속 옳다.
DOT_JARVIS_REAL="$(cd -P "$DOT_JARVIS" 2>/dev/null && pwd || echo "$DOT_JARVIS")"
if [[ "$COMPAT_HOME_REAL" != "$DOT_JARVIS_REAL" ]]; then
  SKIP_COMPAT_CHECKS=1
  emit "error" "compat-home-drift" "$COMPAT_HOME" "resolved=${COMPAT_HOME_REAL:-<unresolved>} expected=${DOT_JARVIS_REAL} — COMPAT_HOME 기반 심링크 검사 스킵"
  alert_throttled "compat-home-drift" "$COMPAT_HOME" "🔴 COMPAT_HOME 드리프트 감지 — 심링크 자동복구 스킵" "resolved=${COMPAT_HOME_REAL:-<unresolved>} expected=${DOT_JARVIS_REAL}"
else
  SKIP_COMPAT_CHECKS=0
fi

violations=0
recoveries=0

# Check 1·2 (+ auto-recovery): 정규 심링크 검증/복구
idx=0
while (( idx < ${#EXPECTED_LINK_PATHS[@]} )); do
  link_path="${EXPECTED_LINK_PATHS[$idx]}"
  expected="${EXPECTED_LINK_TARGETS[$idx]}"
  if (( SKIP_COMPAT_CHECKS == 1 )) && [[ "$link_path" == "${COMPAT_HOME}"/* ]]; then
    idx=$((idx + 1))
    continue
  fi
  if ! recover_link "$link_path" "$expected"; then
    recoveries=$((recoveries + 1))
  fi
  idx=$((idx + 1))
done

# Check 3: SSoT 외부를 가리키는 절대 심링크 (find 에러는 fatal)
while IFS= read -r link; do
  case "$link" in
    *.bak*|*backup*) continue ;;
    # 2026-07-25: 브라우저 프로필 내부는 크롬이 관리하는 영역이라 자비스 토폴로지가 아니다.
    #   크롬 종료 시 임시 소켓 링크의 대상이 사라져 '복구 불가 위반'으로 영구 집계됐고,
    #   그 탓에 이 감사가 상시 실패(exit 1) 상태라 경보로서 신뢰를 잃고 있었다.
    # 2026-08-06 정정: 위 패턴은 실제 경로(job-apply-chrome-profile)와 매칭되지 않아
    #   차단에 실패했다. 10분 주기로 106일간 exit 1 을 냈고 아무도 보지 않게 됐다.
    #   프로필 디렉터리 이름은 도구마다 다르므로 크롬이 만드는 런타임 아티팩트 이름으로도 거른다.
    *browser-profile*|*chrome-profile*|*chromium-profile*) continue ;;
    *Singleton*|*/CrashpadMetrics*) continue ;;
  esac
  target="$(readlink "$link" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then continue; fi
  if [[ "$target" != /* ]]; then continue; fi
  if [[ "$target" == "${DOT_JARVIS}"/* ]]; then continue; fi
  if [[ "$target" == "${SSOT}"* ]]; then continue; fi
  if [[ "$target" == "${HOME}/projects/jarvis"* ]]; then continue; fi
  if [[ "$target" == "${HOME}/jarvis-board"* ]]; then continue; fi
  # 2026-07-25 주석 정정: ~/.jarvis 는 심링크가 아니라 독립 실제 폴더이며,
  #   그 아래 bin/lib/scripts/config/discord 만 정본을 가리키는 호환 링크다(위 EXPECTED 목록에서 관리).
  if [[ "$target" == "${HOME}/.jarvis"* ]]; then continue; fi  # ALLOW-DOTJARVIS (호환 계층 — 허용)
  # 2026-09-10 오픈클로 이관: 정본이 자비스 밖으로 나갔다.
  #   위키(슬롯)·원장·페르소나 설정은 이제 `~/.openclaw-data` 가 소유하고,
  #   자비스 안의 옛 경로는 읽는 쪽을 깨지 않으려 남긴 호환 심링크다.
  #   이 두 줄이 없으면 감사가 정상 이관을 10분마다 위반으로 신고한다(실측: violations=4, exit 1).
  if [[ "$target" == "${HOME}/.openclaw-data"* ]]; then continue; fi  # ALLOW-OPENCLAW-DATA (이관 목적지)
  if [[ "$target" == "${HOME}/.openclaw/"* ]]; then continue; fi      # ALLOW-OPENCLAW (워크스페이스·스크립트)
  emit "warn" "off-ssot-target" "$link" "target=${target}"
  alert_throttled "off-ssot-target" "$link" "⚠️ SSoT 외부 심링크" "target=${target}"
  violations=$((violations + 1))
done < <(find "$DOT_JARVIS" -type l ! -path '*.bak*' ! -path '*node_modules*')

# Check 4: 잔해
while IFS= read -r stale; do
  emit "warn" "stale-backup" "$stale" "leftover backup dir — archive and remove"
  violations=$((violations + 1))
done < <(find "$DOT_JARVIS" -maxdepth 2 -type d \( -name '*.bak-*' -o -name '*.ghost-*' -o -name '*.bak' \))

# Check 4b: 실데이터 디렉토리 존재/비어있지 않음
#   2026-09-03 신설. 계기 — 2026-09-02 23:15~23:22 사이 runtime/ 하위 전부(config·wiki·state·
#   context·discord·logs + 코드 심링크 4개)가 사라졌다. 코드 심링크는 이 감사가 10분 안에
#   되살렸지만 데이터 디렉토리는 아무도 보지 않아 11일간 크론 94% 실패·봇 다운·wiki-slots
#   무력화가 이어졌다. 복구는 하지 않는다(어느 백업이 맞는지는 사람이 정한다) — 알림만 낸다.
# [2026-09-10] 주인님 지시로 디스코드 전면 제거 — discord 를 감시 대상에서 뺀다
DATA_DIRS=(config wiki state context logs)
DATA_SENTINELS=("config/tasks.json")
for d in "${DATA_DIRS[@]}"; do
  if [[ ! -d "${DOT_JARVIS}/${d}" ]] || [[ -z "$(ls -A "${DOT_JARVIS}/${d}" 2>/dev/null)" ]]; then
    emit "error" "data-dir-missing" "${DOT_JARVIS}/${d}" "실데이터 디렉토리가 없거나 비어 있음 — 백업(~/backup/jarvis-topology) 확인 후 수동 복원"
    alert_throttled "data-dir-missing" "${DOT_JARVIS}/${d}" "🔴 runtime 데이터 디렉토리 소실" "${d}/ 이 없거나 비어 있음 — 크론·봇 전면 장애. ~/backup/jarvis-topology 에서 수동 복원 필요"
    violations=$((violations + 1))
  fi
done
for s in "${DATA_SENTINELS[@]}"; do
  if [[ ! -e "${DOT_JARVIS}/${s}" ]]; then
    emit "error" "data-sentinel-missing" "${DOT_JARVIS}/${s}" "핵심 파일 없음"
    alert_throttled "data-sentinel-missing" "${DOT_JARVIS}/${s}" "🔴 runtime 핵심 파일 소실" "${s} 없음 — 해당 서브시스템 정지 상태"
    violations=$((violations + 1))
  fi
done

# Check 5: Claude Code auto memory 무결성
#   2026-08-06 신설. 계기 — MEMORY.md 인덱스가 참조하는 41개 링크 중 20개가 죽어 있었고
#   그 안에 "🔴 최상위 행동 규칙"으로 지정된 항목까지 있었다. 링크가 죽어도 세션은
#   조용히 시작되므로 아무도 몰랐다. 여기서 두 가지만 본다 — 깨진 심링크, 그리고
#   MEMORY.md 가 가리키는 대상의 실재 여부. 역방향(미등재 파일)은 Claude 가 만드는 중일 수
#   있어 검사하지 않는다(오탐을 만들면 Check 3 과 같은 실패를 반복한다).
while IFS= read -r memdir; do
  [[ -d "$memdir" ]] || continue

  while IFS= read -r deadlink; do
    emit "warn" "memory-broken-symlink" "$deadlink" "target=$(readlink "$deadlink" 2>/dev/null || echo '?')"
    alert_throttled "memory-broken-symlink" "$deadlink" "⚠️ auto memory 깨진 링크" "$(basename "$deadlink")"
    violations=$((violations + 1))
  done < <(find -L "$memdir" -maxdepth 1 -type l 2>/dev/null)

  index="${memdir}/MEMORY.md"
  [[ -f "$index" ]] || continue
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in http*|/*) continue ;; esac
    if [[ ! -e "${memdir}/${ref}" ]]; then
      emit "warn" "memory-dangling-index" "$index" "missing=${ref}"
      alert_throttled "memory-dangling-index" "${index}:${ref}" "⚠️ MEMORY.md 가 없는 파일을 가리킴" "$ref"
      violations=$((violations + 1))
    fi
  done < <(grep -oE '\]\([^)]+\.md\)' "$index" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u)
done < <({
  find "${HOME}/.claude/projects" -maxdepth 2 -type d -name memory 2>/dev/null
  # 2026-08-06: autoMemoryDirectory 로 고정한 통합 경로. 크론·봇 세션이 매번 새 임시
  #   디렉터리에서 돌아 메모리가 일회용으로 흩어지던 것을 한 곳으로 모았다(파일 31개 분산 확인).
  [[ -d "${HOME}/.openclaw-data/runtime/claude-automemory" ]] && echo "${HOME}/.openclaw-data/runtime/claude-automemory"
} | sort -u)

# Check 6: auto memory → RAG 다리의 정합성
#   2026-08-06 신설. 계기 — 같은 날 auto memory 경로를 claude-automemory 로 옮겼는데
#   SSoT 로 옮겨주는 훅(post-memory-sync.sh)은 옛 경로에 하드코딩돼 있어 조용히 죽었다.
#   그 사이 기억 26개가 임시 프로젝트 디렉터리에 갇혀 RAG 에 한 번도 들어가지 못했다.
#   Check 5 가 "링크가 성한가"를 본다면 여기는 "기억이 흐르는가"를 본다.
AUTOMEM_CONTRACT="${HOME}/projects/jarvis/dotfiles/claude/settings.memory.json"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SYNC_HOOK="${HOME}/.claude/hooks/post-memory-sync.sh"

read_json_str() {  # $1=파일 $2=키
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        v = json.load(fh).get(sys.argv[2])
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
' "$1" "$2" 2>/dev/null || echo ""
}

expand_home() { printf '%s\n' "${1/#\~/$HOME}"; }

if [[ -f "$CLAUDE_SETTINGS" && -f "$AUTOMEM_CONTRACT" ]]; then
  want="$(read_json_str "$AUTOMEM_CONTRACT" autoMemoryDirectory)"
  have="$(read_json_str "$CLAUDE_SETTINGS" autoMemoryDirectory)"

  if [[ -z "$have" ]]; then
    # 이 값이 없으면 Claude 는 세션마다 새 임시 디렉터리에 기억을 쌓았다 버린다.
    emit "warn" "automem-setting-missing" "$CLAUDE_SETTINGS" "autoMemoryDirectory 미설정 (기대=${want})"
    alert_throttled "automem-setting-missing" "$CLAUDE_SETTINGS" "⚠️ auto memory 경로 설정이 사라짐" "기대=${want}"
    violations=$((violations + 1))
  elif [[ "$have" != "$want" ]]; then
    emit "warn" "automem-setting-drift" "$CLAUDE_SETTINGS" "설정=${have} 계약=${want}"
    alert_throttled "automem-setting-drift" "$CLAUDE_SETTINGS" "⚠️ auto memory 경로가 계약과 다름" "${have} ≠ ${want}"
    violations=$((violations + 1))
  else
    automem_dir="$(expand_home "$have")"
    if [[ ! -d "$automem_dir" ]]; then
      emit "warn" "automem-dir-missing" "$automem_dir" "설정된 auto memory 디렉터리가 실재하지 않음"
      alert_throttled "automem-dir-missing" "$automem_dir" "⚠️ auto memory 디렉터리 없음" "$automem_dir"
      violations=$((violations + 1))
    else
      # 핵심 — 훅이 실제로 이 경로를 감시하는가. 하드코딩 드리프트를 여기서 잡는다.
      #   --print-watched 는 부작용 없이 감시 대상만 출력하는 훅의 자기진단 창구다.
      if [[ -x "$SYNC_HOOK" ]]; then
        # 2026-09-04: 출력을 먼저 변수에 받는다. `hook | grep -q` 는 grep 이 첫 줄에서 닫으면 훅이
        #   SIGPIPE(141) 로 죽고 pipefail 이 그걸 실패로 읽어 '감시 안 함' 오탐을 냈다 — 감시 목록이
        #   bot-work 프로젝트 memory 디렉터리까지 89줄로 늘어난 뒤부터 매 10분 exit 1 의 원인이었다.
        watched_list=$("$SYNC_HOOK" --print-watched 2>/dev/null || true)
        # 2026-09-10 정정: 문자열이 아니라 '같은 디렉토리인가'를 묻는다.
        #   훅은 실경로를 찍고 설정은 리터럴 경로를 담는다. 오픈클로 이관으로
        #   ~/projects/jarvis 가 심링크가 되자 같은 디렉토리인데도 '감시 안 함'으로 오판했다(실측 20:28).
        #   양쪽을 물리 경로로 정규화해 비교하면 트리가 어디로 가든 이 검사는 계속 옳다.
        automem_real="$(cd -P "$automem_dir" 2>/dev/null && pwd || echo "$automem_dir")"
        watched_real=""
        while IFS= read -r w; do
          [[ -z "$w" ]] && continue
          watched_real+="$(cd -P "$w" 2>/dev/null && pwd || echo "$w")"$'\n'
        done <<<"$watched_list"
        if ! grep -qxF "$automem_real" <<<"$watched_real"; then
          emit "warn" "automem-hook-blind" "$SYNC_HOOK" "훅이 ${automem_dir} 를 감시하지 않음 — RAG 유입 중단"
          alert_throttled "automem-hook-blind" "$SYNC_HOOK" "🔴 auto memory 가 RAG 로 못 들어감" "훅이 경로를 못 봄"
          violations=$((violations + 1))
        fi
      else
        emit "warn" "automem-hook-missing" "$SYNC_HOOK" "SSoT 동기화 훅이 없거나 실행 불가"
        alert_throttled "automem-hook-missing" "$SYNC_HOOK" "🔴 auto memory 동기화 훅 부재" "$SYNC_HOOK"
        violations=$((violations + 1))
      fi

      # 정체 감지 — 훅이 죽으면 실파일이 쌓인다. Claude 가 방금 쓴 것과 구분하려고
      #   10분 유예를 둔다(오탐을 만들면 Check 3 과 같은 실패를 반복한다).
      stuck=$(find "$automem_dir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' -mmin +10 2>/dev/null | wc -l | tr -d ' ')
      if (( stuck > 0 )); then
        emit "warn" "automem-files-stuck" "$automem_dir" "SSoT 미이관 실파일 ${stuck}개 (10분 초과)"
        alert_throttled "automem-files-stuck" "$automem_dir" "⚠️ auto memory 파일이 SSoT 로 안 넘어감" "${stuck}개 정체"
        violations=$((violations + 1))
      fi
    fi
  fi
fi

# 원장 rotation: 10MB 초과 시 gzip 압축 후 새 파일 시작
if [[ -f "$LEDGER" ]]; then
  size=$(stat -f "%z" "$LEDGER" 2>/dev/null || echo 0)
  if (( size > 10485760 )); then
    gzip -c "$LEDGER" > "${LEDGER%.jsonl}-$(date +%Y%m%d).jsonl.gz"
    : > "$LEDGER"
    emit "info" "rotated" "$LEDGER" "previous logs archived"
  fi
fi

# 결과
if [[ $recoveries -gt 0 ]]; then
  echo "🔧 auto-recovered ${recoveries} topology violation(s)"
  emit "info" "audit-complete" "$DOT_JARVIS" "recoveries=${recoveries} violations=${violations}"
fi
if [[ $violations -eq 0 ]]; then
  if [[ $recoveries -eq 0 ]]; then emit "info" "ok" "$DOT_JARVIS" "topology clean"; fi
  echo "✅ symlink topology audit: OK (${violations} un-recovered violations, ${recoveries} auto-recovered)"
  exit 0
else
  echo "⚠️  ${violations} un-recovered violations (see ${LEDGER})"
  exit 1
fi