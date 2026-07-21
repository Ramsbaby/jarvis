#!/usr/bin/env bash
# claude-switch.sh — Claude 계정 프로필 전환 (Keychain + 파일 이중 관리)
# /account 슬래시 커맨드에서 호출됨
#
# 사용법:
#   claude-switch.sh status          현재 계정 + 프로필 목록
#   claude-switch.sh use <name>      저장된 프로필로 전환 (Keychain + 파일 동시)
#   claude-switch.sh save <name>     현재 활성 계정을 프로필로 저장 (Keychain 기준)
#   claude-switch.sh refresh         Keychain ↔ 파일 재동기화 (실제 토큰 갱신은 Claude CLI 자동)
#
# ⚠️ 토큰 갱신 정책 (2026-07-10 재작성):
#   OAuth refresh 엔드포인트(platform.claude.com/v1/oauth/token, console.anthropic.com/... 등)를
#   이 스크립트에서 절대 직접 호출하지 않는다.
#   근거: refreshToken은 1회용 회전키. 외부에서 직접 호출하면 Claude CLI가 캐시한 키와 충돌 →
#         토큰 패밀리(계정 전체) 폐기 → 강제 재로그인. (CLAUDE.md 0순위 BLOCKING 룰, 2026-05-31)
#   대신: 만료된 accessToken은 그대로 두고 전환한다. refreshToken이 살아 있으면 Claude CLI가
#         다음 호출에서 자체적으로 갱신하므로 재로그인이 필요 없다.
#
# Claude Code v2.1.50+ : 자격증명 주 저장소는 macOS Keychain
#   Keychain service: "Claude Code-credentials", account: OS 사용자명
#   파일(~/.claude/.credentials.json)은 레거시 fallback이자 미러본.
#
# 손대지 않는 것 (격리 유지):
#   - ~/.claude-bot/.long-lived-token  (디스코드 봇 전용 격리 토큰)
#   - ~/.openclaw/agents/*             (OpenClaw는 API 키 사용, OAuth 계정 전환과 무관)

set -euo pipefail

CREDENTIALS="$HOME/.claude/.credentials.json"
PROFILES_DIR="$HOME/.claude/profiles"

KC_SERVICE="Claude Code-credentials"
KC_ACCOUNT="$(whoami)"

# ── Keychain 유틸 ─────────────────────────────────────────────────────────────

_read_keychain() {
    security find-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w 2>/dev/null || echo ""
}

_write_keychain() {
    local json_data="$1"
    # update API가 없으므로 삭제 후 재생성
    security delete-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" 2>/dev/null || true
    security add-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$json_data"
}

# 활성 자격증명 JSON 획득 (Keychain 우선 → 파일 fallback)
_get_live_json() {
    local kc
    kc="$(_read_keychain)"
    if [[ -n "$kc" ]]; then
        printf '%s' "$kc"; return 0
    fi
    if [[ -f "$CREDENTIALS" ]]; then
        cat "$CREDENTIALS"; return 0
    fi
    return 1
}

# JSON(stdin) → 요약 한 줄 (토큰 원문 미노출)
_fmt_creds() {
    python3 -c "
import json, sys, datetime
try:
    d = json.loads(sys.stdin.read() or '{}')
except Exception:
    print('(파싱 실패)'); sys.exit(0)
for k, v in d.items():
    if isinstance(v, dict) and 'accessToken' in v:
        exp = v.get('expiresAt', 0)
        if exp:
            ed = datetime.datetime.fromtimestamp(exp/1000)
            rem = (ed - datetime.datetime.now()).total_seconds()
            es = ed.strftime('%m/%d %H:%M') + (f' (잔여 {int(rem//3600)}h {int((rem%3600)//60)}m)' if rem > 0 else ' ⚠️ 만료')
        else:
            es = '?'
        email = v.get('emailAddress') or '(이메일 미기록)'
        print(f\"{v.get('subscriptionType','?')} / {email} / 만료: {es}\")
        sys.exit(0)
print('(인증 정보 없음)')
"
}

# JSON(stdin) → accessToken sha256 앞 12자 (식별용, 원문 미노출)
_hash_creds() {
    python3 -c "
import json, sys, hashlib
try:
    d = json.loads(sys.stdin.read() or '{}')
except Exception:
    print(''); sys.exit(0)
for k, v in d.items():
    if isinstance(v, dict) and 'accessToken' in v:
        print(hashlib.sha256(v['accessToken'].encode()).hexdigest()[:12]); sys.exit(0)
print('')
"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== 현재 활성 계정 ==="
    local src="none" live=""
    live="$(_read_keychain)"
    if [[ -n "$live" ]]; then
        src="keychain"
    elif [[ -f "$CREDENTIALS" ]]; then
        src="file"; live="$(cat "$CREDENTIALS")"
    fi
    echo "  저장소: $src"
    echo "  $(printf '%s' "$live" | _fmt_creds)"
    local live_hash
    live_hash="$(printf '%s' "$live" | _hash_creds)"

    echo ""
    echo "=== 저장된 프로필 ==="
    if [[ ! -d "$PROFILES_DIR" ]] || [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null | grep -v '^\.' || true)" ]]; then
        echo "  (없음) — 'save <이름>'으로 저장하세요"
        return
    fi
    for profile_dir in "$PROFILES_DIR"/*/; do
        [[ -d "$profile_dir" ]] || continue
        local name cred info phash marker
        name="$(basename "$profile_dir")"
        cred="$profile_dir/credentials.json"
        [[ -f "$cred" ]] || continue
        info="$(_fmt_creds < "$cred")"
        phash="$(_hash_creds < "$cred")"
        marker=""
        if [[ -n "$live_hash" && "$phash" == "$live_hash" ]]; then marker=" ◀ 현재"; fi
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

    local live
    live="$(_get_live_json)" || { echo "오류: 활성 자격증명이 없습니다. 먼저 /login 하세요."; exit 1; }

    local h
    h="$(printf '%s' "$live" | _hash_creds)"
    if [[ -z "$h" ]]; then
        echo "오류: 자격증명에서 accessToken을 찾지 못했습니다. /login 필요."
        exit 1
    fi

    local profile_dir="$PROFILES_DIR/$name"
    mkdir -p "$profile_dir"

    # 기존 프로필 백업 (덮어쓰기 롤백용)
    if [[ -f "$profile_dir/credentials.json" ]]; then
        cp "$profile_dir/credentials.json" "$profile_dir/credentials.json.bak"
    fi

    printf '%s' "$live" > "$profile_dir/credentials.json"
    chmod 600 "$profile_dir/credentials.json"

    # Keychain을 기준으로 파일 미러 동기화 (drift 방지 — 활성 계정은 그대로)
    printf '%s' "$live" > "$CREDENTIALS"
    chmod 600 "$CREDENTIALS"

    cat > "$profile_dir/meta.json" <<EOF
{
  "name": "$name",
  "savedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "keychain"
}
EOF

    echo "✅ 현재 활성 계정을 [$name] 프로필로 저장했습니다. (Keychain 기준 + 파일 미러)"
    echo "   $(printf '%s' "$live" | _fmt_creds)"
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

    # refreshToken 존재 여부 + accessToken 만료 여부 (엔드포인트 호출 없음)
    local check has_refresh access_state
    check="$(python3 -c "
import json, datetime
d = json.load(open('$profile_cred'))
hr, st = 'no', 'unknown'
for v in d.values():
    if isinstance(v, dict) and 'accessToken' in v:
        hr = 'yes' if v.get('refreshToken') else 'no'
        exp = v.get('expiresAt', 0)
        st = 'expired' if (exp and datetime.datetime.fromtimestamp(exp/1000) < datetime.datetime.now()) else 'ok'
        break
print(hr, st)
" 2>/dev/null || echo "no unknown")"
    has_refresh="$(echo "$check" | awk '{print $1}')"
    access_state="$(echo "$check" | awk '{print $2}')"

    if [[ "$access_state" == "expired" ]]; then
        if [[ "$has_refresh" == "yes" ]]; then
            echo "ℹ️  [$name] accessToken은 만료됐지만 refreshToken이 있어, 전환 후 Claude CLI가 자동 갱신합니다. (재로그인 불필요)"
        else
            echo "⚠️  [$name] 프로필의 accessToken이 만료됐고 refreshToken도 없습니다."
            echo "   → 먼저 해당 계정으로 /login 후  /account save $name  로 갱신하세요."
            echo "   (refresh 엔드포인트 직접 호출은 토큰 폐기 위험이라 하지 않습니다.)"
            exit 1
        fi
    fi

    # 현재 활성 자격증명 백업
    local cur
    cur="$(_get_live_json 2>/dev/null || echo "")"
    if [[ -n "$cur" ]]; then
        printf '%s' "$cur" > "${CREDENTIALS}.bak"
        chmod 600 "${CREDENTIALS}.bak"
    fi

    local new_creds
    new_creds="$(cat "$profile_cred")"

    # 1) 파일 쓰기 (레거시 fallback 미러)
    printf '%s' "$new_creds" > "$CREDENTIALS"
    chmod 600 "$CREDENTIALS"
    # 2) Keychain 쓰기 (Claude Code v2.1.50+ 주 저장소 — 이게 실제 반영을 보장)
    _write_keychain "$new_creds"

    echo "✅ [$name] 계정으로 전환했습니다. (Keychain + 파일 동시 적용)"
    echo "   $(printf '%s' "$new_creds" | _fmt_creds)"
    echo ""
    echo "ℹ️  Jarvis 크론/봇은 다음 claude -p 호출부터 새 계정을 사용합니다."
    echo "ℹ️  대화형 세션은 새 세션부터 반영됩니다."
}

# ── refresh (재동기화 전용 — 외부 엔드포인트 호출 없음) ────────────────────────

cmd_refresh() {
    echo "=== 자격증명 재동기화 (Keychain ↔ 파일) ==="
    echo "  ℹ️  실제 토큰 갱신은 Claude CLI가 자동 수행합니다."
    echo "     (외부 OAuth refresh 엔드포인트 직접 호출은 토큰 패밀리 폐기 위험이라 하지 않습니다.)"
    echo ""

    local live
    live="$(_get_live_json)" || { echo "오류: 활성 자격증명 없음. /login 필요."; exit 1; }

    if [[ -n "$(_read_keychain)" ]]; then
        # Keychain이 주 저장소 → 파일로 미러
        printf '%s' "$live" > "$CREDENTIALS"
        chmod 600 "$CREDENTIALS"
        echo "  ✓ Keychain → 파일 미러 완료"
    else
        # 파일만 있으면 Keychain으로 승격
        _write_keychain "$live"
        echo "  ✓ 파일 → Keychain 승격 완료"
    fi

    # 활성 계정과 토큰이 동일한 프로필 저장본도 최신화 (best-effort)
    local live_hash
    live_hash="$(printf '%s' "$live" | _hash_creds)"
    for profile_dir in "$PROFILES_DIR"/*/; do
        [[ -d "$profile_dir" ]] || continue
        local pcred="$profile_dir/credentials.json"
        [[ -f "$pcred" ]] || continue
        local phash
        phash="$(_hash_creds < "$pcred")"
        if [[ -n "$live_hash" && "$phash" == "$live_hash" ]]; then
            printf '%s' "$live" > "$pcred"
            chmod 600 "$pcred"
            echo "  📋 프로필 [$(basename "$profile_dir")] 동기화 완료"
        fi
    done
    echo ""
    echo "  $(printf '%s' "$live" | _fmt_creds)"
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
