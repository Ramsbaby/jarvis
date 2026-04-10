# ADR-018: 병렬 멀티에이전트 오케스트레이션 패턴

## 상태
ACCEPTED (2026-03-31)
구현 완료: 2026-03-31

## 컨텍스트
현재 Jarvis는 Discord 이벤트 → 단일 에이전트 → 결과 구조.
Task #15에서 병렬 멀티에이전트 패턴으로 전환 예정.

## 결정
Claude Code 서브에이전트 패턴 채택:
- 파일 소유권 원칙: 1파일 = 1에이전트 동시 수정 금지
- Research/Code/Validation 에이전트 역할 분리
- ~/.claude/commands/ 에 오케스트레이터 슬래시 명령어 추가

## 구현 계획
1. ~/.claude/commands/orchestrate.md 신설
2. Research Agent: brave-search + sequential-thinking
3. Code Agent: serena + github
4. Validation Agent: Bash 실행 + 결과 검증
5. Synthesizer: 3개 결과 병합 → 최종 응답

## 트레이드오프
- 장점: 독립 태스크 병렬 처리로 속도 3-5x
- 단점: 에이전트 간 컨텍스트 공유 복잡성

## 구현 완료 내역 (2026-03-31)
- `~/.claude/commands/orchestrate.md` 신설 (Task #15 완료)
- 구성: 태스크 분석 → 파일 소유권 체크 → 병렬 실행 → 결과 합성 4단계
- Research Agent: brave-search + WebFetch, 결과 /tmp/research-result.md 저장
- Code Agent: serena + 파일 편집, 1파일=1에이전트 원칙 준수
- Validation Agent: Bash 실행 + 결과 검증
- 부적합 태스크 필터 기준 명시 (단일 파일 수정, 순서 의존, 30초 이내)
