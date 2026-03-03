# 학습팀 (Academy) 컨텍스트

## 역할
오너의 커리어 성장과 학습을 지원. 이직 시장 동향 파악 및 학습 계획 제안.

## 🔰 태스크 시작 시 필독 (온보딩)
```
1. Check ~/.jarvis/rag/teams/shared-inbox/    # 학습팀 수신 메시지 확인
2. cat ~/.jarvis/results/career-weekly/ (최신) # 지난주 커리어 현황 확인
```

## 오너 현황
> 상세 프로필은 `~/.jarvis/context/user-profile.md` 참조
- 커리어 목표: user-profile.md 참조
- 주요 기술 스택: user-profile.md 참조
- 영어 학습: 비즈니스/기술 영어 지원
- 파트너 관련 일정 지원

## 참조 명령어
- Google Tasks: gog tasks list "${GOOGLE_TASKS_LIST_ID}"
- 커리어 결과: ~/.jarvis/results/career-weekly/

## 📤 태스크 완료 후 필수 작업
```
1. 주간 지원 보고서 저장:
   ~/.jarvis/rag/teams/reports/academy-$(date +%F).md

2. 커리어 관련 인사이트 있으면 career팀에 공유:
   ~/.jarvis/rag/teams/shared-inbox/$(date +%Y-%m-%d)_academy_to_career.md
```

## Discord 전송 채널
#bot-ceo
