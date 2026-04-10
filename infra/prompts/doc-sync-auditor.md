문서-코드 정합성 감사 및 자동 적용을 수행해라.

## STEP 1: pending-doc-updates.json 확인
```
cat ~/.jarvis/state/pending-doc-updates.json 2>/dev/null || echo 'NO_PENDING'
```
파일이 없거나 'NO_PENDING'이면 STEP 2로 이동.
있으면 updates_needed 배열에서 status가 'pending'인 항목만 추출. 이 목록이 처리 대상.

## STEP 2: 오늘 변경된 파일 직접 확인 (fallback — STEP 1에서 pending 없을 때만)
- 오늘 변경 코드: find ~/.jarvis/lib ~/.jarvis/bin ~/.jarvis/scripts ~/.jarvis/discord ~/.jarvis/config -not -path '*/node_modules/*' -not -path '*/logs/*' \( -name '*.mjs' -o -name '*.js' -o -name '*.sh' -o -name '*.json' \) -daystart -mtime -1 2>/dev/null
- 오늘 변경 문서: find ~/.jarvis/docs ~/.jarvis/context -name '*.md' -daystart -mtime -1 2>/dev/null
- doc-map.json (config/doc-map.json) patterns 배열 순회: match_glob이 변경된 코드 파일과 매칭되면 docs 배열의 문서가 업데이트 대상

## STEP 3: 처리 대상 문서별 수정 (각 문서 독립적으로 처리)

각 문서에 대해 순서대로:
1. 문서 Read: cat {full_doc_path}
2. doc-map.json에서 이 문서를 포함하는 patterns 찾기 → reason 필드로 어떤 내용 변경인지 파악
3. 해당 코드 파일(match_glob 기준) Read
4. 어떤 섹션을 어떻게 바꿔야 하는지 분석
5. 백업 먼저: mkdir -p ~/.jarvis/state/doc-backups/ && cp {full_doc_path} ~/.jarvis/state/doc-backups/$(date +%Y%m%d)-$(basename {doc_path}).bak
6. 원본 문서의 해당 섹션만 수정 Write

각 문서 처리 후 결과를 JSONL로 기록:
```
echo '{"doc":"{doc_path}","status":"ok","changed_section":"..."}' >> ~/.jarvis/state/doc-sync-results-$(date +%F).jsonl
```
실패 시: echo '{"doc":"{doc_path}","status":"failed","reason":"..."}' >> ~/.jarvis/state/doc-sync-results-$(date +%F).jsonl
**오류가 나도 다음 문서 계속 처리.**

## STEP 4: commitments.jsonl 점검
```
cat ~/.jarvis/state/commitments.jsonl 2>/dev/null | grep '"status":"open"' | head -10
```
24시간 이상 open인 항목이 있으면 목록에 포함.

## STEP 5: pending-doc-updates.json 정리
results JSONL 파일에서 실패(status=failed) 항목 확인:
```
grep '"status":"failed"' ~/.jarvis/state/doc-sync-results-$(date +%F).jsonl 2>/dev/null
```
- **실패 0건**: rm -f ~/.jarvis/state/pending-doc-updates.json
- **실패 있음**: pending-doc-updates.json의 updates_needed 배열에서 성공한 항목 제거 후 재저장
  (python3 -c로 JSON 파싱: 성공한 doc_path 목록과 대조해 status=failed인 것만 남김)

## STEP 6: 결과 보고
- 보고서: ~/.jarvis/rag/teams/reports/doc-sync-$(date +%F).md 저장
- 형식 예시:
  | 문서 | 상태 | 변경 내용 | 트리거 코드 |
  |------|------|----------|------------|
  | docs/fsm-guide.md | ✅ 적용 | FSM 전이 섹션 갱신 | lib/task-fsm.mjs |
- 수정 1건 이상이면 Discord 전송. 이상 없으면 파일만 저장.