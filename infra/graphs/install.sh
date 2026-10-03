#!/usr/bin/env bash
# install.sh — 고정 판 그대로 설치(lockfile) + better-sqlite3 설치 스크립트 승인 + 자가 시험 + 상태 폴더(700).
# 다시 돌려도 된다. 전역 설치는 하지 않는다.
#   위험 6: npm 이 승인 안 된 설치 스크립트를 건너뛰면 설치는 성공(코드 0)인데 실행 때 'bindings file' 오류로 죽는다.
#           승인은 판마다 다시 한다(package.json allowScripts 에 판이 박힌다). Node 주 버전이 바뀌면 다시 빌드한다.
set -euo pipefail
cd "$(dirname "$0")"

eval "real_home=~$(id -un)"   # lg.sh 와 같은 고정 Node
NODE="${LG_NODE:-$real_home/.nvm/versions/node/v24.21.0/bin/node}"
[[ -x "$NODE" ]] || { echo "[ERROR] 고정 Node 가 없다: $NODE (LG_NODE 로 지정)" >&2; exit 1; }
export PATH="$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin"
STATE="${LG_STATE_DIR:-$HOME/.openclaw-data/runtime/state/graphs}"

npm ci --no-audit --no-fund
npm install-scripts approve better-sqlite3   # 이미 승인돼 있으면 'Nothing to approve' — package.json 은 바뀌지 않는다

if ! "$NODE" run.mjs selftest; then
  echo "자가 시험 실패 — better-sqlite3 를 이 Node 로 다시 빌드한다" >&2
  npm rebuild better-sqlite3
  "$NODE" run.mjs selftest
fi
"$NODE" scripts/check-interrupt-nodes.mjs
"$NODE" scripts/check-graph-rules.mjs

mkdir -p "$(dirname "$STATE")"
mkdir -p -m 700 "$STATE"
chmod 700 "$STATE"
echo "상태 폴더: $STATE ($(stat -f '%Sp' "$STATE"))"
