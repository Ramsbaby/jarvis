#!/usr/bin/env bash
# mq-cli.sh - SQLite message queue CLI helper
#
# Usage:
#   mq-cli.sh send <sender> <channel> <payload_json> [priority]
#   mq-cli.sh receive <recipient> [channel]
#   mq-cli.sh ack <id>
#   mq-cli.sh stats

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
DB_PATH="${BOT_HOME}/state/messages.db"
SQLITE="/usr/bin/sqlite3"

if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: Database not found at $DB_PATH" >&2
  echo "Run init() from message-queue.mjs first." >&2
  exit 1
fi

usage() {
  echo "Usage:"
  echo "  mq-cli.sh send <sender> <channel> <payload_json> [priority]"
  echo "  mq-cli.sh receive <recipient> [channel]"
  echo "  mq-cli.sh ack <id>"
  echo "  mq-cli.sh stats"
  exit 1
}

cmd_send() {
  local sender="${1:?sender required}"
  local channel="${2:?channel required}"
  local payload="${3:?payload_json required}"
  local priority="${4:-normal}"

  # SQL injection 방지: single quote 이스케이프
  sender="${sender//\'/\'\'}"
  channel="${channel//\'/\'\'}"
  payload="${payload//\'/\'\'}"
  priority="${priority//\'/\'\'}"

  "$SQLITE" "$DB_PATH" <<SQL
INSERT INTO messages (sender, channel, payload, priority)
VALUES ('${sender}', '${channel}', '${payload}', '${priority}');
SELECT 'sent id=' || last_insert_rowid();
SQL
}

cmd_receive() {
  local recipient="${1:?recipient required}"
  local channel="${2:-}"

  # SQL injection 방지: single quote 이스케이프
  recipient="${recipient//\'/\'\'}"
  channel="${channel//\'/\'\'}"

  local where="status='pending' AND (recipient='${recipient}' OR recipient IS NULL)"
  if [[ -n "$channel" ]]; then
    where="${where} AND channel='${channel}'"
  fi

  "$SQLITE" -header -column "$DB_PATH" <<SQL
SELECT id, sender, channel, priority, payload, created_at
FROM messages
WHERE ${where}
ORDER BY
  CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 ELSE 2 END,
  created_at ASC
LIMIT 10;
SQL
}

cmd_ack() {
  local id="${1:?message id required}"

  # SQL injection 방지: 숫자만 허용
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: id must be a number" >&2
    return 1
  fi

  "$SQLITE" "$DB_PATH" <<SQL
UPDATE messages
SET status='done', processed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE id=${id};
SELECT 'acked id=' || ${id} || ', changes=' || changes();
SQL
}

cmd_stats() {
  "$SQLITE" -header -column "$DB_PATH" <<SQL
SELECT status, COUNT(*) as count
FROM messages
GROUP BY status
ORDER BY status;
SQL
}

if [[ $# -lt 1 ]]; then
  usage
fi

case "$1" in
  send)    shift; cmd_send "$@" ;;
  receive) shift; cmd_receive "$@" ;;
  ack)     shift; cmd_ack "$@" ;;
  stats)   shift; cmd_stats "$@" ;;
  *)       usage ;;
esac
