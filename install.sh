#!/usr/bin/env bash
set -euo pipefail

# install.sh — Claude Discord Bridge one-command setup
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

# --- Read DISCORD_SERVICE from .env (default: ai.claude-discord-bot) ---
read_discord_service() {
    local svc="ai.claude-discord-bot"
    if [ -f "${BOT_HOME}/discord/.env" ]; then
        local val
        val=$(grep -E '^DISCORD_SERVICE=' "${BOT_HOME}/discord/.env" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
        [ -n "$val" ] && svc="$val"
    fi
    echo "$svc"
}

# --- macOS: install LaunchAgent for auto-start + KeepAlive ---
install_launchagent() {
    local service_name="$1"
    local node_bin
    node_bin="$(command -v node)"
    local plist_path="$HOME/Library/LaunchAgents/${service_name}.plist"

    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${service_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${node_bin}</string>
        <string>${BOT_HOME}/discord/discord-bot.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${BOT_HOME}/discord</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BOT_HOME</key>
        <string>${BOT_HOME}</string>
        <key>NODE_ENV</key>
        <string>production</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${BOT_HOME}/logs/discord-bot.out.log</string>
    <key>StandardErrorPath</key>
    <string>${BOT_HOME}/logs/discord-bot.err.log</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path"
    info "LaunchAgent installed: ${service_name}"
    info "  Start:   launchctl start ${service_name}"
    info "  Stop:    launchctl stop ${service_name}"
    info "  Logs:    tail -f ${BOT_HOME}/logs/discord-bot.out.log"
}

# --- Linux: install systemd user service ---
install_systemd() {
    local service_name="$1"
    local node_bin
    node_bin="$(command -v node)"
    local unit_dir="$HOME/.config/systemd/user"
    local unit_path="${unit_dir}/${service_name}.service"

    mkdir -p "$unit_dir"
    cat > "$unit_path" << EOF
[Unit]
Description=Claude Discord Bridge Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${BOT_HOME}/discord
ExecStart=${node_bin} ${BOT_HOME}/discord/discord-bot.js
Restart=always
RestartSec=10
Environment=BOT_HOME=${BOT_HOME}
Environment=NODE_ENV=production
StandardOutput=append:${BOT_HOME}/logs/discord-bot.out.log
StandardError=append:${BOT_HOME}/logs/discord-bot.err.log

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "${service_name}"
    systemctl --user start "${service_name}"
    info "systemd user service installed: ${service_name}"
    info "  Status:  systemctl --user status ${service_name}"
    info "  Logs:    journalctl --user -u ${service_name} -f"
    info "  Stop:    systemctl --user stop ${service_name}"
}

# --- Install cron jobs (bot-watchdog + launchd-guardian) ---
install_cron() {
    local service_name="$1"
    local cron_env="BOT_HOME=${BOT_HOME} DISCORD_SERVICE=${service_name}"

    # bot-watchdog every 5 minutes
    local watchdog_entry="*/5 * * * * ${cron_env} ${BOT_HOME}/bin/bot-watchdog.sh >> ${BOT_HOME}/logs/cron.log 2>&1"
    # launchd-guardian every 3 minutes
    local guardian_entry="*/3 * * * * ${cron_env} ${BOT_HOME}/scripts/launchd-guardian.sh >> ${BOT_HOME}/logs/cron.log 2>&1"

    # Add to crontab if not already present
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || true)

    local new_cron="$current_cron"
    if ! echo "$current_cron" | grep -q "bot-watchdog.sh"; then
        new_cron="${new_cron}
${watchdog_entry}"
        info "Added bot-watchdog.sh to cron (every 5 min)"
    else
        info "bot-watchdog.sh already in cron — skipped"
    fi
    if ! echo "$current_cron" | grep -q "launchd-guardian.sh"; then
        new_cron="${new_cron}
${guardian_entry}"
        info "Added launchd-guardian.sh to cron (every 3 min)"
    else
        info "launchd-guardian.sh already in cron — skipped"
    fi

    echo "$new_cron" | crontab -
}

# --- Docker mode ---
install_docker() {
    info "Installing Claude Discord Bridge (Docker mode)"

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
    info "Installing Claude Discord Bridge (local mode)"

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

    # node_modules symlinks so lib/ and bin/ scripts can resolve packages
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
             "${BOT_HOME}/watchdog"

    local service_name
    service_name=$(read_discord_service)

    # Install service manager integration
    echo ""
    if command -v launchctl >/dev/null 2>&1; then
        info "macOS detected — installing LaunchAgent (auto-start + KeepAlive)"
        install_launchagent "$service_name"
    elif command -v systemctl >/dev/null 2>&1; then
        info "Linux detected — installing systemd user service"
        install_systemd "$service_name"
    else
        warn "No service manager found. Start manually:"
        warn "  cd ${BOT_HOME}/discord && node discord-bot.js"
    fi

    # Install cron watchdogs
    if command -v crontab >/dev/null 2>&1; then
        install_cron "$service_name"
    else
        warn "crontab not found — skipping watchdog cron setup"
    fi

    echo ""
    info "Installation complete! Service: ${service_name}"
    info "Logs: tail -f ${BOT_HOME}/logs/discord-bot.out.log"
}

# --- Main ---
case "$MODE" in
    --docker) install_docker ;;
    --local)  install_local ;;
    *)
        echo "Usage: ./install.sh [--docker | --local]"
        echo "  --docker  Build and run with Docker Compose (default)"
        echo "  --local   Install dependencies + register as system service (macOS/Linux)"
        exit 1
        ;;
esac
