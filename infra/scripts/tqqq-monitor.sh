#!/usr/bin/env bash
# market-monitor.sh — Yahoo Finance v8에서 SOXL/NVDA/VIX 시세 조회
# WebSearch 불필요. python3 + urllib만 사용.
set -euo pipefail

python3 - << 'PYEOF'
import urllib.request, json
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
now_kst = datetime.now(KST).strftime("%H:%M")

def get_quote(sym):
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=2d"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.loads(r.read())
    meta = d["chart"]["result"][0]["meta"]
    price = meta.get("regularMarketPrice", 0)
    prev  = meta.get("chartPreviousClose") or meta.get("previousClose") or 0
    if not prev:
        closes = d["chart"]["result"][0].get("indicators", {}).get("quote", [{}])[0].get("close", [])
        closes = [c for c in closes if c is not None]
        prev = closes[-2] if len(closes) >= 2 else price
    chg = price - prev
    pct = (chg / prev * 100) if prev else 0
    return price, chg, pct

try:
    soxl_p, soxl_c, soxl_pct = get_quote("SOXL")
    nvda_p, nvda_c, nvda_pct = get_quote("NVDA")
    vix_p,  vix_c,  vix_pct  = get_quote("%5EVIX")
except Exception as e:
    print(f"⚠️ 시세 조회 실패: {e}")
    sys.exit(1)

def fmt_line(label, price, chg, pct):
    arrow = "▲" if chg >= 0 else "▼"
    direction = "오름" if chg >= 0 else "내림"
    return f"• {label}: ${price:.2f} ({arrow}{abs(pct):.2f}%, 어제보다 ${abs(chg):.2f} {direction})"

# VIX 분위기 판단
if vix_p >= 30:
    mood = f"VIX {vix_p:.1f} — 공포 구간. 레버리지 변동성 극심, 포지션 관리 필수."
elif vix_p >= 20:
    mood = f"VIX {vix_p:.1f} — 불확실 구간. 횡보 또는 변동성 주의."
else:
    mood = f"VIX {vix_p:.1f} — 안정 구간. 시장 변동성 낮음."

lines = [
    f"📊 시세 현황 [{now_kst} KST]",
    fmt_line("SOXL", soxl_p, soxl_c, soxl_pct),
    fmt_line("NVDA", nvda_p, nvda_c, nvda_pct),
    "",
    f"📝 시장 분위기",
    mood,
]

# 주의사항
warnings = []
if abs(soxl_pct) >= 5:
    warnings.append(f"⚡ SOXL {abs(soxl_pct):.1f}% 급{'등' if soxl_pct > 0 else '락'} 감지")

if warnings:
    lines += ["", "⚠️ 주의사항"] + warnings

import json as _json

# --- EMBED_DATA: Discord rich embed 카드 ---
# 색상: SOXL 기준
if soxl_pct >= 2:
    _color = 3066993    # green
elif soxl_pct >= 0:
    _color = 10070709   # grey-blue (neutral)
else:
    _color = 15158332   # red

def _pct_str(pct):
    arrow = "▲" if pct >= 0 else "▼"
    return f"{arrow}{abs(pct):.2f}%"

_embed = {
    "title": f"📊 시세 현황  [{now_kst} KST]",
    "color": _color,
    "fields": [
        {"name": "SOXL", "value": f"**${soxl_p:.2f}**  {_pct_str(soxl_pct)}", "inline": True},
        {"name": "NVDA", "value": f"**${nvda_p:.2f}**  {_pct_str(nvda_pct)}", "inline": True},
        {"name": "VIX", "value": mood, "inline": False},
    ],
    "footer": {"text": "Jarvis Market Monitor"}
}
if warnings:
    _embed["fields"].append({"name": "⚠️ 주의사항", "value": "\n".join(warnings), "inline": False})

print(f"EMBED_DATA:{_json.dumps(_embed, ensure_ascii=False)}")

# --- CHART_DATA: 변동률 바차트 ---
def _bar_color(pct):
    return "rgba(75,192,100,0.8)" if pct >= 0 else "rgba(255,99,132,0.8)"

_chart = {
    "type": "bar",
    "data": {
        "labels": ["SOXL", "NVDA"],
        "datasets": [{
            "label": "일간 변동률 (%)",
            "data": [round(soxl_pct,2), round(nvda_pct,2)],
            "backgroundColor": [_bar_color(soxl_pct), _bar_color(nvda_pct)]
        }]
    },
    "options": {
        "title": {"display": True, "text": f"일간 변동률 [{now_kst} KST]"},
        "legend": {"display": False},
        "scales": {"yAxes": [{"ticks": {"beginAtZero": False}}]}
    }
}
print(f"CHART_DATA:{_json.dumps(_chart, ensure_ascii=False)}")
PYEOF
