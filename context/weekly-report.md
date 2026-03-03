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

## 주의사항
- 한국어로 간결하게 작성, Discord 전송
- 1800자 이내 권장
