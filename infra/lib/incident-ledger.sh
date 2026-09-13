#!/usr/bin/env bash
# incident-ledger.sh — 사고 원장 (SELF-HEAL-PLAN 4a, 2026-09-05)
# 원장: ${BOT_HOME}/ledger/incidents.jsonl — append-only 이벤트 로그. 현재 상태는 이벤트를 접어서(fold) 만든다.
#
# 왜 이벤트 로그인가: runtime/ledger 는 덮어쓰지 않는다(정책). 사고의 "닫힘" 은 새 행(ev=close)으로만 기록되고,
# 닫힘에는 반드시 structural_fix(커밋·티켓)가 있어야 한다 — "교훈" 문장은 닫힘이 아니다.
#
# 이벤트 행:
#   {"ev":"open","ts","id","key","source","title","severity","by","cause_hypothesis","structural_fix","evidence"}
#   {"ev":"update","ts","id","patch":{...},"note"}
#   {"ev":"close","ts","id","structural_fix","cause_hypothesis","by"}
#   {"ev":"reopen","ts","id","note"}
#   {"ev":"discard","ts","id","reason"}      — 오탐·시험 호출. closed_by=discard, 닫힘으로 세지 않는다
# id = inc-YYYYMMDD-<sha256(key)[:8]> — key 가 같으면 같은 사고. key 는 "<source>:<식별자>" 형식.
#
# 함수:
#   incident_ledger                       → 원장 경로
#   incident_state                        → 현재 상태 JSON 배열 (opened_at 순)
#   incident_find <id|key>                → 현재 상태 1건 JSON (없으면 rc 1)
#   incident_open <source> <key> <title> [severity] [evidence_json] [cause] [fix] [by] [event_ts]
#                                         → stdout id. rc 0 신규 / 3 이미 알려진 사건 / 4 닫힌 사고의 재발(reopen 기록)
#                                           event_ts(ISO)가 있으면 closed_at 이후의 사건만 재발로 본다 — 센서 원장을
#                                           다시 훑을 때 같은 옛 행이 재발로 둔갑하지 않게. 없으면 지금 일어난 사건
#   incident_update <id|key> <patch_json> [note]
#   incident_close <id|key> <structural_fix> [cause] [by]   → fix 비면 rc 2
#   incident_reopen <id|key> [note]
#   incident_discard <id|key> <reason>    → 오탐 폐기 (사유 필수)
#   incident_open_count                   → 미닫힘 수
#   incident_summary                      → 주간 보고용 한 줄 + 미닫힘 목록

incident_ledger() {
    echo "${BOT_HOME:?BOT_HOME 미설정}/ledger/incidents.jsonl"
}

# JARVIS_INCIDENT_NOW(ISO UTC) 는 테스트가 사건 시각을 고정할 때만 쓴다 — 실행 경로에서는 설정하지 않는다
_incident_now() { [[ -n "${JARVIS_INCIDENT_NOW:-}" ]] && echo "$JARVIS_INCIDENT_NOW" || date -u +%Y-%m-%dT%H:%M:%SZ; }

_incident_id_for_key() {
    local key="$1" h
    h=$(printf '%s' "$key" | shasum -a 256 | cut -c1-8)
    echo "inc-$(date -u +%Y%m%d)-${h}"
}

_incident_append() {
    local row="$1" ledger; ledger=$(incident_ledger)
    mkdir -p "$(dirname "$ledger")"
    # 깨진 JSON 은 원장에 넣지 않는다
    printf '%s\n' "$row" | jq -c . >> "$ledger"
}

# 이벤트 → 현재 상태. jq 한 번으로 접는다.
incident_state() {
    local ledger; ledger=$(incident_ledger)
    [[ -f "$ledger" ]] || { echo '[]'; return 0; }
    # 깨진 행은 건너뛴다 (fromjson? — 한 줄이 깨졌다고 원장 전체를 못 읽으면 안 된다)
    jq -Rc 'fromjson? // empty' "$ledger" | jq -cs '
      map(select(type=="object" and .ev != null and .id != null))
      | reduce .[] as $e ({};
          if $e.ev == "open" then
            (if .[$e.id] == null then
              .[$e.id] = {id:$e.id, key:$e.key, source:$e.source, title:$e.title,
                          severity:($e.severity // "med"), opened_at:$e.ts, opened_by:($e.by // "auto"),
                          cause_hypothesis:($e.cause_hypothesis // ""), structural_fix:($e.structural_fix // ""),
                          evidence:($e.evidence // {}), closed_at:null, closed_by:null, discarded:false,
                          recurrences:0, notes:[], updated_at:$e.ts}
             else . end)
          elif .[$e.id] == null then .
          elif $e.ev == "update" then
            .[$e.id] = (.[$e.id] + ($e.patch // {}) | .updated_at = $e.ts
                        | if $e.note then .notes += [$e.note] else . end)
          elif $e.ev == "close" then
            .[$e.id] = (.[$e.id] | .closed_at = $e.ts | .closed_by = ($e.by // "human") | .updated_at = $e.ts
                        | .structural_fix = ($e.structural_fix // .structural_fix)
                        | .cause_hypothesis = ($e.cause_hypothesis // .cause_hypothesis))
          elif $e.ev == "reopen" then
            .[$e.id] = (.[$e.id] | .closed_at = null | .closed_by = null | .discarded = false | .recurrences += 1
                        | .updated_at = $e.ts | .notes += [($e.note // "reopen")])
          elif $e.ev == "discard" then
            .[$e.id] = (.[$e.id] | .closed_at = $e.ts | .closed_by = "discard" | .discarded = true
                        | .discard_reason = ($e.reason // "") | .updated_at = $e.ts)
          else . end)
      | [.[]] | sort_by(.opened_at)'
}

incident_find() {
    local q="$1" out
    out=$(incident_state | jq -c --arg q "$q" '.[] | select(.id == $q or .key == $q)' | head -1)
    [[ -n "$out" ]] || return 1
    echo "$out"
}

incident_open() {
    local source="$1" key="$2" title="$3" severity="${4:-med}" evidence="${5:-}" cause="${6:-}" fix="${7:-}" by="${8:-auto}" event_ts="${9:-}"
    [[ -n "$evidence" ]] || evidence='{}'
    [[ -n "$source" && -n "$key" && -n "$title" ]] || { echo "incident_open: source/key/title 필요" >&2; return 2; }
    case "$severity" in low|med|high) ;; *) echo "incident_open: severity 는 low|med|high" >&2; return 2 ;; esac
    printf '%s' "$evidence" | jq -e 'type=="object"' >/dev/null 2>&1 || { echo "incident_open: evidence 는 JSON object" >&2; return 2; }
    local cur
    if cur=$(incident_find "$key"); then
        local id closed; id=$(jq -r .id <<<"$cur"); closed=$(jq -r '.closed_at // ""' <<<"$cur")
        if [[ -z "$closed" ]]; then echo "$id"; return 3; fi
        # event_ts 가 있으면 닫힌 뒤에 일어난 사건만 재발. ISO(UTC, Z) 문자열은 사전순 비교가 시간순이다.
        # 없으면 '지금 일어난 사건' 이므로 무조건 재발 (사람이 CLI 로 넣는 경우)
        if [[ -n "$event_ts" && ! "$event_ts" > "$closed" ]]; then echo "$id"; return 3; fi
        [[ -n "$event_ts" ]] || event_ts=$(_incident_now)
        # 닫힌 사고의 재발 — 구조 수정이 버티지 못했다는 신호. reopen 으로 남긴다.
        _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --arg note "재발 ${event_ts}: $title" \
            '{ev:"reopen", ts:$ts, id:$id, note:$note}')"
        echo "$id"; return 4
    fi
    local id; id=$(_incident_id_for_key "$key")
    _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --arg key "$key" --arg source "$source" \
        --arg title "$title" --arg severity "$severity" --arg by "$by" --arg cause "$cause" --arg fix "$fix" \
        --argjson evidence "$evidence" \
        '{ev:"open", ts:$ts, id:$id, key:$key, source:$source, title:$title, severity:$severity, by:$by,
          cause_hypothesis:$cause, structural_fix:$fix, evidence:$evidence}')"
    echo "$id"
}

incident_update() {
    local q="$1" patch="${2:-}" note="${3:-}" cur id
    [[ -n "$patch" ]] || patch='{}'
    cur=$(incident_find "$q") || { echo "incident_update: 없음 — $q" >&2; return 1; }
    id=$(jq -r .id <<<"$cur")
    printf '%s' "$patch" | jq -e 'type=="object"' >/dev/null 2>&1 || { echo "incident_update: patch 는 JSON object" >&2; return 2; }
    # id·key·opened_at·closed_at 은 patch 로 못 바꾼다 (닫힘은 close 로만)
    patch=$(printf '%s' "$patch" | jq -c 'del(.id, .key, .opened_at, .closed_at, .closed_by, .recurrences, .notes)')
    _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --argjson patch "$patch" --arg note "$note" \
        '{ev:"update", ts:$ts, id:$id, patch:$patch} + (if $note != "" then {note:$note} else {} end)')"
    echo "$id"
}

incident_close() {
    local q="$1" fix="${2:-}" cause="${3:-}" by="${4:-human}" cur id
    [[ -n "$fix" ]] || { echo "incident_close: structural_fix(커밋·티켓) 없이는 닫지 않습니다" >&2; return 2; }
    cur=$(incident_find "$q") || { echo "incident_close: 없음 — $q" >&2; return 1; }
    id=$(jq -r .id <<<"$cur")
    if [[ "$(jq -r '.closed_at // ""' <<<"$cur")" != "" ]]; then echo "$id"; return 3; fi
    _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --arg fix "$fix" --arg cause "$cause" --arg by "$by" \
        '{ev:"close", ts:$ts, id:$id, structural_fix:$fix, by:$by} + (if $cause != "" then {cause_hypothesis:$cause} else {} end)')"
    echo "$id"
}

incident_reopen() {
    local q="$1" note="${2:-reopen}" cur id
    cur=$(incident_find "$q") || { echo "incident_reopen: 없음 — $q" >&2; return 1; }
    id=$(jq -r .id <<<"$cur")
    [[ "$(jq -r '.closed_at // ""' <<<"$cur")" != "" ]] || { echo "$id"; return 3; }
    _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --arg note "$note" '{ev:"reopen", ts:$ts, id:$id, note:$note}')"
    echo "$id"
}

# 오탐·시험 호출 등 사고가 아닌 행. 닫힘으로 세지 않고 '폐기' 로 따로 센다 (센서 오탐율의 분자).
incident_discard() {
    local q="$1" reason="${2:-}" cur id
    [[ -n "$reason" ]] || { echo "incident_discard: 사유가 필요합니다" >&2; return 2; }
    cur=$(incident_find "$q") || { echo "incident_discard: 없음 — $q" >&2; return 1; }
    id=$(jq -r .id <<<"$cur")
    if [[ "$(jq -r '.closed_at // ""' <<<"$cur")" != "" ]]; then echo "$id"; return 3; fi
    _incident_append "$(jq -nc --arg ts "$(_incident_now)" --arg id "$id" --arg reason "$reason" '{ev:"discard", ts:$ts, id:$id, reason:$reason}')"
    echo "$id"
}

incident_open_count() {
    incident_state | jq -r 'map(select(.closed_at == null)) | length'
}

# 주간 보고 첫 줄 + 미닫힘 목록. 사람이 읽는 형식.
incident_summary() {
    local st; st=$(incident_state)
    local now_s; now_s=$(date +%s)
    jq -r --argjson now "$now_s" '
      def age: (($now - (.opened_at | sub("\\.[0-9]+";"") | fromdateiso8601)) / 86400 | floor);
      (map(select(.closed_at == null))) as $open
      | ($open | map(select(.severity=="high")) | length) as $h
      | ($open | map(select(.severity=="med")) | length) as $m
      | ($open | map(select(.severity=="low")) | length) as $l
      | (map(select(.closed_at != null and (.discarded | not))) | length) as $closed
      | (map(select(.discarded)) | length) as $disc
      | (map(select(.recurrences > 0)) | length) as $rec
      | "미닫힘 사고 \($open|length)건 (high \($h) · med \($m) · low \($l)) — 닫힘 \($closed)건, 폐기(오탐·시험) \($disc)건, 재발 \($rec)건",
        ($open | sort_by(.severity | if .=="high" then 0 elif .=="med" then 1 else 2 end) | .[]
          | "  • \(.id) [\(.source)/\(.severity)] D+\(age) \(.title)"
            + (if .structural_fix != "" then " → 수정 진행: \(.structural_fix)" else "" end))' <<<"$st"
}
