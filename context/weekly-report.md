# Weekly Report

## 목적
매주 일요일 20:00에 한 주간 시스템 운영 요약 리포트를 생성한다.

## 데이터 수집 방법
- 크론 성공/실패: `grep -c "SUCCESS\|FAIL" ~/.jarvis/logs/cron.log` (이번 주분)
- 시스템 이슈: `cat ~/.jarvis/logs/watchdog.log` 최근 7일
- RAG 통계: `NODE_PATH=~/.jarvis/discord/node_modules node -e "import {RAGEngine} from '$HOME/.jarvis/lib/rag-engine.mjs'; const e=new RAGEngine(); await e.init(); console.log(JSON.stringify(await e.getStats()))" --input-type=module`
- Discord 활동: `wc -l ~/.jarvis/logs/discord-bot.jsonl`

## 리포트 구조
### 📊 주간 KPI
- 크론 태스크 성공률 (목표: 90%+)
- RAG 인덱스 통계 (chunks, sources)
- Discord 응답 건수

### ⚠️ 이슈 & 장애
- 발생 시각, 원인, 해결 여부

### 💡 개선 제안
- 반복 실패 패턴 → 근본 원인 분석
- 다음 주 우선 과제 1~2개

## 크로스팀 종합 분석 (추가)

### Step A: 이번 주 팀 보고서 수집
```
ls -t ~/.jarvis/rag/teams/reports/ | head -30
```
최근 7일 이내 보고서를 팀별로 분류하여 Read:
- `council-*.md` / `insight-*.md` — 간부회의
- `infra-*.md` — 인프라
- `record-*.md` — 기록
- `brand-*.md` — 브랜드
- `academy-*.md` — 학술
- `career-*.md` — 성장
- `doc-supervisor-*.md` — 문서 감독

### Step B: 교차 분석 3가지 축
1. **반복 이슈**: 2개 이상 팀이 동시에 언급한 문제 → 시스템 전체 이슈
2. **공통 블로커**: 여러 팀의 진행을 막는 동일 원인
3. **기회 신호**: 한 팀 성과가 다른 팀에 활용 가능한 것

### Step C: 주간 문서 시스템 건강
```
# doc-supervisor 이번 주 결과 요약
ls -t ~/.jarvis/results/doc-supervisor/ | head -7
```
각 결과에서 GREEN/YELLOW/RED 카운트 집계.

### Step D: 필수 출력 섹션
보고서 마지막에 반드시 포함:
```
## 이번 주 크로스팀 인사이트
1. [인사이트1]: (관련 팀: XX, YY)
2. [인사이트2]: (관련 팀: XX, YY)
3. [인사이트3]: (관련 팀: XX, YY)

## 문서 시스템 주간 건강
- 평균 GREEN 비율: X%
- 주요 이슈: (있으면)
```

## Discord 출력 포맷
> 공통 규칙: `output-format.md` 참조 / 1800자 이내

```
━━━━━━━━━━━━━━━━━━━━
📊 WXX 주간 리포트 (MM-DD ~ MM-DD)
━━━━━━━━━━━━━━━━━━━━
한 줄: [이번 주 한 마디 — 주니어 팀원 톤]

[🔴 긴급/반복 이슈 — 없으면 생략]
[🟡 개선 필요 항목 — 없으면 생략]

⚙️ 크론     성공률 XX% (XX/XX)
🔍 RAG     XX chunks / XX sources
💬 Discord XX건 응답

🔗 크로스팀 인사이트
→ [인사이트1] (팀: XX, YY)
→ [인사이트2] (팀: XX, YY)

🎯 다음 주 우선 과제
→ [과제1]
→ [과제2]
━━━━━━━━━━━━━━━━━━━━
```

## 주의사항
- 한국어로 간결하게 작성, Discord 전송
