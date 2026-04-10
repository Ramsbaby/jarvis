시스템 상태를 체크하고 결과를 마크다운 표로 보여줘.

확인 항목:
1) 디스크 사용량 (df -h | grep '/$')
2) 메모리 (memory_pressure 2>/dev/null | grep 'System-wide memory free percentage' | awk '{print $NF}' 으로 실제 여유율 확인. 20% 미만 MEDIUM, 10% 미만 HIGH)
3) CPU 로드 (uptime)
4) 핵심 프로세스 생존 확인: discord-bot, orchestrator (pgrep -f)
5) 크론 실패 감지: grep -cE 'ABORTED|FAILED' ~/.jarvis/logs/cron.log 로 전체 카운트, tail -200 ~/.jarvis/logs/cron.log | grep -E 'ABORTED|FAILED' 로 최근 실패 목록

판단 기준:
- 최근 1시간 내 ABORTED/FAILED가 3건 이상이면 ⚠️ 크론 장애 경고
- discord-bot 또는 orchestrator 프로세스 없으면 🔴 경고
- 디스크 90% 이상이면 🔴 경고
- 모두 정상이면 ✅ OK 한 줄로 마무리

필수: 끝에 bash ~/.jarvis/scripts/health-check.sh 를 실행하여 health.json 갱신

🚫 RAG 절대 조작 금지 (위반 시 데이터 손실):
- ~/.jarvis/state/rag-rebuilding.json 이 있으면 재인덱싱 진행 중. 절대 건드리지 말 것.
- pgrep -f rag-index 로 실행 중이면 절대 건드리지 말 것.
- RAG 문제 발견 시: 경고(🔧)만 기록. 절대로 아래 행위 금지:
  - pkill / kill 로 rag-index 종료 금지
  - LanceDB dropTable / 디렉토리 삭제 금지
  - index-state.json 수정 금지
  - rag-index 재시작 금지 (timeout 값 무관)
  - RAG DB에 어떠한 방식으로든 접근하여 수정하는 행위 금지
- RAG는 자체 복구 로직이 있으며 자동으로 처리됨. 이 태스크는 보고만 할 것.