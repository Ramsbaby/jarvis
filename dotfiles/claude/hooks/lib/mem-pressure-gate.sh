#!/usr/bin/env bash
# mem-pressure-gate.sh — Stop 훅 LLM 서브프로세스 공용 메모리 압박 게이트
#
# infra/bin/rag-index-safe.sh의 실전 검증된 게이트(2026-06-23 freeze 사고 재발방지용 신설,
# 2026-07-07 재보정, 2026-07-10 swap-total=0 버그 수정)와 동일한 판단 기준을 그대로 재사용한다.
# OS 메모리 압박 레벨(kern.memorystatus_vm_pressure_level)을 1차 신호로, 스왑 여유 고갈을
# 2차 backstop으로 쓴다 — 절대 스왑량은 신뢰 지표가 아니라는 게 rag-index-safe.sh에서 실측됨.
#
# 2026-08-01 맥미니 커널 패닉(watchdog timeout 92s, compressor 세그먼트 100% BAD) 재발 방지용 신설.
# 패닉 당시 stop-wiki-ingest/stop-mistake-extract 등 Haiku 서브프로세스를 async로 spawn하는
# Stop 훅에는 이 종류의 게이트가 전혀 없었다.
#
# Usage:
#   source ".../lib/mem-pressure-gate.sh"
#   if reason=$(mem_pressure_should_skip); then log "SKIP: $reason"; exit 0; fi

mem_pressure_should_skip() {
  local pressure swap_used swap_free
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)
  swap_used=$(sysctl -n vm.swapusage 2>/dev/null | sed -nE 's/.*used = ([0-9]+)\..*/\1/p')
  swap_free=$(sysctl -n vm.swapusage 2>/dev/null | sed -nE 's/.*free = ([0-9]+)\..*/\1/p')

  if [ "${pressure:-1}" -ge 2 ]; then
    echo "OS 메모리 압박 레벨 ${pressure} (경고/위험)"
    return 0
  fi
  if [ "${swap_used:-0}" -gt 0 ] && [ "${swap_free:-99999}" -lt 400 ]; then
    echo "스왑 여유 ${swap_free}MB (<400MB, 소진 임박)"
    return 0
  fi
  return 1
}
