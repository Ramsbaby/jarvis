#!/usr/bin/env bash
set -euo pipefail

# Jarvis 스킬 기능 평가 — 크론 결과 검증 + 파일 구조 검증
# 크론: 주 1회 (일요일 04:30)
# result-check: 최근 크론 실행 결과의 키워드/패턴/길이 검증 (비용 $0)
# validate: 스킬 파일 구조 + 필수 섹션 검증 (비용 $0)

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
EVAL_CONFIG="$BOT_HOME/config/skill-evals/functional.json"
COMMANDS_DIR="$HOME/.claude/commands"
RESULT_DIR="$BOT_HOME/state/skill-eval-results"
LOG_FILE="$BOT_HOME/logs/skill-eval.log"
ROUTE_RESULT="$BOT_HOME/bin/route-result.sh"
DATE=$(date '+%Y-%m-%d')

mkdir -p "$RESULT_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

log "=== 스킬 기능 평가 시작 ==="

if [[ ! -f "$EVAL_CONFIG" ]]; then
    log "ERROR: $EVAL_CONFIG 없음"
    exit 1
fi

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
REPORT=""

# JSON 파싱용 Python 헬퍼
py_read() {
    python3 -c "
import json, sys
with open('$EVAL_CONFIG') as f:
    data = json.load(f)
skills = data['skills']
$1
"
}

SKILL_COUNT=$(py_read "print(len(skills))")

for i in $(seq 0 $((SKILL_COUNT - 1))); do
    # 스킬 정보 추출 (한국어 안전 파싱)
    SKILL_ID=$(py_read "print(skills[$i]['id'])")
    SKILL_NAME=$(py_read "print(skills[$i]['name'])")
    SKILL_MODE=$(py_read "print(skills[$i]['mode'])")

    if [[ "$SKILL_MODE" == "result-check" ]]; then
        # === 결과 검증: 최근 크론 실행 결과 검증 (비용 $0) ===
        result_dir_rel=$(py_read "print(skills[$i].get('result_dir', ''))")
        max_age_hours=$(py_read "print(skills[$i].get('max_age_hours', 48))")
        MIN_LEN=$(py_read "print(skills[$i].get('min_length', 50))")

        result_dir="$BOT_HOME/$result_dir_rel"
        if [[ ! -d "$result_dir" ]]; then
            REPORT="${REPORT}- ⚠️ **${SKILL_NAME}** · 결과 디렉토리 없음\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — 디렉토리 없음: $result_dir_rel"
            continue
        fi

        # 최신 .md 파일 찾기 (에러 파일 제외)
        result_file=$(find "$result_dir" -name "*.md" -not -name "*error*" -type f 2>/dev/null | sort | tail -1)
        if [[ -z "$result_file" ]]; then
            REPORT="${REPORT}- ⚠️ **${SKILL_NAME}** · 성공 결과 없음\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — .md 결과 파일 없음"
            continue
        fi

        # 파일 나이 확인
        file_age_sec=$(( $(date +%s) - $(stat -c '%Y' "$result_file" 2>/dev/null || stat -f %m "$result_file" 2>/dev/null || echo 0) ))
        file_age_hours=$((file_age_sec / 3600))
        if [[ "$file_age_hours" -gt "$max_age_hours" ]]; then
            REPORT="${REPORT}- ⚠️ **${SKILL_NAME}** · 결과 오래됨 (${file_age_hours}h > ${max_age_hours}h)\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — 결과 ${file_age_hours}h 경과 (max: ${max_age_hours}h)"
            continue
        fi

        output=$(cat "$result_file")
        output_len=${#output}

        if [[ "$output_len" -lt "$MIN_LEN" ]]; then
            REPORT="${REPORT}- ❌ **${SKILL_NAME}** · 출력 부족 (${output_len}자 < ${MIN_LEN}자)\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — 출력 부족 (${output_len}자)"
            continue
        fi

        # 키워드 검증
        missing_kw=""
        keywords=$(py_read "print('|'.join(skills[$i].get('expect_keywords', [])))")
        if [[ -n "$keywords" ]]; then
            IFS='|' read -ra KW_ARRAY <<< "$keywords"
            for kw in "${KW_ARRAY[@]}"; do
                if ! echo "$output" | grep -qi "$kw"; then
                    missing_kw="${missing_kw}${kw}, "
                fi
            done
        fi

        # 패턴 검증
        pattern=$(py_read "print(skills[$i].get('expect_pattern', ''))")
        pattern_ok=true
        if [[ -n "$pattern" ]]; then
            if ! echo "$output" | grep -qE "$pattern"; then
                pattern_ok=false
            fi
        fi

        if [[ -z "$missing_kw" && "$pattern_ok" == true ]]; then
            REPORT="${REPORT}- ✅ **${SKILL_NAME}** · ${output_len}자, ${file_age_hours}h전, 키워드 OK\n"
            TOTAL_PASS=$((TOTAL_PASS + 1))
            log "PASS: $SKILL_ID — ${output_len}자, ${file_age_hours}h전"
        else
            detail=""
            if [[ -n "$missing_kw" ]]; then detail="누락: ${missing_kw%%, }"; fi
            if [[ "$pattern_ok" == false ]]; then detail="${detail:+$detail, }패턴 미매칭"; fi
            REPORT="${REPORT}- ⚠️ **${SKILL_NAME}** · ${detail}\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "WARN: $SKILL_ID — $detail"
        fi

    elif [[ "$SKILL_MODE" == "validate" ]]; then
        # === 구조 검증: 파일 구조 + 필수 섹션 확인 ===
        skill_file="$COMMANDS_DIR/${SKILL_ID}.md"
        if [[ ! -f "$skill_file" ]]; then
            REPORT="${REPORT}- ⏭️ **${SKILL_NAME}** · 스킬 파일 없음\n"
            TOTAL_SKIP=$((TOTAL_SKIP + 1))
            log "SKIP: $SKILL_ID — 파일 없음"
            continue
        fi
        line_count=$(wc -l < "$skill_file" | tr -d ' ')
        min_lines=$(py_read "print(skills[$i].get('min_lines', 10))")

        if [[ "$line_count" -lt "$min_lines" ]]; then
            REPORT="${REPORT}- ❌ **${SKILL_NAME}** · ${line_count}줄 (최소 ${min_lines}줄)\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — 줄 수 부족 (${line_count}줄)"
            continue
        fi

        # 필수 섹션 확인
        missing_sections=""
        sections=$(py_read "print('|'.join(skills[$i].get('required_sections', [])))")
        if [[ -n "$sections" ]]; then
            IFS='|' read -ra SEC_ARRAY <<< "$sections"
            for sec in "${SEC_ARRAY[@]}"; do
                if ! grep -qi "$sec" "$skill_file"; then
                    missing_sections="${missing_sections}${sec}, "
                fi
            done
        fi

        if [[ -z "$missing_sections" ]]; then
            REPORT="${REPORT}- ✅ **${SKILL_NAME}** · ${line_count}줄, 필수 섹션 OK\n"
            TOTAL_PASS=$((TOTAL_PASS + 1))
            log "PASS: $SKILL_ID — 구조 검증 OK"
        else
            REPORT="${REPORT}- ❌ **${SKILL_NAME}** · 누락 섹션: ${missing_sections%%, }\n"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            log "FAIL: $SKILL_ID — 누락 섹션: ${missing_sections%%, }"
        fi
    fi
done

# 종합 리포트
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
if [[ "$TOTAL" -eq 0 ]]; then
    log "WARN: 평가 대상 없음"
    exit 0
fi
PASS_RATE=$((TOTAL_PASS * 100 / TOTAL))

SUMMARY="━━━━━━━━━━━━━━━━━━━━
🧪 스킬 기능 평가 ($DATE)
━━━━━━━━━━━━━━━━━━━━

**전체** · ${TOTAL_PASS}/${TOTAL} pass (${PASS_RATE}%)

$(echo -e "$REPORT")
━━━━━━━━━━━━━━━━━━━━"

# Discord 전송
if [[ -x "$ROUTE_RESULT" ]]; then
    "$ROUTE_RESULT" "discord" "skill-eval" "$SUMMARY" "jarvis-ceo" 2>>"$LOG_FILE" || true
fi

echo "$SUMMARY"

# 실패율 30% 이상 경고
if [[ "$PASS_RATE" -lt 70 ]]; then
    log "ALERT: pass rate ${PASS_RATE}%"
    if [[ -x "$BOT_HOME/scripts/alert.sh" ]]; then
        "$BOT_HOME/scripts/alert.sh" "warning" "스킬 평가 경고" "${PASS_RATE}% pass rate (${TOTAL_FAIL}건 실패)" 2>>"$LOG_FILE" || true
    fi
fi

log "=== 스킬 기능 평가 완료: ${TOTAL_PASS}/${TOTAL} (${PASS_RATE}%) ==="
