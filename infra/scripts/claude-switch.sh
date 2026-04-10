#!/usr/bin/env bash
# claude-switch.sh — Claude 계정 프로필 전환 + headless 토큰 갱신
# /account 슬래시 커맨드에서 호출됨
#
# 사용법:
#   claude-switch.sh status          현재 계정 + 프로필 목록
#   claude-switch.sh use <name>      저장된 프로필로 전환 (만료 시 자동 갱신)
#   claude-switch.sh save <name>     현재 계정을 프로필로 저장
#   claude-switch.sh refresh         headless 토큰 갱신 (브라우저 불필요)
#
# Headless refresh: refreshToken → platform.claude.com/v1/oauth/token
# client_id: 9d1c250a-e61b-44d9-88ed-5944d1962f5e (Claude Code OAuth app)

CLAUDE_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_TOKEN_ENDPOINT="https://platform.claude.com/v1/oauth/token"

set -euo pipefail

CREDENTIALS="$HOME/.claude/.credentials.json"
PROFILES_DIR="$HOME/.claude/profiles"

# ── 유틸 ──────────────────────────────────────────────────────────────────────

account_info() {
    local cred_file="$1"
    if [[ ! -f "$cred_file" ]]; then
        echo "(없음)"
        return
    fi
    python3 -c "
import json, datetime, sys
try:
    d = json.load(open('$cred_file'))
    for k, v in d.items():
        if isinstance(v, dict) and 'accessToken' in v:
            exp = v.get('expiresAt', 0)
            if exp:
                exp_dt = datetime.datetime.fromtimestamp(exp/1000)
                remaining = exp_dt - datetime.datetime.now()
                hrs = int(remaining.total_seconds() // 3600)
                mins = int((remaining.total_seconds() % 3600) // 60)
                exp_str = exp_dt.strftime('%m/%d %H:%M') + f' (잔여 {hrs}h {mins}m)' if remaining.total_seconds() > 0 else exp_dt.strftime('%m/%d %H:%M') + ' ⚠️ 만료'
            else:
                exp_str = '?'
            tier = v.get('rateLimitTier', '?')
            sub = v.get('subscriptionType', '?')
            print(f'{sub} / {tier} / 만료: {exp_str}')
            sys.exit(0)
    print('(인증 정보 없음)')
except Exception as e:
    print(f'(파싱 오류: {e})')
" 2>/dev/null || echo "(파싱 실패)"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== 현재 활성 계정 ==="
    echo "  $(account_info "$CREDENTIALS")"
    echo ""
    echo "=== 저장된 프로필 ==="
    if [[ ! -d "$PROFILES_DIR" ]] || [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]]; then
        echo "  (없음) — 'save <이름>'으로 저장하세요"
        return
    fi
    for profile_dir in "$PROFILES_DIR"/*/; do
        local name
        name=$(basename "$profile_dir")
        local cred="$profile_dir/credentials.json"
        local info
        info=$(account_info "$cred")
        # 현재 활성 계정과 같은지 확인
        local marker=""
        if [[ -f "$CREDENTIALS" && -f "$cred" ]]; then
            local cur_token profile_token
            cur_token=$(python3 -c "import json; d=json.load(open('$CREDENTIALS')); [print(list(v.keys())[0] if isinstance(v,dict) else '') for v in d.values()]" 2>/dev/null | head -1 || echo "")
            profile_token=$(python3 -c "import json; d=json.load(open('$cred')); [print(list(v.keys())[0] if isinstance(v,dict) else '') for v in d.values()]" 2>/dev/null | head -1 || echo "")
            # accessToken 앞 20자로 비교
            cur_at=$(python3 -c "import json; d=json.load(open('$CREDENTIALS')); [print(v.get('accessToken','')[:20]) for v in d.values() if isinstance(v,dict) and 'accessToken' in v]" 2>/dev/null | head -1 || echo "x")
            profile_at=$(python3 -c "import json; d=json.load(open('$cred')); [print(v.get('accessToken','')[:20]) for v in d.values() if isinstance(v,dict) and 'accessToken' in v]" 2>/dev/null | head -1 || echo "y")
            if [[ "$cur_at" == "$profile_at" ]]; then
                marker=" ◀ 현재"
            fi
        fi
        echo "  [$name]$marker  $info"
    done
    echo ""
    echo "전환: /account use <이름>   저장: /account save <이름>"
}

# ── save ──────────────────────────────────────────────────────────────────────

cmd_save() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "오류: 프로필 이름을 지정하세요. 예: /account save personal"
        exit 1
    fi
    if [[ ! -f "$CREDENTIALS" ]]; then
        echo "오류: 현재 로그인된 계정이 없습니다. 먼저 claude login을 실행하세요."
        exit 1
    fi
    local profile_dir="$PROFILES_DIR/$name"
    mkdir -p "$profile_dir"
    cp "$CREDENTIALS" "$profile_dir/credentials.json"
    echo "✅ 현재 계정을 [$name] 프로필로 저장했습니다."
    echo "   $(account_info "$profile_dir/credentials.json")"
}

# ── use ───────────────────────────────────────────────────────────────────────

cmd_use() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "오류: 프로필 이름을 지정하세요. 예: /account use personal"
        exit 1
    fi
    local profile_cred="$PROFILES_DIR/$name/credentials.json"
    if [[ ! -f "$profile_cred" ]]; then
        echo "오류: [$name] 프로필이 없습니다."
        echo ""
        cmd_status
        exit 1
    fi

    # 만료 여부 경고
    local is_expired
    is_expired=$(python3 -c "
import json, datetime
d = json.load(open('$profile_cred'))
for v in d.values():
    if isinstance(v, dict) and 'accessToken' in v:
        exp = v.get('expiresAt', 0)
        if exp and datetime.datetime.fromtimestamp(exp/1000) < datetime.datetime.now():
            print('expired')
        else:
            print('ok')
" 2>/dev/null || echo "unknown")

    if [[ "$is_expired" == "expired" ]]; then
        echo "⚠️  [$name] 프로필 토큰 만료 — headless 갱신 시도 중..."
        if do_headless_refresh "$profile_cred"; then
            echo "   자동 갱신 성공 → 계속 전환합니다"
        else
            echo "   자동 갱신 실패. claude login 후 /account save $name 실행 필요."
            exit 1
        fi
    fi

    # 기존 credentials 백업
    if [[ -f "$CREDENTIALS" ]]; then
        cp "$CREDENTIALS" "${CREDENTIALS}.bak"
    fi

    cp "$profile_cred" "$CREDENTIALS"
    echo "✅ [$name] 계정으로 전환했습니다."
    echo "   $(account_info "$CREDENTIALS")"
    echo ""
    echo "ℹ️  Jarvis 크론/봇은 다음 claude -p 호출부터 자동으로 새 계정을 사용합니다."
}

# ── headless token refresh ────────────────────────────────────────────────────
# cred_file 내 refreshToken으로 새 accessToken 발급 후 파일 갱신
# 성공: exit 0 + "갱신 완료" 출력
# 실패: exit 1 + 오류 출력

do_headless_refresh() {
    local cred_file="${1:-$CREDENTIALS}"
    [[ -f "$cred_file" ]] || { echo "❌ credentials 없음: $cred_file"; return 1; }

    local result
    result=$(python3 - "$cred_file" "$CLAUDE_OAUTH_CLIENT_ID" "$CLAUDE_TOKEN_ENDPOINT" << 'PYEOF'
import json, sys, time, urllib.request

cred_file, client_id, endpoint = sys.argv[1], sys.argv[2], sys.argv[3]
creds = json.load(open(cred_file))

# 계정 키 찾기
acct_key = next((k for k, v in creds.items() if isinstance(v, dict) and 'refreshToken' in v), None)
if not acct_key:
    print("ERROR:no_refresh_token"); sys.exit(1)

refresh_token = creds[acct_key]['refreshToken']

payload = json.dumps({
    "grant_type": "refresh_token",
    "refresh_token": refresh_token,
    "client_id": client_id,
}).encode()

req = urllib.request.Request(endpoint, data=payload, headers={
    "Content-Type": "application/json",
    "User-Agent": "claude-cli/2.1.37",
})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
except urllib.error.HTTPError as e:
    print(f"ERROR:http_{e.code}:{e.read().decode()[:100]}"); sys.exit(1)
except Exception as e:
    print(f"ERROR:{e}"); sys.exit(1)

if 'access_token' not in data:
    print(f"ERROR:no_access_token:{data}"); sys.exit(1)

# credentials 갱신
creds[acct_key]['accessToken']  = data['access_token']
creds[acct_key]['refreshToken'] = data.get('refresh_token', refresh_token)  # rotate if provided
creds[acct_key]['expiresAt']    = int((time.time() + data['expires_in']) * 1000)

with open(cred_file, 'w') as f:
    json.dump(creds, f, indent=2)

import datetime
new_exp = datetime.datetime.fromtimestamp(creds[acct_key]['expiresAt'] / 1000).strftime('%H:%M')
print(f"OK:{new_exp}")
PYEOF
    ) || true

    if [[ "$result" == OK:* ]]; then
        local new_exp="${result#OK:}"
        echo "✅ 토큰 갱신 완료 — 새 만료: ${new_exp}"
        return 0
    else
        echo "❌ 갱신 실패: ${result#ERROR:}"
        return 1
    fi
}

cmd_refresh() {
    echo "=== Headless 토큰 갱신 ==="
    echo "  갱신 전: $(account_info "$CREDENTIALS")"
    if do_headless_refresh "$CREDENTIALS"; then
        echo "  갱신 후: $(account_info "$CREDENTIALS")"
        # 활성 프로필과 동기화
        for profile_dir in "$PROFILES_DIR"/*/; do
            local pcred="$profile_dir/credentials.json"
            [[ -f "$pcred" ]] || continue
            local prof_email cur_email
            prof_email=$(python3 -c "import json; d=json.load(open('$pcred')); [print(v.get('emailAddress','')) for v in d.values() if isinstance(v,dict)]" 2>/dev/null | head -1 || echo "")
            cur_email=$(python3  -c "import json; d=json.load(open('$CREDENTIALS')); [print(v.get('emailAddress','')) for v in d.values() if isinstance(v,dict)]" 2>/dev/null | head -1 || echo "")
            if [[ -n "$prof_email" && "$prof_email" == "$cur_email" ]]; then
                cp "$CREDENTIALS" "$pcred"
                echo "  📋 프로필 [$(basename "$profile_dir")] 동기화 완료"
            fi
        done
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

CMD="${1:-status}"
shift 2>/dev/null || true

case "$CMD" in
    status)  cmd_status ;;
    save)    cmd_save "${1:-}" ;;
    use)     cmd_use "${1:-}" ;;
    refresh) cmd_refresh ;;
    *)
        echo "사용법: claude-switch.sh [status|save <name>|use <name>|refresh]"
        exit 1
        ;;
esac
