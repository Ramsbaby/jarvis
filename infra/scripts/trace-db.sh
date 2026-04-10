#!/usr/bin/env bash
set -euo pipefail

# trace-db.sh — 크론 트레이스 SQLite 저장소
# JSONL(task-runner.jsonl, retry.jsonl) → SQLite DB로 증분 적재 + 집계 쿼리
#
# Usage:
#   trace-db.sh init          — DB 초기화 (테이블 생성)
#   trace-db.sh sync          — JSONL → DB 증분 임포트
#   trace-db.sh stats         — 태스크별 통계 출력
#   trace-db.sh cost [days]   — 비용 절약 추정 (기본 7일)
#   trace-db.sh anomaly       — 실행 시간 이상 감지 (CV > 0.3)
#   trace-db.sh query "SQL"   — 직접 쿼리 실행

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DB="${BOT_HOME}/data/traces.db"
JSONL="${BOT_HOME}/logs/task-runner.jsonl"
RETRY_JSONL="${BOT_HOME}/logs/retry.jsonl"
SYNC_MARKER="${BOT_HOME}/data/.trace-sync-offset"

# --- init: 테이블 생성 ---
cmd_init() {
    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS traces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    task TEXT NOT NULL,
    status TEXT NOT NULL,
    msg TEXT,
    duration_s REAL DEFAULT 0,
    pid INTEGER,
    cost_usd REAL DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    total_tokens INTEGER GENERATED ALWAYS AS (input_tokens + output_tokens) STORED,
    imported_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_traces_task ON traces(task);
CREATE INDEX IF NOT EXISTS idx_traces_ts ON traces(ts);
CREATE INDEX IF NOT EXISTS idx_traces_status ON traces(status);

-- FTS5 전문검색 (msg 필드)
CREATE VIRTUAL TABLE IF NOT EXISTS traces_fts USING fts5(
    task, status, msg, content=traces, content_rowid=id
);

-- FTS5 자동 동기화 트리거
CREATE TRIGGER IF NOT EXISTS traces_ai AFTER INSERT ON traces BEGIN
    INSERT INTO traces_fts(rowid, task, status, msg)
    VALUES (new.id, new.task, new.status, new.msg);
END;
SQL
    echo "DB initialized: $DB"
}

# --- sync: JSONL → DB 증분 임포트 (Python으로 안전한 파라미터 바인딩) ---
cmd_sync() {
    if [[ ! -f "$JSONL" ]]; then
        echo "No JSONL file: $JSONL"
        return 0
    fi

    python3 - "$DB" "$JSONL" "$SYNC_MARKER" <<'PYEOF'
import sys, json, sqlite3, os

db_path, jsonl_path, marker_path = sys.argv[1], sys.argv[2], sys.argv[3]

# 마지막 동기화 오프셋
offset = 0
if os.path.exists(marker_path):
    with open(marker_path) as f:
        offset = int(f.read().strip() or 0)

file_size = os.path.getsize(jsonl_path)
if file_size <= offset:
    print(f"Already synced (offset={offset}, file={file_size})")
    sys.exit(0)

conn = sqlite3.connect(db_path)
cur = conn.cursor()
count = 0

with open(jsonl_path, 'r') as f:
    f.seek(offset)
    for line in f:
        line = line.strip()
        if not line or not line.startswith('{'):
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        # status 필드가 없으면 스킵 (비-트레이스 줄)
        if 'status' not in d or 'task' not in d:
            continue
        cur.execute(
            """INSERT INTO traces (ts, task, status, msg, duration_s, pid, cost_usd, input_tokens, output_tokens)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                d.get('ts', ''),
                d.get('task', ''),
                d.get('status', ''),
                d.get('msg', ''),
                d.get('duration_s', 0),
                d.get('pid', 0),
                d.get('cost_usd', 0),
                d.get('input_tokens', 0),
                d.get('output_tokens', 0),
            )
        )
        count += 1

conn.commit()
conn.close()

with open(marker_path, 'w') as f:
    f.write(str(file_size))

print(f"Synced {count} records ({file_size - offset} bytes, offset {offset} → {file_size})")
PYEOF
}

# --- stats: 태스크별 통계 ---
cmd_stats() {
    sqlite3 -header -column "$DB" <<'SQL'
SELECT
    task,
    COUNT(*) FILTER (WHERE status = 'success') AS ok,
    COUNT(*) FILTER (WHERE status IN ('error', 'timeout')) AS fail,
    ROUND(AVG(duration_s) FILTER (WHERE status = 'success'), 1) AS avg_dur_s,
    SUM(total_tokens) AS total_tok,
    ROUND(SUM(cost_usd), 4) AS total_cost,
    MAX(ts) AS last_run
FROM traces
WHERE status IN ('success', 'error', 'timeout')
GROUP BY task
ORDER BY total_tok DESC;
SQL
}

# --- cost: 비용 절약 추정 ---
cmd_cost() {
    local days="${1:-7}"
    sqlite3 -header -column "$DB" <<SQL
-- Claude Opus API 가격: \$15/1M input, \$75/1M output
-- Pro 플랜: \$20/월 고정
SELECT
    '최근 ${days}일' AS period,
    SUM(input_tokens) AS total_input_tok,
    SUM(output_tokens) AS total_output_tok,
    SUM(total_tokens) AS total_tok,
    ROUND(SUM(input_tokens) * 15.0 / 1000000, 2) AS api_input_cost,
    ROUND(SUM(output_tokens) * 75.0 / 1000000, 2) AS api_output_cost,
    ROUND(SUM(input_tokens) * 15.0 / 1000000 + SUM(output_tokens) * 75.0 / 1000000, 2) AS api_total_cost,
    ROUND(SUM(input_tokens) * 15.0 / 1000000 + SUM(output_tokens) * 75.0 / 1000000 - (20.0 * ${days} / 30), 2) AS savings,
    COUNT(*) FILTER (WHERE status = 'success') AS successful_runs
FROM traces
WHERE status = 'success'
  AND ts >= datetime('now', '-${days} days');
SQL
}

# --- anomaly: 실행 시간 이상 감지 (CV > 0.3) ---
cmd_anomaly() {
    echo "=== 실행 시간 이상 감지 (CV > 0.3, 최근 30일, 5회+ 실행) ==="
    sqlite3 -header -column "$DB" <<'SQL'
SELECT
    task,
    COUNT(*) AS runs,
    ROUND(AVG(duration_s), 1) AS avg_s,
    ROUND(MIN(duration_s), 1) AS min_s,
    ROUND(MAX(duration_s), 1) AS max_s,
    ROUND(
        CASE WHEN AVG(duration_s) > 0
        THEN (
            SQRT(AVG(duration_s * duration_s) - AVG(duration_s) * AVG(duration_s))
            / AVG(duration_s)
        )
        ELSE 0 END,
    3) AS cv
FROM traces
WHERE status = 'success'
  AND ts >= datetime('now', '-30 days')
GROUP BY task
HAVING COUNT(*) >= 5 AND cv > 0.3
ORDER BY cv DESC;
SQL
}

# --- query: 직접 쿼리 ---
cmd_query() {
    sqlite3 -header -column "$DB" "$1"
}

# --- Main ---
mkdir -p "$(dirname "$DB")"

case "${1:-help}" in
    init)    cmd_init ;;
    sync)    cmd_init; cmd_sync ;;
    stats)   cmd_stats ;;
    cost)    cmd_cost "${2:-7}" ;;
    anomaly) cmd_anomaly ;;
    query)   cmd_query "${2:?Usage: trace-db.sh query 'SQL'}" ;;
    help|*)
        echo "Usage: trace-db.sh {init|sync|stats|cost [days]|anomaly|query 'SQL'}"
        ;;
esac
