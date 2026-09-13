#!/usr/bin/env bash
# PreToolUse hook: Write 도구 호출 시 기존 도구 탐색 강제
# cl-8080a969ce1423ae: 기존 도구 미탐색 + 자동화 파이프라인 미등록
#
# 새 진단/헬스체크 스크립트를 작성하기 전에 INDEX.md·기존 도구를 탐색하도록 강제한다.
# 이는 중복 개발과 감시 공백을 방지하는 사전 점검이다.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")
CONTENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('content',''))" 2>/dev/null || echo "")

if [[ "$TOOL" != "Write" ]]; then
  exit 0
fi

# 감지 패턴: 새 진단/헬스체크/감시 스크립트
# check-*, verify-*, health-*, watch-*, audit-*, detect-*, validate-*
if echo "$FILE_PATH" | grep -qE '(check-|verify-|health-|watch-|audit-|detect-|validate-)[a-z0-9-]+\.(sh|mjs)$' && \
   echo "$FILE_PATH" | grep -qE '(scripts|bin)' && \
   echo "$CONTENT" | grep -qiE '(check|health|verify|audit|detect|watch)'; then

  # 기존 도구 탐색 강제
  local index_file="${HOME}/projects/jarvis/infra/docs/INDEX.md"
  local tools_dir="${HOME}/projects/jarvis/infra/scripts"
  local existing_tools=""

  # INDEX.md 존재 확인
  if [[ ! -f "$index_file" ]]; then
    echo "⚠️  PRE-WRITE CHECK: INDEX.md 를 먼저 읽어보세요" >&2
    echo "   경로: $index_file" >&2
  fi

  # 유사한 기존 스크립트 탐지
  local script_name=$(basename "$FILE_PATH" | sed 's/\.[a-z]*$//')
  if [[ -d "$tools_dir" ]]; then
    # 유사한 이름의 기존 스크립트 탐지
    existing_tools=$(find "$tools_dir" -maxdepth 1 -type f \
      -name "*${script_name%%-*}*.sh" -o -name "*${script_name%%-*}*.mjs" 2>/dev/null | head -5)

    if [[ -n "$existing_tools" ]]; then
      echo "⚠️  PRE-WRITE CHECK: 유사한 기존 도구가 있습니다" >&2
      echo "$existing_tools" | sed 's/^/   /' >&2
      echo "   위 도구들을 먼저 검토하고, 중복이 없는지 확인해주세요." >&2
    fi
  fi

  # 프롬프트: INDEX.md와 기존 도구를 검토했는지 확인
  echo "⚠️  PRE-WRITE CHECK: cl-8080a969ce1423ae" >&2
  echo "   새 스크립트 작성 전 반드시 확인:" >&2
  echo "   1️⃣  ./infra/docs/INDEX.md (TASKS-INDEX.md 참조)" >&2
  echo "   2️⃣  ./infra/scripts/ 에서 유사한 도구 탐색" >&2
  echo "   3️⃣  TEAMS.md 에서 관련 팀 및 담당자 확인" >&2
  echo "" >&2
  echo "   → 기존 도구를 발견했다면 해당 도구를 수정/확장하는 것이 더 낫습니다." >&2
  echo "" >&2
fi

exit 0
