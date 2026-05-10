#!/usr/bin/env bash
# recon-run.sh — 정보탐험대 주간 실행 래퍼
# Usage: recon-run.sh
# Cron: 0 9 * * 1 (매주 월요일 09:00)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
CRON_LOG="$BOT_HOME/logs/cron.log"
ASK_CLAUDE="$BOT_HOME/bin/ask-claude.sh"

log() {
    echo "[$(date '+%F %T')] [recon-run] $1" | tee -a "$CRON_LOG"
}

if [[ ! -f "$ASK_CLAUDE" ]]; then
    log "ERROR: ask-claude.sh not found: $ASK_CLAUDE"
    exit 1
fi

log "START — 정보탐험대 주간 실행"

# recon 팀의 정보탐험 프롬프트
PROMPT="정보탐험대 주간 리포트 생성:

AI/기술/시장/정책 분야의 중요 정보를 탐험하고 정리해서 주간 리포트를 작성해주세요.

**작성 포맷:**
## 🔍 주간 정보탐험 리포트

### 1️⃣ AI/LLM 동향 (5건 이상)
- 주요 발표/릴리스/뉴스 중심
- 각 항목: 제목, 날짜, 한 줄 요약

### 2️⃣ 기술 트렌드 (5건 이상)
- 개발 커뮤니티, GitHub, 기술 뉴스
- 각 항목: 기술명, 주목 이유, 한 줄 요약

### 3️⃣ 시장/정책 동향 (5건 이상)
- 테크 시장, 규제 정책, M&A
- 각 항목: 사건명, 영향도, 한 줄 요약

### 4️⃣ 한국 관련 정보 (3건 이상)
- 한국 스타트업, 투자, 기술 정책
- 각 항목: 주제, 중요도, 한 줄 요약

모든 항목은 출처(URL, 보도사)를 기재해주세요. 감정 표현 없이 객관적으로 작성하세요.

## 보고서 품질 루브릭 (감사팀 자동 평가 기준)
보고서 본문 작성 완료 후 아래 4개 항목을 자가 체크하여 보고서 **마지막 줄**에 다음 형식으로 반드시 표기할 것:
\`루브릭: N/4 | ✅R1 ✅R2 ✅R3 ✅R4\`

- **[R1]** 4개 섹션(AI/LLM, 기술 트렌드, 시장/정책, 한국) 각 3건 이상 항목 포함
- **[R2]** 모든 항목에 출처(URL 또는 보도사) 기재 (1건 누락이라도 ❌)
- **[R3]** 감정/주관적 표현 0건 — 객관적 서술만 (\"놀랍게도\", \"대단한\" 등 금지)
- **[R4]** Jarvis 시스템 관련 항목 1건 이상 강조 표기 (\"🎯 Jarvis 주목:\" 태그 사용)

루브릭 4/4이면 감사팀 자동 평가 A등급. 2/4 이하이면 다음 주 재점검 대상."

# ask-claude.sh 실행
# 파라미터: TASK_ID PROMPT ALLOWED_TOOLS TIMEOUT MAX_BUDGET
"$ASK_CLAUDE" \
    "recon-weekly" \
    "$PROMPT" \
    "Read,Write,Bash,WebSearch,Glob,Grep" \
    "900" \
    "3.00"

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS — 정보탐험 완료"
    exit 0
else
    log "FAILED — recon-weekly exited with code $EXIT_CODE"
    exit $EXIT_CODE
fi