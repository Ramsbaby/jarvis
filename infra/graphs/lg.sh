#!/bin/sh
# lg.sh — 고정 Node 로 run.mjs 를 부른다. 다른 Node(예: Homebrew 25)로 돌면 better-sqlite3 가 뜨지 않는다(위험 6).
# 고정 Node 는 계정의 진짜 홈에서 찾는다 — HOME 이 바뀐 환경(시험·예약 잡)에서도 같은 Node 를 쓰게.
eval "real_home=~$(id -un)"
NODE="${LG_NODE:-$real_home/.nvm/versions/node/v24.21.0/bin/node}"
if [ ! -x "$NODE" ]; then
  echo "ERROR - node 고정 Node 가 없다: $NODE (LG_NODE 로 지정)"
  exit 1
fi
# watch: 판정 집계를 읽어 기준 밖이면 알리고 지시함에 올린다(scripts/lg-watch.mjs, 예약 잡 graphs: lg-watch daily)
if [ "${1:-}" = "watch" ]; then
  shift
  exec "$NODE" "$(dirname "$0")/scripts/lg-watch.mjs" "$@"
fi
exec "$NODE" "$(dirname "$0")/run.mjs" "$@"
