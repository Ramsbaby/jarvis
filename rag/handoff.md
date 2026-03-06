# 세션 인계 노트

> 진행 중인 작업과 다음 세션에서 이어할 것들

## 진행 중
- ROADMAP.md 기반 Phase 2~5 순차 진행

## 다음 세션 (P0 — 즉시)
- [ ] Company DNA 단일 파일 생성 (`~/.jarvis/config/company-dna.md`) — SSoT 위반 해소
- [ ] architecture.md 실제 구현과 동기화 (6건 경로 불일치 수정)
- [ ] README.md 상태 업데이트 ("설계 완료" → "운영 중")
- [ ] obsidian-git 플러그인 설치 (자동 commit/push 활성화)
- [ ] news-briefing, memory-cleanup, token-sync 크론 실행 확인 (내일 스케줄 후)

## 이번 주 (P1)
- [ ] weekly-kpi, monthly-review 크론 추가
- [ ] 자율처리 레벨 문서 작성
- [ ] rag/memory.md 역할 재정의 (user-profile.md와 역할 분리)
- [ ] RAG 커버리지 추가 — reports/(25개), decisions/(3개) 디렉토리 인덱싱
- [ ] rate-limit-check 50% 실패율 원인 조사 (timeout 설정)

## 최근 완료 (2026-03-01)
- Serena MCP Discord bot 연동 (프로젝트 기본, activate_project로 전환)
- 자비스 페르소나 시스템 프롬프트 주입 (영국식 위트, 금지표현, 톤)
- context/*.md 15개 파일 생성 + Company DNA 규칙 반영 (stock-monitor, market-alert 등)
- RAG 인덱싱 확장: 147 sources, 1,591 chunks
- RAG 크론 OPENAI_API_KEY 오류 수정 (dotenv 로딩 추가)
- Serena MCP 전수 감사 (3개 에이전트): 설정 양호, LSP 정상, 심볼 검색 1~6ms
- Discord bot allowedTools에 activate_project, find_referencing_code_snippets 추가
- web_dashboard_open_on_launch: false 변경
- ROADMAP.md 종합 로드맵 문서 작성
- E2E 테스트 27/27 PASS
