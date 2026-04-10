# Jarvis Job Crawler — 설치 방법

## 1. Chrome 확장 설치

1. Chrome 주소창에 `chrome://extensions/` 입력
2. 우측 상단 **개발자 모드** 켜기 (토글)
3. **압축 해제된 확장 프로그램 로드** 클릭
4. 이 폴더 선택: `~/.jarvis/chrome-extension/`
5. 설치 완료 → 툴바에 🤖 아이콘 표시

## 2. 첫 실행 확인

- 설치 1분 후 자동으로 첫 크롤링 시작
- Chrome 개발자 도구 → Extensions → Jarvis Job Crawler → **Service Worker** 클릭 → Console에서 로그 확인
- jarvis-career 채널에서 결과 확인

## 3. 수동 실행

- 툴바의 🤖 아이콘 클릭 → **지금 바로 크롤링** 버튼

## 4. 스케줄

- 매 4시간마다 자동 실행
- Chrome이 실행 중이어야 함 (Mac Mini 상시 켜두면 OK)

## 주의사항

- Chrome을 종료하면 알람이 멈춤 (재시작 시 자동 재등록)
- `chrome://extensions/` → Jarvis Job Crawler → 세부정보 → **"확장 프로그램 페이지 유지"** 활성화 권장
