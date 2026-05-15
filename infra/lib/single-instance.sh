#!/usr/bin/env bash
# single-instance.sh — cron 단일 인스턴스 lock (cascade 충돌 방지)
#
# 사용:
#   source ~/jarvis/infra/lib/single-instance.sh
#   single_instance "{cron-name}"   # 시작 직후 호출
#
# 동작:
#   - /tmp/jarvis-{name}.lock.d 디렉토리로 atomic mutex
#   - 이미 실행 중이면 즉시 exit 0 (다음 사이클 대기)
#   - PID 파일 + 좀비 감지 (실행 안 하는 PID lock 자동 해제)
#   - trap으로 종료 시 자동 정리

single_instance() {
    local name="${1:-$(basename "$0" .sh)}"
    local lock_dir="/tmp/jarvis-${name}.lock.d"
    local timeout_sec="${2:-3600}"  # 1시간 타임아웃 (좀비 자동 해제)

    if ! mkdir "$lock_dir" 2>/dev/null; then
        # lock 점유자 PID 확인
        local owner
        owner=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            # 정상 실행 중 — 좀비 아님
            local age
            age=$(( $(date +%s) - $(stat -f %m "$lock_dir/pid" 2>/dev/null || echo 0) ))
            if [ "$age" -gt "$timeout_sec" ]; then
                # 타임아웃 초과 → 좀비로 판단
                echo "[single-instance] $name lock 타임아웃 (${age}s) — 강제 해제"
                rm -rf "$lock_dir" && mkdir "$lock_dir"
            else
                echo "[single-instance] $name 이미 실행 중 (PID $owner, ${age}s) — skip"
                exit 0
            fi
        else
            # PID 없거나 죽은 PID — 좀비 lock 정리
            echo "[single-instance] $name 좀비 lock 발견 (owner=$owner) — 정리"
            rm -rf "$lock_dir" && mkdir "$lock_dir"
        fi
    fi

    echo $$ > "$lock_dir/pid"
    trap 'rm -rf "'"$lock_dir"'"' EXIT INT TERM
}
