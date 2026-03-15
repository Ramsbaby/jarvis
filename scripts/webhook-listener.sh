#!/usr/bin/env bash
set -euo pipefail

# webhook-listener.sh — GitHub Webhook 수신기
#
# 동작 방식:
#   1. smee-client 방식 (기본): npx smee-client가 smee.io 채널을 구독하고
#      로컬 Python HTTP 서버로 Webhook payload를 포워딩
#   2. Python HTTP 서버가 payload를 수신 → HMAC-SHA256 서명 검증 →
#      GitHub 이벤트 타입별로 emit-event.sh 호출
#
# 필수 환경변수:
#   JARVIS_SMEE_URL          smee.io 채널 URL (예: https://smee.io/xxxxxxxxxx)
#   GITHUB_WEBHOOK_SECRET    GitHub Webhook 설정의 Secret 값 (HMAC-SHA256 검증용)
#
# 지원 이벤트:
#   X-GitHub-Event: pull_request (action=opened) → github.pr_opened
#   X-GitHub-Event: push                         → github.push
#   X-GitHub-Event: issues (action=opened)       → github.issue_opened
#
# 사용법:
#   JARVIS_SMEE_URL=https://smee.io/xxx GITHUB_WEBHOOK_SECRET=mysecret \
#     ~/.jarvis/scripts/webhook-listener.sh
#
# 직접 HTTP 서버만 기동 (smee 없이):
#   WEBHOOK_PORT=9000 GITHUB_WEBHOOK_SECRET=mysecret \
#     ~/.jarvis/scripts/webhook-listener.sh --no-smee

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
EMIT_EVENT="${BOT_HOME}/scripts/emit-event.sh"
LOG="${BOT_HOME}/logs/webhook-listener.log"
WEBHOOK_PORT="${WEBHOOK_PORT:-9000}"
NO_SMEE=false

# --- 인자 파싱 ---
for arg in "$@"; do
    case "$arg" in
        --no-smee) NO_SMEE=true ;;
        --help|-h)
            echo "Usage: webhook-listener.sh [--no-smee]"
            echo ""
            echo "Environment variables:"
            echo "  JARVIS_SMEE_URL          smee.io channel URL"
            echo "  GITHUB_WEBHOOK_SECRET    HMAC-SHA256 secret for payload verification"
            echo "  WEBHOOK_PORT             Local HTTP server port (default: 9000)"
            exit 0
            ;;
    esac
done

mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [webhook-listener] $*" | tee -a "$LOG"
}

# --- 사전 점검 ---
if [[ ! -x "$EMIT_EVENT" ]]; then
    log "ERROR: emit-event.sh를 찾을 수 없거나 실행 권한이 없음: ${EMIT_EVENT}"
    exit 1
fi

if [[ -z "${GITHUB_WEBHOOK_SECRET:-}" ]]; then
    log "WARN: GITHUB_WEBHOOK_SECRET 환경변수가 설정되지 않음 — HMAC 서명 검증 비활성화 (보안 위험)"
fi

# --- smee 방식 환경변수 검증 ---
if [[ "$NO_SMEE" == false ]]; then
    if [[ -z "${JARVIS_SMEE_URL:-}" ]]; then
        log "ERROR: JARVIS_SMEE_URL 환경변수가 설정되지 않았습니다."
        log ""
        log "설정 방법:"
        log "  1. https://smee.io/new 에 접속하여 새 채널 URL을 발급받으세요."
        log "  2. 발급된 URL(예: https://smee.io/xxxxxxxxxx)을 복사하세요."
        log "  3. GitHub 저장소 → Settings → Webhooks → Add webhook:"
        log "     Payload URL: https://smee.io/xxxxxxxxxx"
        log "     Content type: application/json"
        log "     Secret: (GITHUB_WEBHOOK_SECRET 값과 동일하게)"
        log "     Events: Pull requests, Pushes, Issues"
        log "  4. ~/.jarvis/config/webhook.env 파일에 아래 내용 추가:"
        log "     JARVIS_SMEE_URL=https://smee.io/xxxxxxxxxx"
        log "     GITHUB_WEBHOOK_SECRET=your-secret-here"
        log "  5. LaunchAgent plist의 EnvironmentVariables 섹션에 위 두 항목 추가"
        log "     또는 launchctl setenv 명령으로 직접 주입"
        exit 1
    fi
fi

# --- Python HTTP 서버 스크립트 생성 (임시 파일) ---
PYTHON_SERVER_SCRIPT=$(mktemp /tmp/jarvis-webhook-server.XXXXXX.py)
trap 'rm -f "$PYTHON_SERVER_SCRIPT"' EXIT

cat > "$PYTHON_SERVER_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Jarvis GitHub Webhook HTTP 서버
- POST / 수신 → HMAC-SHA256 검증 → 이벤트 타입 파싱 → emit-event.sh 호출
"""

import hashlib
import hmac
import http.server
import json
import logging
import os
import subprocess
import sys

PORT = int(os.environ.get("WEBHOOK_PORT", "9000"))
SECRET = os.environ.get("GITHUB_WEBHOOK_SECRET", "").encode()
EMIT_EVENT = os.environ.get("EMIT_EVENT_PATH", "")
LOG_FILE = os.environ.get("WEBHOOK_LOG", "")

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [webhook-server] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        *(
            [logging.FileHandler(LOG_FILE)]
            if LOG_FILE
            else []
        ),
    ],
)
logger = logging.getLogger(__name__)


def verify_signature(payload_body: bytes, signature_header: str) -> bool:
    """HMAC-SHA256 서명 검증 (GitHub 표준)"""
    if not SECRET:
        logger.warning("GITHUB_WEBHOOK_SECRET 미설정 — 서명 검증 건너뜀 (보안 위험)")
        return True
    if not signature_header or not signature_header.startswith("sha256="):
        logger.error("X-Hub-Signature-256 헤더 없음 또는 형식 오류")
        return False
    expected_sig = "sha256=" + hmac.new(
        SECRET, payload_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected_sig, signature_header)


def emit_event(event_name: str, payload: dict) -> None:
    """emit-event.sh 호출"""
    if not EMIT_EVENT or not os.path.isfile(EMIT_EVENT):
        logger.error(f"emit-event.sh 경로 없음: {EMIT_EVENT}")
        return
    try:
        payload_json = json.dumps(payload, ensure_ascii=False)
        result = subprocess.run(
            ["/bin/bash", EMIT_EVENT, event_name, payload_json],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            logger.info(f"emit-event.sh 성공: event={event_name}")
        else:
            logger.error(
                f"emit-event.sh 실패: event={event_name}, "
                f"rc={result.returncode}, stderr={result.stderr.strip()}"
            )
    except subprocess.TimeoutExpired:
        logger.error(f"emit-event.sh 타임아웃: event={event_name}")
    except Exception as e:
        logger.error(f"emit-event.sh 호출 오류: {e}")


def parse_and_emit(github_event: str, body: dict) -> None:
    """GitHub 이벤트 타입 → Jarvis 이벤트 매핑 및 발행"""

    if github_event == "pull_request":
        action = body.get("action", "")
        if action == "opened":
            pr = body.get("pull_request", {})
            repo = body.get("repository", {})
            payload = {
                "repo": repo.get("full_name", ""),
                "pr_number": pr.get("number", 0),
                "title": pr.get("title", ""),
                "author": pr.get("user", {}).get("login", ""),
                "url": pr.get("html_url", ""),
                "base_branch": pr.get("base", {}).get("ref", ""),
                "head_branch": pr.get("head", {}).get("ref", ""),
            }
            logger.info(
                f"PR opened: repo={payload['repo']}, pr=#{payload['pr_number']}"
            )
            emit_event("github.pr_opened", payload)
        else:
            logger.info(f"pull_request action={action} — 무시 (opened 외 이벤트)")

    elif github_event == "push":
        repo = body.get("repository", {})
        pusher = body.get("pusher", {})
        commits = body.get("commits", [])
        ref = body.get("ref", "")
        payload = {
            "repo": repo.get("full_name", ""),
            "ref": ref,
            "branch": ref.replace("refs/heads/", ""),
            "pusher": pusher.get("name", ""),
            "commit_count": len(commits),
            "head_commit_message": body.get("head_commit", {}).get("message", "")[:100],
            "compare_url": body.get("compare", ""),
        }
        logger.info(
            f"Push: repo={payload['repo']}, branch={payload['branch']}, "
            f"commits={payload['commit_count']}"
        )
        emit_event("github.push", payload)

    elif github_event == "issues":
        action = body.get("action", "")
        if action == "opened":
            issue = body.get("issue", {})
            repo = body.get("repository", {})
            payload = {
                "repo": repo.get("full_name", ""),
                "issue_number": issue.get("number", 0),
                "title": issue.get("title", ""),
                "author": issue.get("user", {}).get("login", ""),
                "url": issue.get("html_url", ""),
                "labels": [lbl.get("name", "") for lbl in issue.get("labels", [])],
            }
            logger.info(
                f"Issue opened: repo={payload['repo']}, issue=#{payload['issue_number']}"
            )
            emit_event("github.issue_opened", payload)
        else:
            logger.info(f"issues action={action} — 무시 (opened 외 이벤트)")

    elif github_event == "ping":
        zen = body.get("zen", "")
        hook_id = body.get("hook_id", "")
        logger.info(f"GitHub ping 수신 — hook_id={hook_id}, zen='{zen}'")

    else:
        logger.info(f"미지원 GitHub 이벤트: {github_event} — 무시")


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length)

            # smee-client 포워딩 헤더 지원 (x-original-* 접두사)
            github_event = (
                self.headers.get("X-GitHub-Event")
                or self.headers.get("x-original-x-github-event")
                or ""
            )
            signature = (
                self.headers.get("X-Hub-Signature-256")
                or self.headers.get("x-original-x-hub-signature-256")
                or ""
            )

            logger.info(
                f"POST {self.path} — event={github_event}, "
                f"size={len(raw_body)}B, "
                f"from={self.client_address[0]}"
            )

            # HMAC 검증
            if not verify_signature(raw_body, signature):
                logger.error("서명 검증 실패 — 요청 거부")
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'{"error":"signature verification failed"}')
                return

            # JSON 파싱
            try:
                body = json.loads(raw_body)
            except json.JSONDecodeError as e:
                logger.error(f"JSON 파싱 실패: {e}")
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'{"error":"invalid json"}')
                return

            # 이벤트 처리
            if github_event:
                parse_and_emit(github_event, body)
            else:
                logger.warning("X-GitHub-Event 헤더 없음 — 이벤트 타입 미식별")

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        except Exception as e:
            logger.error(f"요청 처리 중 예외: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error":"internal server error"}')

    def do_GET(self):
        """헬스체크 엔드포인트"""
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","service":"jarvis-webhook-listener"}')

    def log_message(self, format, *args):
        # Python HTTP 서버 기본 로그 억제 (우리 logger로 대체)
        pass


if __name__ == "__main__":
    logger.info(f"=== Jarvis Webhook HTTP 서버 시작 (port={PORT}) ===")
    logger.info(f"emit-event.sh: {EMIT_EVENT}")
    logger.info(f"HMAC 검증: {'활성화' if SECRET else '비활성화 (GITHUB_WEBHOOK_SECRET 미설정)'}")

    with http.server.ThreadingHTTPServer(("127.0.0.1", PORT), WebhookHandler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            logger.info("서버 종료 (KeyboardInterrupt)")
PYEOF

log "=== Jarvis Webhook Listener 시작 ==="
log "BOT_HOME=${BOT_HOME}"
log "WEBHOOK_PORT=${WEBHOOK_PORT}"
log "EMIT_EVENT=${EMIT_EVENT}"
log "NO_SMEE=${NO_SMEE}"

# --- smee-client 프로세스 관리 ---
SMEE_PID=""

cleanup() {
    log "종료 신호 수신 — 정리 중..."
    if [[ -n "$SMEE_PID" ]] && kill -0 "$SMEE_PID" 2>/dev/null; then
        log "smee-client 종료 (PID=$SMEE_PID)"
        kill "$SMEE_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# --- smee-client 기동 ---
if [[ "$NO_SMEE" == false ]]; then
    # npx smee-client 존재 여부 확인
    if ! command -v npx &>/dev/null; then
        log "ERROR: npx 명령을 찾을 수 없습니다. Node.js/npm이 설치되어 있어야 합니다."
        log "설치 방법: brew install node"
        exit 1
    fi

    log "smee-client 기동 중 — URL=${JARVIS_SMEE_URL} → http://127.0.0.1:${WEBHOOK_PORT}"
    npx smee-client \
        --url "${JARVIS_SMEE_URL}" \
        --target "http://127.0.0.1:${WEBHOOK_PORT}" \
        >> "$LOG" 2>&1 &
    SMEE_PID=$!
    log "smee-client 시작됨 (PID=${SMEE_PID})"

    # smee-client가 정상 기동되도록 잠시 대기
    sleep 2
    if ! kill -0 "$SMEE_PID" 2>/dev/null; then
        log "ERROR: smee-client 기동 실패. 로그를 확인하세요: ${LOG}"
        exit 1
    fi
else
    log "smee 없이 직접 HTTP 서버 모드 (로컬 Webhook 포워딩 또는 ngrok 사용 시)"
fi

# --- Python HTTP 서버 기동 (포그라운드) ---
log "Python Webhook HTTP 서버 기동 (port=${WEBHOOK_PORT})..."
exec env \
    WEBHOOK_PORT="${WEBHOOK_PORT}" \
    GITHUB_WEBHOOK_SECRET="${GITHUB_WEBHOOK_SECRET:-}" \
    EMIT_EVENT_PATH="${EMIT_EVENT}" \
    WEBHOOK_LOG="${LOG}" \
    python3 "$PYTHON_SERVER_SCRIPT"
