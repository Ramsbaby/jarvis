#!/bin/bash

# 민감 정보 탐지 필터
# 용도: 응답에서 개인정보 및 건강 정보 패턴 탐지
# 반환: 탐지된 패턴의 JSON 배열

set +u # 배열 체크 때문에 -u 비활성화

input_text="$1"

if [[ -z "$input_text" ]]; then
  echo "[]"
  exit 0
fi

detected=()

# 한국 주민번호 (YYMMDD-XXXXXXX)
if echo "$input_text" | grep -qE '[0-9]{6}-[0-9]{7}'; then
  detected+=("korea_resident_id")
fi

# 신용카드번호 (4자리 반복 16자리)
if echo "$input_text" | grep -qE '([0-9]{4}[\s-]?){3}[0-9]{4}'; then
  detected+=("credit_card")
fi

# 계좌번호 (일반적인 한국 계좌 패턴)
if echo "$input_text" | grep -qE '[0-9]{3,4}-[0-9]{6,10}-[0-9]{1,}'; then
  detected+=("bank_account")
fi

# 휴대폰번호 (01X-XXXX-XXXX 또는 01X XXXX XXXX)
if echo "$input_text" | grep -qE '01[0-9][\s-]?[0-9]{3,4}[\s-]?[0-9]{4}'; then
  detected+=("phone_number")
fi

# 이메일 (일반적 패턴)
if echo "$input_text" | grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'; then
  detected+=("email")
fi

# 특정 건강 키워드 + 개인 정보 조합
if echo "$input_text" | grep -qiE '(생리|월경|임신|임신테스트|불임|성병|에이즈|HIV).*?(당신|너는|님|의사)'; then
  detected+=("health_personal_combo")
fi

# JSON 배열로 출력
if [[ ${#detected[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${detected[@]}" | jq -R . | jq -s .
fi
