# Jarvis RAG Module

Optional long-term knowledge base for Jarvis. Adds semantic search across documents, decisions, session transcripts, and notes using **LanceDB** + **Ollama embeddings**.

## Quick Start

```bash
# From the jarvis repo root
python scripts/setup_rag.py
```

The wizard checks prerequisites, installs dependencies, and enables RAG.

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| **Node.js** | 18+ | RAG engine runtime |
| **Ollama** | latest | Local embedding generation |

The embedding model (`snowflake-arctic-embed2`) is auto-installed by the setup wizard.

## Architecture

```
User query (Discord / Cron task)
    │
    ├── [Static context: insight-report.md]     ← Insight Layer
    │       매일 자동 생성되는 행동 메트릭 + 상황 인사이트
    │       항상 system prompt에 포함 (~1.2KB)
    │
    ├── [Dynamic context: rag-query.mjs]        ← RAG Layer
    │       BM25 + Vector hybrid search (RRF k=60)
    │       쿼리별 관련 청크 5-10개 반환
    │
    └── [LanceDB: documents.lance]
            snowflake-arctic-embed2 (1024-dim, multilingual)
```

### Insight Layer — 자동 상황 인식

매일 04:15 크론으로 사용자의 행동 패턴을 분석하여 1페이지 리포트를 생성합니다.

**2단계 파이프라인:**

| 단계 | 스크립트 | LLM | 비용 |
|------|---------|:---:|:----:|
| **Layer 1: 메트릭 수집** | `insight-metrics.mjs` | 불필요 | $0 |
| **Layer 2: 해석** | `insight-distill.mjs` | Claude | ~$0.03/회 |

**Layer 1** (LLM 없이 순수 데이터 분석):
- 토픽 빈도 변화율 (예: "커리어 토픽 534배 급증")
- 도메인별 활동 추세 (예: "인프라 하락 + 커리어 급등 = focus shift")
- 엔티티 모멘텀 (예: "Company-A, Company-B 급상승 = 경력 재정리 중")
- 일별 활동 히트맵

**Layer 2** (Claude가 숫자를 해석):
- 메트릭 + Google Calendar 일정 + 대화 요약을 Claude에 전달
- "이 숫자들이 왜 이렇게 변하고 있는가?" 해석
- 결과를 `~/.jarvis/context/insight-report.md`에 저장

**소비 경로:**
- `context-loader.sh`가 매 요청마다 자동 로드 → system prompt에 항상 포함
- Discord 봇, 크론 태스크 모두에서 Claude가 사용자의 현재 상황을 파악한 채 응답

## Indexing

Place `.md` files in your configured data directory, then:

```bash
bash rag/bin/rag-index-safe.sh
```

For automated indexing, copy the cron template:

```bash
cat rag/templates/crontab-rag.example
# Edit paths, then: crontab -e
```

## Configuration

RAG settings in `~/.config/jarvis/config.json`:

```json
{
  "rag_enabled": true,
  "rag_search_limit": 5,
  "rag_search_timeout_sec": 10.0
}
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `JARVIS_RAG_HOME` | (see below) | RAG data directory |
| `BOT_HOME` | `~/.local/share/jarvis` | Infrastructure home |

**Data directory priority**: `JARVIS_RAG_HOME` > `BOT_HOME/rag` > `~/.local/share/jarvis/rag`

## CLI Tools

```bash
cd rag

# Search
npm run query -- "your search query"

# Stats
npm run stats

# Insight metrics (no LLM, pure data analysis)
node bin/insight-metrics.mjs

# Insight distillation (metrics + Claude interpretation → .md report)
node bin/insight-distill.mjs

# Compact (reclaim space from deleted chunks)
npm run compact

# Repair (deduplicate stale chunks)
npm run repair -- --dry-run
```

## Troubleshooting

<details>
<summary>npm install fails on lancedb</summary>

LanceDB uses native Node addons. Ensure you have build tools:
- macOS: `xcode-select --install`
- Linux: `apt install build-essential`
- Windows: Install Visual Studio Build Tools

</details>

<details>
<summary>Embedding errors (Ollama)</summary>

```bash
# Check Ollama is running
curl http://localhost:11434/api/ps

# Check model is installed
ollama list | grep snowflake

# Pull if missing
ollama pull snowflake-arctic-embed2
```

</details>

<details>
<summary>RAG search returns no results</summary>

1. Check DB exists: `npm run stats`
2. If no DB, run indexing: `bash bin/rag-index-safe.sh`
3. Check logs: `cat ~/.local/share/jarvis/logs/rag-index.log`

</details>

<details>
<summary>Insight report not generated</summary>

```bash
# Manual run
BOT_HOME=~/.jarvis node rag/bin/insight-distill.mjs

# Check if metrics work (no LLM needed)
BOT_HOME=~/.jarvis node rag/bin/insight-metrics.mjs

# Verify report exists
cat ~/.jarvis/context/insight-report.md
```

</details>
