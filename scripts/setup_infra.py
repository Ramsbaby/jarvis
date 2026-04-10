#!/usr/bin/env python3
"""
🏗️ Jarvis Infrastructure Setup Wizard

Sets up the Jarvis infrastructure module: Discord bot, data directories,
environment config, cron jobs, and macOS LaunchAgents.

Prerequisites:
  - Node.js 18+
  - Ollama running locally
"""

import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

# ── Repo root: two levels up from scripts/setup_infra.py ──
REPO_ROOT = Path(__file__).resolve().parent.parent
INFRA_DIR = REPO_ROOT / "infra"
DATA_HOME = Path.home() / ".local" / "share" / "jarvis"

DATA_SUBDIRS = ["logs", "state", "context", "inbox", "results", "rag", "data"]


# ═══════════════════════════════════════════
#  Output helpers (emoji + indentation)
# ═══════════════════════════════════════════

def print_header(msg):
    print(f"\n{'=' * 50}")
    print(f"  {msg}")
    print(f"{'=' * 50}")


def print_step(emoji, msg):
    print(f"\n  {emoji} {msg}")


def print_ok(msg):
    print(f"    ✅ {msg}")


def print_fail(msg):
    print(f"    ❌ {msg}")


def print_info(msg):
    print(f"    ℹ️  {msg}")


def print_warn(msg):
    print(f"    ⚠️  {msg}")


def print_skip(msg):
    print(f"    ⏭️  {msg}")


def ask_yes_no(prompt, default=True):
    """Ask a yes/no question. Returns bool."""
    suffix = " [Y/n]: " if default else " [y/N]: "
    try:
        answer = input(f"    ❓ {prompt}{suffix}").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return default
    if not answer:
        return default
    return answer in ("y", "yes")


def ask_input(prompt, required=True, secret=False):
    """Ask for text input. Returns string or None."""
    try:
        value = input(f"    📝 {prompt}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return None
    if required and not value:
        print_fail("This field is required.")
        return ask_input(prompt, required=required, secret=secret)
    return value or None


# ═══════════════════════════════════════════
#  Step 1: Check Node.js >= 18
# ═══════════════════════════════════════════

def check_node():
    """Check Node.js >= 18 is installed."""
    print_step("📦", "Checking Node.js...")
    node = shutil.which("node")
    if not node:
        print_fail("Node.js not found. Install from https://nodejs.org/ (v18+)")
        return False

    try:
        version_output = subprocess.check_output(
            [node, "--version"], text=True
        ).strip()
        major = int(version_output.lstrip("v").split(".")[0])
        if major < 18:
            print_fail(f"Node.js {version_output} found, but v18+ required.")
            return False
        print_ok(f"Node.js {version_output}")
        return True
    except Exception as e:
        print_fail(f"Failed to check Node.js version: {e}")
        return False


# ═══════════════════════════════════════════
#  Step 2: Check Ollama running
# ═══════════════════════════════════════════

def check_ollama():
    """Check Ollama is running."""
    print_step("🦙", "Checking Ollama...")

    try:
        import urllib.request

        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=5) as resp:
            json.loads(resp.read())
    except Exception:
        print_fail("Ollama not running. Start it: ollama serve")
        return False

    print_ok("Ollama is running")
    return True


# ═══════════════════════════════════════════
#  Step 3: Install Discord bot deps
# ═══════════════════════════════════════════

def install_discord_deps():
    """Run npm install in infra/discord/."""
    print_step("📥", "Installing Discord bot dependencies...")

    discord_dir = INFRA_DIR / "discord"
    if not (discord_dir / "package.json").exists():
        print_fail(f"infra/discord/package.json not found at {discord_dir}")
        return False

    npm = shutil.which("npm")
    if not npm:
        print_fail("npm not found. It should come with Node.js.")
        return False

    try:
        subprocess.run(
            [npm, "install"],
            cwd=str(discord_dir),
            check=True,
            timeout=300,
        )
        print_ok("Dependencies installed (infra/discord/node_modules/)")
        return True
    except subprocess.TimeoutExpired:
        print_fail("npm install timed out (5 min limit).")
        return False
    except subprocess.CalledProcessError as e:
        print_fail(f"npm install failed (exit {e.returncode})")
        return False


# ═══════════════════════════════════════════
#  Step 4: Create data directories
# ═══════════════════════════════════════════

def create_data_dirs():
    """Create ~/.local/share/jarvis/ and subdirectories."""
    print_step("📁", "Creating data directories...")

    created = []
    for subdir in DATA_SUBDIRS:
        path = DATA_HOME / subdir
        if not path.exists():
            path.mkdir(parents=True, exist_ok=True)
            created.append(subdir)

    # Also ensure config dir exists
    config_dir = DATA_HOME / "config"
    if not config_dir.exists():
        config_dir.mkdir(parents=True, exist_ok=True)
        created.append("config")

    if created:
        print_ok(f"Created: {DATA_HOME}/")
        for d in created:
            print(f"      📂 {d}/")
    else:
        print_ok(f"All directories already exist: {DATA_HOME}/")


# ═══════════════════════════════════════════
#  Step 5: Generate .env file
# ═══════════════════════════════════════════

def generate_env_file():
    """Ask user for tokens and write .env file."""
    print_step("🔑", "Generating .env file...")

    env_path = DATA_HOME / ".env"

    if env_path.exists():
        print_info(f".env already exists at {env_path}")
        if not ask_yes_no("Overwrite existing .env?", default=False):
            print_skip("Keeping existing .env")
            return

    print_info("Enter credentials (required for Discord bot + Claude integration)")

    discord_token = ask_input("DISCORD_TOKEN", required=True)
    if not discord_token:
        print_fail("DISCORD_TOKEN is required. Skipping .env generation.")
        return

    anthropic_key = ask_input("ANTHROPIC_API_KEY", required=True)
    if not anthropic_key:
        print_fail("ANTHROPIC_API_KEY is required. Skipping .env generation.")
        return

    env_content = (
        "# Jarvis Infrastructure Environment\n"
        f"# Generated by setup_infra.py\n"
        f"\n"
        f"DISCORD_TOKEN={discord_token}\n"
        f"ANTHROPIC_API_KEY={anthropic_key}\n"
        f"\n"
        f"# Data home\n"
        f"BOT_HOME={DATA_HOME}\n"
    )

    env_path.write_text(env_content)
    env_path.chmod(0o600)
    print_ok(f".env written to {env_path} (permissions: 600)")


# ═══════════════════════════════════════════
#  Step 6: Copy config templates
# ═══════════════════════════════════════════

def copy_config_templates():
    """Copy infra/config/*.example.json → ~/.local/share/jarvis/config/ (without .example)."""
    print_step("⚙️", "Copying config templates...")

    src_dir = INFRA_DIR / "config"
    dst_dir = DATA_HOME / "config"
    dst_dir.mkdir(parents=True, exist_ok=True)

    if not src_dir.exists():
        print_warn(f"Config source not found: {src_dir}")
        return

    # Look for *.example.json files
    examples = list(src_dir.glob("*.example.json"))

    if not examples:
        # Fall back: copy all .json files as templates (skip if dest exists)
        examples = list(src_dir.glob("*.json"))
        if not examples:
            print_info("No config templates found in infra/config/")
            return

        copied = 0
        skipped = 0
        for src in examples:
            dst = dst_dir / src.name
            if dst.exists():
                skipped += 1
                continue
            shutil.copy2(str(src), str(dst))
            copied += 1

        if copied:
            print_ok(f"Copied {copied} config file(s) to {dst_dir}/")
        if skipped:
            print_skip(f"Skipped {skipped} existing config(s)")
        return

    copied = 0
    skipped = 0
    for src in examples:
        # Remove .example from filename: foo.example.json → foo.json
        dst_name = src.name.replace(".example", "")
        dst = dst_dir / dst_name
        if dst.exists():
            skipped += 1
            continue
        shutil.copy2(str(src), str(dst))
        copied += 1

    if copied:
        print_ok(f"Copied {copied} config template(s) to {dst_dir}/")
    if skipped:
        print_skip(f"Skipped {skipped} existing config(s)")


# ═══════════════════════════════════════════
#  Step 7: Install cron jobs (optional)
# ═══════════════════════════════════════════

def install_cron_jobs():
    """Optionally install cron jobs from template."""
    print_step("⏰", "Cron job setup...")

    crontab_example = INFRA_DIR / "templates" / "crontab.example"

    if not crontab_example.exists():
        print_info("No crontab template found at infra/templates/crontab.example")
        print_skip("Skipping cron setup")
        return

    if not ask_yes_no("Install automated cron jobs?", default=False):
        print_skip("Skipping cron setup")
        return

    # Read and replace placeholders
    template = crontab_example.read_text()
    replacements = {
        "{{REPO_ROOT}}": str(REPO_ROOT),
        "{{INFRA_DIR}}": str(INFRA_DIR),
        "{{DATA_HOME}}": str(DATA_HOME),
        "{{HOME}}": str(Path.home()),
    }
    for placeholder, value in replacements.items():
        template = template.replace(placeholder, value)

    # Show what will be added
    print_info("The following entries will be appended to your crontab:")
    print()
    for line in template.strip().splitlines():
        print(f"      {line}")
    print()

    if not ask_yes_no("Proceed with cron installation?", default=False):
        print_skip("Cron installation cancelled")
        return

    try:
        # Get current crontab
        result = subprocess.run(
            ["crontab", "-l"],
            capture_output=True,
            text=True,
        )
        current = result.stdout if result.returncode == 0 else ""

        # Append new entries
        marker = "# --- Jarvis Infra (auto-generated) ---"
        if marker in current:
            print_warn("Jarvis cron entries already exist. Remove them manually first.")
            print_info("  Run: crontab -e")
            return

        new_crontab = (
            f"{current.rstrip()}\n\n"
            f"{marker}\n"
            f"{template.strip()}\n"
            f"# --- End Jarvis Infra ---\n"
        )

        proc = subprocess.run(
            ["crontab", "-"],
            input=new_crontab,
            text=True,
            check=True,
        )
        print_ok("Cron jobs installed")
    except Exception as e:
        print_fail(f"Failed to install cron jobs: {e}")


# ═══════════════════════════════════════════
#  Step 8: Install LaunchAgents (macOS only)
# ═══════════════════════════════════════════

LAUNCH_AGENTS = [
    "ai.jarvis.discord-bot",
    "ai.jarvis.watchdog",
    "ai.jarvis.rag-watcher",
]


def install_launch_agents():
    """Install macOS LaunchAgents (optional, macOS only)."""
    if platform.system() != "Darwin":
        print_step("🍎", "LaunchAgent setup... (skipped: not macOS)")
        return

    print_step("🍎", "LaunchAgent setup (macOS)...")

    templates_dir = INFRA_DIR / "templates" / "launchagents"
    agents_dir = Path.home() / "Library" / "LaunchAgents"
    agents_dir.mkdir(parents=True, exist_ok=True)

    # Check if plist templates exist
    available = []
    for name in LAUNCH_AGENTS:
        plist_src = templates_dir / f"{name}.plist"
        if plist_src.exists():
            available.append((name, plist_src))

    if not available:
        print_info(f"No LaunchAgent templates found in {templates_dir}/")
        print_info("Expected files: " + ", ".join(f"{n}.plist" for n in LAUNCH_AGENTS))
        print_skip("Skipping LaunchAgent setup")
        return

    if not ask_yes_no(
        f"Install {len(available)} LaunchAgent(s)? ({', '.join(n for n, _ in available)})",
        default=False,
    ):
        print_skip("Skipping LaunchAgent setup")
        return

    installed = 0
    for name, src in available:
        dst = agents_dir / f"{name}.plist"

        if dst.exists():
            print_skip(f"{name} already installed")
            continue

        # Read, replace placeholders, write
        content = src.read_text()
        content = content.replace("{{REPO_ROOT}}", str(REPO_ROOT))
        content = content.replace("{{INFRA_DIR}}", str(INFRA_DIR))
        content = content.replace("{{DATA_HOME}}", str(DATA_HOME))
        content = content.replace("{{HOME}}", str(Path.home()))

        dst.write_text(content)
        print_ok(f"Installed {dst}")

        # Load the agent
        try:
            subprocess.run(
                ["launchctl", "load", str(dst)],
                check=True,
                capture_output=True,
            )
            print_ok(f"Loaded {name}")
            installed += 1
        except subprocess.CalledProcessError:
            print_warn(f"Could not load {name}. Load manually: launchctl load {dst}")

    if installed:
        print_ok(f"{installed} LaunchAgent(s) installed and loaded")


# ═══════════════════════════════════════════
#  Step 9: Verify setup
# ═══════════════════════════════════════════

def verify_setup():
    """Run verification checks and print summary."""
    print_step("🔍", "Verifying setup...")

    checks = []

    # Check Discord bot deps
    discord_modules = INFRA_DIR / "discord" / "node_modules"
    if discord_modules.exists():
        print_ok("Discord bot dependencies installed")
        checks.append(("Discord deps", True))
    else:
        print_fail("Discord bot node_modules/ missing")
        checks.append(("Discord deps", False))

    # Check Discord bot can parse (syntax check)
    node = shutil.which("node")
    bot_js = INFRA_DIR / "discord" / "discord-bot.js"
    if node and bot_js.exists():
        try:
            result = subprocess.run(
                [node, "--check", str(bot_js)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                print_ok("Discord bot syntax OK")
                checks.append(("Bot syntax", True))
            else:
                print_warn(f"Bot syntax check failed: {result.stderr[:200]}")
                checks.append(("Bot syntax", False))
        except Exception as e:
            print_warn(f"Could not verify bot: {e}")
            checks.append(("Bot syntax", False))

    # Check data dirs
    all_dirs_ok = all((DATA_HOME / d).is_dir() for d in DATA_SUBDIRS)
    if all_dirs_ok:
        print_ok(f"Data directories present: {DATA_HOME}/")
        checks.append(("Data dirs", True))
    else:
        missing = [d for d in DATA_SUBDIRS if not (DATA_HOME / d).is_dir()]
        print_warn(f"Missing data dirs: {', '.join(missing)}")
        checks.append(("Data dirs", False))

    # Check .env
    env_path = DATA_HOME / ".env"
    if env_path.exists():
        print_ok(f".env file present: {env_path}")
        checks.append((".env", True))
    else:
        print_warn(f".env not found at {env_path}")
        checks.append((".env", False))

    return checks


# ═══════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════

def main():
    print_header("🏗️  Jarvis Infrastructure Setup Wizard")
    print(f"  📍 Repo root: {REPO_ROOT}")
    print(f"  📍 Data home: {DATA_HOME}")

    # ── Prerequisites ──
    if not check_node():
        print("\n⛔ Setup aborted. Install Node.js 18+ first.")
        sys.exit(1)

    if not check_ollama():
        print("\n⛔ Setup aborted. Start Ollama first: ollama serve")
        sys.exit(1)

    # ── Core setup ──
    if not install_discord_deps():
        print("\n⛔ Setup aborted. Fix npm install issues first.")
        sys.exit(1)

    create_data_dirs()
    generate_env_file()
    copy_config_templates()

    # ── Optional: cron + LaunchAgents ──
    install_cron_jobs()
    install_launch_agents()

    # ── Verify ──
    checks = verify_setup()

    # ── Summary ──
    passed = sum(1 for _, ok in checks if ok)
    total = len(checks)

    print_header(f"🏁 Setup Complete — {passed}/{total} checks passed")
    print()
    for name, ok in checks:
        icon = "✅" if ok else "❌"
        print(f"    {icon} {name}")
    print()

    print("  🚀 Next steps:")
    print(f"     1. Review .env:  cat {DATA_HOME}/.env")
    print(f"     2. Start bot:    cd {INFRA_DIR}/discord && node discord-bot.js")
    print(f"     3. Check status: python {REPO_ROOT}/scripts/setup_infra.py --verify")
    print()


if __name__ == "__main__":
    # Quick --verify flag: only run verification
    if len(sys.argv) > 1 and sys.argv[1] == "--verify":
        print_header("🔍 Jarvis Infrastructure Verification")
        checks = verify_setup()
        passed = sum(1 for _, ok in checks if ok)
        total = len(checks)
        print(f"\n  {'✅' if passed == total else '⚠️'}  {passed}/{total} checks passed\n")
        sys.exit(0 if passed == total else 1)

    main()
