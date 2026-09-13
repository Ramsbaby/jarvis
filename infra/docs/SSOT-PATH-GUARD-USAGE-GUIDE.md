# SSoT Path Guard Usage Guide

**Cluster ID**: cl-1a81b2956a7f0cc9 — SSoT Multi-Repository Path Inconsistency Prevention  
**Purpose**: Prevent synchronization errors when editing files that exist in multiple repositories  
**Status**: Production  

## Quick Start

### Before Editing a File

Always check if the file you're about to edit is part of a multi-repo SSoT:

```bash
~/jarvis/infra/lib/ssot-path-guard.sh /path/to/file
```

The guard will tell you:
- Whether the file is a known SSoT file
- If there are related copies in other repositories
- Whether synchronization is required

### Exit Codes

| Code | Meaning | Action Required |
|------|---------|-----------------|
| 0 | File is safe to edit alone | Proceed with edit |
| 1 | Related files exist (non-critical) | Check related files after editing |
| 2 | **CRITICAL**: Related files must be synced | DO NOT edit without syncing plan |
| 127 | Configuration error | Fix configuration first |

## Common Workflows

### Scenario 1: Editing a CRITICAL SSoT File

```bash
$ ~/jarvis/infra/lib/ssot-path-guard.sh ~/.jarvis/config/monitoring.json
[INFO] File belongs to repository: jarvis-config
[WARN] This file is part of SSoT mapping: monitoring_config
[WARN] Found 1 related file(s) that MUST be synchronized:
  ✓ EXISTS: /Users/ramsbaby/jarvis/runtime/config/monitoring.json
[ERROR] *** CRITICAL: This is a CRITICAL SSoT mapping ***
[ERROR] After editing this file, you MUST synchronize:
  1. Review all related files listed above
  2. Apply the same changes to each copy
  3. Verify consistency before committing
```

**Action Plan**:
1. ✓ Open both files side-by-side
2. ✓ Make changes to BOTH files
3. ✓ Verify the changes match exactly
4. ✓ Test the changes (config reload, etc.)
5. ✓ Commit both file changes together

---

### Scenario 2: Editing a Non-SSoT File

```bash
$ ~/jarvis/infra/lib/ssot-path-guard.sh ~/jarvis/infra/scripts/some-script.sh
[INFO] File belongs to repository: jarvis-main
[OK] File is not part of any known SSoT mapping
```

**Action Plan**:
1. ✓ Edit freely, no synchronization needed
2. ✓ Test and commit as normal

---

### Scenario 3: Missing Related File

```bash
$ ~/jarvis/infra/lib/ssot-path-guard.sh ~/jarvis/infra/config/channel-map.json
[INFO] File belongs to repository: jarvis-main
[WARN] Expected related SSoT files are MISSING:
  ✗ MISSING: /Users/ramsbaby/jarvis/runtime/config/channel-map.json
[WARN] This may indicate an incomplete setup or missing repository.
```

**Action Plan**:
1. Check if the related file should exist:
   ```bash
   ls -la /Users/ramsbaby/jarvis/runtime/config/channel-map.json
   ```
2. If it should exist:
   - Restore it from backup
   - Or create it by copying from the existing file
3. If it shouldn't exist:
   - Update the SSoT configuration: `~/jarvis/infra/config/ssot-paths.json`

---

## Command Reference

### Check a Single File

```bash
~/jarvis/infra/lib/ssot-path-guard.sh /path/to/file
```

Returns status and related files (if any).

### Check with Sync Points

```bash
~/jarvis/infra/lib/ssot-path-guard.sh /path/to/file --sync
```

Displays all files that must be synchronized together.

### List All SSoT Mappings

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --list-ssot
```

Shows all known SSoT mappings and their criticality.

**Output**:
```
[INFO] All SSoT mappings:
  [CRITICAL] channel_map          Discord channel-to-webhook mapping
  [CRITICAL] guard_config         Guard and validation script configuration
   model_config         AI model configuration and routing
  [CRITICAL] monitoring_config    Monitoring configuration for alerts and health checks
  [CRITICAL] task_registry        Task configuration must be synchronized across both locations
```

### List All SSoT Paths

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --list-paths
```

Shows all known SSoT file paths and whether they exist.

**Output**:
```
[INFO] All known SSoT paths:
  ✓ /Users/ramsbaby/.jarvis/config/guard_config.json
  ✓ /Users/ramsbaby/.jarvis/config/monitoring.json
  ✓ /Users/ramsbaby/jarvis/infra/config/channel-map.json
  ✓ /Users/ramsbaby/jarvis/infra/config/guard_config.json
  ...
```

### Validate Configuration

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --validate-config
```

Checks that the SSoT configuration file is valid and complete.

### Help

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --help
```

Displays usage information and exit codes.

---

## SSoT Mappings Reference

### monitoring_config (CRITICAL)

**Purpose**: Monitoring and alert configuration  
**Files**:
- `/Users/ramsbaby/.jarvis/config/monitoring.json`
- `/Users/ramsbaby/jarvis/runtime/config/monitoring.json`

**Why Critical**: Configuration must match exactly across both locations for alerts to work correctly.

**Sync Procedure**:
1. Edit one file
2. Copy changes to the other
3. Verify by comparing diffs
4. Test alert triggers

---

### task_registry (CRITICAL)

**Purpose**: Task routing and configuration  
**Files**:
- `/Users/ramsbaby/jarvis/infra/config/task-routing-config.json`
- `/Users/ramsbaby/.jarvis/state/tasks.json`

**Why Critical**: Task system relies on consistent configuration.

**Sync Procedure**:
1. Make changes to both files
2. Validate JSON syntax
3. Test task creation and routing

---

### channel_map (CRITICAL)

**Purpose**: Discord channel-to-webhook mapping  
**Files**:
- `/Users/ramsbaby/jarvis/infra/config/channel-map.json`
- `/Users/ramsbaby/jarvis/runtime/config/channel-map.json`

**Why Critical**: Wrong channel mapping causes messages to go to wrong channels.

**Sync Procedure**:
1. Update both copies
2. Test by sending a test message
3. Verify message appears in correct channel

---

### guard_config (CRITICAL)

**Purpose**: Guard and validation script configuration  
**Files**:
- `/Users/ramsbaby/jarvis/infra/config/guard_config.json`
- `/Users/ramsbaby/.jarvis/config/guard_config.json`

**Why Critical**: Guards enforce critical system rules; misconfigs bypass safety checks.

**Sync Procedure**:
1. Update both files identically
2. Test guard validation
3. Ensure no existing functionality breaks

---

### model_config (Non-Critical)

**Purpose**: AI model configuration and routing  
**Files**:
- `/Users/ramsbaby/jarvis/infra/config/models.json`
- `/Users/ramsbaby/jarvis/runtime/config/models.json`

**Why Non-Critical**: Model changes are gracefully handled by fallback logic.

**Sync Procedure**:
1. Update one file
2. Update the other when convenient
3. Monitor for any unexpected behavior

---

## Troubleshooting

### Problem: Guard Says File is Not in Any Repository

**Cause**: The file path doesn't match any patterns in the configuration.

**Solution**:
1. Check the file path is absolute
2. Verify the path matches repository patterns in `ssot-paths.json`
3. Add the path to the configuration if needed

```bash
# Example: Check if ~/.jarvis/config/foo.json is recognized
~/jarvis/infra/lib/ssot-path-guard.sh ~/.jarvis/config/foo.json
```

---

### Problem: Guard Says Related File is Missing

**Cause**: A SSoT file is expected but doesn't exist.

**Solution**:
1. Check if the file should exist:
   ```bash
   ls -la /path/to/missing/file
   ```
2. If it should exist:
   - Restore from backup
   - Copy from existing SSoT copy
3. If it shouldn't exist:
   - Update `ssot-paths.json` to remove it from the mapping

---

### Problem: Exit Code is Always 0, Even for CRITICAL Files

**Cause**: Configuration may be missing or invalid.

**Solution**:
1. Validate configuration:
   ```bash
   ~/jarvis/infra/lib/ssot-path-guard.sh --validate-config
   ```
2. Check that `ssot-paths.json` exists and is valid JSON
3. Verify the file is in a `critical_paths` list

---

### Problem: Guard Works Manually But Not in Shell Scripts

**Cause**: The guard is checking file existence; symlinks may not resolve.

**Solution**:
1. Use absolute paths, not relative paths
2. Resolve symlinks before checking:
   ```bash
   FILE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
   ~/jarvis/infra/lib/ssot-path-guard.sh "$FILE"
   ```

---

## Integration Examples

### Shell Function Wrapper

Add this to your `~/.zshrc` or `~/.bashrc`:

```bash
# Before editing any file, check if it's a multi-repo SSoT
check-ssot() {
    ~/jarvis/infra/lib/ssot-path-guard.sh "$1"
    local exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        echo ""
        echo "⚠️  CRITICAL SSoT File Detected!"
        echo "You MUST synchronize related files before committing."
        echo ""
        return 2
    fi
    return 0
}

# Usage: check-ssot ~/.jarvis/config/monitoring.json
```

### Pre-Commit Hook

Create `.git/hooks/pre-commit`:

```bash
#!/bin/bash
set -e

# Check all staged files for SSoT issues
while IFS= read -r file; do
    if ~/jarvis/infra/lib/ssot-path-guard.sh "$file" >/dev/null 2>&1; then
        exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            echo "❌ CRITICAL SSoT violation detected: $file"
            echo "Sync all related files before committing"
            exit 1
        fi
    fi
done < <(git diff --cached --name-only)

echo "✓ SSoT validation passed"
```

### Git Alias

```bash
git config --global alias.check-ssot '!~/jarvis/infra/lib/ssot-path-guard.sh'
git check-ssot /path/to/file
```

---

## Best Practices

1. **Always Check Before Editing**: Run the guard before opening any file in an editor:
   ```bash
   ~/jarvis/infra/lib/ssot-path-guard.sh /path/to/file
   ```

2. **Keep Related Files in View**: When editing CRITICAL SSoT files, use split-pane or split windows:
   ```bash
   # In a terminal
   code -r ~/.jarvis/config/monitoring.json ~/jarvis/runtime/config/monitoring.json
   ```

3. **Sync Immediately**: Don't delay synchronizing related files. The sooner you sync, the sooner you can test.

4. **Commit Together**: Always commit SSoT file changes together in a single commit with a clear message:
   ```bash
   git commit -m "Update monitoring config (SSoT sync: monitoring_config)"
   ```

5. **Test After Sync**: Always verify that your changes work correctly after syncing:
   - For config files: reload the service
   - For mapping files: test the functionality
   - For task files: create a test task

6. **Document Why**: Include the cluster ID and mapping name in your commit message:
   ```bash
   git commit -m "Fix Discord channel webhook (SSoT: cl-1a81b2956a7f0cc9, channel_map)"
   ```

---

## Configuration Maintenance

### Add a New SSoT Mapping

1. Edit `~/jarvis/infra/config/ssot-paths.json`
2. Add to `ssot_mappings`:
   ```json
   "new_mapping": {
     "primary_paths": [
       "/path/to/file1",
       "/path/to/file2"
     ],
     "description": "Description of what this mapping controls",
     "critical": true
   }
   ```
3. Test the guard:
   ```bash
   ~/jarvis/infra/lib/ssot-path-guard.sh /path/to/file1
   ```

### Add a New Repository

1. Edit `~/jarvis/infra/config/ssot-paths.json`
2. Add to `repositories`:
   ```json
   {
     "id": "new-repo",
     "name": "Description",
     "path": "/Users/ramsbaby/path/to/repo",
     "patterns": [
       "^/Users/ramsbaby/path/to/repo/critical/"
     ]
   }
   ```
3. Validate:
   ```bash
   ~/jarvis/infra/lib/ssot-path-guard.sh --validate-config
   ```

---

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review configuration in `~/jarvis/infra/config/ssot-paths.json`
3. Run `--validate-config` to check for errors
4. Report cluster ID: **cl-1a81b2956a7f0cc9**

