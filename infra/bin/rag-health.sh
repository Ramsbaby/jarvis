#!/usr/bin/env bash
# rag-health.sh — RAG system health check
# Checks: index log, disk usage, index state, fragment count, compact status
# Output: "RAG OK" or "RAG ERROR: [specific issue]"
set -euo pipefail

RAG_INDEX_LOG="$HOME/.openclaw-data/runtime/logs/rag-index.log"
LANCEDB_PATH="$HOME/.local/share/jarvis/rag/lancedb"
INDEX_STATE="$HOME/.local/share/jarvis/rag/index-state.json"
FRAGMENTS_PATH="$LANCEDB_PATH/documents.lance/data"
COMPACT_LOG="$HOME/.jarvis/logs/rag-lancedb-compact.log"

# Check 1: Index log
if [[ ! -f "$RAG_INDEX_LOG" ]]; then
    echo "RAG ERROR: Index log not found ($RAG_INDEX_LOG)"
    exit 1
fi

INDEX_LOG=$(tail -3 "$RAG_INDEX_LOG" 2>/dev/null || true)
if [[ -z "$INDEX_LOG" ]]; then
    echo "RAG ERROR: Empty index log"
    exit 1
fi

# Check 2: Disk usage
DISK_USAGE=$(du -sh "$LANCEDB_PATH" 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$DISK_USAGE" ]]; then
    echo "RAG ERROR: Cannot read disk usage"
    exit 1
fi

# Check 3: Index state
if [[ ! -f "$INDEX_STATE" ]]; then
    echo "RAG ERROR: Index state file not found ($INDEX_STATE)"
    exit 1
fi

INDEX_STATE_LINES=$(wc -l < "$INDEX_STATE" 2>/dev/null || echo "0")
INDEX_STATE_LINES=$(echo "$INDEX_STATE_LINES" | xargs)
if [[ -z "$INDEX_STATE_LINES" || "$INDEX_STATE_LINES" -lt 1 ]]; then
    echo "RAG ERROR: Index state file is empty"
    exit 1
fi

# Check 4: Fragment count
if [[ ! -d "$FRAGMENTS_PATH" ]]; then
    echo "RAG ERROR: Fragments directory not found ($FRAGMENTS_PATH)"
    exit 1
fi

FRAGMENT_COUNT=$(ls -1 "$FRAGMENTS_PATH" 2>/dev/null | wc -l || echo "0")
FRAGMENT_COUNT=$(echo "$FRAGMENT_COUNT" | xargs)
if [[ "$FRAGMENT_COUNT" -ge 5000 ]]; then
    echo "RAG ERROR: Fragment count too high ($FRAGMENT_COUNT >= 5000, compact may be failing)"
    exit 1
fi

# Check 5: Last successful compact
LAST_COMPACT=$(tail -30 "$COMPACT_LOG" 2>/dev/null | grep -i "DONE\|countRows" | tail -1 || true)
if [[ -z "$LAST_COMPACT" ]]; then
    echo "RAG ERROR: No recent successful compact found in log"
    exit 1
fi

# All checks passed
echo "RAG OK"
exit 0
