#!/usr/bin/env bash
# jarvis-paths.sh — 경로 SSoT (shell 버전)
#
# 왜 이 파일이 존재하는가:
#   BOT_HOME/JARVIS_HOME/HOME/.jarvis 3가지 패턴이 60+개 스크립트에 혼재했다.
#   A2 마이그레이션(2026-04-17) 이후 런타임 경로는 ~/jarvis/runtime 단일 기준.
#   구버전 경로(~/.jarvis, ~/.local/share/jarvis)는 호환성 심링크로만 유지됨.
#
# 사용법:
#   source "$(dirname "${BASH_SOURCE[0]}")/jarvis-paths.sh"
#   # 이후 BOT_HOME, CRON_LOG, TASKS_JSON 등을 사용
#
# 환경 변수 우선순위:
#   1. BOT_HOME    — LaunchAgent plist EnvironmentVariables 에서 주입 (런타임)
#   2. JARVIS_HOME — Docker/CI override
#   3. ~/jarvis/runtime — A2 마이그레이션 이후 기본값

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