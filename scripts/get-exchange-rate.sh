#!/usr/bin/env bash
# get-exchange-rate.sh — USD/KRW 환율 조회 (Frankfurter API, 무료)
# 출력: 숫자만 (예: 1487)
# 실패 시 exit 1 (호출측에서 기본값 처리)

set -euo pipefail

CACHE_FILE="${BOT_HOME:-$HOME/.jarvis}/state/exchange-rate-usd-krw.json"
CACHE_TTL=3600  # 1시간 캐시

# 캐시 유효성 확인
if [[ -f "$CACHE_FILE" ]]; then
  cached_time=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(d.get('ts',0))" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - cached_time ))
  if [[ $age -lt $CACHE_TTL ]]; then
    python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(int(d['rate']))" 2>/dev/null && exit 0
  fi
fi

# Frankfurter API (ECB 기반, 무료, 인증 불필요)
RATE=$(curl -sf "https://api.frankfurter.app/latest?from=USD&to=KRW" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d['rates']['KRW']))" 2>/dev/null) || true

if [[ -z "$RATE" ]]; then
  # 백업: Yahoo Finance 비공식
  RATE=$(curl -sf "https://query1.finance.yahoo.com/v8/finance/chart/USDKRW=X?interval=1d&range=1d" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d['chart']['result'][0]['meta']['regularMarketPrice']))" 2>/dev/null) || true
fi

if [[ -z "$RATE" ]]; then
  exit 1
fi

# 캐시 저장
python3 -c "
import json, time
data = {'rate': $RATE, 'ts': int(time.time())}
import os; os.makedirs(os.path.dirname('$CACHE_FILE'), exist_ok=True)
json.dump(data, open('$CACHE_FILE', 'w'))
" 2>/dev/null || true

echo "$RATE"
