#!/usr/bin/env bash
set -euo pipefail

# jarvis-init.sh — Interactive onboarding wizard for new Jarvis users
# ADR-008: Lite/Company dual mode
#
# Usage: jarvis-init.sh

JARVIS_HOME="${HOME}/jarvis/runtime"

# --- Colors ---
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "     ╔═══════════════════════════════════════╗"
    echo "     ║        JARVIS — AI Company-in-a-Box   ║"
    echo "     ║     Your Personal Operations System   ║"
    echo "     ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"
    if [[ -n "$default" ]]; then
        echo -en "${BOLD}${prompt}${NC} [${default}]: "
    else
        echo -en "${BOLD}${prompt}${NC}: "
    fi
    read -r input
    eval "$var_name=\"${input:-$default}\""
}

ask_choice() {
    local prompt="$1"
    local options="$2"  # "a|b|c"
    local default="$3"
    local var_name="$4"
    echo -en "${BOLD}${prompt}${NC} (${options}) [${default}]: "
    read -r input
    eval "$var_name=\"${input:-$default}\""
}

success() { echo -e "  ${GREEN}✓${NC} $1"; }
info()    { echo -e "  ${CYAN}→${NC} $1"; }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }

# === Main ===
banner

echo -e "${BOLD}Welcome! Let's set up Jarvis in under 5 minutes.${NC}"
echo ""

# --- Step 1: Basic info ---
echo -e "${BOLD}Step 1/5: Basic Info${NC}"
ask "Your name" "User" USER_NAME
ask "Timezone" "Asia/Seoul" USER_TZ
success "Name: $USER_NAME, TZ: $USER_TZ"
echo ""

# --- Step 2: Mode ---
echo -e "${BOLD}Step 2/5: Operation Mode${NC}"
echo "  lite    — 3 basic tasks, ready in 5 minutes (recommended for first-time)"
echo "  company — 7 AI teams, full orchestration, knowledge management"
ask_choice "Choose mode" "lite|company" "lite" JARVIS_MODE
success "Mode: $JARVIS_MODE"
echo ""

# --- Step 3: Discord ---
echo -e "${BOLD}Step 3/5: Discord Integration${NC}"
echo "  Create a Discord bot at https://discord.com/developers/applications"
echo "  Paste the bot token below (or press Enter to skip for now)."
ask "Discord bot token" "" DISCORD_TOKEN
if [[ -n "$DISCORD_TOKEN" ]]; then
    ask "Discord server (guild) ID" "" GUILD_ID
    ask "Discord channel ID (main channel)" "" CHANNEL_ID
    success "Discord configured"
else
    warn "Discord skipped — you can configure later in discord/.env"
fi
echo ""

# --- Step 4: LLM Provider ---
echo -e "${BOLD}Step 4/5: LLM Provider${NC}"
echo "  claude-max — Claude Max subscription + claude CLI (recommended, \$0 extra)"
echo "  api        — Anthropic API key (pay-per-use)"
echo "  ollama     — Local Ollama (free, lower quality)"
ask_choice "Primary LLM" "claude-max|api|ollama" "claude-max" LLM_PROVIDER

ANTHROPIC_KEY=""
if [[ "$LLM_PROVIDER" == "api" ]]; then
    ask "Anthropic API key" "" ANTHROPIC_KEY
fi
success "LLM: $LLM_PROVIDER"
echo ""

# --- Step 5: Obsidian Vault ---
echo -e "${BOLD}Step 5/5: Obsidian Vault (optional)${NC}"
echo "  Connect an Obsidian vault for AI-powered knowledge management."
ask "Vault path (or Enter to skip)" "" VAULT_PATH
if [[ -n "$VAULT_PATH" ]]; then
    VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
    if [[ -d "$VAULT_PATH" ]]; then
        success "Vault: $VAULT_PATH"
    else
        warn "Path not found: $VAULT_PATH — will be created on first sync"
    fi
else
    warn "Vault skipped — you can configure later"
fi
echo ""

# === Generate configuration ===
echo -e "${BOLD}Generating configuration...${NC}"

# --- discord/.env ---
ENV_FILE="${JARVIS_HOME}/discord/.env"
if [[ -n "$DISCORD_TOKEN" ]]; then
    # 2026-05-08: ANTHROPIC_API_KEY 라인 제거 — OAuth 전용 정책 (jarvis-ethos.md Iron Law 4.1)
    cat > "$ENV_FILE" <<EOF
BOT_LOCALE=en
DISCORD_TOKEN=${DISCORD_TOKEN}
GUILD_ID=${GUILD_ID}
CHANNEL_IDS=${CHANNEL_ID}
# Claude 인증: OAuth (~/.claude/.credentials.json) — ANTHROPIC_API_KEY 미사용
EOF
    chmod 600 "$ENV_FILE"
    success "discord/.env created"
else
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "${JARVIS_HOME}/discord/.env.example" "$ENV_FILE" 2>/dev/null || true
        success "discord/.env copied from example"
    fi
fi

# --- tasks.json (mode-based) ---
TASKS_OUT="${JARVIS_HOME}/config/tasks.json"
if [[ "$JARVIS_MODE" == "lite" ]]; then
    if [[ -f "$TASKS_OUT" ]]; then
        # Backup existing tasks.json before switching to Lite
        BACKUP="${TASKS_OUT}.backup.$(date +%F_%H%M%S)"
        cp "$TASKS_OUT" "$BACKUP"
        info "Existing tasks.json backed up to $(basename "$BACKUP")"
    fi
    cp "${JARVIS_HOME}/config/tasks.json.example" "$TASKS_OUT" 2>/dev/null || true
    success "tasks.json — Lite mode (3 tasks)"
else
    # Company mode: keep full tasks.json if exists, else use example
    if [[ ! -f "$TASKS_OUT" ]]; then
        cp "${JARVIS_HOME}/config/tasks.json.example" "$TASKS_OUT" 2>/dev/null || true
    fi
    success "tasks.json — Company mode ($(jq '.tasks | length' "$TASKS_OUT" 2>/dev/null || echo '?') tasks)"
fi

# --- Generate effective-tasks.json ---
"${JARVIS_HOME}/bin/plugin-loader.sh" 2>/dev/null && success "effective-tasks.json generated" || true

# --- Save init state ---
cat > "${JARVIS_HOME}/.initialized" <<EOF
user_name=${USER_NAME}
timezone=${USER_TZ}
mode=${JARVIS_MODE}
llm_provider=${LLM_PROVIDER}
vault_path=${VAULT_PATH}
initialized_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
success "Init state saved"

# --- Setup crontab (if not already configured) ---
echo ""
echo -e "${BOLD}Setup Summary${NC}"
echo ""
echo "  Mode:     $JARVIS_MODE"
echo "  LLM:      $LLM_PROVIDER"
echo "  Discord:  ${DISCORD_TOKEN:+configured}${DISCORD_TOKEN:-skipped}"
echo "  Vault:    ${VAULT_PATH:-skipped}"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo ""
if [[ -z "$DISCORD_TOKEN" ]]; then
    echo "  1. Configure Discord: edit ${JARVIS_HOME}/discord/.env"
    echo "  2. Start the bot:     cd ${JARVIS_HOME}/discord && node discord-bot.js"
else
    echo "  1. Start the bot:     cd ${JARVIS_HOME}/discord && node discord-bot.js"
fi
echo ""
if [[ "$JARVIS_MODE" == "lite" ]]; then
    echo "  Upgrade to Company mode anytime:"
    echo "    ${JARVIS_HOME}/bin/jarvis-init.sh"
fi
echo ""
echo -e "${GREEN}${BOLD}Jarvis is ready. Let's build something great, ${USER_NAME}.${NC}"
echo ""