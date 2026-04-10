#!/bin/bash
# docker-entrypoint.sh — Jarvis Docker 컨테이너 시작 스크립트

set -e

# crond 백그라운드 시작 (Alpine dcron 방식)
crond -b -L /jarvis/logs/crond.log 2>/dev/null || echo "[entrypoint] crond 시작 건너뜀"

echo "[entrypoint] PM2 런타임 시작..."
exec pm2-runtime ecosystem.config.cjs
