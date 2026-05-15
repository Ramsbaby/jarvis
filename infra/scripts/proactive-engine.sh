#!/usr/bin/env bash
set -euo pipefail

# proactive-engine.sh — 선제적 말걸기 엔진 v1.3
# 하루 3회 실행 (09:00 / 14:00 / 19:00 KST)
#
# 체크 0: self-watchdog        — 엔진 자체 30h+ 미실행 감지 → Discord 알림
# 체크 1: personal-dates.json  — 오늘/내일 중요일
# 체크 2: gog tasks            — 최근 완료된 면접·시험 키워드 항목
# 체크 3: 침묵 감지            — discord-history 3일+ 주인님 발화 없으면 안부
# 체크 4: follow-ups.json      — 이벤트 레지스트리 (하드코딩 없음, 데이터로 관리)
# 자가 점검: 각 체크 N회 연속 실패 시 Discord 알림

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
PERSONAL_DATES="$BOT_HOME/context/owner/personal-dates.json"
FOLLOW_UPS="$BOT_HOME/context/owner/follow-ups.json"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
STATE_FILE="$BOT_HOME/state/proactive-engine.json"
HISTORY_DIR="$BOT_HOME/context/discord-history"
LOG="$BOT_HOME/logs/proactive-engine.log"

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [proactive-engine] $*" | tee -a "$LOG"; }

log "=== proactive-engine 시작 ($(date '+%H:%M KST')) ==="

python3 - \
    "$PERSONAL_DATES" \
    "$FOLLOW_UPS" \
    "$MONITORING_CONFIG" \
    "$STATE_FILE" \
    "$HISTORY_DIR" \
    "${GOOGLE_ACCOUNT:-}" \
    "$LOG" << 'PYEOF'

import json
import sys
import subprocess
import os
import glob
from datetime import date, datetime, timedelta

personal_dates_file = sys.argv[1]
follow_ups_file = sys.argv[2]
monitoring_config_file = sys.argv[3]
state_file = sys.argv[4]
history_dir = sys.argv[5]
google_account = sys.argv[6]
log_file = sys.argv[7]

today = date.today()
today_str = today.strftime('%Y-%m-%d')

GOOGLE_TASKS_LIST_ID = "MDE3MjE5NzU0MjA3NTAxOTg4ODc6MDow"
SILENCE_THRESHOLD_DAYS = 3
ERROR_THRESHOLD = 3  # N회 연속 실패 시 Discord 알림


# ─── 공통 유틸 ───────────────────────────────────────────────────────────

def plog(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open(log_file, 'a') as f:
        f.write(f"[{ts}] [py] {msg}\n")


def load_config():
    with open(monitoring_config_file) as f:
        config = json.load(f)
    return config['webhooks']['jarvis']


def load_state():
    try:
        with open(state_file) as f:
            return json.load(f)
    except Exception:
        return {
            "sent_dates": {},
            "flags": {
                "samsung_result_asked": False,
                "samsung_asked_date": ""
            },
            "check_errors": {},
            "last_run": ""
        }


def save_state(s):
    with open(state_file, 'w') as f:
        json.dump(s, f, ensure_ascii=False, indent=2)


def send_discord(webhook_url, content):
    payload = json.dumps({"content": content}, ensure_ascii=False)
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "-H", "Content-Type: application/json",
             "-d", payload, webhook_url],
            capture_output=True, text=True, timeout=30
        )
        code = result.stdout.strip()
        if code.startswith('2'):
            plog(f"SENT OK: {content[:100]}")
            return True
        else:
            plog(f"SEND FAILED (HTTP {code}): {content[:100]}")
            return False
    except Exception as e:
        plog(f"SEND ERROR: {e}")
        return False


# ─── 자가 점검 헬퍼 ──────────────────────────────────────────────────────

def get_check_state(check_id):
    """체크별 에러 상태 딕셔너리 반환 (없으면 초기값 생성)"""
    return state.setdefault('check_errors', {}).setdefault(check_id, {
        'consecutive': 0, 'last_error': '', 'last_alerted': ''
    })


def notify_check_error(check_id, error_msg, force_once=False):
    """체크 실패 누적 → 임계치(3회) 이상 또는 force_once 시 Discord 알림 (당일 1회)"""
    cs = get_check_state(check_id)
    cs['consecutive'] = cs.get('consecutive', 0) + 1
    cs['last_error'] = str(error_msg)[:200]

    label_map = {
        'check1': '개인 중요일 파일(personal-dates.json)',
        'check2_gog': 'Google Tasks 인증(gog)',
        'check4': '팔로업 레지스트리(follow-ups.json)',
    }
    label = label_map.get(check_id, check_id)

    already_alerted_today = cs.get('last_alerted', '') == today_str
    should_alert = (force_once or cs['consecutive'] >= ERROR_THRESHOLD) and not already_alerted_today

    if should_alert:
        if force_once:
            msg = (f"⚠️ **Jarvis 선제 엔진 오류** — {label}\n"
                   f"원인: `{cs['last_error']}`\n"
                   f"> 재인증 또는 설정 확인이 필요합니다.")
        else:
            msg = (f"⚠️ **Jarvis 선제 엔진 오류** — {label} {cs['consecutive']}회 연속 실패\n"
                   f"원인: `{cs['last_error']}`")
        if send_discord(webhook_url, msg):
            cs['last_alerted'] = today_str
        plog(f"오류 알림 전송 [{check_id}] consecutive={cs['consecutive']} force={force_once}")

    save_state(state)
    plog(f"체크 오류 기록 [{check_id}] consecutive={cs['consecutive']}")


def reset_check_error(check_id):
    """체크 성공 → 연속 실패 카운트 초기화"""
    cs = get_check_state(check_id)
    if cs.get('consecutive', 0) > 0:
        plog(f"체크 오류 초기화 [{check_id}] ({cs['consecutive']}회 → 0)")
        cs['consecutive'] = 0
        save_state(state)


# ─── 초기화 ──────────────────────────────────────────────────────────────

try:
    webhook_url = load_config()
except Exception as e:
    plog(f"ERROR: monitoring.json 로드 실패: {e}")
    sys.exit(0)

state = load_state()
to_send = []  # (check_type, dedup_key, message[, fid])


# ─── 체크 0: self-watchdog (엔진 자체 미실행 30h+ 감지) ──────────────

plog("체크 0: self-watchdog 시작")
try:
    last_run_str = state.get('last_run', '')
    if last_run_str:
        last_run_dt = datetime.fromisoformat(last_run_str)
        hours_since = (datetime.now() - last_run_dt).total_seconds() / 3600
        if hours_since > 30:  # 하루 3회(8~10h 간격) → 30h = 최소 2회 이상 미실행
            alert_key = f"engine_stale_{today_str}"
            if alert_key not in state.get('sent_dates', {}):
                stale_msg = (
                    f"🔴 **Jarvis 선제 엔진 비정상** — {int(hours_since)}시간째 미실행\n"
                    f"마지막 정상 실행: {last_run_dt.strftime('%m/%d %H:%M KST')}\n"
                    f"> LaunchAgent 또는 크론 상태를 확인해 주세요. `/doctor` 실행 권장."
                )
                if send_discord(webhook_url, stale_msg):
                    state.setdefault('sent_dates', {})[alert_key] = today_str
                    save_state(state)
                plog(f"self-watchdog: {int(hours_since)}h 미실행 알림 전송")
            else:
                plog(f"self-watchdog: {int(hours_since)}h 미실행이나 오늘 이미 알림 전송됨")
        else:
            plog(f"self-watchdog PASS: 마지막 실행 {hours_since:.1f}h 전")
    else:
        plog("self-watchdog: 최초 실행 (last_run 없음)")
except Exception as e:
    plog(f"self-watchdog ERROR: {e}")


# ─── 체크 1: 개인 중요일 (오늘=D+0, 내일=D+1) ────────────────────────

plog("체크 1: personal-dates 스캔")
try:
    with open(personal_dates_file) as f:
        dates_data = json.load(f)
    reset_check_error('check1')  # 파일 읽기 성공 → 연속 실패 초기화

    sent_dates = state.setdefault('sent_dates', {})

    for entry in dates_data.get('dates', []):
        m = entry.get('month')
        d = entry.get('day')
        eid = entry.get('id', '')
        label = entry.get('label', '')
        emoji = entry.get('emoji', '🎉')
        msg_tmpl = entry.get('message', '')

        for offset, tag in [(0, 'today'), (1, 'tomorrow')]:
            try:
                check_date = date(today.year, m, d)
            except ValueError:
                continue

            diff = (check_date - today).days
            if diff != offset:
                continue

            dedup_key = f"{eid}_{tag}_{today_str[:7]}"  # 월별 1회만
            if dedup_key in sent_dates:
                plog(f"체크 1 SKIP: {dedup_key}")
                continue

            # greeting 필드 우선 사용, 없으면 message 폴백
            if offset == 0:
                raw = entry.get('greeting') or f"{emoji} {msg_tmpl}"
            else:
                raw = entry.get('tomorrow_greeting') or (
                    f"{emoji} **내일({check_date.strftime('%m/%d')})** "
                    f"{label} D-1 — 미리 알림드립니다."
                )

            # 변수 치환
            if 'birthYear' in entry:
                age = today.year - entry['birthYear']
                raw = raw.replace('{age}', str(age))
            if 'since' in entry:
                years = today.year - entry['since']
                raw = raw.replace('{years}', str(years))
            raw = raw.replace('{date}', check_date.strftime('%m/%d'))

            to_send.append(('personal_date', dedup_key, raw))
            plog(f"체크 1 TRIGGERED: {label} offset={offset}")

except FileNotFoundError:
    plog("체크 1 SKIP: personal-dates.json 없음")
    notify_check_error('check1', 'personal-dates.json 파일 없음')
except Exception as e:
    plog(f"체크 1 ERROR: {e}")
    notify_check_error('check1', str(e))


# ─── 체크 2: gog tasks 완료 항목 (면접·시험·결과 키워드) ─────────────

plog("체크 2: gog tasks 완료 항목 스캔")
TASK_KEYWORDS = ['면접', '시험', '인터뷰', '과제', 'SAA', 'SAP', '합격', '탈락', '결과', '전형', '코딩테스트']
try:
    cmd = ["gog", "tasks", "list", GOOGLE_TASKS_LIST_ID]
    if google_account:
        cmd += ["--account", google_account]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    if result.returncode == 0:
        reset_check_error('check2_gog')  # 성공 → 연속 실패 초기화
        lines = result.stdout.split('\n')
        for line in lines:
            if any(kw in line for kw in TASK_KEYWORDS):
                line_lower = line.lower()
                # 완료 표시: [x], ✅, completed
                if '[x]' in line_lower or '✅' in line or 'completed' in line_lower:
                    dedup_key = f"task_complete_{today_str}"
                    if dedup_key not in state.get('sent_dates', {}):
                        task_title = line.strip().lstrip('[xX] ').lstrip('✅ ').strip()
                        msg = f"📋 **{task_title[:60]}** 완료 처리하셨네요. 어떻게 됐나요?"
                        to_send.append(('task_complete', dedup_key, msg))
                        plog(f"체크 2 TRIGGERED: {task_title[:60]}")
                        break  # 하루 1건만
    else:
        stderr_text = result.stderr or ''
        if '403' in stderr_text or 'insufficient' in stderr_text.lower() or 'permission' in stderr_text.lower():
            notify_check_error('check2_gog',
                               'gog Auth 만료 (403 insufficientPermissions) — 재인증 필요',
                               force_once=True)
        else:
            notify_check_error('check2_gog', f'gog exit {result.returncode}: {stderr_text[:100]}')
        plog(f"체크 2: gog tasks 실패 (exit {result.returncode}) — skip")

except FileNotFoundError:
    plog("체크 2 SKIP: gog 명령 없음")
    notify_check_error('check2_gog', 'gog 명령어 없음 (PATH 설정 오류)', force_once=True)
except Exception as e:
    plog(f"체크 2 ERROR: {e}")
    notify_check_error('check2_gog', str(e))


# ─── 체크 3: 침묵 감지 (3일+ 대화 없음) — 주인님 직접 발화 기준 ────────────

plog("체크 3: 침묵 감지 (주인님 직접 발화 기준)")
try:
    # 파일명이 YYYY-MM-DD 또는 YYYY-MM-DD-HHMMSS 형식인 것 역순 정렬
    # mtime 기반 아님 — 봇 크론 메시지가 파일 갱신해도 오탐 없도록
    import re as _re
    history_files = sorted(
        [f for f in glob.glob(os.path.join(history_dir, '2*.md'))
         if _re.match(r'^\d{4}-\d{2}-\d{2}', os.path.basename(f))],
        reverse=True
    )

    # 주인님 직접 발화 패턴 (봇 자동 메시지·크론 알림 제외)
    OWNER_PATTERNS = ['**이정우**', '[이정우]', '[대화 상대]', 'User:']

    last_user_date = None
    for f in history_files:
        try:
            content = open(f, 'r', encoding='utf-8', errors='ignore').read()
            if any(p in content for p in OWNER_PATTERNS):
                fname = os.path.basename(f)[:10]  # YYYY-MM-DD
                last_user_date = datetime.strptime(fname, '%Y-%m-%d')
                break
        except Exception:
            continue

    if last_user_date:
        days_since = (datetime.now() - last_user_date).days
        if days_since >= SILENCE_THRESHOLD_DAYS:
            dedup_key = f"silence_{today_str[:7]}"  # 월별 1회
            if dedup_key not in state.get('sent_dates', {}):
                msg = f"🤫 주인님, {days_since}일간 조용하시네요. 잘 지내고 계신가요?"
                to_send.append(('silence', dedup_key, msg))
                plog(f"체크 3 TRIGGERED: {days_since}일 침묵 (마지막 발화: {last_user_date.strftime('%m/%d')})")
            else:
                plog("체크 3 SKIP: 이번 달 이미 전송됨")
        else:
            plog(f"체크 3 PASS: 마지막 주인님 발화 {days_since}일 전 ({last_user_date.strftime('%m/%d')})")
    else:
        plog("체크 3 SKIP: 히스토리 파일에서 주인님 발화 패턴 없음")

except Exception as e:
    plog(f"체크 3 ERROR: {e}")


# ─── 체크 4: follow-ups.json 레지스트리 (하드코딩 없음) ─────────────

plog("체크 4: follow-ups 레지스트리 스캔")
try:
    with open(follow_ups_file) as f:
        fu_data = json.load(f)
    reset_check_error('check4')  # 파일 읽기 성공 → 연속 실패 초기화

    followup_state = state.setdefault('follow_ups', {})

    for item in fu_data.get('items', []):
        fid = item.get('id', '')
        subject = item.get('subject', '')
        resolved = item.get('resolved', False)
        event_date_str = item.get('event_date', '')
        threshold = item.get('follow_up_after_days', 7)
        msg_tmpl = item.get('message', '')
        max_fu = item.get('max_follow_ups', 3)

        if resolved:
            plog(f"체크 4 SKIP [{fid}]: resolved=true")
            continue

        if not event_date_str:
            continue

        event_date = date.fromisoformat(event_date_str)
        days_since = (today - event_date).days

        if days_since < threshold:
            plog(f"체크 4 PASS [{fid}]: {days_since}일 경과 ({threshold}일 미달)")
            continue

        # 이미 오늘 전송했는지 dedup
        dedup_key = f"followup_{fid}_{today_str}"
        if dedup_key in state.get('sent_dates', {}):
            plog(f"체크 4 SKIP [{fid}]: 오늘 이미 전송됨")
            continue

        # 최대 횟수 초과 여부 확인
        fu_count = followup_state.get(fid, {}).get('count', 0)
        if fu_count >= max_fu:
            plog(f"체크 4 SKIP [{fid}]: 최대 횟수({max_fu}) 초과")
            continue

        msg = msg_tmpl.replace('{days}', str(days_since))
        to_send.append(('followup', dedup_key, msg, fid))
        plog(f"체크 4 TRIGGERED [{fid}]: {days_since}일 경과 (횟수 {fu_count+1}/{max_fu})")

except FileNotFoundError:
    plog("체크 4 SKIP: follow-ups.json 없음")
    notify_check_error('check4', 'follow-ups.json 파일 없음')
except Exception as e:
    plog(f"체크 4 ERROR: {e}")
    notify_check_error('check4', str(e))


# ─── 전송 & 상태 업데이트 ─────────────────────────────────────────────

# last_run 항상 기록 (체크 4개 완료 증거 — self-watchdog이 이 값으로 생존 확인)
state['last_run'] = datetime.now().isoformat()
save_state(state)

if not to_send:
    plog("전송 대상 없음 — 조용히 종료")
    sys.exit(0)

plog(f"전송 대상: {len(to_send)}건")

for item in to_send:
    check_type = item[0]
    dedup_key = item[1]
    msg = item[2]
    fid = item[3] if len(item) > 3 else None

    if send_discord(webhook_url, msg):
        if dedup_key:
            state.setdefault('sent_dates', {})[dedup_key] = today_str
        if check_type == 'followup' and fid:
            fu_st = state.setdefault('follow_ups', {}).setdefault(fid, {'count': 0})
            fu_st['count'] += 1
            fu_st['last_sent'] = today_str
        save_state(state)

plog(f"=== 완료: {len(to_send)}건 처리됨 ===")
PYEOF

EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    log "ERROR: Python 블록 실패 (exit $EXIT_CODE)"
    exit 1
fi

log "=== proactive-engine 종료 ==="
