#!/usr/bin/env bash
set -euo pipefail

# plugin-loader.sh — Scan plugins/ + tasks.json → generate effective-tasks.json
# ADR-007: File-Convention Plugin System
#
# Usage: plugin-loader.sh [--validate] [--dry-run]
#   --validate  : only validate manifests, don't generate
#   --dry-run   : print effective JSON to stdout instead of writing

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
PLUGINS_DIR="${BOT_HOME}/plugins"
TASKS_FILE="${BOT_HOME}/config/tasks.json"
EFFECTIVE_FILE="${BOT_HOME}/config/effective-tasks.json"

VALIDATE_ONLY=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --validate) VALIDATE_ONLY=true ;;
        --dry-run)  DRY_RUN=true ;;
    esac
done

log() { echo "[plugin-loader] $1" >&2; }

# --- Required fields for validation ---
REQUIRED_FIELDS='["id","name","prompt","allowedTools","output","timeout","resultMaxChars"]'

# --- Collect plugin manifests ---
PLUGIN_TASKS="[]"
ERRORS=0

if [[ -d "$PLUGINS_DIR" ]]; then
    for manifest in "$PLUGINS_DIR"/*/manifest.json; do
        [[ -f "$manifest" ]] || continue
        plugin_dir=$(dirname "$manifest")
        plugin_name=$(basename "$plugin_dir")

        # Skip dot-prefixed example plugins (they're templates, not active)
        if [[ "$plugin_name" == .* ]]; then
            continue
        fi

        # Validate JSON syntax
        if ! jq -e '.' "$manifest" >/dev/null 2>&1; then
            log "ERROR: Invalid JSON in $manifest"
            (( ERRORS++ )) || true
            continue
        fi

        # Validate required fields
        missing=$(jq -r --argjson req "$REQUIRED_FIELDS" '
            $req[] as $f | select(has($f) | not) | $f
        ' "$manifest" 2>/dev/null)

        if [[ -n "$missing" ]]; then
            log "ERROR: $plugin_name missing fields: $missing"
            (( ERRORS++ )) || true
            continue
        fi

        plugin_id=$(jq -r '.id' "$manifest")

        # Auto-set contextFile if context.md exists in plugin dir
        local_context="${plugin_dir}/context.md"
        if [[ -f "$local_context" ]]; then
            # Inject contextFile path into manifest
            task_entry=$(jq --arg cf "$local_context" '. + {contextFile: $cf}' "$manifest")
        else
            task_entry=$(cat "$manifest")
        fi

        # Remove non-task fields (version, description, tags) before merging
        task_entry=$(echo "$task_entry" | jq 'del(.version, .description, .tags)')

        PLUGIN_TASKS=$(echo "$PLUGIN_TASKS" | jq --argjson entry "$task_entry" '. + [$entry]')
        log "OK: $plugin_name ($plugin_id)"
    done
fi

plugin_count=$(echo "$PLUGIN_TASKS" | jq 'length')

if [[ "$VALIDATE_ONLY" == "true" ]]; then
    log "Validation complete: $plugin_count plugins, $ERRORS errors"
    exit "$ERRORS"
fi

# --- Merge: tasks.json + plugins (plugins override on id collision) ---
if [[ ! -f "$TASKS_FILE" ]]; then
    # tasks.json이 없으면 기존 effective-tasks.json 보존 (빈 파일로 덮어쓰기 방지)
    if [[ -f "$EFFECTIVE_FILE" ]]; then
        _existing_count=$(jq '.tasks | length' "$EFFECTIVE_FILE" 2>/dev/null || echo "0")
        if (( _existing_count > 0 )); then
            log "WARNING: $TASKS_FILE not found, preserving existing $EFFECTIVE_FILE ($_existing_count tasks)"
            exit 0
        fi
    fi
    log "WARNING: $TASKS_FILE not found, using plugins only"
    BASE_TASKS="[]"
else
    BASE_TASKS=$(jq '.tasks // []' "$TASKS_FILE")
fi

# Merge: for each plugin task, replace if id exists in base, append if new
EFFECTIVE=$(python3 -c "
import json, sys

base = json.loads(sys.argv[1])
plugins = json.loads(sys.argv[2])

# Index base tasks by id
base_idx = {t['id']: i for i, t in enumerate(base)}

for pt in plugins:
    pid = pt['id']
    if pid in base_idx:
        # Plugin overrides base task
        base[base_idx[pid]] = pt
    else:
        base.append(pt)

print(json.dumps({'tasks': base}, indent=2, ensure_ascii=False))
" "$BASE_TASKS" "$PLUGIN_TASKS") || {
    log "ERROR: Merge failed"
    exit 1
}

base_count=$(echo "$BASE_TASKS" | jq 'length')
effective_count=$(echo "$EFFECTIVE" | jq '.tasks | length')

if [[ "$DRY_RUN" == "true" ]]; then
    echo "$EFFECTIVE"
    log "Dry run: $base_count base + $plugin_count plugins = $effective_count effective tasks"
    exit 0
fi

# --- Write effective-tasks.json (atomic) ---
TMP_FILE=$(mktemp "${EFFECTIVE_FILE}.XXXXXX")
echo "$EFFECTIVE" > "$TMP_FILE"
mv "$TMP_FILE" "$EFFECTIVE_FILE"

log "Generated: $base_count base + $plugin_count plugins = $effective_count effective tasks"
log "Written to: $EFFECTIVE_FILE"
