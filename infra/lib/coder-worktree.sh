#!/usr/bin/env bash
# coder-worktree.sh — jarvis-coder 격리 실행용 git worktree (SELF-HEAL-PLAN 1b, 2026-09-04)
# coder-functions.sh 와 verify-sprint-contract.sh 가 source 한다. 호출자가 BOT_HOME 을 설정한 뒤 source.
#
# 원칙: 코더는 본체(~/projects/jarvis)를 읽기만 한다. 편집·스냅샷·롤백·문법 게이트·검증은 전부
#   worktree(브랜치 coder/<task>) 안에서 일어난다. 결과물은 브랜치 + runtime/results/<task>/patch.diff.
#   본체 반영은 사람이 한다(coder-merge.sh, 3b). 9/2 사고(코더가 본체를 편집하다 runtime 소실)의 구조적 봉쇄.
#
# 켜고 끄기: JARVIS_CODER_WORKTREE=1(기본) / 0 이면 옛 방식(본체 직접 편집).
# 위치:    ${JARVIS_CODER_WT_ROOT:-$HOME/jarvis-worktrees/coder}/<task>  — runtime/ 보호 경로 밖이어야
#          에이전트 쓰기 경계(jarvis-agent-write-boundary)가 scope 모드로 허용한다. /tmp 는 재부팅에 사라져 안 쓴다.
# 공유:    worktree 에는 gitignore 된 runtime/ 과 infra/node_modules 가 없다 — 본체로 심링크한다(데이터·의존성 공유).
#          심링크는 저장소 공통 info/exclude 에 등록해 스냅샷 커밋에 섞이지 않게 한다.
# 브랜치:  작업 끝(done/failed/보류)엔 worktree 만 지우고 브랜치는 남긴다. 재큐되면 브랜치에서 다시 만든다.
#          7일 미처리 브랜치 폐기는 3d.
#
# 함수:
#   coder_worktree_enabled                  → 0 이면 켜짐
#   coder_worktree_main_repo                → 본체 저장소 최상위 (BOT_HOME 이 든 저장소)
#   coder_worktree_path <task>              → 경로 문자열
#   coder_worktree_ensure <task>            → 없으면 생성(브랜치 있으면 재사용), stdout 경로. 실패 return 1
#   coder_worktree_remove <task>            → worktree 제거(브랜치 유지)
#   coder_worktree_export_patch <task> <wt> → runtime/results/<task>/patch.diff (본체 기준선 대비), stdout 경로
#   coder_rewrite_cmd <cmd> <wt>            → 본체 경로를 worktree 경로로 치환 (verifyCmd/completionCheck 용)
#   coder_run_cmd <wt> <cmd> [timeout]      → cd <wt> 후 치환한 명령 실행

coder_worktree_enabled() {
    [[ "${JARVIS_CODER_WORKTREE:-1}" == "1" ]]
}

coder_worktree_main_repo() {
    git -C "${BOT_HOME}" rev-parse --show-toplevel 2>/dev/null
}

coder_worktree_root() {
    echo "${JARVIS_CODER_WT_ROOT:-${HOME}/jarvis-worktrees/coder}"
}

# 태스크 id → 디렉터리·브랜치에 안전한 이름 (영숫자 . _ - 만)
coder_worktree_name() {
    local n; n=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
    n="${n#-}"; n="${n#.}"
    echo "${n:-task}"
}

coder_worktree_path() {
    echo "$(coder_worktree_root)/$(coder_worktree_name "$1")"
}

coder_worktree_branch() {
    echo "coder/$(coder_worktree_name "$1")"
}

# 본체 기준 브랜치 — 본체가 체크아웃한 브랜치. detached 면 main.
coder_worktree_base_branch() {
    local main; main=$(coder_worktree_main_repo) || { echo main; return; }
    local b; b=$(git -C "$main" symbolic-ref --short HEAD 2>/dev/null || true)
    echo "${JARVIS_CODER_BASE_BRANCH:-${b:-main}}"
}

_coder_wt_log() {
    if type _coder_log &>/dev/null; then _coder_log "$1"; else echo "[coder-worktree] $1" >&2; fi
}

coder_worktree_ensure() {
    local task="$1"
    local main wt branch base root
    main=$(coder_worktree_main_repo) || { _coder_wt_log "WORKTREE: BOT_HOME 이 git 저장소 안이 아님 — 생성 불가"; return 1; }
    root=$(coder_worktree_root); wt=$(coder_worktree_path "$task"); branch=$(coder_worktree_branch "$task")
    base=$(coder_worktree_base_branch)

    # 살아 있는 worktree 면 재사용 (show-toplevel 은 실경로를 돌려주므로 실경로끼리 비교 — /var/tmp → /private/var/tmp)
    if [[ -f "$wt/.git" ]] && [[ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$wt" 2>/dev/null && pwd -P)" ]]; then
        echo "$wt"; return 0
    fi
    # 깨진 잔재(등록만 남았거나 디렉터리만 남음) 정리 — root 아래일 때만 지운다
    git -C "$main" worktree prune >/dev/null 2>&1 || true
    if [[ -d "$wt" && "$wt" == "$root/"* ]]; then rm -rf "$wt"; fi
    mkdir -p "$root" 2>/dev/null || { _coder_wt_log "WORKTREE: root 생성 실패: $root"; return 1; }

    local _out
    if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
        _out=$(git -C "$main" worktree add "$wt" "$branch" 2>&1) || { _coder_wt_log "WORKTREE: 기존 브랜치로 생성 실패: ${_out:0:200}"; return 1; }
        _coder_wt_log "WORKTREE: 재생성 ${wt} (브랜치 ${branch} 재사용)"
    else
        _out=$(git -C "$main" worktree add -b "$branch" "$wt" "$base" 2>&1) || { _coder_wt_log "WORKTREE: 생성 실패: ${_out:0:200}"; return 1; }
        _coder_wt_log "WORKTREE: 생성 ${wt} (브랜치 ${branch} ← ${base})"
    fi

    # 데이터·의존성 공유 심링크 + 공통 exclude 등록 (스냅샷 `git add -A` 에 섞이지 않도록)
    local exclude; exclude=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
    if [[ -n "$exclude" ]]; then mkdir -p "$(dirname "$exclude")" 2>/dev/null || true; fi
    local link target rel
    for rel in runtime infra/node_modules; do
        target="$main/$rel"; link="$wt/$rel"
        [[ -e "$target" && ! -e "$link" ]] || continue
        ln -s "$target" "$link" 2>/dev/null || true
        if [[ -n "$exclude" ]] && ! grep -qx "/$rel" "$exclude" 2>/dev/null; then echo "/$rel" >> "$exclude"; fi
    done
    echo "$wt"
}

coder_worktree_remove() {
    local task="$1"
    local main wt; main=$(coder_worktree_main_repo) || return 0
    wt=$(coder_worktree_path "$task")
    [[ -d "$wt" ]] || return 0
    # 심링크를 먼저 걷는다 — worktree remove --force 가 링크 너머를 따라가지 않지만, 잔재 rm -rf 경로가 따라갈 수 있다
    rm -f "$wt/runtime" "$wt/infra/node_modules" 2>/dev/null || true
    git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || {
        [[ "$wt" == "$(coder_worktree_root)/"* ]] && rm -rf "$wt"
        git -C "$main" worktree prune >/dev/null 2>&1 || true
    }
    _coder_wt_log "WORKTREE: 제거 ${wt} (브랜치 $(coder_worktree_branch "$task") 유지)"
}

# 본체 기준선(merge-base) 대비 브랜치 전체 diff → runtime/results/<task>/patch.diff
coder_worktree_export_patch() {
    local task="$1" wt="$2"
    local base mb dir file
    base=$(coder_worktree_base_branch)
    mb=$(git -C "$wt" merge-base "$base" HEAD 2>/dev/null || true)
    [[ -n "$mb" ]] || return 1
    dir="${BOT_HOME}/results/${task}"; file="${dir}/patch.diff"
    mkdir -p "$dir" 2>/dev/null || return 1
    git -C "$wt" diff "$mb" HEAD > "$file" 2>/dev/null || return 1
    echo "$file"
}

# 본체 경로 → worktree 경로 (verifyCmd·completionCheck 가 본체가 아니라 작업 사본을 검사하게).
#   ~/projects/jarvis/infra/x · ~/projects/jarvis/x · `cd ~/projects/jarvis`      → <wt>/...
#   ~/.jarvis/{bin,lib,scripts,infra}/x · $BOT_HOME/lib/x → <wt>/infra/...   (runtime 의 코드 심링크)
#   ~/.openclaw-data/runtime/config/x · $BOT_HOME/state/x        → 그대로            (데이터는 본체 공유)
#   ~/jarvis-board/x                                     → 그대로            (다른 저장소)
# 경계는 뒤따르는 문자로 판단한다: '/'·공백·; & | ) 따옴표·끝. `~/projects/jarvis` 단독(cd 대상)도 잡는다.
# [2026-09-11] 위 주석은 2026-09-10 일괄 치환으로 신경로가 됐는데 아래 코드는 안 따라왔다.
# 그 사이 이 치환기는 ~/projects/jarvis/... 를 **그대로 통과**시켰다 —
# 즉 코더가 자기 worktree 가 아니라 **정본 트리에 직접** 명령을 쏘고 있었다.
# 격리가 실패한 게 아니라 조용히 격리를 그만둔 것이라 아무 에러도 안 났다.
# 이제 별칭을 먼저 절대경로로 펴고, 옛 경로는 정본 루트로 접은 뒤, 한 벌의 규칙만 적용한다.
read -r -d '' _CODER_REWRITE_PL <<'PERL' || true
my $h = $ENV{JW_H}; my $wt = $ENV{JW_WT};
my $root = $ENV{JW_ROOT} || "$h/projects/jarvis";   # [회차8 2026-09-12] 저장소 루트 이전
# [회차8 2026-09-13] 런타임은 더 이상 저장소 루트 밑이 아니다.
#   예전 값 "$root/runtime" 은 지금 **장벽 파일**이라, `$BOT_HOME/config/x` 같은
#   런타임 *데이터* 경로가 죽은 자리로 치환되고 있었다.
#   테스트는 code 경로($BOT_HOME/lib 등)만 재서 이걸 못 봤다 — 105/106 통과의 사각지대.
my $rt = $ENV{JW_RT} || "$h/.openclaw-data/runtime";
# 정본 런타임은 BOT_HOME 과 **무관하게** 항상 알아본다.
#   BOT_HOME 은 테스트 픽스처나 임시 트리로 덮이는 값이라, 그것만 믿으면
#   `~/.openclaw-data/runtime/...` 이 그대로 지나가 버린다(2026-09-13 실측).
my $crt = "$h/.openclaw-data/runtime";
my $rel = $root; $rel =~ s{^\Q$h\E/}{};          # HOME 상대 표기 (예: projects/jarvis)
my $b = q{(?=/|[\s;&|)"'`]|$)};
# 1) ~ · $HOME · ${HOME} 별칭을 절대경로로 편다 (신경로 먼저, 그 다음 옛 경로)
s{(?<![\w/])(?:~|\$HOME|\$\{HOME\})/\Q$rel\E$b}{$root}g;
s{(?<![\w/])(?:~|\$HOME|\$\{HOME\})/\.openclaw-data/runtime$b}{$crt}g;
s{(?<![\w/])(?:~|\$HOME|\$\{HOME\})/jarvis$b}{$h/jarvis}g;
# 2) 옛 경로(~/jarvis)는 정본 루트로 접는다 — 2026-09-10 이관 잔재를 한 자리에서 흡수
s{\Q$h\E/jarvis$b}{$root}g;
# 3) BOT_HOME 계열 별칭 → runtime
s{(?<![\w/])(?:~/\.jarvis|\$BOT_HOME|\$\{BOT_HOME\})$b}{$rt}g;
s{\Q$h\E/\.jarvis$b}{$rt}g;
# 4) 코드는 worktree 로, runtime 데이터는 본체에 남긴다
s{\Q$rt\E/infra$b}{$wt/infra}g;
s{\Q$rt\E/(bin|lib|scripts)$b}{$wt/infra/$1}g;
s{\Q$root\E(?!/runtime$b)$b}{$wt}g;
PERL
# [2026-09-11] JARVIS_HOME 은 믿지 않는다 — runtime/.env 가 이 값을 `~/.jarvis`(= runtime 심링크)로
#   덮어쓴다. 그 값을 루트로 쓰면 치환이 runtime 을 루트로 착각해 격리가 다시 어긋난다.
#   이 파일은 <root>/infra/lib/ 에 있으므로 두 단계 위가 루트다 — env 오염과 무관하다.
_CODER_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_CODER_JARVIS_ROOT="$(cd -- "${_CODER_LIB_DIR}/../.." && pwd -P)"
coder_rewrite_cmd() {
    local cmd="$1" wt="$2"
    JW_H="$HOME" JW_WT="$wt" \
    JW_ROOT="$_CODER_JARVIS_ROOT" \
    JW_RT="${BOT_HOME:-$HOME/.openclaw-data/runtime}" \
    perl -pe "$_CODER_REWRITE_PL" <<<"$cmd"
}

# cd <wt> 후 치환한 명령 실행. stdout/stderr 그대로, exit code 그대로.
coder_run_cmd() {
    local wt="$1" cmd="$2" timeout_s="${3:-}"
    local rewritten; rewritten=$(coder_rewrite_cmd "$cmd" "$wt")
    local tcmd; tcmd=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
    if [[ -n "$timeout_s" && -n "$tcmd" ]]; then
        (cd "$wt" && JARVIS_CODER_REPO="$wt" "$tcmd" "$timeout_s" bash -c "$rewritten")
    else
        (cd "$wt" && JARVIS_CODER_REPO="$wt" bash -c "$rewritten")
    fi
}
