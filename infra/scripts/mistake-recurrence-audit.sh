#!/usr/bin/env bash
# mistake-recurrence-audit.sh — 오답 재발 카운터 + 임계 초과 시 Discord 알림
#
# 매일 03:30 KST cron에서 실행. 지난 7일간 mistake-ledger.jsonl의 titles를
# 패턴 fingerprint(소문자 + 특수문자 제거)로 normalize 후 카운트.
# 같은 fingerprint가 3회 이상 재발했으면 구조적 실패 → Discord 경고.
#
# 목표: "오답은 기록만 되는 게 아니라 **재발 횟수 임계**가 울리게" 구조화.
#
# 안전 원칙:
#   - 파싱 실패해도 exit 0 (다른 크론 영향 없음)
#   - Discord 전송 실패해도 exit 0
#   - --dry-run 옵션 지원

set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER="${BOT_HOME}/state/mistake-ledger.jsonl"
REPORT_DIR="${BOT_HOME}/state"
REPORT_FILE="${REPORT_DIR}/mistake-recurrence.json"
EMBED_CACHE="${REPORT_DIR}/mistake-embedding-cache.json"  # 옵션 A (P1) — 임베딩 캐시
LOG="${BOT_HOME}/logs/mistake-recurrence.log"
DRY_RUN="${1:-}"

mkdir -p "$REPORT_DIR" "$(dirname "$LOG")"

ts() { TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z'; }

if [[ ! -f "$LEDGER" ]]; then
  echo "[$(ts)] ledger 없음 — skip" >> "$LOG"
  exit 0
fi

# 지난 7일 epoch
CUTOFF_EPOCH=$(TZ=Asia/Seoul date -v-7d '+%s' 2>/dev/null || TZ=Asia/Seoul date -d '7 days ago' '+%s')
THRESHOLD=3  # 재발 3회 이상이면 경고
SIM_THRESHOLD=0.50  # 옵션 A (P1) — 임베딩 cluster 임계치 (본질 동일 vs 무관 분리도 실측 기준)
EMBED_MODEL="snowflake-arctic-embed2"
EMBED_URL="http://localhost:11434/api/embeddings"

# ─── Python으로 fingerprint + 카운트 + 임베딩 클러스터링 (옵션 A) ───
REPORT=$(python3 <<PYEOF 2>/dev/null
import json, re, sys, hashlib, math, os, urllib.request, urllib.error
from collections import Counter
from datetime import datetime, timezone, timedelta

ledger_path = "$LEDGER"
cutoff_epoch = $CUTOFF_EPOCH
threshold = $THRESHOLD
sim_threshold = float("$SIM_THRESHOLD")
embed_cache_path = "$EMBED_CACHE"
embed_url = "$EMBED_URL"
embed_model = "$EMBED_MODEL"

def fingerprint(title):
    s = re.sub(r'[^\w가-힣]+', ' ', title.lower()).strip()
    s = re.sub(r'\s+', ' ', s)
    return s[:60]

def parse_ts(ts_str):
    try:
        ts_str = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', ts_str)
        return datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%S%z').timestamp()
    except Exception:
        try:
            ts_str2 = re.sub(r'\.\d+', '', ts_str)
            return datetime.strptime(ts_str2, '%Y-%m-%dT%H:%M:%S%z').timestamp()
        except Exception:
            return 0

# ─── 임베딩 호출 + 캐시 (옵션 A 가드 #8) ───
def _hash(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]

def load_embed_cache():
    if not os.path.exists(embed_cache_path):
        return {}
    try:
        with open(embed_cache_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

def save_embed_cache(cache):
    try:
        # cache 크기 제한 (오래된 항목 제거 — LRU 근사)
        if len(cache) > 2000:
            keys = list(cache.keys())[:1000]
            cache = {k: cache[k] for k in keys}
        with open(embed_cache_path, 'w', encoding='utf-8') as f:
            json.dump(cache, f, ensure_ascii=False)
    except Exception:
        pass

def embed_one(text, cache):
    h = _hash(text)
    if h in cache:
        return cache[h]
    try:
        req = urllib.request.Request(
            embed_url,
            data=json.dumps({"model": embed_model, "prompt": text}).encode('utf-8'),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            emb = json.loads(r.read())["embedding"]
        cache[h] = emb
        return emb
    except Exception:
        return None  # graceful fallback (Ollama 다운 등)

def cosine(a, b):
    dot = sum(x*y for x,y in zip(a,b))
    na = math.sqrt(sum(x*x for x in a))
    nb = math.sqrt(sum(x*x for x in b))
    return dot / (na * nb) if na * nb > 0 else 0.0

# ─── 1단계: 기존 fingerprint 카운트 (그대로 유지) ───
counter = Counter()
samples = {}
all_titles = []  # 옵션 A 클러스터링용
with open(ledger_path, 'r', encoding='utf-8') as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        ts_epoch = parse_ts(d.get('ts', ''))
        if ts_epoch < cutoff_epoch:
            continue
        for title in d.get('titles', []):
            fp = fingerprint(title)
            if not fp:
                continue
            counter[fp] += 1
            samples.setdefault(fp, []).append(title[:100])
            all_titles.append(title[:200])

recurring = {fp: n for fp, n in counter.items() if n >= threshold}

# ─── 2단계: 임베딩 클러스터링 (옵션 A 신규) ───
clusters = []
embed_status = "skipped"
embed_calls = 0
embed_cache_hits = 0
unique_titles = list(dict.fromkeys(all_titles))  # 중복 제거 (순서 유지)

if unique_titles:
    cache = load_embed_cache()
    embeddings = {}
    for t in unique_titles:
        h = _hash(t)
        if h in cache:
            embeddings[t] = cache[h]
            embed_cache_hits += 1
        else:
            emb = embed_one(t, cache)
            if emb is not None:
                embeddings[t] = emb
                embed_calls += 1
    save_embed_cache(cache)

    if embeddings:
        embed_status = f"ok (cache_hit={embed_cache_hits}, fresh={embed_calls})"
        # Greedy single-linkage clustering (시드 기준)
        used = set()
        for i, t in enumerate(unique_titles):
            if t in used or t not in embeddings:
                continue
            seed_emb = embeddings[t]
            cluster_members = [t]
            used.add(t)
            for j, u in enumerate(unique_titles):
                if u in used or u not in embeddings or i == j:
                    continue
                if cosine(seed_emb, embeddings[u]) >= sim_threshold:
                    cluster_members.append(u)
                    used.add(u)
            if len(cluster_members) >= 2:  # cluster size ≥ 2
                clusters.append({
                    'seed': cluster_members[0][:100],
                    'size': len(cluster_members),
                    'members': [m[:100] for m in cluster_members],
                })
        clusters.sort(key=lambda c: -c['size'])
    else:
        embed_status = "ollama_unreachable_fallback"

result = {
    'generated_at': datetime.now(tz=timezone(timedelta(hours=9))).isoformat(timespec='seconds'),
    'window_days': 7,
    'threshold': threshold,
    'total_unique_patterns': len(counter),
    'recurring_count': len(recurring),
    'top_recurring': [
        {'fingerprint': fp, 'count': n, 'sample_title': samples[fp][0]}
        for fp, n in sorted(recurring.items(), key=lambda x: -x[1])[:10]
    ],
    # 옵션 A 신규 필드
    'sim_threshold': sim_threshold,
    'embed_status': embed_status,
    'embed_calls': embed_calls,
    'embed_cache_hits': embed_cache_hits,
    'cluster_count': len(clusters),
    'top_clusters': clusters[:10],
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PYEOF
)

if [[ -z "$REPORT" ]]; then
  echo "[$(ts)] Python 파싱 실패 — skip" >> "$LOG"
  exit 0
fi

echo "$REPORT" > "$REPORT_FILE"
RECURRING_COUNT=$(echo "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['recurring_count'])" 2>/dev/null || echo 0)
CLUSTER_COUNT=$(echo "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cluster_count', 0))" 2>/dev/null || echo 0)
EMBED_STATUS=$(echo "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('embed_status', 'unknown'))" 2>/dev/null || echo unknown)

echo "[$(ts)] 재발 패턴 ${RECURRING_COUNT}건 (임계 ${THRESHOLD}회/7일) · 본질 cluster ${CLUSTER_COUNT}건 · embed=${EMBED_STATUS}" >> "$LOG"

# 옵션 A: cluster_count ≥ 2 또는 fingerprint recurring 있으면 알림
if [[ "$RECURRING_COUNT" -eq 0 && "$CLUSTER_COUNT" -lt 2 ]]; then
  exit 0
fi

# ─── Discord 알림 (임계 초과 시) ───
if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "[DRY RUN] 알림 예정:"
  echo "$REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"🚨 오답 재발 감지 (글자) — {d['recurring_count']}개 패턴이 최근 7일 {d['threshold']}회 이상 반복\")
for item in d['top_recurring'][:3]:
    print(f\"  · [{item['count']}회] {item['sample_title']}\")
clusters = d.get('top_clusters', [])
if clusters:
    print('')
    print(f\"🧠 본질 동일 cluster (의미) — {d.get('cluster_count', 0)}개 · sim≥{d.get('sim_threshold')} · {d.get('embed_status', '')}\")
    for c in clusters[:5]:
        print(f\"  · [{c['size']}건] 시드: {c['seed'][:80]}\")
        for m in c['members'][1:3]:
            print(f\"       ↪ {m[:80]}\")
"
  exit 0
fi

# send_discord 사용 (기존 라이브러리 재활용)
# shellcheck source=/dev/null
if [[ -f "${BOT_HOME}/lib/discord-notify-bash.sh" ]]; then
  source "${BOT_HOME}/lib/discord-notify-bash.sh"
  MSG=$(echo "$REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = []

# 1) fingerprint 재발 (기존)
if d['recurring_count'] > 0:
    lines.append(f\"🚨 **오답 재발 감지 (글자 매칭)** — {d['recurring_count']}개 패턴이 최근 {d['window_days']}일 {d['threshold']}회 이상 반복\")
    for i, item in enumerate(d['top_recurring'][:5], 1):
        lines.append(f\"{i}. [{item['count']}회] {item['sample_title']}\")
    lines.append('')

# 2) 임베딩 cluster (옵션 A 신규)
clusters = d.get('top_clusters', [])
if clusters:
    lines.append(f\"🧠 **본질 동일 cluster (의미 매칭)** — {d.get('cluster_count', 0)}개 cluster · sim≥{d.get('sim_threshold', 0)} · embed={d.get('embed_status', 'unknown')}\")
    for i, c in enumerate(clusters[:5], 1):
        lines.append(f\"{i}. [{c['size']}건] 시드: {c['seed']}\")
        for m in c['members'][1:3]:  # 시드 외 2건만 미리보기
            lines.append(f\"     ↪ {m}\")
    lines.append('')

lines.append(f\"리포트: ~/jarvis/runtime/state/mistake-recurrence.json\")
lines.append(f\"구조적 가드가 부재하다는 신호 — oops/verify 스킬로 즉각 재발방지 훅 신설 권고\")
print('\\n'.join(lines))
")
  send_discord "$MSG" "jarvis-system" 2>>"$LOG" || echo "[$(ts)] Discord 전송 실패 (webhook=jarvis-system)" >> "$LOG"
  echo "[$(ts)] Discord 알림 전송" >> "$LOG"
else
  echo "[$(ts)] discord-notify-bash.sh 없음 — Discord skip" >> "$LOG"
fi

exit 0
