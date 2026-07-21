---
description: "Claude 계정 전환 및 관리. 회사/개인 계정 전환, 토큰 갱신. '계정 전환', '회사 계정', '개인 계정', 'account', '토큰 갱신' 요청 시 사용."
---

# Claude 계정 관리

회사($220) ↔ 개인($110) Claude 계정 전환

## 명령어

| 명령 | 설명 |
|------|------|
| (없음) | 양쪽 계정 상태 + 현재 활성 + 토큰 잔여시간 |
| `use company` | 회사 계정으로 전환 (자동 갱신) |
| `use personal` | 개인 계정으로 전환 |
| `save company` | 현재 로그인을 company 프로필로 저장 |
| `save personal` | 현재 로그인을 personal 프로필로 저장 |
| `refresh` | Keychain ↔ 파일 재동기화 (실제 토큰 갱신은 Claude CLI가 자동) |

## 계정 전환 흐름

**회사 한도 초과 시:**
1. `/account use personal`

**월요일 회사 리셋 후:**
1. `/account use company`

**개인 토큰 만료로 전환 안 될 때:**
1. `/login` (personal 계정으로 브라우저 인증)
2. `/account save personal`
3. `/account use personal`

## 실행

```bash
SCRIPT=~/.jarvis/scripts/claude-switch.sh

if [[ ! -f "$SCRIPT" ]]; then
    echo "⚠ 스크립트 없음: $SCRIPT"
    exit 1
fi

chmod +x "$SCRIPT"
ARG="${ARGUMENTS:-}"

if [[ -z "$ARG" ]]; then
    bash "$SCRIPT" status
elif [[ "$ARG" == use* ]]; then
    NAME=$(echo "$ARG" | awk '{print $2}')
    bash "$SCRIPT" use "$NAME"
elif [[ "$ARG" == save* ]]; then
    NAME=$(echo "$ARG" | awk '{print $2}')
    bash "$SCRIPT" save "$NAME"
elif [[ "$ARG" == refresh ]]; then
    bash "$SCRIPT" refresh
else
    bash "$SCRIPT" "$ARG"
fi
```
