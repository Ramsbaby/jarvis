#!/usr/bin/env bash
# hooks-wiring-audit.sh — 훅 파일은 있는데 settings 어디에도 배선되지 않은 것(orphan)을 탐지한다.
#
# 도입 배경 (2026-08-11):
#   2026-08-03 "hook cleanup" 작업에서 훅 15개 배선이 한 번에 빠졌다.
#   파일은 전부 남아 있어 `ls hooks/` 로는 정상으로 보였고, 8일간 아무도 몰랐다.
#   그중 mistake-prewarn.sh 는 오답노트 4,930건을 재발 빈도순으로 주입하는 훅이었다.
#   "파일 존재 = 작동"이라는 가정을 깨는 것이 이 스크립트의 유일한 목적이다.
#
# 원칙: 읽기 전용. 아무것도 고치지 않는다. 비차단(항상 exit 0, --strict 일 때만 1).
#
# 사용:
#   hooks-wiring-audit.sh            # 사람이 읽는 표
#   hooks-wiring-audit.sh --json     # 기계 판독용
#   hooks-wiring-audit.sh --strict   # orphan 있으면 exit 1 (크론/CI 용)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HOOKS_DIR="${CLAUDE_HOOKS_DIR:-$HOME/.claude/hooks}"
MODE="${1:-table}"

[ -d "$HOOKS_DIR" ] || { echo "훅 디렉토리 없음: $HOOKS_DIR" >&2; exit 0; }

python3 - "$HOOKS_DIR" "$MODE" <<'PY'
import json, os, re, sys

hooks_dir, mode = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")

# 배선을 선언할 수 있는 모든 층. "없다"고 말하려면 이 목록을 전부 봐야 한다.
SETTINGS = [
    f"{home}/.claude/settings.json",
    f"{home}/.claude/settings.local.json",
    f"{home}/jarvis/.claude/settings.json",
    f"{home}/jarvis/.claude/settings.local.json",
    "/Library/Application Support/ClaudeCode/managed-settings.json",
]

wired, layers_seen, broken = {}, [], []
abs_paths = {}   # 파일명 → 명령어에 적힌 절대/틸드 경로 (다른 디렉토리의 훅 판정용)
for p in SETTINGS:
    if not os.path.exists(p):
        continue
    layers_seen.append(p)
    try:
        conf = json.load(open(p))
    except Exception as e:
        broken.append((p, str(e)))
        continue
    for ev, groups in (conf.get("hooks") or {}).items():
        for g in groups or []:
            for hk in g.get("hooks", []) or []:
                cmd = hk.get("command", "")
                # 같은 명령어 안에 파일명이 여러 번 나와도(존재·권한 검사 관용구) 1회로 센다
                for name in set(re.findall(r'([A-Za-z0-9_.-]+\.(?:sh|py|mjs|js))', cmd)):
                    src = f"{os.path.basename(p)}:{ev}"
                    if src not in wired.setdefault(name, []):
                        wired[name].append(src)
                    m = re.search(r'([~/][^\s\'"]*' + re.escape(name) + r')', cmd)
                    if m:
                        abs_paths.setdefault(name, os.path.expanduser(m.group(1)))

# 훅 디렉토리에 실재하는 실행 파일
present = sorted(
    f for f in os.listdir(hooks_dir)
    if os.path.isfile(os.path.join(hooks_dir, f))
    and f.endswith((".sh", ".py", ".mjs", ".js"))
    and not f.endswith((".bak", ".orig"))
)

# 의도적 미배선은 여기에 등재한다 (한 줄에 파일명 하나, # 주석 허용).
# 등재 이유를 주석으로 남기지 않으면 다음 사람이 사고와 구분할 수 없다.
ALLOW = f"{home}/.claude/hooks/.wiring-allowlist"
allowed = set()
if os.path.exists(ALLOW):
    for line in open(ALLOW):
        line = line.split("#", 1)[0].strip()
        if line:
            allowed.add(line)

# 배선표에 없어도 다른 훅이 내부에서 호출하면 죽은 게 아니다 (간접 배선)
indirect = {}
for f in present:
    if f in wired:
        continue
    for caller in present:
        if caller == f:
            continue
        try:
            if f in open(os.path.join(hooks_dir, caller), errors="ignore").read():
                indirect.setdefault(f, []).append(caller)
        except OSError:
            pass

orphans = [f for f in present if f not in wired and f not in indirect and f not in allowed]
# 배선은 있는데 파일이 없는 반대 방향도 사고다 (훅 삭제 후 배선 잔존).
# 명령어가 다른 디렉토리를 가리키면 그 경로로 판정한다 — hooks_dir 만 보면 오탐이다.
dangling = [
    n for n in wired
    if not os.path.exists(abs_paths.get(n, os.path.join(hooks_dir, n)))
]

if mode == "--json":
    print(json.dumps({
        "checked_layers": layers_seen,
        "hook_files": len(present),
        "wired_direct": len([f for f in present if f in wired]),
        "wired_indirect": {k: v for k, v in indirect.items()},
        "allowlisted": sorted(allowed & set(present)),
        "orphans": orphans,
        "dangling": dangling,
        "unparsable": [p for p, _ in broken],
    }, ensure_ascii=False, indent=2))
else:
    print(f"훅 파일 {len(present)}개 · 직접배선 {len([f for f in present if f in wired])}개 · "
          f"간접호출 {len(indirect)}개 · 예외등재 {len(allowed & set(present))}개 · "
          f"orphan {len(orphans)}개 · dangling {len(dangling)}개")
    print(f"조회한 설정 층 {len(layers_seen)}개:")
    for p in layers_seen:
        print(f"  · {p.replace(home,'~')}")
    for p, e in broken:
        print(f"  ⚠️  파싱 실패: {p.replace(home,'~')} — {e}")
    if orphans:
        print("\n❌ orphan (파일은 있으나 어느 층에도 배선 없음):")
        for f in orphans:
            print(f"   {f}")
    if dangling:
        print("\n⚠️  dangling (배선은 있으나 파일 없음):")
        for f in dangling:
            print(f"   {f}  ← {', '.join(wired[f])}")
    if not orphans and not dangling:
        print("\n✅ 불일치 없음")

if mode == "--strict" and (orphans or dangling or broken):
    sys.exit(1)
PY
