FROM node:22-alpine

LABEL maintainer="ramsbaby" \
      description="Jarvis AI 집사 — Discord bot + automation"

# bash, curl, git, jq, dcron (crontab 지원)
RUN apk add --no-cache bash curl git jq dcron

# gtimeout → timeout 심볼릭 링크 (macOS GNU coreutils 호환)
RUN ln -sf /usr/bin/timeout /usr/local/bin/gtimeout

# PM2 글로벌 설치
RUN npm install -g pm2

WORKDIR /jarvis

# 의존성 먼저 복사 (Docker 레이어 캐시 활용)
COPY discord/package*.json ./discord/
RUN cd discord && npm ci --omit=dev

# 전체 소스 복사
COPY . .

# 엔트리포인트 스크립트 복사 및 실행 권한 부여
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 디렉토리 생성
RUN mkdir -p logs inbox rag context state results

ENV JARVIS_HOME=/jarvis \
    NODE_ENV=production

CMD ["/docker-entrypoint.sh"]
