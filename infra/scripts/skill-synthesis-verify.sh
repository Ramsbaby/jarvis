#!/usr/bin/env bash
# skill-synthesis-verify.sh
# council-insight(23:05 KST) 실행 후 10분 뒤(23:15 KST) SKILL_JSON 합성 결과 자동 검증
set -euo pipefail

SKILLS_FILE="${HOME}/jarvis/runtime/skills/skills.jsonl"
BOT_LOG="${HOME}/jarvis/runtime/logs/bot-cron.log"
TODAY=$(TZ=Asia/Seoul date '+%Y-%m-%d')
KST=$(TZ=Asia/Seoul date '+%H:%M KST')

echo "### 🔬 SKILL 합성 검증 — ${TODAY} ${KST}"
echo ""

# 1. council-insight 오늘 실행 여부 (로그에서 태스크 ID 확인)
ci_ran=$(grep "council-insight" "$BOT_LOG" 2>/dev/null | grep "$(date '+%Y-%m-%d')\|오늘\|DONE\|완료\|\[B1\]\|SKILL_JSON\|EUREKA_JSON" | tail -1 || true)
ci_log_tail=$(grep "council-insight" "$BOT_LOG" 2>/dev/null | tail -1 || true)
if [[ -n "$ci_log_tail" ]]; then
    echo "✅ council-insight 최근 로그: $(echo "$ci_log_tail" | cut -c1-120)"
else
    echo "⚠️ council-insight 로그 없음 — 오늘 미실행 가능성"
fi
echo ""

# 2. SKILL_JSON 합성 로그 확인 (오늘자 기준)
skill_log=$(grep "SKILL_JSON 자동 합성" "$BOT_LOG" 2>/dev/null | tail -3 || true)
if [[ -n "$skill_log" ]]; then
    echo "✅ SKILL_JSON 합성 감지:"
    while IFS= read -r line; do echo "  $line"; done <<< "$skill_log"
else
    echo "ℹ️ SKILL_JSON 합성 로그 없음"
    echo "  → LLM이 오늘 재사용 패턴을 발견하지 못한 경우 정상 (강제 출력 금지 설계)"
fi
echo ""

# 3. skills.jsonl 현황
if [[ -f "$SKILLS_FILE" ]]; then
    today_count=$(grep -c "\"${TODAY}" "$SKILLS_FILE" 2>/dev/null || echo 0)
    total_count=$(wc -l < "$SKILLS_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    echo "📚 skills.jsonl — 오늘 **${today_count}건** / 누계 **${total_count}건**"
    if [[ "$today_count" -gt 0 ]]; then
        echo ""
        echo "오늘 적재된 Skill:"
        grep "\"${TODAY}" "$SKILLS_FILE" 2>/dev/null \
            | jq -r '"  - [" + .type + "] " + .title' 2>/dev/null \
            || grep "\"${TODAY}" "$SKILLS_FILE" | head -3
    fi
else
    echo "⚠️ skills.jsonl 파일 없음 — 한 번도 적재된 적 없음"
fi
echo ""

# 4. EUREKA_JSON 처리 확인
eureka_log=$(grep "EUREKA_JSON 적재" "$BOT_LOG" 2>/dev/null | tail -2 || true)
if [[ -n "$eureka_log" ]]; then
    echo "✅ EUREKA_JSON: $(echo "$eureka_log" | tail -1 | cut -c1-100)"
else
    echo "ℹ️ EUREKA_JSON 적재 없음 (council-insight가 EUREKA 미출력 시 정상)"
fi

echo ""

# 5. 📊 GRADER — 오늘 적재된 Skill 품질 평가 (Hermes GEPA 경량 구현)
GRADES_FILE="${HOME}/jarvis/runtime/skills/grades.jsonl"
mkdir -p "${HOME}/jarvis/runtime/skills"

if [[ -f "$SKILLS_FILE" ]]; then
    today_skills=$(grep "\"${TODAY}" "$SKILLS_FILE" 2>/dev/null || true)
    if [[ -n "$today_skills" ]]; then
        echo "### 📊 품질 평가 (Grader)"
        grade_count=0
        while IFS= read -r skill; do
            [[ -z "$skill" ]] && continue
            skill_id=$(echo "$skill" | jq -r '.id // "unknown"' 2>/dev/null || true)
            title=$(echo "$skill" | jq -r '.title // ""' 2>/dev/null || true)
            pattern=$(echo "$skill" | jq -r '.pattern // ""' 2>/dev/null || true)
            evidence=$(echo "$skill" | jq -r '.evidence // [] | length' 2>/dev/null || echo 0)
            reusable=$(echo "$skill" | jq -r '.reusable_in // [] | length' 2>/dev/null || echo 0)
            skill_type=$(echo "$skill" | jq -r '.type // ""' 2>/dev/null || true)

            score=0
            # 기준 1: title 길이 10~40자
            title_len=${#title}
            [[ "$title_len" -ge 10 && "$title_len" -le 40 ]] && score=$((score+1))
            # 기준 2: pattern ≥ 30자
            pattern_len=${#pattern}
            [[ "$pattern_len" -ge 30 ]] && score=$((score+1))
            # 기준 3: evidence 1개 이상
            [[ "$evidence" -ge 1 ]] && score=$((score+1))
            # 기준 4: reusable_in 1개 이상
            [[ "$reusable" -ge 1 ]] && score=$((score+1))
            # 기준 5: 유효한 type enum
            case "$skill_type" in
                pattern|insight|correction|anti-pattern) score=$((score+1)) ;;
            esac

            if [[ "$score" -ge 3 ]]; then
                grade_label="✅ PASS"
            else
                grade_label="⚠️ FAIL"
            fi
            echo "  ${grade_label} [${score}/5] ${title:-$skill_id}"

            # grades.jsonl 적재
            grade_ts=$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S+09:00')
            grade_entry=$(jq -cn \
                --arg id "$skill_id" \
                --arg date "$TODAY" \
                --arg ts "$grade_ts" \
                --argjson score "$score" \
                --arg title "$title" \
                '{id:$id, date:$date, ts:$ts, score:$score, title:$title}')
            echo "$grade_entry" >> "$GRADES_FILE"
            grade_count=$((grade_count+1))
        done <<< "$today_skills"
        echo "  → ${grade_count}건 평가 완료 | grades.jsonl 적재"
    else
        echo "### 📊 품질 평가 (Grader)"
        echo "  ℹ️ 오늘 적재된 Skill 없음 — 평가 생략"
    fi
else
    echo "### 📊 품질 평가 (Grader)"
    echo "  ℹ️ skills.jsonl 없음 — 평가 생략"
fi
echo ""

# 6. 🧬 EVOLUTION SIGNAL — 최근 5건 평균 점수 < 3.0 시 PROMPT_IMPROVE 신호
echo "### 🧬 진화 신호 (Evolution Signal)"
if [[ -f "$GRADES_FILE" ]]; then
    total_entries=$(wc -l < "$GRADES_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "$total_entries" -ge 1 ]]; then
        # 최근 5건 점수 평균 (Python3 — bc보다 float 안정적)
        avg_score=$(tail -5 "$GRADES_FILE" | jq -r '.score' | \
            python3 -c "import sys; nums=[float(l) for l in sys.stdin if l.strip()]; print(f'{sum(nums)/len(nums):.2f}' if nums else '0')" 2>/dev/null || echo "0")
        echo "  최근 5건 평균 점수: **${avg_score} / 5.0**"

        # Python3 float 비교
        needs_improve=$(python3 -c "print('yes' if float('${avg_score}') < 3.0 else 'no')" 2>/dev/null || echo "no")
        if [[ "$needs_improve" == "yes" ]]; then
            echo ""
            echo "  ⚠️ 평균 점수 3.0 미만 → PROMPT_IMPROVE 신호 발동"
            echo ""
            echo "  **PROMPT_IMPROVE** (council-insight 프롬프트 개선 권고):"
            echo "  → SKILL_JSON 출력 시 'pattern' 필드를 30자 이상 구체적으로 기술하도록 지시 강화"
            echo "  → 'evidence' 배열에 반드시 파일 경로 또는 명령 출력 1개 이상 포함 지시"
            echo "  → 'reusable_in' 항목을 최소 2개 이상 예시로 제시하도록 지시"
            echo "  → title은 10~40자, 재사용 가능한 구조를 담아 작성하도록 지시"
            echo ""
            echo "  💡 council-insight.md promptFile의 SKILL_JSON 가이드라인 섹션을 위 기준으로 업데이트하십시오."
            echo "  → 결재: L4 (대표님) 승인 후 반영"
        else
            echo "  ✅ 평균 점수 3.0 이상 — 현재 프롬프트 품질 양호"
        fi
    else
        echo "  ℹ️ grades.jsonl 데이터 없음 — 다음 실행 시 평가 시작"
    fi
else
    echo "  ℹ️ grades.jsonl 없음 — 첫 평가 후 진화 신호 활성화"
fi

echo ""
echo "---"
echo "💡 0건이면 LLM이 패턴 없다고 판단 = 정상 동작. 3일 연속 0건이면 프롬프트 검토 권장."
