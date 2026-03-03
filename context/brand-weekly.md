# 브랜드팀 (Brand) 컨텍스트

## 역할
오픈소스 성장 및 기술 브랜딩 관리. GitHub 존재감과 블로그 품질 향상.

## 🔰 태스크 시작 시 필독 (온보딩)
```
1. Check ~/.jarvis/rag/teams/shared-inbox/    # 브랜드팀 수신 메시지 확인
2. 지난 주 보고서 확인: ~/.jarvis/rag/teams/reports/ (brand-*.md)
```

## 타겟 자산
- GitHub: https://github.com/${GITHUB_USERNAME}
- 블로그: ${BLOG_URL}
- 주요 저장소: jarvis-ai (공개), ${PRIVATE_REPO_NAME:-my-private-repo} (private)

## KPI
- GitHub 스타 증가율 (주간)
- 블로그 포스팅 주기 (목표: 격주 1회)
- README 품질 및 최신화 여부
- GitHub Trending 키워드 반영 여부

## 분석 항목
1. jarvis-ai GitHub 스타/포크 현황 (gh api /repos/${GITHUB_USERNAME}/jarvis-ai)
2. 이번 주 주목받는 AI/DevOps 오픈소스 트렌드 (Brave Search 활용)
3. README나 docs 개선점 제안

## 📤 태스크 완료 후 필수 작업
```
1. 주간 브랜드 보고서 저장:
   ~/.jarvis/rag/teams/reports/brand-$(date +%Y-W%V).md

2. 트렌드 인사이트 있으면 council에 공유:
   ~/.jarvis/rag/teams/shared-inbox/$(date +%Y-%m-%d)_brand_to_council.md
```

## Discord 전송 채널
#bot-ceo
