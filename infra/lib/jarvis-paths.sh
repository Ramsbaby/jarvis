#!/usr/bin/env bash
# jarvis-paths.sh — ~/.jarvis 경로 SSoT (shell 버전)
#
# 왜 이 파일이 존재하는가:
#   BOT_HOME/JARVIS_HOME/HOME/.jarvis 3가지 패턴이 60+개 스크립트에 혼재했다.
#   macOS 기본값도 ~/.local/share/jarvis(Linux/Docker용) vs ~/.jarvis(macOS)가
#   스크립트마다 달라 인터랙티브 실행 시 wrong path 버그가 반복됐다.
#
# 사용법:
#   source "$(dirname "${BASH_SOURCE[0]}")/jarvis-paths.sh"
#   # 이후 BOT_HOME, CRON_LOG, TASKS_JSON 등을 사용
#
# 환경 변수 우선순위:
#   1. BOT_HOME    — LaunchAgent plist EnvironmentVariables 에서 주입 (런타임)
#   2. JARVIS_HOME — Docker/CI override
#   3. ~/.jarvis   — macOS 기본값 (이 시스템의 실제 경로)

# ── Root ─────────────────────────────────────────────────────────────────────
export BOT_HOME="${BOT_HOME:-${JARVIS_HOME:-${HOME}/jarvis/runtime}}"

# ── Logs ─────────────────────────────────────────────────────────────────────
export JARVIS_LOGS_DIR="${BOT_HOME}/logs"
export JARVIS_CRON_LOG="${BOT_HOME}/logs/cron.log"
export JARVIS_RAG_INDEX_LOG="${BOT_HOME}/logs/rag-index.log"

# ── Config ───────────────────────────────────────────────────────────────────
export JARVIS_TASKS_JSON="${BOT_HOME}/config/tasks.json"

# ── State ────────────────────────────────────────────────────────────────────
export JARVIS_STATE_DIR="${BOT_HOME}/state"
export JARVIS_CB_DIR="${BOT_HOME}/state/circuit-breaker"
export JARVIS_BOARD_MINUTES_DIR="${BOT_HOME}/state/board-minutes"
export JARVIS_COMMITMENTS="${BOT_HOME}/state/commitments.jsonl"

# ── Results ──────────────────────────────────────────────────────────────────
export JARVIS_RESULTS_DIR="${BOT_HOME}/results"

# ── RAG ──────────────────────────────────────────────────────────────────────
export JARVIS_RAG_DIR="${BOT_HOME}/rag"
export JARVIS_RAG_DATA="${BOT_HOME}/rag/data"