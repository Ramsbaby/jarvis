#!/usr/bin/env python3
"""
opensync.py — Allowlist-based open-source sync with personal info scanning.

Ensures only explicitly allowed files reach the public repo.
Scans allowed files for personal data patterns before committing.

Usage:
    python scripts/opensync.py              # Interactive mode
    python scripts/opensync.py --dry-run    # Preview only, no changes
    python scripts/opensync.py --auto       # Auto-approve (CI mode)
"""

import json
import os
import re
import sys
import hashlib
import subprocess
from pathlib import Path
from fnmatch import fnmatch


# ── Paths ──

REPO_ROOT = Path(__file__).resolve().parent.parent
OPENSYNC_YML = REPO_ROOT / ".opensync.yml"
REVIEWED_FILE = REPO_ROOT / "private" / ".opensync-reviewed.json"


# ── YAML-lite parser (no PyYAML dependency) ──

def parse_opensync_yml(path):
    """Parse .opensync.yml without external dependencies."""
    allow = []
    deny = []
    current_section = None

    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "allow:":
            current_section = "allow"
            continue
        if stripped == "deny:":
            current_section = "deny"
            continue
        if stripped.startswith("- "):
            value = stripped[2:].strip().strip('"').strip("'")
            if current_section == "allow":
                allow.append(value)
            elif current_section == "deny":
                deny.append(value)

    return allow, deny


# ── File collection ──

def collect_allowed_files(allow_patterns, deny_patterns):
    """Collect files matching allowlist, excluding deny patterns."""
    allowed = set()

    for pattern in allow_patterns:
        if "**" in pattern:
            # Recursive glob
            base = pattern.split("**")[0].rstrip("/")
            base_path = REPO_ROOT / base if base else REPO_ROOT
            suffix = pattern.split("**")[-1].lstrip("/")
            if base_path.exists():
                for f in base_path.rglob(suffix or "*"):
                    if f.is_file():
                        allowed.add(f.relative_to(REPO_ROOT))
        elif "*" in pattern:
            # Simple glob
            for f in REPO_ROOT.glob(pattern):
                if f.is_file():
                    allowed.add(f.relative_to(REPO_ROOT))
        else:
            # Exact file
            f = REPO_ROOT / pattern
            if f.is_file():
                allowed.add(f.relative_to(REPO_ROOT))

    # Apply deny patterns
    filtered = set()
    for f in allowed:
        f_str = str(f)
        denied = False
        for deny in deny_patterns:
            # Skip negation patterns (e.g., !**/.env.example)
            if deny.startswith("!"):
                continue
            if fnmatch(f_str, deny) or fnmatch(f.name, deny.lstrip("*/")):
                denied = True
                break
        # Check negation (re-allow)
        if denied:
            for deny in deny_patterns:
                if deny.startswith("!") and fnmatch(f_str, deny[1:]):
                    denied = False
                    break
        if not denied:
            filtered.add(f)

    return sorted(filtered)


# ── Personal data scanner ──

SCAN_PATTERNS = [
    # Emails
    (r"[\w.+-]+@(?:gmail|naver|kakao|hotmail|outlook|yahoo)\.\w+", "email address"),
    # Discord tokens
    (r"[MN][A-Za-z\d]{23,}\.[A-Za-z\d_-]{6}\.[A-Za-z\d_-]{27,}", "Discord token"),
    # Discord webhook URLs
    (r"discord\.com/api/webhooks/\d{17,20}/[A-Za-z0-9_-]+", "Discord webhook"),
    # API keys
    (r"sk-ant-api[A-Za-z0-9_-]{20,}", "Anthropic API key"),
    (r"ghp_[A-Za-z0-9]{30,}", "GitHub token"),
    # Hardcoded home paths
    (r"/Users/[a-zA-Z]+/\.", "macOS home path"),
    (r"/home/[a-zA-Z]+/", "Linux home path"),
    (r"C:\\Users\\[a-zA-Z]+\\", "Windows home path"),
    # Hardcoded Discord channel/user IDs (17+ digits as string literals)
    (r"'(\d{17,20})'", "hardcoded Discord ID"),
]

# Compile patterns
_COMPILED_PATTERNS = [(re.compile(p), desc) for p, desc in SCAN_PATTERNS]


def scan_file(filepath):
    """Scan a file for personal data patterns. Returns list of (line_num, description, match)."""
    findings = []
    try:
        content = filepath.read_text(errors="replace")
    except Exception:
        return findings

    for i, line in enumerate(content.splitlines(), 1):
        for pattern, desc in _COMPILED_PATTERNS:
            matches = pattern.findall(line)
            for m in matches:
                findings.append((i, desc, m if isinstance(m, str) else m))

    return findings


# ── Reviewed file cache ──

def load_reviewed():
    """Load previously reviewed file hashes."""
    if REVIEWED_FILE.exists():
        try:
            return json.loads(REVIEWED_FILE.read_text())
        except Exception:
            pass
    return {}


def save_reviewed(reviewed):
    """Save reviewed file hashes."""
    REVIEWED_FILE.parent.mkdir(parents=True, exist_ok=True)
    REVIEWED_FILE.write_text(json.dumps(reviewed, indent=2))


def file_hash(filepath):
    """SHA256 hash of file content."""
    return hashlib.sha256(filepath.read_bytes()).hexdigest()[:16]


# ── Main ──

def main():
    dry_run = "--dry-run" in sys.argv
    auto_mode = "--auto" in sys.argv

    if not OPENSYNC_YML.exists():
        print("  .opensync.yml not found!")
        sys.exit(1)

    # Parse config
    allow_patterns, deny_patterns = parse_opensync_yml(OPENSYNC_YML)
    print(f"  Allowlist: {len(allow_patterns)} patterns, Deny: {len(deny_patterns)} patterns")

    # Collect files
    files = collect_allowed_files(allow_patterns, deny_patterns)
    print(f"  Collected {len(files)} files for public sync")

    if dry_run:
        print("\n  Files that would be synced:")
        for f in files:
            print(f"    {f}")
        print(f"\n  Total: {len(files)} files")

    # Scan for personal data
    reviewed = load_reviewed()
    warnings = []
    blockers = []
    new_files = []

    for f in files:
        full_path = REPO_ROOT / f
        h = file_hash(full_path)
        f_str = str(f)

        # Check if previously reviewed (same content)
        if f_str in reviewed and reviewed[f_str] == h:
            continue

        # Scan
        findings = scan_file(full_path)
        if findings:
            for line_num, desc, match in findings:
                entry = f"    {f}:{line_num} — {desc}: {match[:50]}"
                # High confidence = blocker, low = warning
                if desc in ("Discord token", "Anthropic API key", "GitHub token", "Discord webhook"):
                    blockers.append(entry)
                else:
                    warnings.append(entry)

        # Track new files (never been in reviewed)
        if f_str not in reviewed:
            new_files.append(f_str)

    # Report
    if blockers:
        print(f"\n  {len(blockers)} BLOCKED (secrets detected):")
        for b in blockers:
            print(b)
        print("\n  Fix these before syncing!")
        sys.exit(1)

    if warnings:
        print(f"\n  {len(warnings)} warnings (review recommended):")
        for w in warnings:
            print(w)

    if new_files and not dry_run and not auto_mode:
        print(f"\n  {len(new_files)} new files (first time in public):")
        for nf in new_files[:20]:
            print(f"    {nf}")
        if len(new_files) > 20:
            print(f"    ... and {len(new_files) - 20} more")

    if warnings and not auto_mode and not dry_run:
        answer = input("\n  Proceed with sync? (y/N): ").strip().lower()
        if answer != "y":
            print("  Sync cancelled.")
            sys.exit(0)

    if dry_run:
        print("\n  Dry run complete. No changes made.")
        sys.exit(0)

    # Update reviewed cache
    for f in files:
        full_path = REPO_ROOT / f
        reviewed[str(f)] = file_hash(full_path)
    save_reviewed(reviewed)

    print(f"\n  {len(files)} files verified for public sync.")
    print("  Reviewed cache updated.")
    print("  Run `git add -A && git commit && git push` to publish.")


if __name__ == "__main__":
    main()
