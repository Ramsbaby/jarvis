주간 CEO 다이제스트를 작성합니다.

## Step 1: 데이터 수집

1) `git -C ~/.jarvis log --oneline --since="7 days ago"` — 이번 주 주요 작업
2) `ls -t ~/.jarvis/rag/teams/reports/ | head -20` — 최근 팀 보고서 목록
3) `cat ~/.jarvis/state/context-bus.md` — 최근 크로스팀 요약
4) `ls ~/.jarvis/state/decisions/ | tail -7` — 이번 주 의사결정 로그
5) `cat ~/.jarvis/results/weekly-kpi/$(ls -t ~/.jarvis/results/weekly-kpi/ 2>/dev/null | head -1) 2>/dev/null` — 최근 KPI

## Step 2: 보고서 작성

수집된 데이터를 종합하여 아래 구조로 보고서를 작성합니다.

1. **이번 주 주요 작업** — git log 기반, 5줄 이내
2. **개선/수정 사항** — commit message 분류: feat/fix/chore
3. **팀별 핵심 성과** — 팀당 1줄
4. **KPI 변화** — 전주 대비 (있을 때만)
5. **다음 주 핵심 과제** — 3개 이내
6. **대표 확인/판단 필요 사항** — 있을 때만, 없으면 생략

## Step 3: 저장

보고서를 `~/.jarvis/rag/teams/reports/ceo-digest-{{DATE_WEEK}}.md` 에 마크다운으로 저장합니다.
