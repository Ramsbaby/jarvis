#!/usr/bin/env python3
"""outfile-hook-holdout-measure.py — post-bash-outfile-verify 훅 14일 홀드아웃 측정.

자가개선 엔진 "교정 MVP" 전제 시험용:
  "실수 → 구조(코드 훅) 변경 → 재발 감소"가 실제로 성립하는가?

측정 대상 클러스터: promoter #103 cl-3565f45fbbb7c802
  ("검증 없이 파일 생성/완료 상태 보고 후 자기 정정")

지표 2종 (동일 regex 로 baseline·D+14 재현):
  · NARROW  = 훅이 실제로 잡는 부분집합(제품 파일 생성 실패류 오답 제목 수)
  · BROAD   = #103 클러스터 전체(파일 생성/업로드 완료 거짓보고류)
데이터 소스: ~/jarvis/runtime/state/mistake-ledger.jsonl (CLI Stop 훅 오답 추출 원장)
훅 활동:     ~/jarvis/runtime/ledger/outfile-verify.jsonl (훅이 실제 warn 낸 건수)

사용:
  python3 outfile-hook-holdout-measure.py --baseline   # baseline 기록(최초 1회, 2026-07-20)
  python3 outfile-hook-holdout-measure.py --measure     # D+14(2026-08-03) 이후 델타 측정
  python3 outfile-hook-holdout-measure.py               # 현재 창 조회만(기록 안 함)

주의(정직 표기):
  · 이 측정은 인과 증명이 아니라 상관 관찰이다. 훅은 CLI 표면에서만 warn 하고,
    재발 감소에는 다른 요인(작업량 변화·다른 가드)이 섞일 수 있다.
  · NARROW 는 제목 키워드 프록시라 ±오차가 있다. 훅 활동 원장(warn 건수)이 더 직접적 신호.
"""
import json
import os
import re
import sys
import datetime

HOME = os.path.expanduser("~")
MISTAKE_LEDGER = os.path.join(HOME, "jarvis/runtime/state/mistake-ledger.jsonl")
WARN_LEDGER = os.path.join(HOME, "jarvis/runtime/ledger/outfile-verify.jsonl")
BASELINE_FILE = os.path.join(HOME, "jarvis/runtime/ledger/outfile-hook-holdout-baseline.json")

# ── FROZEN 측정 regex (baseline 과 D+14 가 반드시 동일해야 함) ────────────
NARROW_RE = (
    r'(PDF|pdf).{0,6}(생성|완료|변환|미완|실패)|생성 완료.{0,6}미완|변환 실패|'
    r'렌더링.{0,4}미|파일 없이|미생성|0바이트|빈 파일|생성 실패|산출물 미생성|존재 선언'
)
BROAD_RE = (
    r'업로드 완료|저장 완료|생성 완료|파일 생성|생성 직후|생성했|업로드했|미생성|파일 없이'
)
ANCHOR = "2026-07-20"          # baseline 창의 끝(기준일)
HOLDOUT_DAYS = 14              # D+14


def _load_titles():
    recs = []
    try:
        with open(MISTAKE_LEDGER, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                ts = o.get("ts", "")
                for t in o.get("titles", []):
                    recs.append((ts, t))
    except Exception:
        pass
    return recs


def _days_before(ts, anchor_dt):
    try:
        d = datetime.datetime.fromisoformat(
            ts.replace("Z", "").split("+")[0].split(".")[0])
        return (anchor_dt - d).days
    except Exception:
        return 9999


def _count(recs, rx, anchor_dt, lo, hi):
    r = re.compile(rx)
    return sum(1 for ts, t in recs if r.search(t) and lo <= _days_before(ts, anchor_dt) < hi)


def _warn_count(anchor_dt, lo, hi):
    n = 0
    try:
        with open(WARN_LEDGER, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("event") != "warn":
                    continue
                if lo <= _days_before(o.get("ts", ""), anchor_dt) < hi:
                    n += 1
    except Exception:
        pass
    return n


def _windows(anchor_str):
    anchor_dt = datetime.datetime.fromisoformat(anchor_str)
    recs = _load_titles()
    return {
        "anchor": anchor_str,
        "narrow_last14d": _count(recs, NARROW_RE, anchor_dt, 0, 14),
        "narrow_prior14d": _count(recs, NARROW_RE, anchor_dt, 14, 28),
        "broad_last14d": _count(recs, BROAD_RE, anchor_dt, 0, 14),
        "broad_prior14d": _count(recs, BROAD_RE, anchor_dt, 14, 28),
        "hook_warn_last14d": _warn_count(anchor_dt, 0, 14),
    }


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--show"

    if mode == "--baseline":
        w = _windows(ANCHOR)
        rec = {
            "recorded_at": datetime.datetime.now().astimezone().isoformat(),
            "cluster": "cl-3565f45fbbb7c802",
            "cluster_label": "#103 검증 없이 파일 생성/완료 상태 보고",
            "hook": "post-bash-outfile-verify.sh",
            "defense_type": "A_hook",
            "anchor": ANCHOR,
            "measure_date_dplus14": "2026-08-03",
            "narrow_regex": NARROW_RE,
            "broad_regex": BROAD_RE,
            "baseline_windows": w,
            "note": "NARROW=훅 타깃 부분집합(제품파일 생성실패), BROAD=#103 전체. "
                    "상관 관찰이며 인과 아님. 훅 warn 원장이 더 직접적 신호.",
        }
        with open(BASELINE_FILE, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False, indent=2)
        print("BASELINE 기록 완료 ->", BASELINE_FILE)
        print(json.dumps(w, ensure_ascii=False, indent=2))
        return

    if mode == "--measure":
        today = datetime.date.today().isoformat()
        w = _windows(today)
        base = None
        if os.path.exists(BASELINE_FILE):
            base = json.load(open(BASELINE_FILE, encoding="utf-8"))
        print("=== D+14 홀드아웃 측정 (anchor=%s) ===" % today)
        print(json.dumps(w, ensure_ascii=False, indent=2))
        if base:
            b = base["baseline_windows"]
            print("\n=== baseline(2026-07-20) 대비 델타 ===")
            print("NARROW last14d: %d -> %d (델타 %+d)" % (
                b["narrow_last14d"], w["narrow_last14d"],
                w["narrow_last14d"] - b["narrow_last14d"]))
            print("BROAD  last14d: %d -> %d (델타 %+d)" % (
                b["broad_last14d"], w["broad_last14d"],
                w["broad_last14d"] - b["broad_last14d"]))
            print("훅 warn 건수(최근14d): %d (0보다 크면 패턴이 라이브로 발생·훅 발화 증명)" %
                  w["hook_warn_last14d"])
            print("\n판정 가이드: NARROW 하락 + 훅 warn>0 → '구조=재발감소' 전제 지지 신호. "
                  "NARROW 불변/상승 → 전제 반증 신호(또는 훅 미발화·작업량 증가 confound 점검).")
        return

    # default: 현재 창 조회만
    print(json.dumps(_windows(ANCHOR), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
