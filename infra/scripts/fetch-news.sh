#!/usr/bin/env bash
# fetch-news.sh — RSS 기반 금융/시장 뉴스 크롤러
# 사용법: fetch-news.sh [키워드1] [키워드2] ...
# 예시: fetch-news.sh tariff trade war market
# 출력: 매칭 헤드라인 목록 (날짜·제목·출처)

set -euo pipefail

KEYWORDS=("${@:-tariff trade war market}")
MATCH_PATTERN=$(IFS="|"; echo "${KEYWORDS[*]}")

RSS_FEEDS=(
  "CNBC|https://www.cnbc.com/id/10000664/device/rss/rss.html"
  "CNBC_Markets|https://www.cnbc.com/id/20910258/device/rss/rss.html"
  "BBC_Biz|https://feeds.bbci.co.uk/news/business/rss.xml"
  "YahooFin|https://finance.yahoo.com/rss/topstories"
  "NYT_Biz|https://rss.nytimes.com/services/xml/rss/nyt/Business.xml"
)

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

python3 - "$MATCH_PATTERN" "${RSS_FEEDS[@]}" << 'PYEOF'
import sys, urllib.request, re
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone

pattern = sys.argv[1].lower()
feeds = sys.argv[2:]

results = []

for feed_spec in feeds:
    parts = feed_spec.split("|", 1)
    source, url = parts[0], parts[1]
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as r:
            xml = r.read().decode("utf-8", errors="ignore")

        titles = re.findall(r"<title><!\[CDATA\[(.*?)\]\]></title>|<title>(.*?)</title>", xml, re.DOTALL)
        dates  = re.findall(r"<pubDate>(.*?)</pubDate>", xml)
        links  = re.findall(r"<link>(.*?)</link>", xml)

        flat_titles = [a or b for a, b in titles if (a or b).strip() and "rss" not in (a or b).lower()][:30]
        for i, title in enumerate(flat_titles):
            title = title.strip()
            keywords = [k.strip() for k in pattern.split("|")]
            if any(k in title.lower() for k in keywords):
                pub = ""
                if i < len(dates):
                    try:
                        dt = parsedate_to_datetime(dates[i])
                        pub = dt.strftime("%m/%d %H:%M")
                    except:
                        pub = dates[i][:16]
                results.append((pub, source, title))
    except Exception as e:
        print(f"[{source}] 실패: {e}", file=sys.stderr)

if not results:
    print("해당 키워드 뉴스 없음")
else:
    results.sort(key=lambda x: x[0], reverse=True)
    for pub, src, title in results[:15]:
        print(f"[{pub}] [{src}] {title}")
PYEOF
