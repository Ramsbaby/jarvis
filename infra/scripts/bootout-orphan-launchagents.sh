#!/usr/bin/env bash
# bootout-orphan-launchagents.sh
#
# Purpose: Safely tear down 5 known orphan/broken Jarvis tasks.
#   - 3 LaunchAgents whose backing scripts are gone (boot loops, exit 127)
#       * com.jarvis.board-conclude     (every 5 min, hot-loop)
#       * com.jarvis.board-meeting-am
#       * com.jarvis.board-meeting-pm
#   - 2 Nexus tasks.json entries to disable in place (auto-disable + reason memo)
#       * system-health   (exit 127, CB neutralised)
#       * github-monitor  (paused until completion)
#
# Behaviour:
#   - Default = DRY-RUN. Prints every command that *would* run, mutates nothing.
#   - --apply = perform the changes.
#   - LaunchAgent plists are NEVER deleted: they are copied into a dated
#     backup dir, then the live file is renamed to *.disabled-YYYYMMDD-HHMMSS
#     (collision-safe; existing *.disabled files are preserved untouched).
#   - tasks.json is patched atomically with jq into a tmp file, then mv-ed
#     into place. Original is backed up alongside it as tasks.json.bak-<ts>.
#
# Naming: jarvis-core convention -> [domain]-[target]-[action].
#
# Safety:
#   - set -euo pipefail
#   - trap cleanup of temp files
#   - refuses to run as root
#   - logs every action both to stdout and to a session log

set -euo pipefail

# ---- constants ------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
TS="$(date +%Y%m%d-%H%M%S)"
TODAY="$(date +%Y%m%d)"
LA_DIR="$HOME/Library/LaunchAgents"
BACKUP_DIR="$LA_DIR/_orphan-backup-${TODAY}"
TASKS_JSON="$HOME/jarvis/runtime/config/tasks.json"
LOG_DIR="$HOME/.jarvis/logs"
LOG_FILE="$LOG_DIR/bootout-orphan-${TS}.log"

# 3 LaunchAgent labels to bootout (no .plist suffix)
LA_LABELS=(
  "com.jarvis.board-conclude"
  "com.jarvis.board-meeting-am"
  "com.jarvis.board-meeting-pm"
)

# 2 tasks.json ids to flip enabled:false + record _disabled_reason
TASKS_IDS=(
  "system-health"
  "github-monitor"
)

DISABLED_REASON_SYSTEM_HEALTH="2026-04-18: exit 127 + circuit breaker neutralised; pending root-cause investigation. Re-enable only after script restored and CB cleared."
DISABLED_REASON_GITHUB_MONITOR="2026-04-18: temporarily paused until completion. Re-enable after gate pattern review."

# ---- flags ----------------------------------------------------------------

MODE="dry-run"
for arg in "$@"; do
  case "$arg" in
    --apply)   MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run | --apply]

  --dry-run  (default) Print actions, do not change anything.
  --apply    Execute. Backs up plists, bootouts agents, patches tasks.json.

Targets:
  LaunchAgents (3): ${LA_LABELS[*]}
  tasks.json   (2): ${TASKS_IDS[*]}

Backup of plists: $BACKUP_DIR
Backup of tasks.json: \${TASKS_JSON}.bak-${TS}
Session log: $LOG_FILE
EOF
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (use --help)" >&2
      exit 2
      ;;
  esac
done

# ---- guards ---------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Refusing to run as root." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH (required for tasks.json patch)." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# ---- temp + cleanup -------------------------------------------------------

TMP_TASKS=""
cleanup() {
  if [[ -n "$TMP_TASKS" && -f "$TMP_TASKS" ]]; then
    rm -f "$TMP_TASKS"
  fi
}
trap cleanup EXIT

# ---- helpers --------------------------------------------------------------

log() {
  # both stdout and append to log file (only when applying)
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

run() {
  # In dry-run: print prefixed. In apply: print + execute (errors surface via -e).
  # Pass argv directly — no eval, no shell-metachar reparse.
  if [[ "$MODE" == "dry-run" ]]; then
    log "[DRY] $*"
  else
    log "[RUN] $*"
    "$@"
  fi
}

# Variant for commands where non-zero exit is acceptable (e.g., "already unloaded").
run_ok() {
  if [[ "$MODE" == "dry-run" ]]; then
    log "[DRY] $*"
  else
    log "[RUN] $*"
    "$@" || true
  fi
}

# ---- header ---------------------------------------------------------------

log "=== bootout-orphan-launchagents.sh ($MODE) @ $TS ==="
log "Backup dir : $BACKUP_DIR"
log "Tasks json : $TASKS_JSON"
log "Log file   : $LOG_FILE"
log ""

# ---- step 1: bootout LaunchAgents ----------------------------------------

log "--- Step 1/2: tear down 3 orphan LaunchAgents ---"

run mkdir -p "$BACKUP_DIR"

for label in "${LA_LABELS[@]}"; do
  plist="$LA_DIR/${label}.plist"
  if [[ ! -f "$plist" ]]; then
    log "[SKIP] $label: $plist not found (already gone)"
    continue
  fi

  # 1a. Backup the live plist
  run cp -p "$plist" "$BACKUP_DIR/${label}.plist"

  # 1b. bootout from launchd (gui domain). Allow non-zero (already unloaded).
  run_ok launchctl bootout "gui/$(id -u)/${label}"

  # 1c. Rename live plist to a unique .disabled-<ts> name to avoid
  #     clobbering any existing .disabled file. Hard delete is forbidden.
  disabled_path="${plist}.disabled-${TS}"
  run mv "$plist" "$disabled_path"

  log "[OK]  $label -> backed up + bootout + renamed ($disabled_path)"
done

log ""

# ---- step 2: patch tasks.json --------------------------------------------

log "--- Step 2/2: patch tasks.json (system-health, github-monitor) ---"

if [[ ! -f "$TASKS_JSON" ]]; then
  log "[ERR] tasks.json not found at $TASKS_JSON"
  exit 1
fi

# Backup of original (always, including in apply mode)
run cp -p "$TASKS_JSON" "${TASKS_JSON}.bak-${TS}"

# Build jq filter that flips enabled:false + writes _disabled_reason for both ids.
# Uses argjson reasons so the strings stay correctly quoted.
JQ_FILTER='
  .tasks |= map(
    if .id == $id_sh then
      . + {enabled: false, _disabled_reason: $reason_sh}
    elif .id == $id_gh then
      . + {enabled: false, _disabled_reason: $reason_gh}
    else . end
  )
'

TMP_TASKS="$(mktemp -t tasks-json-patch.XXXXXX)"

if [[ "$MODE" == "dry-run" ]]; then
  log "[DRY] jq patch -> would set enabled:false + _disabled_reason on:"
  for id in "${TASKS_IDS[@]}"; do
    log "       - $id"
  done
  log "[DRY] would atomically: mv <tmp> $TASKS_JSON"
else
  jq \
    --arg id_sh   "system-health" \
    --arg id_gh   "github-monitor" \
    --arg reason_sh "$DISABLED_REASON_SYSTEM_HEALTH" \
    --arg reason_gh "$DISABLED_REASON_GITHUB_MONITOR" \
    "$JQ_FILTER" \
    "$TASKS_JSON" > "$TMP_TASKS"

  # validate before swap
  if ! jq -e '.tasks | length > 0' "$TMP_TASKS" >/dev/null; then
    log "[ERR] jq output failed validation; aborting swap."
    exit 1
  fi

  mv "$TMP_TASKS" "$TASKS_JSON"
  TMP_TASKS=""  # consumed
  log "[OK]  tasks.json patched in place; backup at ${TASKS_JSON}.bak-${TS}"
fi

log ""
log "=== Done ($MODE). Re-run with --apply to execute. ==="
