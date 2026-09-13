#!/usr/bin/env bash
# post-tool-docdebt.sh — PostToolUse: doc-debt 실시간 추적
# 코드 파일 편집 → doc-map 매칭 → debt 추가
# 문서 파일 편집 → 해당 debt 해소
# 항상 exit 0 (PostToolUse는 블로킹 불가)

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [[ -z "$FILE_PATH" ]]; then exit 0; fi

BOT_HOME="${HOME}/.jarvis"
DOC_MAP="${BOT_HOME}/config/doc-map.json"
DOC_DEBT="${BOT_HOME}/state/doc-debt.json"

# doc-map 이 없거나 패턴이 0개면 이 훅은 아무 일도 하지 않는다.
# 2026-05-01~08-25 doc-map.json 이 {"patterns":[]} 로 비어 있었고, 그 116일 동안
# 세 층(부채 등록·종료 차단·doc-sync-auditor)이 전부 "pass" 를 찍으며 죽어 있었다.
# 조용히 exit 0 하지 않고 흔적을 남긴다 — 침묵이 곧 무감지였다.
if [[ ! -f "$DOC_MAP" ]]; then
    echo "[$(date '+%F %T')] [docdebt] doc-map 없음: $DOC_MAP — 문서부채 추적 비활성" \
        >> "${BOT_HOME}/logs/doc-debt.log" 2>/dev/null || true
    exit 0
fi

_DM_PATTERNS=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("patterns",[])))' "$DOC_MAP" 2>/dev/null || echo 0)
if [[ "${_DM_PATTERNS:-0}" -eq 0 ]]; then
    echo "[$(date '+%F %T')] [docdebt] ⚠ doc-map 패턴 0개 — 문서부채가 영원히 0건이 된다: $DOC_MAP" \
        >> "${BOT_HOME}/logs/doc-debt.log" 2>/dev/null || true
    exit 0
fi

# doc-debt.json 없으면 세션 골격 생성 (atomic write)
if [[ ! -f "$DOC_DEBT" ]]; then
    python3 - "$DOC_DEBT" <<'PYEOF'
import json, sys, datetime, tempfile, os as _os
path = sys.argv[1]
skeleton = {
    "session_start": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "debts": {}
}
fd, tmp = tempfile.mkstemp(dir=_os.path.dirname(path), suffix=".tmp")
try:
    with _os.fdopen(fd, "w") as f:
        json.dump(skeleton, f, indent=2, ensure_ascii=False)
    _os.rename(tmp, path)
except Exception:
    _os.unlink(tmp)
    raise
PYEOF
fi

# 자동생성 문서 — debt 강제 대상 제외
AUTO_GENERATED="docs/SYSTEM-OVERVIEW.md"

PYEC=0
python3 - "$DOC_MAP" "$DOC_DEBT" "$FILE_PATH" "$AUTO_GENERATED" <<'PYEOF' || PYEC=$?
import json, sys, os, re, datetime, tempfile

doc_map_path, debt_path, file_path, auto_gen_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
auto_generated = set(auto_gen_raw.split(","))
home = os.path.expanduser("~")
jarvis_prefix = home + "/jarvis/"          # 마이그레이션 후 경로: ~/projects/jarvis/
jarvis_prefix_legacy = home + "/.jarvis/"  # 구형 경로 (하위호환)

# Worktree 경로 정규화 — ~/projects/jarvis/.claude/worktrees/<name>/infra/docs/X.md
# 를 ~/projects/jarvis/infra/docs/X.md 로 변환해 이후 로직이 main 체크아웃과 동일하게 처리.
# 없으면 asymmetric 버그: 코드 편집은 debt 추가되는데 doc 편집은 해소 안 됨.
_worktree_re = re.compile(r'^' + re.escape(jarvis_prefix) + r'\.claude/worktrees/[^/]+/(.*)$')
_m = _worktree_re.match(file_path)
if _m:
    file_path = jarvis_prefix + _m.group(1)

fname = os.path.basename(file_path)
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

try:
    doc_map = json.load(open(doc_map_path))
    debt = json.load(open(debt_path))
except Exception:
    sys.exit(0)

# 문서 파일 편집 → 해당 debt 해소
# ~/projects/jarvis/infra/docs/X.md → rel = "docs/X.md"
# ~/projects/jarvis/docs/X.md      → rel = "docs/X.md"  (legacy 경로 하위호환)
matched_prefix = None
for pfx in (jarvis_prefix + "infra/", jarvis_prefix, jarvis_prefix_legacy):
    if file_path.startswith(pfx):
        matched_prefix = pfx
        break
if matched_prefix:
    rel = file_path[len(matched_prefix):]  # e.g. "docs/ARCHITECTURE.md"
    if (rel.startswith("docs/") or rel.startswith("adr/")) and rel.endswith(".md"):
        if rel in debt.get("debts", {}):
            del debt["debts"][rel]
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(debt_path), suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(debt, f, indent=2, ensure_ascii=False)
                os.rename(tmp, debt_path)
            except Exception:
                os.unlink(tmp)
                raise
        sys.exit(0)

# 코드 파일 → doc-map 매칭 → debt 추가 (멱등)
frel = file_path.replace(jarvis_prefix, "").replace(home + "/", "")
changed = False
for pattern in doc_map.get("patterns", []):
    mg = pattern.get("match_glob", "")
    if not mg:
        continue
    if mg in file_path or mg in fname:
        for doc in pattern.get("docs", []):
            if doc in auto_generated:
                continue
            debts = debt.setdefault("debts", {})
            if doc not in debts:
                debts[doc] = {
                    "triggered_by": [],
                    "reason": pattern.get("reason", ""),
                    "created_at": now
                }
            if frel not in debts[doc]["triggered_by"]:
                debts[doc]["triggered_by"].append(frel)
                changed = True

if changed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(debt_path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(debt, f, indent=2, ensure_ascii=False)
        os.rename(tmp, debt_path)
    except Exception:
        os.unlink(tmp)
        raise
PYEOF
if [[ $PYEC -ne 0 ]]; then
    echo "[$(date '+%F %T')] [docdebt] Python failed (exit $PYEC): $FILE_PATH" \
        >> "${BOT_HOME}/logs/doc-debt.log" 2>/dev/null || true
fi

exit 0
