#!/usr/bin/env bash
# test-answered-the-question.sh — "물으신 것에 답했는가" 차단기 회귀 테스트
#
# 왜 있나 (2026-08-04):
#   하루 종일 주인님 질문과 다른 것을 냈다. 실패 두 종류가 반복됐다.
#     · 미룸 — 뼈대만 주고 "원하시면 채워드리겠습니다"로 알맹이를 다음 턴에 넘김
#     · 딴짓 — "왜 이러냐"고 물으셨는데 원인 대신 자료를 수집해 옴
#   텍스트 규칙을 다섯 번 고쳤고 전부 효과 0이었다. 그래서 차단(exit 2)으로 간다.
#
# 설계 실측 이력 (같은 실수를 다시 하지 않기 위해 남긴다):
#   1차 — 1500자/20배 게이트. 실제 실패가 문턱 아래로 빠져나갔다.
#   2차 — 800자/8배. 여전히 통과. 딴짓은 길이·배율과 무관하다는 게 드러났다.
#   3차 — 배율 게이트 폐기, 400자 비용 게이트만 유지. 4/4 통과.
#
# 주의: 케이스당 소형 모델을 부르므로 20초 안팎이 걸린다. 전체 ~1분.
#       테스트가 실제 프로젝트 디렉터리에 임시 트랜스크립트를 만들었다가 지운다.
#
# 실행: bash ~/projects/jarvis/infra/scripts/test-answered-the-question.sh

set -uo pipefail

HOOK="${HOME}/.claude/hooks/stop-answered-the-question.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "❌ 훅을 찾을 수 없음: $HOOK"
  exit 1
fi

HOOK="$HOOK" python3 <<'PYEOF'
import json, os, random, subprocess, sys, time

HOOK = os.environ["HOOK"]
PROJ = os.path.expanduser("~/.claude/projects/-Users-ramsbaby-jarvis")
os.makedirs(PROJ, exist_ok=True)

DEFER = (
 "음식이면 대만이 정답입니다.\n\n## 대만 음식 여행이 실패하는 이유\n"
 "못 찾아서가 아닙니다. 배가 안 꺼져서입니다. 한 끼에 배부르게 먹는 한국식 계획을 세우면 "
 "하루에 세 번밖에 못 먹습니다. 대만은 조금씩 자주 먹는 구조라 한 집에서 한두 가지만 시키고 옮겨야 합니다.\n\n"
 "## 야시장은 골라야 합니다\n스린은 관광객용입니다. 로컬이 가는 건 라오허제, 닝샤, 통화입니다.\n\n"
 "## 3일 뼈대\n1일차 오후 도착 — 저녁은 라오허제.\n2일차 — 아침 조식집, 점심 우육면, 저녁 닝샤 야시장.\n"
 "3일차 오전 — 조식 한 번 더.\n\n숙소는 중산역이나 시먼딩 근처가 낫습니다.\n\n"
 "가게 이름까지 박아서 시간대별로 짜드릴까요? 지금은 뼈대만 드린 거라, 원하시면 실제 상호로 채워드리겠습니다.")

OFFTOPIC = (
 "찾아서 바로 내겠습니다.\n\n## 조식\n푸항더우장 — 타이베이 메인스테이션 도보권. 대부분 6시에 열고 11시면 닫습니다.\n"
 "다쓰팡 — 단빙 전문, 메인스테이션 남쪽 한 블록, 7시 오픈.\n웨이딩 — 완화구 한커우가 2단 18호, 6:30~13:45.\n"
 "라오장자 — 24시간. 쌀가루 단빙이라 식감이 더 쫀득합니다.\n\n"
 "## 우육면\n천하삼절 — 仁愛路四段27巷3號. 11:30-14:30 / 17:30-20:30. 미슐랭 빕구르망. 육수를 6~8시간 고아냅니다.\n\n"
 "## 야시장\n라오허제 福州世祖胡椒餅 — 입구, 빕구르망. 전통 화덕에 굽습니다.\n"
 "닝샤 — 오후 4~5시 오픈. 일직선 동선. 굴전은 쭝청하오, 면은 똥파하오.\n\n"
 "## 망고빙수\n빙찬 — 双連街 2호, 11:00-21:00, 180TWD.\n스무시하우스 — 용캉제.\n"
 "개심복합식첨품 — 완화구 쿤밍가 262호 1층, 09:00-21:00.")

ANSWERED = (
 "오늘 한 것 세 덩어리입니다.\n\n첫째, 여행 질문에 협상 메모가 나온 사고를 고쳤습니다. 커리어 자료를 붙이는 훅이 "
 "글자만 보고 발동했고, 자료 끝의 '반영해 답할 것'이 주인님 질문을 이겼습니다. 그 명령문을 참고자료로 강등하고 "
 "글자 대신 문장 끝을 보게 고쳤습니다.\n\n둘째, 답변에 연봉 숫자가 나오면 정본과 대조해 틀리면 막는 장치를 만들었습니다. "
 "8월 3일 사고를 재현하니 정확히 차단됐습니다.\n\n셋째, 형식 계측기가 넷 중 하나꼴로 크론 출력을 재던 걸 막고 "
 "라벨링 도구를 만들었습니다.\n\n건드린 파일은 여덟 개고 회귀 테스트 21건이 전부 통과했습니다.")

CASES = [
    ("미룸 — 뼈대만 주고 '짜드릴까요'로 끝냄", "음식목적이 커", DEFER, "BLOCK"),
    ("딴짓 — '왜 이러냐'에 맛집 정보로 답함",
     "이게 아닌데. 내가 정보를 달라는게 아니라 답변이 왜이렇게 나오냐고 묻는거잖아. 근본적인 조치하라고",
     OFFTOPIC, "BLOCK"),
    ("정상 — 물으신 것에 답함", "뭐가 작업된거임?", ANSWERED, "PASS"),
    ("정상 — 짧은 수락 (모델 호출 없어야)", "커밋할까요?", "네, 하겠습니다.", "PASS"),
]

npass = nfail = 0
print("━━━ '물으신 것에 답했는가' 차단기 회귀 테스트 ━━━\n")
for desc, q, a, want in CASES:
    path = os.path.join(PROJ, f"aqregress{random.randint(10000, 99999)}.jsonl")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": q}},
                                ensure_ascii=False) + "\n")
            fh.write(json.dumps({"type": "assistant",
                                 "message": {"content": [{"type": "text", "text": a}]}},
                                ensure_ascii=False) + "\n")
        t0 = time.time()
        p = subprocess.run(["bash", HOOK],
                           input=json.dumps({"transcript_path": path, "session_id": "regress"}),
                           capture_output=True, text=True)
        el = time.time() - t0
    finally:
        try:
            os.remove(path)
        except OSError:
            pass

    got = "BLOCK" if p.returncode == 2 else "PASS"
    if got == want:
        npass += 1
        mark = "✅"
    else:
        nfail += 1
        mark = "💥"
    print(f"{mark} {got:<6}(기대 {want:<5}) {el:5.1f}s  {desc}")
    if got == "BLOCK":
        body = [l.strip() for l in p.stderr.splitlines() if l.strip()]
        if len(body) > 1:
            print(f"      → {body[1][:110]}")

print(f"\n━━━ 결과: {npass} 통과 / {nfail} 실패 ━━━")
sys.exit(1 if nfail else 0)
PYEOF
