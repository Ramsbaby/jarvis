#!/usr/bin/env python3
"""
🧠 RAG Setup Wizard for Jarvis

Sets up the optional RAG (Retrieval-Augmented Generation) module
that gives Jarvis long-term knowledge base search capabilities.

Prerequisites:
  - Node.js 18+
  - Ollama running locally with snowflake-arctic-embed2 model
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def print_step(emoji, msg):
    print(f"\n  {emoji} {msg}")


def print_ok(msg):
    print(f"    ✅ {msg}")


def print_fail(msg):
    print(f"    ❌ {msg}")


def print_info(msg):
    print(f"    ℹ️  {msg}")


def check_node():
    """Check Node.js >= 18 is installed."""
    print_step("📦", "Checking Node.js...")
    node = shutil.which("node")
    if not node:
        print_fail("Node.js not found. Install from https://nodejs.org/ (v18+)")
        return False

    try:
        version_output = subprocess.check_output([node, "--version"], text=True).strip()
        major = int(version_output.lstrip("v").split(".")[0])
        if major < 18:
            print_fail(f"Node.js {version_output} found, but v18+ is required.")
            return False
        print_ok(f"Node.js {version_output}")
        return True
    except Exception as e:
        print_fail(f"Failed to check Node.js version: {e}")
        return False


def check_ollama():
    """Check Ollama is running and has the embedding model."""
    print_step("🦙", "Checking Ollama...")

    try:
        import urllib.request
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            models = [m.get("name", "") for m in data.get("models", [])]
    except Exception:
        print_fail("Ollama not running. Start it: ollama serve")
        return False

    print_ok("Ollama is running")

    # Check for embedding model
    embed_model = "snowflake-arctic-embed2"
    has_embed = any(embed_model in m for m in models)

    if not has_embed:
        print_info(f"Embedding model '{embed_model}' not found. Pulling...")
        try:
            subprocess.run(
                ["ollama", "pull", embed_model],
                check=True,
                timeout=600,
            )
            print_ok(f"Model '{embed_model}' installed")
        except subprocess.TimeoutExpired:
            print_fail(f"Timed out pulling {embed_model}. Try manually: ollama pull {embed_model}")
            return False
        except Exception as e:
            print_fail(f"Failed to pull {embed_model}: {e}")
            return False
    else:
        print_ok(f"Embedding model '{embed_model}' available")

    return True


def install_npm_deps():
    """Run npm install in the rag/ directory."""
    print_step("📥", "Installing RAG dependencies...")

    rag_dir = Path(__file__).resolve().parent.parent / "rag"
    if not (rag_dir / "package.json").exists():
        print_fail(f"rag/package.json not found at {rag_dir}")
        return False

    try:
        npm = shutil.which("npm")
        if not npm:
            print_fail("npm not found. It should come with Node.js.")
            return False

        subprocess.run(
            [npm, "install"],
            cwd=str(rag_dir),
            check=True,
            timeout=300,
        )
        print_ok("Dependencies installed (rag/node_modules/)")
        return True
    except subprocess.TimeoutExpired:
        print_fail("npm install timed out.")
        return False
    except subprocess.CalledProcessError as e:
        print_fail(f"npm install failed: {e}")
        return False


def create_data_dir():
    """Create the RAG data directory."""
    print_step("📁", "Creating RAG data directory...")

    rag_home = os.environ.get("JARVIS_RAG_HOME")
    bot_home = os.environ.get("BOT_HOME")

    if rag_home:
        data_dir = Path(rag_home)
    elif bot_home:
        data_dir = Path(bot_home) / "rag"
    else:
        data_dir = Path.home() / ".local" / "share" / "jarvis" / "rag"

    data_dir.mkdir(parents=True, exist_ok=True)
    print_ok(f"Data directory: {data_dir}")
    return str(data_dir)


def enable_rag_config():
    """Set rag_enabled: true in the Jarvis config."""
    print_step("⚙️", "Enabling RAG in config...")

    config_path = None
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        config_path = Path(xdg) / "jarvis" / "config.json"
    else:
        config_path = Path.home() / ".config" / "jarvis" / "config.json"

    if not config_path.exists():
        print_info(f"Config file not found at {config_path}. Creating with RAG enabled.")
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config = {"rag_enabled": True}
    else:
        try:
            config = json.loads(config_path.read_text())
        except Exception:
            config = {}
        config["rag_enabled"] = True

    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    print_ok(f"rag_enabled: true in {config_path}")


def verify_rag():
    """Run rag-stats to verify everything works."""
    print_step("🔍", "Verifying RAG setup...")

    rag_dir = Path(__file__).resolve().parent.parent / "rag"
    node = shutil.which("node")

    try:
        result = subprocess.run(
            [node, str(rag_dir / "bin" / "rag-stats.mjs"), "--json"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(rag_dir),
        )
        if result.returncode == 0:
            try:
                stats = json.loads(result.stdout)
                if stats.get("dbExists"):
                    print_ok(f"RAG DB found: {stats.get('totalChunks', 0)} chunks, {stats.get('totalSources', 0)} sources")
                else:
                    print_info("RAG DB not yet created. It will be created on first indexing run.")
                    print_info(f"  Run: bash {rag_dir / 'bin' / 'rag-index-safe.sh'}")
            except json.JSONDecodeError:
                print_ok("rag-stats ran successfully")
        else:
            print_info(f"rag-stats exited with code {result.returncode}")
            if result.stderr:
                print_info(f"  stderr: {result.stderr[:200]}")
        return True
    except Exception as e:
        print_fail(f"Verification failed: {e}")
        return False


def main():
    print("\n🧠 Jarvis RAG Setup Wizard")
    print("=" * 40)

    # Step 1: Check prerequisites
    if not check_node():
        print("\n⛔ Setup aborted. Install Node.js 18+ first.")
        sys.exit(1)

    if not check_ollama():
        print("\n⛔ Setup aborted. Start Ollama first.")
        sys.exit(1)

    # Step 2: Install dependencies
    if not install_npm_deps():
        print("\n⛔ Setup aborted. Fix npm install issues first.")
        sys.exit(1)

    # Step 3: Create data directory
    data_dir = create_data_dir()

    # Step 4: Enable in config
    enable_rag_config()

    # Step 5: Verify
    verify_rag()

    # Done
    print("\n" + "=" * 40)
    print("✅ RAG setup complete!")
    print()
    print("  📚 To index your first documents:")
    rag_dir = Path(__file__).resolve().parent.parent / "rag"
    print(f"     bash {rag_dir / 'bin' / 'rag-index-safe.sh'}")
    print()
    print("  🔄 For automated indexing, see:")
    print(f"     {rag_dir / 'templates' / 'crontab-rag.example'}")
    print()


if __name__ == "__main__":
    main()
