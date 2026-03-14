# Weekly KPI Report

## 목적
매주 월요일 08:30에 지난 한 주간 봇 시스템 운영 KPI를 집계하고 Discord에 전송한다.

## PDCA — Plan 단계 핵심 리포트
이 리포트를 읽고 이번 주 목표를 설정한다.

## 데이터 수집 방법
- 크론 성공/실패: `grep -E "SUCCESS|FAILED" ~/.jarvis/logs/cron.log | tail -500`
- RAG 통계: `tail -1 ~/.jarvis/logs/rag-index.log`
- Discord 응답 건수: `wc -l < ~/.jarvis/logs/discord-bot.jsonl`
- 에러 빈도: `grep "ERROR\|FAILED" ~/.jarvis/logs/cron.log | wc -l`

## 리포트 구조
### 📊 이번 주 KPI

| 지표 | 목표 | 실제 | 상태 |
|------|------|------|------|
| 크론 성공률 | 90%+ | XX% | ✅/⚠️ |
| RAG 청크 수 | 증가 | XXXX | ✅/⚠️ |
| Discord 응답 | - | XX건 | - |

### ⚠️ 주요 실패 태스크
(실패 태스크 ID + 빈도)

### 💡 개선 제안
(최대 2개, 실행 가능한 것 우선)

## 자율처리율 (OKR 기반 자율 결정 실행율)

### 정의
board-meeting에서 자동 결정(decisions)된 항목 중 실제로 해당 태스크가 cron.log에 SUCCESS 기록을 남긴 비율.
`자율처리율 = executed / total × 100`

### 데이터 소스
- 결정사항 원본: `~/.jarvis/state/decisions/YYYY-MM-DD.jsonl`
- 실행 기록: `~/.jarvis/logs/cron.log` (SUCCESS 항목)
- 집계 결과: `~/.jarvis/state/autonomy-rate.json`

### 집계 방법 (decision-tracker.sh)
```bash
# 집계 실행 (board-meeting 파싱 + executed 판정 + 자율처리율 계산)
bash ~/.jarvis/scripts/decision-tracker.sh

# 최신 자율처리율 조회
python3 -c "
import json
d = json.load(open('$HOME/.jarvis/state/autonomy-rate.json'))
print(f'자율처리율: {d[\"autonomy_rate\"]}% ({d[\"executed\"]}/{d[\"total_decisions\"]}) — {d[\"window\"]} 기준')
print('팀별:', {t: f'{v[\"rate\"]}%' for t, v in d['by_team'].items()})
print('OKR별:', {o: f'{v[\"rate\"]}%' for o, v in d['by_okr'].items()})
"

# decisions.jsonl 직접 파싱 (날짜 지정)
python3 -c "
import json, os
d_dir = os.path.expanduser('~/.jarvis/state/decisions')
total = executed = 0
for f in sorted(os.listdir(d_dir)):
    if not f.endswith('.jsonl'): continue
    for line in open(os.path.join(d_dir, f)):
        line = line.strip()
        if not line: continue
        rec = json.loads(line)
        total += 1
        if rec.get('executed'): executed += 1
rate = round(executed/total*100,1) if total else 0
print(f'전체 자율처리율: {rate}% ({executed}/{total})')
"
```

### KPI 테이블 추가 항목
| 지표 | 목표 | 실제 | 상태 |
|------|------|------|------|
| 자율처리율 | 80%+ | `autonomy-rate.json` 참조 | ✅/⚠️ |

### 판정 기준
- 80%+ → GREEN (정상 자율 운영)
- 60~80% → YELLOW (점검 필요)
- 60% 미만 → RED (결정 → 실행 연결 이슈, 원인 분석 필수)

### 갱신 주기
- `decision-tracker.sh`는 매일 council-insight(23:00) 실행 시 또는 weekly-kpi 태스크에서 호출
- `autonomy-rate.json`은 실행 시마다 최신 7일 기준으로 덮어쓰기 갱신

## 주의사항
- 1800자 이내 Discord 전송
- 수치 없는 칭찬 금지 — 데이터로만 말하기
- Company DNA DNA-C004: 크론 성공률 90% 미달 시 반드시 원인 명시
