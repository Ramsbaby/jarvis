# Connections Weekly Insight

## 목적
지난 7일간 board-meeting에서 추출된 connections.jsonl을 분석해 크로스팀 패턴과 반복 인사이트를 #jarvis-ceo에 보고한다.

## 데이터 수집 (Step 1 — 반드시 실행)

```bash
# 최근 7일 connections 데이터 수집
python3 -c "
import json, datetime, sys
from pathlib import Path

f = Path('$HOME/.jarvis/state/connections.jsonl')
if not f.exists():
    print('NO_DATA')
    sys.exit(0)

cutoff = (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
entries = []
for line in f.read_text().strip().splitlines():
    try:
        d = json.loads(line)
        if d.get('date', '') >= cutoff:
            entries.append(d)
    except: pass

print(f'ENTRIES: {len(entries)}')
all_conns = [c for e in entries for c in e.get('connections', [])]
print(f'TOTAL_CONNECTIONS: {len(all_conns)}')

# 노드 빈도 집계
from collections import Counter
nodes = Counter()
for c in all_conns:
    nodes[c['from']] += 1
    nodes[c['to']] += 1
print('TOP_NODES:', json.dumps(nodes.most_common(8), ensure_ascii=False))

# 고강도 연결 (strength >= 0.7)
strong = [c for c in all_conns if c.get('strength', 0) >= 0.7]
print(f'STRONG_CONNECTIONS: {len(strong)}')
for c in strong[:5]:
    print(f'  [{c[\"strength\"]}] {c[\"from\"]} → {c[\"to\"]}')

# 반복 패턴 (같은 from-to가 2회 이상)
pairs = Counter((c['from'], c['to']) for c in all_conns)
repeated = [(k, v) for k, v in pairs.items() if v >= 2]
repeated.sort(key=lambda x: -x[1])
print('REPEATED_PATTERNS:', json.dumps(repeated[:5], ensure_ascii=False))
"
```

## 분석 기준 (Step 2)

데이터를 바탕으로 아래를 도출:

1. **핵심 허브 노드** — 가장 많이 연결된 상위 3개 노드. 이 노드가 왜 중요한지 한 줄 해석
2. **반복 패턴** — 이번 주 2회 이상 등장한 from→to 관계. 구조적 원인 추정
3. **강한 인과관계** — strength 0.8+ 연결만 추출. 대표님이 행동해야 할 근거로 활용
4. **위험 신호** — 시스템 이슈 ↔ 비즈니스 지표 연결이 반복되면 에스컬레이션

## 출력 포맷 (Step 3 — Discord #jarvis-ceo)

아래 형식을 **정확히** 따를 것. 마크다운 테이블 금지.

```
━━━━━━━━━━━━━━━━━━━━
🔗 주간 Connections 인사이트 (MM-DD ~ MM-DD)
━━━━━━━━━━━━━━━━━━━━
📊 분석 범위: N개 세션 / M개 연결

**핵심 허브**
- **[노드명]** · 이번 주 X회 등장 — [한 줄 해석]
- **[노드명]** · X회 — [한 줄 해석]

**반복 패턴 (구조적 징후)**
- [from] → [to] · X회 반복 — [원인 추정]
- [from] → [to] · X회 반복 — [원인 추정]

**강한 인과관계 (strength 0.8+)**
- [from] → [to] (0.X) — [행동 시사점]

**대표님 주목사항**
→ [이번 주 가장 중요한 패턴 + 권고 액션 1개]
━━━━━━━━━━━━━━━━━━━━
```

## 주의사항
- 데이터가 3일 미만이면 "데이터 누적 중 (N일)" 문구 추가 후 가용 데이터로 분석
- 수치 없는 해석 금지 — 반드시 strength 또는 빈도 수치 포함
- 1500자 이내
- 긍정편향 금지 — 반복되는 부정 패턴이 있으면 직접 명시
