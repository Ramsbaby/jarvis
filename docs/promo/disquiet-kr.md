# Disquiet 제출용

> 제출 URL: https://disquiet.io/product/submit

## 제품명
Jarvis — 자가 복구하는 AI 운영 플랫폼

## 한줄 소개
자는 동안 시스템을 점검하고, 뉴스를 분석하고, 코드를 짜는 AI 비서. Mac Mini 하나로 24/7 운영.

## 상세 설명

### 문제
ChatGPT/Claude Memory는 "기억"만 한다. 기억한 걸 바탕으로 행동하지 않는다. 서비스가 죽으면 직접 고쳐야 하고, 뉴스는 직접 찾아야 하고, 코드는 직접 짜야 한다.

### 해결
Jarvis는 기억 + 분석 + 자동화 + 자가 복구를 하나의 시스템으로 통합.

- **기억**: RAG 지식 베이스 (10,000+ 문서, 하이브리드 검색)
- **분석**: 매일 행동 메트릭을 자동 수집하고 Claude가 해석 ("특정 토픽 빈도가 급증, 관심 영역 전환 감지")
- **자동화**: 99개 스크립트가 새벽에 코드 감사, 뉴스 브리핑, 시스템 점검
- **자가 복구**: 4층 복구 체계. 서비스가 죽으면 3분 내 자동 재시작
- **자율 코딩**: Dev-Queue가 작업을 추출하고 Claude가 자동 실행

### 차별점
- API 과금 0원 (Claude 구독만)
- 100% 로컬 (데이터 유출 없음)
- 멀티유저 + 가족 모드
- 8개 AI 에이전트 팀 + Board Meeting AI

### 기술 스택
Node.js, LanceDB, Ollama, Discord.js, macOS LaunchAgent

## URL
https://github.com/Ramsbaby/jarvis

## 카테고리
개발자 도구 / AI / 자동화
