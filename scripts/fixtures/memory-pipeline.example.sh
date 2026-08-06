# memory-pipeline.example.sh — test-memory-pipeline.sh 픽스처 템플릿
#
# 쓰는 법:
#   cp scripts/fixtures/memory-pipeline.example.sh \
#      scripts/fixtures/memory-pipeline.local.sh
#   # 그리고 .local.sh 의 값을 본인 세션 기록에 맞게 채운다
#
# 왜 분리했나:
#   ⑤ 주입 · ⑥ 원본 강제 주입 테스트는 "저장된 대화에서 원문이 실제로
#   딸려오는가"를 본다. 그러려면 검증 질문이 실제 대화 내용이어야 하고,
#   그 질문 자체가 개인정보가 된다. 공개 저장소에 남기지 않으려고
#   값만 이 파일로 뺐다.
#
#   .local.sh 가 없으면 ⑤⑥ 중 4개 항목이 SKIP 되고 나머지 15개는 그대로 돈다.
#   골격(검색·세션 저장·원문 복원·RAG 청킹)은 픽스처 없이도 전부 검증된다.

# ⑤ 커리어 사실이 우선 주입되는지 확인할 트리거 질문.
#    본인 기록에 커리어 관련 대화가 쌓여 있는 주제로 쓴다.
FX_CAREER_PROMPT="<커리어 주제 질문 한 줄>"

# ⑤ 주입 블록에서 '커리어 사실'로 셀 grep 패턴 (ERE, | 로 구분).
#    이 패턴에 걸린 항목이 전체의 70% 이상이어야 통과한다.
FX_CAREER_PATTERN="<키워드1>|<키워드2>|<키워드3>"

# ⑥(b) 원문 대조가 필요한 질문들 — 훅이 전부 발화해야 한다.
#      "누가 뭐라고 했지?" 처럼 과거 대화 원문을 되짚는 형태로 쓴다.
FX_RECALL_QUERIES=(
  "<원문 대조가 필요한 질문 1>"
  "<원문 대조가 필요한 질문 2>"
  "<원문 대조가 필요한 질문 3>"
)

# ⑥(c) 핵심 재현.
#      FX_CORE_QUERY 를 던졌을 때 FX_CORE_EXPECT 문자열이
#      [오너] 발화로 주입돼야 한다. EXPECT 는 저장된 대화에 실제로
#      들어 있는 문구를 그대로 쓴다.
FX_CORE_QUERY="<핵심 질문>"
FX_CORE_EXPECT="<저장된 대화에 실제로 있는 문구>"
