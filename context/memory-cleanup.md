# Memory Cleanup

## 목적
매일 새벽 2:00에 오래된 결과 파일과 세션 데이터를 정리한다.

## 주의사항
- ~/.jarvis/results/ 하위 디렉토리에서 7일 이상 된 파일 삭제
- ~/.jarvis/state/sessions.json에서 7일 이상 된 항목 제거
- 삭제 전 파일 수 확인, 정리된 파일 수 요약 출력
- 실수로 최신 파일 삭제하지 않도록 find -mtime +7 사용
