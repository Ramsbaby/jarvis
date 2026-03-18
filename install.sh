#!/usr/bin/env bash
set -euo pipefail

# install.sh — Jarvis one-command setup
# Usage: ./install.sh [--docker | --local] [--tier 0|1|2]
#
# Dependency tiers:
#   --tier 0  Core only: discord.js + dotenv (~150MB). No SQLite, no RAG, no embeddings.
#             Good for: testing, resource-constrained systems, Discord-only use.
#   --tier 1  Standard: + SQLite history + YAML support (~350MB). No LanceDB/OpenAI.
#             Good for: most users who don't need vector search.
#   --tier 2  Full: + LanceDB vector search + OpenAI embeddings (~700MB). (default)
#             Good for: RAG-powered memory, semantic search across notes.

BOT_HOME="$(cd "$(dirname "$0")" && pwd)"
INSTALL_MODE="--local"
TIER=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker) INSTALL_MODE="--docker" ;;
        --local)  INSTALL_MODE="--local" ;;
        --tier)
            shift
            TIER="$1"
            if [[ "$TIER" != "0" && "$TIER" != "1" && "$TIER" != "2" ]]; then
                echo "Error: --tier must be 0, 1, or 2"
                exit 1
            fi
            ;;
        --tier=*)
            TIER="${1#--tier=}"
            if [[ "$TIER" != "0" && "$TIER" != "1" && "$TIER" != "2" ]]; then
                echo "Error: --tier must be 0, 1, or 2"
                exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: ./install.sh [--docker | --local] [--tier 0|1|2]"
            echo ""
            echo "  --local         Install dependencies locally (default)"
            echo "  --docker        Build and run with Docker Compose"
            echo "  --tier 0        Core only: discord.js + dotenv (~150MB)"
            echo "  --tier 1        Standard: + SQLite + YAML (~350MB)"
            echo "  --tier 2        Full: + LanceDB + OpenAI embeddings (~700MB, default)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1. Run ./install.sh --help for usage."
            exit 1
            ;;
    esac
    shift
done

MODE="$INSTALL_MODE"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
    # Node.js version check (22+ required for --experimental-sqlite)
    if command -v node >/dev/null 2>&1; then
        NODE_MAJOR=$(node --version 2>/dev/null | tr -d 'v' | cut -d'.' -f1)
        if [[ -n "$NODE_MAJOR" ]] && [[ "$NODE_MAJOR" -lt 22 ]]; then
            error "Node.js 22+ required (found $(node --version)). Update at https://nodejs.org/"
            ok=false
        fi
    fi
    check_command jq "brew install jq / apt install jq" || ok=false
    if [ "$ok" = false ]; then
        error "Missing dependencies. Install them and re-run."
        exit 1
    fi
    # claude CLI — required for all bot functionality (every response uses claude -p)
    if command -v claude >/dev/null 2>&1; then
        info "Dependencies OK (node $(node -v), jq, claude CLI)"
    else
        warn "claude CLI not found."
        echo ""
        echo "  ⚠️  claude CLI is REQUIRED for this bot to function."
        echo "  Every Discord response and cron task calls 'claude -p'."
        echo "  Without it, the bot starts but does nothing."
        echo ""
        echo "  Install: npm install -g @anthropic-ai/claude-code"
        echo "  Then auth: claude  (requires Claude Max subscription)"
        echo ""
        error "Install claude CLI and authenticate before starting the bot."
        exit 1
    fi
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

# --- LaunchAgent setup (macOS only) ---
setup_launchagents() {
    if [[ "$(uname)" != "Darwin" ]]; then
        warn "LaunchAgents are macOS only — skipping"
        return 0
    fi

    local LA_DIR="${HOME}/Library/LaunchAgents"
    local NODE_PATH
    NODE_PATH="$(command -v node)"
    local BASH_PATH="/bin/bash"
    mkdir -p "$LA_DIR"

    # Discord bot (KeepAlive)
    local BOT_PLIST="${LA_DIR}/ai.jarvis.discord-bot.plist"
    if [ ! -f "$BOT_PLIST" ]; then
        cat > "$BOT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.jarvis.discord-bot</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_PATH}</string>
        <string>${BOT_HOME}/discord/discord-bot.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${BOT_HOME}/discord</string>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key>
        <string>production</string>
        <key>PATH</key>
        <string>$(dirname "$NODE_PATH"):/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>BOT_HOME</key>
        <string>${BOT_HOME}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${BOT_HOME}/logs/discord-bot.out.log</string>
    <key>StandardErrorPath</key>
    <string>${BOT_HOME}/logs/discord-bot.err.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ExitTimeOut</key>
    <integer>20</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
        info "Created LaunchAgent: ai.jarvis.discord-bot"
    else
        info "LaunchAgent ai.jarvis.discord-bot already exists"
    fi

    # Watchdog (KeepAlive, runs every 180s)
    local WD_PLIST="${LA_DIR}/ai.jarvis.watchdog.plist"
    if [ ! -f "$WD_PLIST" ]; then
        cat > "$WD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.jarvis.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BASH_PATH}</string>
        <string>${BOT_HOME}/scripts/watchdog.sh</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(dirname "$NODE_PATH"):/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${BOT_HOME}/logs/watchdog.out.log</string>
    <key>StandardErrorPath</key>
    <string>${BOT_HOME}/logs/watchdog.err.log</string>
    <key>ProcessType</key>
    <string>Standard</string>
</dict>
</plist>
PLIST
        info "Created LaunchAgent: ai.jarvis.watchdog"
    else
        info "LaunchAgent ai.jarvis.watchdog already exists"
    fi

    echo ""
    echo -e "  ${CYAN}To activate LaunchAgents:${NC}"
    echo "    launchctl bootstrap gui/\$(id -u) ${BOT_PLIST}"
    echo "    launchctl bootstrap gui/\$(id -u) ${WD_PLIST}"
    echo ""
    echo -e "  ${CYAN}To check status:${NC}"
    echo "    launchctl list | grep jarvis"
}

# --- Crontab setup ---
setup_crontab() {
    local EXISTING
    EXISTING=$(crontab -l 2>/dev/null || true)

    if echo "$EXISTING" | grep -q "jarvis-cron.sh"; then
        info "Crontab already contains jarvis-cron entries"
        return 0
    fi

    echo ""
    echo -e "${BOLD}Would you like to install the default crontab entries?${NC}"
    echo "  This adds 3 basic cron jobs: morning-standup, daily-summary, system-health"
    echo -en "  Install crontab? (y/n) [n]: "
    read -r INSTALL_CRON
    if [[ "$INSTALL_CRON" != "y" && "$INSTALL_CRON" != "Y" ]]; then
        warn "Crontab setup skipped — add entries manually later"
        return 0
    fi

    local CRON_ENTRIES
    CRON_ENTRIES=$(cat <<CRON
# --- Jarvis AI Assistant ---
5 8 * * * ${BOT_HOME}/bin/jarvis-cron.sh morning-standup >> ${BOT_HOME}/logs/cron.log 2>&1
0 20 * * * ${BOT_HOME}/bin/jarvis-cron.sh daily-summary >> ${BOT_HOME}/logs/cron.log 2>&1
1,31 * * * * ${BOT_HOME}/bin/jarvis-cron.sh system-health >> ${BOT_HOME}/logs/cron.log 2>&1
*/3 * * * * ${BOT_HOME}/scripts/launchd-guardian.sh >> ${BOT_HOME}/logs/launchd-guardian.log 2>&1
CRON
)

    if [ -n "$EXISTING" ]; then
        echo "$EXISTING"$'\n'"$CRON_ENTRIES" | crontab -
    else
        echo "$CRON_ENTRIES" | crontab -
    fi
    info "Crontab entries installed (4 jobs)"
}

# --- Docker mode ---
install_docker() {
    info "Installing Jarvis (Docker mode)"

    check_command docker "https://docs.docker.com/get-docker/" || exit 1
    check_command "docker compose" "Docker Desktop or docker-compose-plugin" || {
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
        warn "discord/.env needs configuration — continuing with setup..."
    fi

    info "Installing Node dependencies (Tier ${TIER})..."
    cd "${BOT_HOME}/discord"
    case "$TIER" in
        0)
            warn "Tier 0: core only — SQLite history, RAG, and vector search are disabled"
            # Install only the essential packages explicitly
            npm install --production \
                discord.js dotenv js-yaml chokidar
            ;;
        1)
            warn "Tier 1: standard — LanceDB vector search and OpenAI embeddings are disabled"
            warn "RAG will use BM25 full-text search only (no vector embeddings)"
            # Install without the heavy optional packages
            npm install --production
            npm uninstall lancedb @lancedb/lancedb openai 2>/dev/null || true
            ;;
        2|*)
            npm install --production
            ;;
    esac

    # Ensure relative node_modules symlinks
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
             "${BOT_HOME}/logs" "${BOT_HOME}/rag" "${BOT_HOME}/results" \
             "${BOT_HOME}/plugins"

    # Generate effective-tasks.json
    if [ -x "${BOT_HOME}/bin/plugin-loader.sh" ]; then
        "${BOT_HOME}/bin/plugin-loader.sh" 2>/dev/null && info "Plugin system initialized" || true
    fi

    # Platform-specific setup
    setup_launchagents
    setup_crontab

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete! (Tier ${TIER})${NC}"
    echo ""
    if [[ "$TIER" == "0" ]]; then
        echo -e "  ${YELLOW}Tier 0 — Features disabled:${NC} SQLite chat history, RAG search, vector embeddings"
        echo -e "  ${CYAN}Upgrade later:${NC} ./install.sh --local --tier 2"
        echo ""
    elif [[ "$TIER" == "1" ]]; then
        echo -e "  ${YELLOW}Tier 1 — Features disabled:${NC} Vector search (BM25 full-text search still works)"
        echo -e "  ${CYAN}Upgrade later:${NC} cd ${BOT_HOME}/discord && npm install lancedb openai"
        echo ""
    fi
    echo -e "  ${CYAN}Next steps:${NC}"
    echo "  1. Edit discord/.env with your tokens (required first)"
    echo "     → DISCORD_TOKEN, CLAUDE_HOME, and optionally OPENAI_API_KEY"
    echo "  2. Authenticate Claude: run 'claude' and complete browser login"
    echo "  3. Run the setup wizard: ${BOT_HOME}/bin/jarvis-init.sh"
    echo "  4. Start the bot: cd ${BOT_HOME}/discord && node discord-bot.js"
    echo "  5. Verify install: bash ${BOT_HOME}/scripts/e2e-test.sh"
    echo ""
}

# --- Main ---
case "$MODE" in
    --docker) install_docker ;;
    --local)  install_local ;;
    *)
        echo "Usage: ./install.sh [--docker | --local] [--tier 0|1|2]"
        echo "  --local   Install dependencies locally (default, recommended)"
        echo "  --docker  Build and run with Docker Compose"
        echo "  --tier 0  Core only (~150MB, no SQLite/RAG/embeddings)"
        echo "  --tier 1  Standard (~350MB, no LanceDB/OpenAI)"
        echo "  --tier 2  Full (~700MB, all features, default)"
        exit 1
        ;;
esac
