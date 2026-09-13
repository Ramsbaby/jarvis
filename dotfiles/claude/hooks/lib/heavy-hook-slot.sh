#!/usr/bin/env bash
# heavy-hook-slot.sh — 서브프로세스/LLM을 실제로 스폰하는 무거운 훅 4종 간
# 교차 동시성 캡 (stop-wiki-ingest / stop-mistake-extract / rag-index-safe / vera-autosummon-runner).
#
# 2026-08-01 맥미니 커널 패닉(watchdog timeout 92s, compressor 세그먼트 100% BAD) 재발 방지용 신설.
# 이 4개는 이미 각자 자기 자신의 중복 실행은 막고 있다 —
#   rag-index-safe.sh: mkdir 단일 인스턴스 락 + OS 메모리 압박 게이트
#   vera-autosummon: 세션별 인플라이트 락
#   wiki-ingest / mistake-extract: per-cwd 5분 쿨다운 + 메모리 압박 게이트(mem-pressure-gate.sh)
# 이 라이브러리가 막는 건 "이 4개가 서로 다른 종류로 동시에" 겹치는 경우 — 각자의 락은
# 자기 자신만 보고 옆 훅이 지금 무거운 작업 중인지는 모른다.
#
# mkdir 원자적 락 N개(슬롯) 방식 — rag-index-safe.sh와 동일 원리(macOS 호환, flock 불요).
# 논블로킹: 슬롯이 없으면 즉시 실패 반환(대기 안 함) — 호출부가 곧바로 skip 처리해야 한다.
#
# Usage:
#   source ".../lib/heavy-hook-slot.sh"
#   if ! heavy_slot_acquire "wiki-ingest"; then log "SKIP: 교차 슬롯 없음"; exit 0; fi
#   trap 'heavy_slot_release' EXIT   # 호출부 책임 — 기존 trap이 있으면 그 안에 함께 넣을 것

HEAVY_SLOT_DIR="${HOME}/.jarvis/state/heavy-hook-slots"
HEAVY_SLOT_COUNT=2
_HEAVY_SLOT_HELD=""

heavy_slot_acquire() {
  local owner="${1:-unknown}"
  mkdir -p "$HEAVY_SLOT_DIR" 2>/dev/null || return 1
  local i slot owner_pid
  for (( i = 1; i <= HEAVY_SLOT_COUNT; i++ )); do
    slot="${HEAVY_SLOT_DIR}/slot-${i}.d"
    if mkdir "$slot" 2>/dev/null; then
      printf '%s %s\n' "$$" "$owner" > "${slot}/owner" 2>/dev/null || true
      _HEAVY_SLOT_HELD="$slot"
      return 0
    fi
    # stale 슬롯 회수: owner 프로세스가 이미 죽었으면 정리 후 재획득 시도
    owner_pid=$(awk '{print $1; exit}' "${slot}/owner" 2>/dev/null)
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -rf "$slot" 2>/dev/null || true
      if mkdir "$slot" 2>/dev/null; then
        printf '%s %s\n' "$$" "$owner" > "${slot}/owner" 2>/dev/null || true
        _HEAVY_SLOT_HELD="$slot"
        return 0
      fi
    fi
  done
  return 1
}

heavy_slot_release() {
  [[ -n "$_HEAVY_SLOT_HELD" ]] && rm -rf "$_HEAVY_SLOT_HELD" 2>/dev/null
  _HEAVY_SLOT_HELD=""
  return 0
}
