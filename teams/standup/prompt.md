[모닝 브리핑 — {{DATE}}]

아래 항목을 순서대로 수집하라. 각 항목은 실제 명령/파일로 직접 확인할 것.

**1. 시스템 지표** (Bash로 직접 확인)
- Claude Max rate limit: Read ~/.jarvis/state/rate-tracker.json → 5시간/7일 사용량 %
- 크론 통계: grep으로 오늘자 cron.log에서 SUCCESS/FAILED 건수
- E2E: Read ~/.jarvis/results/e2e-health/ 최신 파일 → 통과/실패 건수
- 메모리: vm_stat | head -5 → 여유 메모리 계산
- 디스크: df -h / → 사용량/여유

**2. 어제 이슈/이벤트** — {{CTX_BUS}} 읽기
- 어제 발생한 장애, 경고, 수동 조치 필요 항목만 추출
- 이미 해결된 것은 "해결됨"으로 짧게, 미해결만 상세히

**3. 일정** (Bash로 확인)
- gog calendar list --from today --to today --account \${GOOGLE_ACCOUNT:-your@gmail.com} 2>&1
- gog tasks list "${GOOGLE_TASKS_LIST_ID:-YOUR_LIST_ID}" 2>&1
- 인증 만료 시 "Google 인증 만료 — 재인증 필요" 한 줄로 경고

**4. 시장** (WebSearch)
- "TQQQ SOXL NVDA stock price today" 검색
- 3종목: 현재가, 전일 대비 %, 특이사항만

**5. 뉴스** (WebSearch)
- "AI tech news {{DATE}}" 검색, 핵심 1개만

형식 (이 구조를 정확히 따를 것):
## 모닝 브리핑 — {{DATE}}

**시스템**
- Rate limit: 5h X%/7d X% | 크론: 성공 X/실패 X | E2E: X/X pass
- [이상 있으면만] 메모리·디스크·프로세스 경고

**어제 이슈**
- [미해결] 항목명 — 상세
- [해결됨] 항목명

**일정**
- 오늘 일정 목록 또는 "일정 없음"

**시장**
- TQQQ $XX.XX (X.X%) | SOXL $XX.XX (X.X%) | NVDA $XX.XX (X.X%)
- [손절선 접근 등 특이사항만]

**뉴스**
- [제목] — 한 줄 요약
