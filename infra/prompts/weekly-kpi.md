ultrathink

이번 주 Jarvis 시스템 KPI 집계: 1) grep 'SUCCESS\|FAILED' ~/.jarvis/logs/cron.log | tail -500 으로 태스크별 성공/실패율 집계 (성공률 90% 미달 태스크 명시) 2) tail -1 ~/.jarvis/logs/rag-index.log 으로 RAG 통계 3) wc -l < ~/.jarvis/logs/discord-bot.jsonl 으로 Discord 응답 건수 4) ls ~/.jarvis/results/ 으로 결과 디렉토리 수 5) tail -1 ~/.jarvis/results/cost-monitor/$(ls -t ~/.jarvis/results/cost-monitor/ 2>/dev/null | head -1) 2>/dev/null 으로 비용 현황. 개선 제안 1~2개 포함. 1800자 이내 한국어.

분석 완료 후 결과를 ~/.jarvis/rag/teams/reports/weekly-kpi-$(date +%Y-W%V).md 에 마크다운으로 저장해줘.