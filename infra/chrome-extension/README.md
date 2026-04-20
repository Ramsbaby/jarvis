# Chrome Extension (Private)

> **이 디렉토리의 실제 코드는 private 관리됩니다.**

## 왜 private 인가

이 Chrome 확장은 **초기 크롤러 프로토타입**입니다. 사이트 목록·파서 로직·대상 도메인 등이 오너 환경에 강하게 결합되어 있어 공개 저장소에서 추적하지 않습니다.

## 현재 활성 크롤러

공개 저장소의 활성 크롤러는 Node.js 기반으로 이전되었습니다.

| 컴포넌트 | 파일 | 역할 |
|---|---|---|
| 크롤러 | `infra/scripts/inbox-crawl.mjs` | 대상 페이지 HTTP 수집 |
| 매처 | `infra/scripts/inbox-match.mjs` | 프로필 기반 스코어링 |
| 알림 | `infra/scripts/inbox-alert.sh` | Discord 전송 |
| 타겟 정의 | `private/config/inbox-targets.json` | gitignored (오너 개인) |

## 사용 방법

Chrome 확장이 필요하면 오너 본인의 로컬 `infra/chrome-extension/` 아래에서 직접 관리합니다. 공개 저장소 fork 사용자는 `inbox-crawl.mjs` 경로를 이용하세요.
