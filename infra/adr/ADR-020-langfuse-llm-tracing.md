# ADR-020: Langfuse 자체 호스팅 — LLM 옵저버빌리티

## 상태
ACCEPTED (2026-03-31)

## 배경

Jarvis는 하루 수백 건의 LLM 호출(llm-gateway, Discord bot, Board API)을 실행하지만 다음이 불투명하다:
- 어떤 태스크가 얼마만큼의 토큰/비용을 쓰는가
- 프롬프트 품질이 시간에 따라 나빠지거나 좋아지는가
- 어떤 에이전트가 실패율이 높은가

## 결정

**Langfuse v2** (오픈소스)를 Mac Mini에 Docker Compose로 자체 호스팅한다.
- 포트: `3200` (board=3100, dashboard=3000과 충돌 없음)
- 데이터: named volume `langfuse-db-data` (PostgreSQL 15)
- 관리: `langfuse-ctl.sh` + `ai.jarvis.langfuse` LaunchAgent

### 트레이싱 계층

| 레이어 | 파일 | 방식 |
|--------|------|------|
| bash (llm-gateway) | `lib/langfuse-trace.sh` | HTTP API (fire & forget, `& disown`) |
| Node.js (Discord bot) | `discord/lib/langfuse-client.mjs` | `langfuse` npm SDK |
| Node.js (Board API) | `dashboard` 미통합 (Groq 직접 호출, 별도 고려) | — |

### 보안

- API 키(`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`)는 `docker/langfuse/.env`에 저장, chmod 600
- Langfuse UI는 localhost:3200 전용 (Cloudflare 터널 미노출)
- `TELEMETRY_ENABLED=false` — Langfuse 본사로 사용 데이터 전송 차단

## 대안 검토

| 옵션 | 이유 기각 |
|------|----------|
| Langfuse Cloud | 외부 SaaS — 프롬프트/응답 내용이 외부로 전송됨. 프라이버시 위험 |
| Langfuse v3 | ClickHouse + MinIO 필요 — Mac Mini 단일 노드에 과도한 오버헤드 |
| Helicone self-hosted | Langfuse 대비 커뮤니티 작음, 한국어 문서 없음 |
| 직접 구현 (SQLite) | 이미 있는 task-store.mjs로 감당 불가. 시각화 없음 |

## 결과

- 매 `llm_call()` 완료 시 trace → generation 자동 기록 (모델, 토큰, 비용, 지속시간)
- `langfuse-report.sh` 주간 리포트로 Discord 전송 (P3-3 구현)
- Langfuse UI: http://localhost:3200

## 관련 ADR

- ADR-006: LLM Gateway Multi-Provider (tracing이 gateway에 후크)
- ADR-019: Self-healing Degraded Mode (L3 진입 시 trace로 원인 추적 가능)
