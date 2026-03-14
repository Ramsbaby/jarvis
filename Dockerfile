FROM node:22-alpine

LABEL maintainer="ramsbaby" \
      description="Jarvis AI 집사 — Discord bot + automation"

# bash, curl, git, jq, dcron (crontab 지원)
RUN apk add --no-cache bash curl git jq dcron

# gtimeout → timeout 심볼릭 링크 (macOS GNU coreutils 호환)
RUN ln -sf /usr/bin/timeout /usr/local/bin/gtimeout

# PM2 + Claude CLI 글로벌 설치
RUN npm install -g pm2 @anthropic-ai/claude-code

WORKDIR /jarvis

# 의존성 먼저 복사 (Docker 레이어 캐시 활용)
COPY discord/package*.json ./discord/
RUN cd discord && npm ci --omit=dev

# 전체 소스 복사
COPY . .

# lib/*.mjs 가 discord/node_modules를 찾을 수 있도록 루트에 심볼릭 링크
# (rag-watch.mjs, rag-engine.mjs 등이 dotenv/chokidar/lancedb 사용)
RUN ln -sf /jarvis/discord/node_modules /jarvis/node_modules

# 엔트리포인트 스크립트 복사 및 실행 권한 부여
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 디렉토리 생성
RUN mkdir -p logs inbox rag context state results

# 런타임 락 디렉토리 초기화 (컨테이너 재시작 시 stale lock 방지)
RUN mkdir -p /tmp/jarvis-locks

ENV JARVIS_HOME=/jarvis \
    NODE_ENV=production

CMD ["/docker-entrypoint.sh"]
