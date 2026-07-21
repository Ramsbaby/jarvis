# preply-engine — 교재 콘텐츠/형식 분리 엔진

> 2026-07-11 신설. 배경: 7일간 봇 출력 토큰의 97%(529만)가 preply 채널의 **100KB HTML 통짜 생성·재생성**에서 발생
> → 주간 쿼터 소진 → 가족 채널 응답 실패. 근본 해법으로 "LLM은 콘텐츠만, HTML은 코드가" 구조 도입.
> 캐서린 퀴즈 유실(6/26)·케이리 89개 소실(6/28)·정답 노출(6일 반복) 사고가 전부 통짜 재생성에서 발생 —
> 이 엔진에서는 **구조적으로 발생 불가**.

## 구성

| 파일 | 역할 |
|---|---|
| `parse.mjs` | 교재 HTML → `content.json` 역변환 (읽기 전용 · 미분류 블록은 raw 통과 = 소실 0) |
| `render.mjs` | `content.json` → 교재 HTML 조립 (CSS/JS는 골드 바이트 보존 템플릿) |
| `compare.mjs` | 원본 vs 재조립 의미 동등성 4종 검사 (class·텍스트·정답시퀀스·onclick) |
| `templates/head.tpl.html` | 골드 v6에서 바이트 그대로 추출한 head+CSS (정답숨김·인쇄·발광 hover 내장) |
| `templates/engine.tpl.js` | 골드 v6 채점 엔진 (checkQ/toggleAns/showUnit/switchGram) 바이트 보존 |

## 사용 (표준 흐름)

```bash
E=~/jarvis/infra/preply-engine
M=~/jarvis/runtime/preply-materials

# 부분 수정: content.json의 해당 항목만 Edit → 재렌더 → verify
node $E/render.mjs $M/한국어수업_미쉘_Unit1-4_v6.content.json $M/한국어수업_미쉘_Unit1-4_v7.html
bash ~/jarvis/infra/scripts/preply-student.sh verify $M/한국어수업_미쉘_Unit1-4_v7.html

# 신규 학생: 골드 content.json 복사 → 테마·이름·콘텐츠 필드만 패치 → 렌더
cp $M/한국어수업_미쉘_Unit1-4_v6.content.json $M/한국어수업_신학생_Unit1-4.content.json
# (LLM이 JSON 필드 패치) → render → verify → pdf → send

# 기존 HTML을 처음 엔진에 편입할 때: 역변환 + 동등성 증명
node $E/parse.mjs <교재.html> <교재.content.json>
node $E/render.mjs <교재.content.json> /tmp/rebuilt.html
node $E/compare.mjs <교재.html> /tmp/rebuilt.html   # 4/4 PASS여야 편입
```

## 파일럿 검증 결과 (2026-07-11 · 미쉘 골드 v6)

- 역변환 인벤토리: 유닛 6 · 단어 45 · 퀴즈 52문항/보기 104 · 문화비교 12 · raw 통과 16블록
- compare 4/4 PASS: class 79종 일치 · 가시 텍스트 33,595자 완전 일치 · 정답 시퀀스 104개 일치 · onclick 일치
- 공식 verify: 원본과 동일 결과 (WARN 1건 = 본인 이름 오탐, 원본도 동일)
- 렌더 아이(브라우저 실측): fail 0 · warn 0 + 스크린샷 육안 확인

## 렌더러에 박제된 보람님 영구 규칙 (검사가 아니라 발생 불가)

- 정답은 `checkQ(this,bool)` 불리언 + `ans-reveal`로만 — 보기 텍스트에 ✓·정답 마커 있으면 **렌더 자체가 실패**
- 문항당 정답 정확히 1개 아니면 **렌더 실패** (0개·2개+ 차단)
- 정답숨김 CSS·인쇄 CSS·노란 발광·밝은 배경 = head 템플릿 바이트 보존 (LLM이 건드릴 수 없음)
- italic: 템플릿에 font-style:normal 고정

## 규약

- `content.json`은 교재 HTML과 **같은 폴더에 나란히** 둔다 (`<교재명>.content.json`)
- 렌더 후에도 기존 `verify`·렌더 아이·`send` 게이트는 그대로 통과시킨다 (엔진은 게이트를 대체하지 않음)
- 스키마에 없는 특수 블록은 `{t:'raw', html}` 통과 — 억지로 구조화하지 말 것
