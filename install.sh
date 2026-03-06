#!/usr/bin/env bash
set -euo pipefail

# install.sh — Jarvis one-command setup
# Usage: ./install.sh [--docker | --local]

BOT_HOME="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:---docker}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- Dependency checks ---
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "$1 is required but not installed."
        echo "  Install: $2"
        return 1
    fi
}

check_common_deps() {
    local ok=true
    check_command node "https://nodejs.org/ or nvm" || ok=false
    check_command claude "npm install -g @anthropic-ai/claude-code" || ok=false
    if [ "$ok" = false ]; then
        error "Missing dependencies. Install them and re-run."
        exit 1
    fi
    info "Common dependencies OK (node $(node -v), claude CLI)"
}

# --- Setup env files ---
setup_env() {
    if [ ! -f "${BOT_HOME}/discord/.env" ]; then
        if [ -f "${BOT_HOME}/discord/.env.example" ]; then
            cp "${BOT_HOME}/discord/.env.example" "${BOT_HOME}/discord/.env"
            warn "Created discord/.env from .env.example"
            warn "Edit discord/.env and fill in your tokens before starting."
            return 1
        else
            error "discord/.env.example not found. Create discord/.env manually."
            return 1
        fi
    fi
    info "discord/.env exists"
    return 0
}

setup_personas() {
    if [ ! -f "${BOT_HOME}/discord/personas.json" ]; then
        if [ -f "${BOT_HOME}/discord/personas.json.example" ]; then
            cp "${BOT_HOME}/discord/personas.json.example" "${BOT_HOME}/discord/personas.json"
            info "Created discord/personas.json from example"
        fi
    fi
}

# --- Docker mode ---
install_docker() {
    info "Installing Jarvis (Docker mode)"

    check_command docker "https://docs.docker.com/get-docker/" || exit 1
    check_command "docker compose" "Docker Desktop or docker-compose-plugin" || {
        # fallback: check docker-compose
        check_command docker-compose "https://docs.docker.com/compose/install/" || exit 1
    }

    local env_ok=true
    setup_env || env_ok=false
    setup_personas

    if [ "$env_ok" = false ]; then
        error "Fix discord/.env first, then re-run: ./install.sh --docker"
        exit 1
    fi

    info "Building Docker image..."
    cd "${BOT_HOME}"
    docker compose build

    info "Starting bot..."
    docker compose up -d

    echo ""
    info "Bot is running! Check logs with: docker compose logs -f"
    info "Stop with: docker compose down"
}

# --- Local mode (macOS/Linux direct) ---
install_local() {
    info "Installing Jarvis (local mode)"

    check_common_deps

    local env_ok=true
    setup_env || env_ok=false
    setup_personas

    if [ "$env_ok" = false ]; then
        error "Fix discord/.env first, then re-run: ./install.sh --local"
        exit 1
    fi

    info "Installing Node dependencies..."
    cd "${BOT_HOME}/discord"
    npm install --production

    # Ensure relative node_modules symlinks (relative paths work regardless of install location)
    if [ ! -e "${BOT_HOME}/lib/node_modules" ]; then
        ln -s ../discord/node_modules "${BOT_HOME}/lib/node_modules"
        info "Created lib/node_modules symlink"
    fi
    if [ ! -e "${BOT_HOME}/bin/node_modules" ]; then
        ln -s ../discord/node_modules "${BOT_HOME}/bin/node_modules"
        info "Created bin/node_modules symlink"
    fi

    # Create runtime directories
    mkdir -p "${BOT_HOME}/context" "${BOT_HOME}/state/pids" \
             "${BOT_HOME}/logs" "${BOT_HOME}/rag" "${BOT_HOME}/results"

    echo ""
    info "Installation complete!"
    info "Run the setup wizard: ${BOT_HOME}/bin/jarvis-init.sh"
    info "Then start the bot:   cd ${BOT_HOME}/discord && node discord-bot.js"
}

# --- Main ---
case "$MODE" in
    --docker) install_docker ;;
    --local)  install_local ;;
    *)
        echo "Usage: ./install.sh [--docker | --local]"
        echo "  --docker  Build and run with Docker Compose (default)"
        echo "  --local   Install dependencies locally and run directly"
        exit 1
        ;;
esac
