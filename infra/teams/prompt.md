[정보팀 일일 브리핑 — {{DATE}}]

**Step 1: 시세 데이터 (파일에서 읽기 — WebSearch 불필요)**
- {{BOT_HOME}}/results/stock-monitor/ 에서 최신 .md 파일 Glob 후 Read
- Stock/ETF/VIX 데이터를 거기서 가져와라

**Step 2: 뉴스 검색** (WebSearch 2회)
1. "AI LLM news today {{DATE}}" — 오늘 주요 AI 뉴스
2. "tech startup news {{DATE_MONTH}}" — 기술/스타트업 동향

**Step 3: 보고서 작성**

## 📡 정보팀 일일 브리핑 — {{DATE}}
**AI/Tech 주요 뉴스**
- [뉴스1 제목]: 한 줄 요약
- [뉴스2 제목]: 한 줄 요약

**기술 트렌드**
- {{OWNER_NAME}} 관심사(백엔드, Java, 비동기) 연관 트렌드 1-2개

**시장 동향** (stock-monitor 데이터 기반)
- Stock: $XX.XX (X.X%) | ETF: $XX.XX (X.X%)
