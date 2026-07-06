#!/usr/bin/env bash
set -euo pipefail

# preply-profile-verify.sh — 교재 콘텐츠가 학생 프로필(수준·모국어·학습목표)을 반영했는지 검증.
# 2026-07-03: cl-951102fcc7ddfd81 반복 실수 클러스터 방지용 구조적 가드.
#
# 목적: 신규 학생 교재 생성 시, 프로필 필드(level/native_language/goal)가
#      실제 콘텐츠(어휘 어려움·설명 언어·학습 테마)에 반영되도록 강제.
#
# 사용:
#   preply-profile-verify.sh check <학생한글명> <HTML파일>
#      → HTML에서 프로필이 반영되었는지 검증 (level/goal/theme).
#        FAIL이면 exit 1, 경고면 exit 0+경고메시지.
#
#   preply-profile-verify.sh init-migration <레지스트리JSON>
#      → 기존 학생 프로필 필드를 canonical로 정규화 (마이그레이션용).
#
#   preply-profile-verify.sh report <레지스트리JSON>
#      → 프로필 완성도 리포트 (어느 학생이 미확인 필드를 가졌는지).

JARVIS="${HOME}/jarvis"
REGISTRY="${JARVIS}/runtime/config/preply-students.json"
PROFILE_STATE="${JARVIS}/runtime/state/preply-profile-state.jsonl"

err() { echo "❌ $*" >&2; exit 1; }
warn() { echo "⚠️ $*" >&2; }
info() { echo "ℹ️ $*"; }

[ -f "$REGISTRY" ] || err "레지스트리 없음: $REGISTRY"

# 레지스트리에서 한 학생의 프로필 필드 읽기
get_student_profile() {
  local name="$1"
  python3 - "$REGISTRY" "$name" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
name = sys.argv[2]
for s in reg.get('students', []):
    names = [s.get('name_ko'), s.get('name_en'), *s.get('alt_names', [])]
    if name in [n for n in names if n]:
        profile = {
            'level': s.get('level'),
            'native_language': s.get('languages', [None])[0] if s.get('languages') else None,
            'goal': s.get('goal'),
            'country': s.get('country'),
            'theme': s.get('theme'),
            'interests': s.get('interests', [])
        }
        print(json.dumps(profile, ensure_ascii=False))
        sys.exit(0)
print('{}')
PY
}

# 교재 HTML에서 프로필 관련 키워드 감지
detect_profile_in_html() {
  local f="$1"
  local level_key="$2"
  local goal_key="$3"
  local theme_key="$4"

  local level_count=0
  local goal_count=0
  local theme_count=0

  # level 키워드: 초급/초보/초중급/중급/고급/완전초급 등
  # HTML에서 텍스트 노드만 검사 (CSS나 주석 제외)
  for keyword in 초급 초보 초중급 중급 고급 완전초급 입문; do
    if grep -qi "$keyword" "$f"; then
      level_count=$((level_count + 1))
    fi
  done

  # goal 키워드: travel/hobby/culture/conversation/business
  for keyword in 여행 취미 문화 회화 실용 커뮤니 이야기 드라마 노래; do
    if grep -qi "$keyword" "$f"; then
      goal_count=$((goal_count + 1))
    fi
  done

  # theme 키워드: K-pop/K-drama/business/music 등
  local theme_words=$(echo "$theme_key" | tr ' ' '\n' | head -3)
  while IFS= read -r word; do
    if [ -n "$word" ] && grep -qi "$word" "$f"; then
      theme_count=$((theme_count + 1))
    fi
  done <<< "$theme_words"

  python3 - <<EOF
import json
print(json.dumps({
  'level_detected': $level_count > 0,
  'goal_detected': $goal_count > 0,
  'theme_detected': $theme_count > 0,
  'level_score': $level_count,
  'goal_score': $goal_count,
  'theme_score': $theme_count
}, ensure_ascii=False))
EOF
}

cmd_check() {
  local student_name="${1:-}"
  local html_file="${2:-}"

  [ -n "$student_name" ] || err "학생 이름 필요: preply-profile-verify.sh check <학생> <파일>"
  [ -n "$html_file" ] || err "HTML 파일 필요: preply-profile-verify.sh check <학생> <파일>"

  html_file="${html_file/#\~/$HOME}"
  [ -f "$html_file" ] || err "파일 없음: $html_file"

  info "🔍 프로필 반영 검증: $(basename "$html_file")"
  echo "─────────────────────────────"

  # 학생 프로필 로드
  local profile_json
  profile_json=$(get_student_profile "$student_name")
  if [ "$profile_json" = "{}" ]; then
    warn "학생을 찾지 못함: $student_name"
    return 1
  fi

  # 프로필 필드 추출
  local level goal theme country
  level=$(echo "$profile_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('level', ''))")
  goal=$(echo "$profile_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('goal', ''))")
  theme=$(echo "$profile_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('theme', ''))")
  country=$(echo "$profile_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('country', ''))")

  local fail=0 warn_count=0

  # 1) 수준(level) 검증
  if [ -z "$level" ] || [ "$level" = "None" ] || [ "$level" = "미확인" ]; then
    warn "프로필에 수준(level)이 미확인 — 교재에서 어휘 어려움을 확인할 수 없음"
    warn_count=$((warn_count + 1))
  else
    echo "프로필 수준: $level"
    # HTML에서 수준 관련 표현 감지
    if ! grep -qi "$level" "$html_file" 2>/dev/null; then
      warn_count=$((warn_count + 1))
      echo "  ⚠️ 교재에 수준 정보('$level')가 반영되지 않은 것 같음 (어휘 난이도 불일치 위험)"
    else
      echo "  수준 반영: ✅"
    fi
  fi

  # 2) 목표(goal) 검증
  if [ -z "$goal" ] || [ "$goal" = "None" ] || [ "$goal" = "미확인" ]; then
    warn "프로필에 학습목표(goal)가 미확인 — 교재 테마 일관성 확인 불가"
    warn_count=$((warn_count + 1))
  else
    echo "프로필 목표: $goal"
    # goal 키워드 검사
    local goal_found=0
    for keyword in travel culture hobby business conversation conversation; do
      if echo "$goal" | grep -qi "$keyword" && grep -qi "$keyword" "$html_file" 2>/dev/null; then
        goal_found=1
        break
      fi
    done
    if [ "$goal_found" -eq 0 ]; then
      warn_count=$((warn_count + 1))
      echo "  ⚠️ 교재의 테마가 목표('$goal')와 일치하지 않을 수 있음"
    else
      echo "  목표 반영: ✅"
    fi
  fi

  # 3) 테마(theme) 검증
  if [ -z "$theme" ] || [ "$theme" = "None" ] || [ "$theme" = "미확인" ]; then
    warn "프로필에 테마(theme)가 미확인 — 교재 맞춤성 확인 불가"
    warn_count=$((warn_count + 1))
  else
    echo "프로필 테마: $theme"
    # 테마 키워드 (첫 2-3개 단어만)
    local theme_sample=$(echo "$theme" | cut -d' ' -f1-3)
    if ! grep -qi "$theme_sample" "$html_file" 2>/dev/null; then
      warn_count=$((warn_count + 1))
      echo "  ⚠️ 교재에 테마('$theme')가 반영되지 않은 것 같음 (미쉘 복사 미정화 의심)"
    else
      echo "  테마 반영: ✅"
    fi
  fi

  # 4) 국가(country) 검증 (선택사항 — 문화 비교에 사용)
  if [ -z "$country" ] || [ "$country" = "None" ]; then
    echo "국가: 미확인"
  else
    echo "국가: $country"
    # 국가명이 비교 섹션에 있는지 확인
    local country_sample=$(echo "$country" | cut -d' ' -f1)
    if grep -qi "compare-note\|문화\|[Cc]ulture" "$html_file" 2>/dev/null; then
      if grep -qi "$country_sample" "$html_file" 2>/dev/null; then
        echo "  문화비교 반영: ✅"
      else
        warn_count=$((warn_count + 1))
        echo "  ⚠️ 문화 비교 섹션에 학생 국가('$country')가 없음"
      fi
    fi
  fi

  echo "─────────────────────────────"

  # 상태 저장 (감사 추적용)
  {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | check | $student_name | $(basename "$html_file") | level=$level | goal=$goal | theme=$theme | warns=$warn_count | fails=$fail"
  } >> "$PROFILE_STATE" 2>/dev/null || true

  if [ "$fail" -gt 0 ]; then
    echo "결과: ❌ FAIL ${fail}건 — 프로필 미확인 상태로 생성됨"
    return 1
  elif [ "$warn_count" -gt 0 ]; then
    echo "결과: ⚠️ 주의 ${warn_count}건 — 프로필 반영 불완전 (수정 권장)"
    return 0
  else
    echo "결과: ✅ 통과 — 프로필이 교재에 반영됨"
    return 0
  fi
}

cmd_init_migration() {
  local reg_file="${1:-$REGISTRY}"
  [ -f "$reg_file" ] || err "레지스트리 없음: $reg_file"

  info "🔄 기존 학생 프로필 필드 정규화 (마이그레이션)"
  echo "─────────────────────────────"

  python3 - "$reg_file" <<'PY'
import json, sys
reg_path = sys.argv[1]
reg = json.load(open(reg_path))

count_migrated = 0
for s in reg.get('students', []):
    # native_language 필드 추가 (languages 배열의 첫 요소)
    if 'native_language' not in s:
        langs = s.get('languages', [])
        s['native_language'] = langs[0] if langs else None
        count_migrated += 1

json.dump(reg, open(reg_path, 'w'), ensure_ascii=False, indent=2)
print(f'✅ {count_migrated}명 학생 마이그레이션 완료')
PY
}

cmd_report() {
  local reg_file="${1:-$REGISTRY}"
  [ -f "$reg_file" ] || err "레지스트리 없음: $reg_file"

  info "📊 학생 프로필 완성도 리포트"
  echo "─────────────────────────────"

  python3 - "$reg_file" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))

total = 0
complete = 0
missing = {'level': 0, 'goal': 0, 'native_language': 0, 'theme': 0}
incomplete = []

for s in reg.get('students', []):
    total += 1
    name = s.get('name_ko', '?')
    fields_ok = 0

    if s.get('level') and s.get('level') not in ['미확인', 'None']:
        fields_ok += 1
    else:
        missing['level'] += 1

    if s.get('goal') and s.get('goal') not in ['미확인', 'None']:
        fields_ok += 1
    else:
        missing['goal'] += 1

    if s.get('native_language') and s.get('native_language') not in ['미확인', 'None']:
        fields_ok += 1
    else:
        missing['native_language'] += 1

    if s.get('theme') and s.get('theme') not in ['미확인', 'None']:
        fields_ok += 1
    else:
        missing['theme'] += 1

    if fields_ok == 4:
        complete += 1
    else:
        incomplete.append((name, 4 - fields_ok))

print(f"전체: {total}명")
print(f"프로필 완성: {complete}명 ({complete*100//total}%)")
print(f"\n미확인 필드 분석:")
print(f"  - level: {missing['level']}명")
print(f"  - goal: {missing['goal']}명")
print(f"  - native_language: {missing['native_language']}명")
print(f"  - theme: {missing['theme']}명")

if incomplete:
    print(f"\n🔧 프로필 보완 필요 ({len(incomplete)}명):")
    for name, missing_count in sorted(incomplete, key=lambda x: -x[1])[:10]:
        print(f"  - {name}: {missing_count}개 필드 미확인")
PY
}

sub="${1:-}"; shift || true
case "$sub" in
  check)           cmd_check "$@" ;;
  init-migration)  cmd_init_migration "$@" ;;
  report)          cmd_report "$@" ;;
  *)
    cat >&2 <<'EOF'
preply-profile-verify.sh — 학생 프로필 반영 검증

  check <학생> <파일>          교재가 학생 프로필을 반영했는지 검증
  init-migration [레지스트리]   기존 데이터 마이그레이션 (native_language 필드 추가)
  report [레지스트리]          프로필 완성도 리포트 출력
EOF
    exit 1
    ;;
esac
