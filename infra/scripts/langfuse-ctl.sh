#!/usr/bin/env bash
# langfuse-ctl.sh — Langfuse self-hosted container management
#
# Usage:
#   langfuse-ctl.sh start    — start containers (waits for Docker socket)
#   langfuse-ctl.sh stop     — stop containers
#   langfuse-ctl.sh status   — show container status + health
#   langfuse-ctl.sh logs     — tail container logs
#   langfuse-ctl.sh reset    — ⚠ destroy data volumes and restart fresh
#   langfuse-ctl.sh setup    — interactive first-time setup (generates .env)

set -euo pipefail

LANGFUSE_DIR="${BOT_HOME:-${HOME}/jarvis/runtime}/docker/langfuse"
LOG_FILE="${BOT_HOME:-${HOME}/jarvis/runtime}/logs/langfuse-ctl.log"
HEALTH_URL="http://localhost:3200/api/public/health"
DOCKER_SOCK="/var/run/docker.sock"
MAX_WAIT_DOCKER=60   # seconds to wait for Docker Desktop
MAX_WAIT_READY=90    # seconds to wait for Langfuse to become ready

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2; }

_require_env() {
  if [[ ! -f "$LANGFUSE_DIR/.env" ]]; then
    echo "ERROR: $LANGFUSE_DIR/.env not found."
    echo "  Run: bash $0 setup"
    exit 1
  fi
}

_wait_docker() {
  local waited=0
  while [[ ! -S "$DOCKER_SOCK" ]]; do
    if (( waited >= MAX_WAIT_DOCKER )); then
      log "ERROR: Docker socket not available after ${MAX_WAIT_DOCKER}s — is Docker Desktop running?"
      exit 1
    fi
    log "Waiting for Docker socket... (${waited}s)"
    sleep 5
    (( waited += 5 ))
  done
}

_compose() {
  docker compose --project-directory "$LANGFUSE_DIR" "$@"
}

cmd_start() {
  _require_env
  _wait_docker
  log "Starting Langfuse containers..."
  _compose up -d --remove-orphans
  log "Containers started. Waiting for health check..."

  local waited=0
  while (( waited < MAX_WAIT_READY )); do
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
      log "Langfuse ready at http://localhost:3200"
      return 0
    fi
    sleep 5
    (( waited += 5 ))
  done
  log "WARN: Langfuse health check timed out after ${MAX_WAIT_READY}s (containers may still be starting)"
}

cmd_stop() {
  _wait_docker
  log "Stopping Langfuse containers..."
  _compose stop
  log "Stopped."
}

cmd_status() {
  _wait_docker
  echo "=== Container status ==="
  _compose ps 2>/dev/null || echo "(no containers running)"

  echo ""
  echo "=== Health ==="
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
  if [[ "$status" == "200" ]]; then
    echo "Langfuse: UP (HTTP 200)"
  else
    echo "Langfuse: DOWN (HTTP $status)"
  fi
}

cmd_logs() {
  _wait_docker
  _compose logs -f --tail=100
}

cmd_reset() {
  echo "WARNING: This will destroy all Langfuse trace data."
  echo -n "Type 'yes' to confirm: "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then echo "Aborted."; exit 0; fi
  _wait_docker
  log "Destroying Langfuse containers and volumes..."
  _compose down -v
  log "Reset complete. Run: $0 start"
}

cmd_setup() {
  if [[ -f "$LANGFUSE_DIR/.env" ]]; then
    echo "INFO: $LANGFUSE_DIR/.env already exists."
    echo -n "Overwrite? [y/N]: "
    read -r confirm
    if [[ "$confirm" != "y" ]]; then exit 0; fi
  fi

  echo "Generating Langfuse .env with random secrets..."
  local pg_pass nextauth_secret salt pub_key sec_key
  pg_pass=$(openssl rand -hex 16)
  nextauth_secret=$(openssl rand -base64 32)
  salt=$(openssl rand -base64 32)
  pub_key="lf-pub-$(openssl rand -hex 12)"
  sec_key="lf-sk-$(openssl rand -hex 24)"

  cat > "$LANGFUSE_DIR/.env" <<EOF
POSTGRES_PASSWORD=${pg_pass}
NEXTAUTH_SECRET=${nextauth_secret}
SALT=${salt}
LANGFUSE_PUBLIC_KEY=${pub_key}
LANGFUSE_SECRET_KEY=${sec_key}
LANGFUSE_INIT_USER_EMAIL=admin@jarvis.local
LANGFUSE_INIT_USER_PASSWORD=$(openssl rand -hex 8)
EOF

  chmod 600 "$LANGFUSE_DIR/.env"

  echo ""
  echo "Created: $LANGFUSE_DIR/.env"
  echo ""
  echo "API keys for tracing (add to discord/.env or ~/jarvis/runtime/.env):"
  echo "  LANGFUSE_BASE_URL=http://localhost:3200"
  echo "  LANGFUSE_PUBLIC_KEY=${pub_key}"
  echo "  LANGFUSE_SECRET_KEY=${sec_key}"
  echo ""
  echo "Admin password is in: $LANGFUSE_DIR/.env (LANGFUSE_INIT_USER_PASSWORD)"
  echo ""
  echo "Next: bash $0 start"
}

case "${1:-status}" in
  start)  cmd_start  ;;
  stop)   cmd_stop   ;;
  status) cmd_status ;;
  logs)   cmd_logs   ;;
  reset)  cmd_reset  ;;
  setup)  cmd_setup  ;;
  *)
    echo "Usage: $0 {start|stop|status|logs|reset|setup}"
    exit 1
    ;;
esac