#!/usr/bin/env bash
# jira-sync.sh — JIRA 담당 티켓 전체 수집 → Vault 저장 + #jarvis-blog 포스팅
# 용도: 이력서/커리어 히스토리 업데이트 시 수동 실행
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARVIS_DIR="$(dirname "$SCRIPT_DIR")"
JIRA_ENV="$JARVIS_DIR/config/jira.env"
VAULT_FILE="$HOME/Jarvis-Vault/05-career/jira-work-history.md"
MONITORING="$JARVIS_DIR/config/monitoring.json"

# 인증 정보 로드
if [[ ! -f "$JIRA_ENV" ]]; then
  echo "ERROR: $JIRA_ENV 없음" >&2; exit 1
fi
source "$JIRA_ENV"

BLOG_WEBHOOK=$(python3 -c "
import json, sys
d = json.load(open('$MONITORING'))
print(d['webhooks']['jarvis-blog'])
")

OWNER_DISPLAY_NAME="${OWNER_DISPLAY_NAME:-$(echo "$JIRA_EMAIL" | cut -d@ -f1)}"
echo "[jira-sync] 티켓 수집 시작..."

python3 - "$JIRA_EMAIL" "$JIRA_API_TOKEN" "$JIRA_ACCOUNT_ID" "$VAULT_FILE" "$BLOG_WEBHOOK" "$OWNER_DISPLAY_NAME" "$JIRA_URL" << 'PYEOF'
import sys, urllib.request, base64, json, datetime, urllib.error

email, token, account_id, vault_file, webhook_url, display_name, jira_url = sys.argv[1:]

creds = base64.b64encode(f"{email}:{token}".encode()).decode()
headers = {
    "Authorization": f"Basic {creds}",
    "Accept": "application/json",
    "Content-Type": "application/json"
}

def jira_post(endpoint, payload):
    req = urllib.request.Request(
        f"{jira_url}{endpoint}",
        data=json.dumps(payload).encode(),
        headers=headers, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())

# 전체 티켓 수집
all_issues = []
next_page_token = None
while True:
    payload = {
        "jql": f'assignee = "{account_id}" ORDER BY updated DESC',
        "maxResults": 100,
        "fields": ["summary","status","project","issuetype","created","updated","priority","labels"]
    }
    if next_page_token:
        payload["nextPageToken"] = next_page_token

    data = jira_post("/rest/api/3/search/jql", payload)
    issues = data.get('issues', [])
    all_issues.extend(issues)
    next_page_token = data.get('nextPageToken')
    if not next_page_token or not issues:
        break

print(f"[jira-sync] 총 {len(all_issues)}개 티켓 수집")

# 프로젝트별 + 상태별 분류
projects = {}
status_groups = {"완료": [], "진행중": [], "대기": []}
done_keywords = ["done", "완료", "closed", "resolved"]
wip_keywords  = ["진행", "in progress", "in qa", "review"]

for issue in all_issues:
    f = issue['fields']
    proj_name = f['project']['name']
    proj_key  = f['project']['key']
    status    = f['status']['name'].lower()
    projects.setdefault(proj_key, {"name": proj_name, "issues": []})
    projects[proj_key]["issues"].append(issue)

    if any(k in status for k in done_keywords):
        status_groups["완료"].append(issue)
    elif any(k in status for k in wip_keywords):
        status_groups["진행중"].append(issue)
    else:
        status_groups["대기"].append(issue)

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

# ── Markdown 생성 ──
lines = [
    "---",
    "tags: [career, jira, work-history]",
    f"updated: {now}",
    "---",
    "",
    f"# JIRA 작업 이력 ({display_name})",
    "",
    f"> 마지막 동기화: {now}  ",
    f"> 총 담당 티켓: **{len(all_issues)}개**",
    "",
    "## 프로젝트별 요약",
    "",
]

for key, proj in sorted(projects.items(), key=lambda x: -len(x[1]["issues"])):
    issues = proj["issues"]
    done_cnt = sum(1 for i in issues if any(k in i['fields']['status']['name'].lower() for k in done_keywords))
    lines.append(f"### {proj['name']} ({key})")
    lines.append(f"- 총 {len(issues)}개 | 완료 {done_cnt}개 | 진행/대기 {len(issues)-done_cnt}개")
    lines.append("")

    # 상태 그룹별 출력
    for status_label in ["진행중·QA", "대기", "완료"]:
        if status_label == "진행중·QA":
            grp = [i for i in issues if any(k in i['fields']['status']['name'].lower() for k in wip_keywords)]
        elif status_label == "대기":
            grp = [i for i in issues if not any(k in i['fields']['status']['name'].lower() for k in done_keywords+wip_keywords)]
        else:
            grp = [i for i in issues if any(k in i['fields']['status']['name'].lower() for k in done_keywords)]

        if not grp:
            continue
        lines.append(f"#### {status_label} ({len(grp)})")
        for issue in grp:
            f = issue['fields']
            url = f"https://skdnd.atlassian.net/browse/{issue['key']}"
            updated = f['updated'][:10]
            lines.append(f"- [{issue['key']}]({url}) {f['summary'][:80]}  ")
            lines.append(f"  `{f['status']['name']}` | {updated}")
        lines.append("")

# 작업 유형 분석 (이력서용 키워드)
lines += [
    "## 작업 유형 분석 (이력서 키워드용)",
    "",
]
keywords = {
    "계약": ["계약"],
    "수납/결제": ["수납", "결제", "가상계좌", "입금"],
    "퇴실/정산": ["퇴실", "정산"],
    "공실/현황": ["공실", "현황"],
    "버그 수정": ["오류", "버그", "bug", "수정", "에러"],
    "API/연동": ["api", "연동", "인터페이스"],
    "성능/인프라": ["성능", "속도", "최적화", "인프라", "배포"],
}
for label, kws in keywords.items():
    matched = [i for i in all_issues if any(k in i['fields']['summary'].lower() for k in kws)]
    if matched:
        lines.append(f"- **{label}**: {len(matched)}건")
lines.append("")

with open(vault_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"[jira-sync] Vault 저장 완료: {vault_file}")

# ── Discord #jarvis-blog 포스팅 ──
proj_summary = "\n".join(
    f"  • **{v['name']}**: {len(v['issues'])}개"
    for k, v in sorted(projects.items(), key=lambda x: -len(x[1]["issues"]))
)
done_total = len(status_groups["완료"])
wip_total  = len(status_groups["진행중"])

discord_payload = {
    "username": "Jarvis Career",
    "embeds": [{
        "title": "📋 JIRA 작업 이력 동기화 완료",
        "description": f"**{display_name}** 님의 담당 티켓이 Vault에 저장됐습니다.",
        "color": 0x0052CC,
        "fields": [
            {"name": "총 티켓", "value": str(len(all_issues)), "inline": True},
            {"name": "완료", "value": str(done_total), "inline": True},
            {"name": "진행중·QA", "value": str(wip_total), "inline": True},
            {"name": "프로젝트별", "value": proj_summary, "inline": False},
            {"name": "저장 위치", "value": "`~/Jarvis-Vault/05-career/jira-work-history.md`", "inline": False},
        ],
        "footer": {"text": f"동기화 시각: {now}"},
        "url": f"{jira_url}/jira/your-work"
    }]
}

req = urllib.request.Request(
    webhook_url,
    data=json.dumps(discord_payload).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "JarvisBot/1.0"}, method="POST"
)
try:
    with urllib.request.urlopen(req) as r:
        print(f"[jira-sync] Discord #jarvis-blog 포스팅 완료")
except urllib.error.HTTPError as e:
    print(f"[jira-sync] Discord 포스팅 실패: {e.code} {e.read().decode()[:100]}")

PYEOF

echo "[jira-sync] 완료"
