#!/usr/bin/env bash
# RAG Bug Detector - DB 데이터 품질 자동 감지
# 매일 03:10 실행. 수일간 발견 못한 버그를 자동 탐지.
# 감지: (1) 소스 편향, (2) discord-history 미인덱싱, (3) index-state vs DB 불일치
# 쿨다운: 24시간

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
RAG_LOG="$BOT_HOME/logs/rag-index.log"
INDEX_STATE="$BOT_HOME/rag/index-state.json"
LANCEDB_PATH="$BOT_HOME/rag/lancedb"
DISCORD_HISTORY_DIR="$BOT_HOME/context/discord-history"
COOLDOWN_FILE="$BOT_HOME/state/rag-bug-last-alert.txt"
COOLDOWN_SECONDS=86400  # 24시간
RESULTS_DIR="$BOT_HOME/results/rag-quality"
TODAY=$(date '+%Y-%m-%d')
REPORT_FILE="$RESULTS_DIR/$TODAY.md"

# ============================================================================
# Shared libraries
# ============================================================================
if [[ ! -f "$MONITORING_CONFIG" ]]; then
    echo "ERROR: monitoring.json not found at $MONITORING_CONFIG" >&2
    exit 1
fi

WEBHOOK="jarvis-system"
source "${BOT_HOME}/lib/discord-notify-bash.sh"

# ============================================================================
# 함수
# ============================================================================

is_in_cooldown() {
    if [[ ! -f "$COOLDOWN_FILE" ]]; then
        return 1
    fi
    local last_time
    last_time=$(head -1 "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    if [[ ! "$last_time" =~ ^[0-9]+$ ]]; then
        last_time=0
    fi
    local now
    now=$(date +%s)
    local elapsed=$((now - last_time))
    if [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
        return 0
    fi
    return 1
}

set_cooldown() {
    mkdir -p "$(dirname "$COOLDOWN_FILE")"
    date +%s > "$COOLDOWN_FILE"
}

# ============================================================================
# 감지 실행
# ============================================================================

issues_found=0
report_lines=()
report_lines+=("# RAG Bug Detector Report - $TODAY")
report_lines+=("")
report_lines+=("실행 시각: $(date '+%Y-%m-%d %H:%M:%S')")
report_lines+=("")

# --- (1) 소스 편향 감지 ---
report_lines+=("## 1. 소스 편향 감지")
report_lines+=("")

bias_result=$(LANCEDB_DIR="$LANCEDB_PATH" node -e "
const lancedb = require('@lancedb/lancedb');
(async () => {
    const db = await lancedb.connect(process.env.LANCEDB_DIR);
    const table = await db.openTable('documents');
    const total = await table.countRows();
    if (total === 0) {
        console.log(JSON.stringify({status:'empty', total:0, issues:[]}));
        return;
    }
    const rows = await table.query().select(['source']).limit(total).toArray();
    // Count by top-level path prefix
    const counts = {};
    rows.forEach(r => {
        // Normalize: extract path up to 3rd level under home
        const m = r.source.match(/^(\/Users\/[^/]+\/[^/]+\/[^/]+)\//);
        const key = m ? m[1] : r.source;
        counts[key] = (counts[key] || 0) + 1;
    });
    const issues = [];
    const sorted = Object.entries(counts).sort((a,b) => b[1]-a[1]);
    sorted.forEach(([path, count]) => {
        const pct = Math.round(count * 100 / total);
        if (pct >= 70) {
            issues.push({path, count, pct, severity:'critical'});
        } else if (pct >= 50) {
            issues.push({path, count, pct, severity:'warning'});
        }
    });
    console.log(JSON.stringify({status:'ok', total, top: sorted.slice(0,5).map(([p,c]) => ({path:p, count:c, pct:Math.round(c*100/total)})), issues}));
})().catch(e => { console.log(JSON.stringify({status:'error', message: e.message})); });
" 2>/dev/null) || bias_result='{"status":"error","message":"node execution failed"}'

bias_status=$(echo "$bias_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','error'))" 2>/dev/null || echo "error")

if [[ "$bias_status" == "error" ]]; then
    report_lines+=("- ERROR: LanceDB 쿼리 실패")
    report_lines+=("")
elif [[ "$bias_status" == "empty" ]]; then
    report_lines+=("- WARN: DB가 비어 있음 (0 chunks)")
    report_lines+=("")
    issues_found=$((issues_found + 1))
else
    total_chunks=$(echo "$bias_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])")
    report_lines+=("- 총 청크 수: $total_chunks")

    # Print top sources
    top_sources=$(echo "$bias_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('top', []):
    print(f\"  - {t['path']}: {t['count']} ({t['pct']}%)\")
")
    report_lines+=("- 상위 소스:")
    while IFS= read -r line; do
        report_lines+=("$line")
    done <<< "$top_sources"

    bias_issues=$(echo "$bias_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('issues',[])))")
    if [[ "$bias_issues" -gt 0 ]]; then
        issues_found=$((issues_found + 1))
        bias_detail=$(echo "$bias_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for i in d['issues']:
    print(f\"  - {i['severity'].upper()}: {i['path']} = {i['pct']}% ({i['count']} chunks)\")
")
        report_lines+=("- **편향 감지됨:**")
        while IFS= read -r line; do
            report_lines+=("$line")
        done <<< "$bias_detail"
    else
        report_lines+=("- 편향 없음 (70% 초과 소스 없음)")
    fi
    report_lines+=("")
fi

# --- (2) discord-history 인덱싱 확인 ---
report_lines+=("## 2. Discord History 인덱싱 확인")
report_lines+=("")

today_file="$DISCORD_HISTORY_DIR/$TODAY.md"
current_hour=$(date '+%H')

if [[ ! -f "$today_file" ]]; then
    # 오전 10시 이전이면 아직 생성 안 됐을 수 있음
    if [[ "$current_hour" -ge 10 ]]; then
        report_lines+=("- WARN: 오늘의 discord-history 파일 없음: $today_file")
        issues_found=$((issues_found + 1))
    else
        report_lines+=("- OK: 아직 오전 10시 이전, 파일 미생성 정상")
    fi
else
    # 파일이 있으면 index-state.json에 등록됐는지 확인
    if [[ -f "$INDEX_STATE" ]]; then
        indexed=$(IDX_PATH="$INDEX_STATE" IDX_KEY="$today_file" python3 -c "
import json, os
with open(os.environ['IDX_PATH']) as f:
    d = json.load(f)
key = os.environ['IDX_KEY']
if key in d:
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "error")
        if [[ "$indexed" == "yes" ]]; then
            report_lines+=("- OK: $today_file 인덱싱 확인됨")
        elif [[ "$indexed" == "no" ]]; then
            if [[ "$current_hour" -ge 10 ]]; then
                report_lines+=("- WARN: $today_file 존재하지만 인덱싱 안 됨")
                issues_found=$((issues_found + 1))
            else
                report_lines+=("- OK: 오전 10시 이전, 다음 인덱싱 사이클에서 처리 예정")
            fi
        else
            report_lines+=("- ERROR: index-state.json 파싱 실패")
        fi
    else
        report_lines+=("- WARN: index-state.json 파일 없음")
        issues_found=$((issues_found + 1))
    fi
fi
report_lines+=("")

# --- (3) index-state.json vs DB 청크 수 불일치 ---
report_lines+=("## 3. Index State vs DB 청크 수 일치 확인")
report_lines+=("")

if [[ -f "$INDEX_STATE" ]]; then
    state_count=$(IDX_PATH="$INDEX_STATE" python3 -c "import json,os; print(len(json.load(open(os.environ['IDX_PATH']))))" 2>/dev/null || echo "0")
else
    state_count="0"
    report_lines+=("- WARN: index-state.json 없음")
fi

# rag-index.log에서 마지막 total chunks 추출
if [[ -f "$RAG_LOG" ]]; then
    log_chunks=$(grep -oE '[0-9]+ total chunks' "$RAG_LOG" | tail -1 | grep -oE '^[0-9]+' || echo "0")
else
    log_chunks="0"
fi

# LanceDB 실제 행 수
db_chunks=$(LANCEDB_DIR="$LANCEDB_PATH" node -e "
const lancedb = require('@lancedb/lancedb');
(async () => {
    const db = await lancedb.connect(process.env.LANCEDB_DIR);
    const table = await db.openTable('documents');
    console.log(await table.countRows());
})().catch(() => console.log('0'));
" 2>/dev/null || echo "0")

report_lines+=("- index-state.json 소스 수: $state_count")
report_lines+=("- rag-index.log 마지막 total chunks: $log_chunks")
report_lines+=("- LanceDB 실제 행 수: $db_chunks")

# 불일치 체크: log_chunks vs db_chunks (25% 이상 차이)
if [[ "$log_chunks" -gt 0 ]] && [[ "$db_chunks" -gt 0 ]]; then
    diff_abs=$((log_chunks - db_chunks))
    if [[ $diff_abs -lt 0 ]]; then
        diff_abs=$(( -diff_abs ))
    fi
    diff_pct=$((diff_abs * 100 / log_chunks))
    if [[ $diff_pct -ge 25 ]]; then
        report_lines+=("- **불일치 감지**: log=$log_chunks vs db=$db_chunks (차이 ${diff_pct}%)")
        issues_found=$((issues_found + 1))
    else
        report_lines+=("- 일치 확인 (차이 ${diff_pct}%, 기준 25% 미만)")
    fi
elif [[ "$log_chunks" -eq 0 ]] && [[ "$db_chunks" -eq 0 ]]; then
    report_lines+=("- WARN: 둘 다 0, DB가 비어 있을 수 있음")
    issues_found=$((issues_found + 1))
fi
report_lines+=("")

# --- (4) LanceDB 크기·Fragment 경보 (2026-04-22 18GB·15834 fragment hang 사고 재발 방지) ---
report_lines+=("## 4. LanceDB 크기·Fragment 경보")
report_lines+=("")

if [[ -d "$LANCEDB_PATH/documents.lance" ]]; then
    # 활성 테이블만 측정 (격리본 제외 — verify 감사에서 적발된 범위 오류 수정)
    active_kb=$(du -sk "$LANCEDB_PATH/documents.lance" 2>/dev/null | awk '{print $1}')
    active_gb_int=$((active_kb / 1024 / 1024))

    if [[ -d "$LANCEDB_PATH/documents.lance/data" ]]; then
        frag_count=$(find "$LANCEDB_PATH/documents.lance/data" -maxdepth 1 -type f -name "*.lance" 2>/dev/null | wc -l | tr -d ' ')
    else
        frag_count=0
    fi

    report_lines+=("- 활성 테이블 크기: ${active_gb_int} GB")
    report_lines+=("- Fragment 수: $frag_count")

    if [[ "$active_gb_int" -ge 10 ]]; then
        report_lines+=("- **CRITICAL**: 활성 테이블 ${active_gb_int}GB — 즉시 compaction/rebuild 필요")
        issues_found=$((issues_found + 1))
    elif [[ "$active_gb_int" -ge 5 ]]; then
        report_lines+=("- **WARNING**: 활성 테이블 ${active_gb_int}GB — compaction 권고")
        issues_found=$((issues_found + 1))
    fi

    if [[ "$frag_count" -ge 5000 ]]; then
        report_lines+=("- **CRITICAL**: Fragment ${frag_count}개 — compaction 실패 의심")
        issues_found=$((issues_found + 1))
    elif [[ "$frag_count" -ge 1000 ]]; then
        report_lines+=("- **WARNING**: Fragment ${frag_count}개 — compaction 권고")
        issues_found=$((issues_found + 1))
    fi

    # 격리본은 별도 집계 — INFO/WARN 분리 (디스크 풀 리스크는 표시하되 issues_found 카운트 제외)
    broken_count=$(find "$LANCEDB_PATH" -maxdepth 1 -type d -name "documents.lance.broken-*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$broken_count" -gt 0 ]]; then
        broken_kb=$(du -sck "$LANCEDB_PATH"/documents.lance.broken-* 2>/dev/null | tail -1 | awk '{print $1}')
        broken_gb_int=$((broken_kb / 1024 / 1024))
        report_lines+=("- **INFO**: 격리본 ${broken_count}개, 총 ${broken_gb_int}GB — 7일 관찰 후 수동 정리 권고 (자동 삭제 금지)")
    fi
fi

report_lines+=("")

# ============================================================================
# 결과 저장 및 알림
# ============================================================================

report_lines+=("## 결론")
report_lines+=("")
if [[ $issues_found -gt 0 ]]; then
    report_lines+=("**${issues_found}개 이슈 감지됨** - 확인 필요")
else
    report_lines+=("모든 항목 정상")
fi

# 리포트 저장
mkdir -p "$RESULTS_DIR"
printf '%s\n' "${report_lines[@]}" > "$REPORT_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAG bug detector: $issues_found issues found. Report: $REPORT_FILE"

# 이슈 있으면 Discord 알림 (쿨다운 체크)
if [[ $issues_found -gt 0 ]]; then
    if is_in_cooldown; then
        echo "Cooldown active, skipping Discord alert."
    else
        summary="🔍 RAG Bug Detector - ${issues_found}개 이슈 감지"
        detail=""
        if [[ "$bias_issues" -gt 0 ]] 2>/dev/null; then
            detail="${detail}\n- 소스 편향 감지됨"
        fi
        if echo "${report_lines[*]}" | grep -q "discord-history.*없음\|인덱싱 안 됨"; then
            detail="${detail}\n- Discord history 인덱싱 이상"
        fi
        if echo "${report_lines[*]}" | grep -q "불일치 감지"; then
            detail="${detail}\n- Index vs DB 청크 수 불일치"
        fi
        message="$summary${detail}\n\n리포트: $REPORT_FILE"
        send_discord "$(echo -e "$message")"
        set_cooldown
    fi
fi