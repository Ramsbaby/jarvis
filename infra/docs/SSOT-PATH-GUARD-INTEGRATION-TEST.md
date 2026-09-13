# SSoT Path Guard Integration Test & Validation

**Cluster ID**: cl-1a81b2956a7f0cc9  
**Guard Name**: ssot-path-guard.sh  
**Guard Type**: Pre-edit validation (file consistency)  
**Created**: 2026-08-05  

## Overview

This test suite validates the **SSoT Path Guard** system, which prevents multi-repo synchronization errors by detecting when a file belongs to multiple SSoT (Single Source of Truth) mappings and warning about the need to synchronize all copies.

## Test Environment

- **Configuration**: `~/jarvis/infra/config/ssot-paths.json`
- **Guard Script**: `~/jarvis/infra/lib/ssot-path-guard.sh`
- **Test Data**: Production SSoT files from three repositories:
  - `~/jarvis` (Main repository)
  - `~/.jarvis` (Config repository)
  - `~/Jarvis-Vault` (Knowledge vault)

## Test Cases

### Test 1: Configuration Validation

**Purpose**: Verify that the SSoT configuration file is valid and complete.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --validate-config
```

**Expected Output**:
- Exit code: 0
- Message: `[OK] Configuration valid`

**Verification Checklist**:
- ✓ JSON is valid (parseable by jq)
- ✓ Contains `repositories` section
- ✓ Contains `ssot_mappings` section
- ✓ Contains `rules` section

---

### Test 2: List SSoT Mappings

**Purpose**: Display all known SSoT mappings and their criticality levels.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --list-ssot
```

**Expected Output**:
```
[INFO] All SSoT mappings:
  [CRITICAL] channel_map          Discord channel-to-webhook mapping
  [CRITICAL] guard_config         Guard and validation script configuration
   model_config         AI model configuration and routing
  [CRITICAL] monitoring_config    Monitoring configuration for alerts and health checks
  [CRITICAL] task_registry        Task configuration must be synchronized across both locations
```

**Verification Checklist**:
- ✓ All 5 mappings are listed
- ✓ 4 mappings marked as [CRITICAL]
- ✓ 1 mapping (model_config) unmarked

---

### Test 3: CRITICAL SSoT File Detection

**Purpose**: Verify that critical SSoT files are detected and synchronization requirements are shown.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh ~/.jarvis/config/monitoring.json
```

**Expected Output**:
```
[INFO] Checking SSoT status for: /Users/ramsbaby/.jarvis/config/monitoring.json
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

**Expected Exit Code**: 2 (Critical warning)

**Verification Checklist**:
- ✓ File identified as CRITICAL SSoT
- ✓ Related file path is shown
- ✓ Synchronization requirements are clearly stated
- ✓ Exit code is 2 (not 0)

---

### Test 4: Non-CRITICAL SSoT File Detection

**Purpose**: Verify that non-critical SSoT files still warn but don't block editing.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh ~/jarvis/infra/config/models.json
```

**Expected Behavior**:
- Exit code: 0 or 1 (warning, not critical)
- File is still identified as SSoT
- Related files are listed
- Warning is shown but no [CRITICAL] block marker

**Verification Checklist**:
- ✓ File detected as SSoT
- ✓ Related files listed
- ✓ No [CRITICAL] designation
- ✓ Exit code < 2

---

### Test 5: Non-SSoT File

**Purpose**: Verify that files not in any SSoT mapping pass without warnings.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh ~/jarvis/infra/scripts/some-script.sh
```

**Expected Output**:
```
[INFO] Checking SSoT status for: /Users/ramsbaby/jarvis/infra/scripts/some-script.sh
[INFO] File belongs to repository: jarvis-main
[OK] File is not part of any known SSoT mapping
```

**Expected Exit Code**: 0

**Verification Checklist**:
- ✓ No warnings are shown
- ✓ File is in a known repository
- ✓ Clear message stating "not part of any known SSoT"
- ✓ Exit code is 0

---

### Test 6: Sync Points Display

**Purpose**: Show all related files when --sync flag is used.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh ~/.jarvis/config/monitoring.json --sync
```

**Expected Output**: Should include sync points section showing all related files.

---

### Test 7: Missing Repository File

**Purpose**: Warn when a SSoT mapping expects a file that doesn't exist.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh ~/jarvis/infra/config/channel-map.json
```

**Expected Output** (approximately):
```
[WARN] Expected related SSoT files are MISSING:
  ✗ MISSING: /Users/ramsbaby/jarvis/runtime/config/channel-map.json
```

**Expected Exit Code**: 1 (warning)

**Verification Checklist**:
- ✓ Missing file is reported
- ✓ File path is clearly shown
- ✓ Warning message indicates incomplete setup

---

### Test 8: Help Output

**Purpose**: Verify help text is available and informative.

```bash
~/jarvis/infra/lib/ssot-path-guard.sh --help
```

**Verification Checklist**:
- ✓ Usage examples are shown
- ✓ Exit codes are documented
- ✓ Guard cluster ID is displayed
- ✓ All major options are listed

---

## Integration Test Script

Run all tests at once:

```bash
#!/bin/bash
set -e

GUARD="~/jarvis/infra/lib/ssot-path-guard.sh"

echo "=== Test 1: Configuration Validation ==="
$GUARD --validate-config
echo "✓ PASS"
echo ""

echo "=== Test 2: List SSoT Mappings ==="
$GUARD --list-ssot | grep -q "monitoring_config" && echo "✓ PASS" || echo "✗ FAIL"
echo ""

echo "=== Test 3: CRITICAL SSoT Detection ==="
$GUARD ~/.jarvis/config/monitoring.json > /tmp/test3.txt 2>&1 || true
if grep -q "CRITICAL" /tmp/test3.txt; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi
echo ""

echo "=== Test 4: Non-SSoT File ==="
# Use a file that's definitely not SSoT
$GUARD ~/jarvis/infra/scripts/discord-file-upload.mjs 2>&1 | grep -q "not part of any known" && echo "✓ PASS" || echo "✗ FAIL"
echo ""

echo "All integration tests completed"
```

## Validation Criteria

✅ **Pass Condition**:
- Configuration validation succeeds
- SSoT mappings are correctly identified
- CRITICAL files trigger exit code 2
- Sync points are shown for multi-file mappings
- Non-SSoT files are passed without warnings

❌ **Fail Condition**:
- Configuration is invalid or incomplete
- Files are misidentified as SSoT or non-SSoT
- Exit codes are incorrect
- Related file paths are wrong or missing
- Help text is unavailable

## Regression Test

To ensure this guard doesn't break existing workflows:

1. Edit a CRITICAL SSoT file and verify the warning is shown
2. Edit a non-SSoT file and verify no blocking warnings occur
3. Verify the guard can be used in shell scripts and CI pipelines
4. Confirm exit codes are appropriate for conditional logic

## Known Limitations

1. **Configuration Not Auto-Reloaded**: Changes to `ssot-paths.json` require re-running the guard
2. **Exact Path Matching**: The guard looks for exact file paths in SSoT mappings; symlinks may not be detected
3. **No Diff Validation**: The guard checks for file existence, not actual content consistency

## Future Enhancements

1. Auto-generate sync validation from differences between related files
2. Implement optional auto-sync mode (with user confirmation)
3. Add watch mode to detect changes to SSoT files in real-time
4. Create pre-commit hook integration for automatic validation
5. Support for glob patterns in SSoT_mappings for dynamic path matching

## Related Clusters

- **cl-7cc6d5b18177ab54**: Consistency checking (partial update detection)
- **cl-5df6f4a4943a2b1f**: MCP path validation
- **cl-eba9e129c709bb2a**: File location error prevention

