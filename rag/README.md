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
User query
    |
    v
[Python: ragSearch tool]
    |  subprocess call
    v
[Node.js: rag-query.mjs]
    |
    +-- [Insight DB search] ← 2nd-layer semantic memory
    |       query와 관련된 상위 수준 인사이트 주입
    |       (예: "사용자가 이직 준비 중")
    |
    +-- [rag-engine.mjs]
    |       BM25 full-text search (primary, free)
    |       Vector similarity (Ollama snowflake-arctic-embed2, 1024-dim)
    |       Reciprocal Rank Fusion (RRF, k=60)
    |
    v
[LanceDB]
    |-- documents.lance  ← 1차: 원본 청크 벡터
    |-- insights.lance   ← 2차: LLM 추론 인사이트
```

### Insight DB (2nd-layer Memory)

기존 RAG는 문서 청크를 벡터로 저장할 뿐, "이 사람이 지금 무엇을 하고 있는지"는 추론하지 못합니다. Insight DB는 이 문제를 해결합니다.

**작동 원리:**

1. `insight-distill.mjs` (매일 04:00 크론)가 entity-graph 클러스터 + 대화 요약을 수집
2. Ollama LLM이 상위 수준 인사이트를 추출 (예: "사용자가 이직을 준비하고 있다")
3. 인사이트를 벡터 임베딩과 함께 `insights.lance` 테이블에 저장
4. 쿼리 시 `rag-query.mjs`가 관련 인사이트를 벡터 유사도로 검색하여 RAG 결과 앞에 주입

**필터링:** 쿼리와 무관한 인사이트는 L2 거리 임계값(1.2) + 신뢰도 임계값(0.5)으로 자동 필터링되어 노이즈를 방지합니다.

**인사이트 카테고리:** `life_phase` | `goal` | `interest` | `skill` | `routine` | `concern`

**생명주기:** 인사이트는 30일 TTL로 자동 만료되며, 다음 distill에서 갱신(supersede)됩니다.

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

# Search (insights + RAG chunks)
npm run query -- "your search query"

# Stats
npm run stats

# Insight distillation (extract high-level insights from chunks)
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
