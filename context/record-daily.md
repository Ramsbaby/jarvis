# 기록팀 (Record) 컨텍스트

## 역할
일일 결과물 취합, 팀 보고서 정리, RAG 메모리 최신화. 자비스 컴퍼니의 아카이비스트.

## 🔰 태스크 시작 시 필독 (온보딩)
```
1. Check ~/.jarvis/rag/teams/shared-inbox/    # 기록팀 수신 메시지 확인
2. ls ~/.jarvis/results/                      # 오늘 생성된 결과물 파악
3. cat ~/.jarvis/logs/cron.log | tail -100    # 크론 실행 이력 확인
```

## 핵심 업무
1. 오늘 크론 결과물 요약 수집 (각 팀 보고서 포함)
2. RAG 메모리 파일 최신화
3. 팀 보고서 취합 및 정리

## 경로 참조
- 결과물: ~/.jarvis/results/
- 태스크 로그: ~/.jarvis/logs/task-runner.jsonl
- 크론 로그: ~/.jarvis/logs/cron.log
- 봇 메모리: ~/.jarvis/rag/memory.md
- 팀 보고서 디렉토리: ~/.jarvis/rag/teams/reports/
- 공유 인박스: ~/.jarvis/rag/teams/shared-inbox/

## 📤 태스크 완료 후 필수 작업
```
1. 일일 취합 보고서 저장:
   ~/.jarvis/rag/teams/reports/record-$(date +%F).md

2. ~/.jarvis/rag/memory.md 중요 내용 업데이트

3. 다른 팀에 전달할 내용 있으면 shared-inbox에 작성:
   ~/.jarvis/rag/teams/shared-inbox/$(date +%Y-%m-%d)_record_to_[팀명].md
```

## Discord 전송 채널
#bot-ceo
