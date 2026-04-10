#!/usr/bin/env bash
# test-compress-analyzer.sh - 빠른 테스트용 스크립트

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
TEST_DIR="/tmp/quick-compress-test-$$"
OUTPUT_DIR="${BOT_HOME}/tmp/compress-loss-analysis"

echo "=== 빠른 테스트 실행 ==="

# 테스트 디렉토리 생성
mkdir -p "$TEST_DIR" "$OUTPUT_DIR"
trap "rm -rf '$TEST_DIR'" EXIT

# 1. 테스트 데이터 생성
cat > "$TEST_DIR/test-input.md" << 'EOF'
# Council Insight Test Data
Generated: 2026-03-22

## 팀별 상태
- Council팀: GREEN - 정상 운영, 성과 지표 95.2%
- Infra팀: GREEN - 안정적 인프라, 가동률 99.8%
- Record팀: NORMAL - 기록 관리 양호, 완료율 87.5%
- Career팀: NORMAL - 성장 지표 정상, 진행률 78.3%
- Brand팀: GREEN - 브랜드 관리 우수, 만족도 92.1%
- Academy팀: NORMAL - 학습 진행률 75.2%

## 시스템 상태
- 크론 성공률: 95.2%
- 시스템 가용성: 99.8%
- 평균 응답시간: 45ms
- 디스크 사용량: 68.4%
- 메모리 사용량: 72.1%

## 주요 이슈
1. 메모리 사용량이 72.1%로 주의 필요
2. 일부 크론 작업에서 간헐적 지연 발생 (3-5초)
3. 네트워크 트래픽 증가 추세 (30% 상승)
4. 백업 시스템 용량 부족 경고

## 권고사항
1. 메모리 최적화 작업 수행 권장
2. 크론 작업 간격 재조정 검토 (현재 5분 -> 3분)
3. 네트워크 모니터링 강화 필요
4. 백업 시스템 정기 점검 및 용량 확장
5. 로그 로테이션 정책 개선
EOF

# 2. smartCompress 테스트
echo "smartCompress 테스트 중..."

if [[ -f "${BOT_HOME}/lib/nexus/shared.mjs" ]]; then
    # Node.js로 압축 테스트
    node --input-type=module -e "
    import { readFileSync, writeFileSync } from 'fs';
    import { smartCompress } from '$BOT_HOME/lib/nexus/shared.mjs';

    const input = readFileSync('$TEST_DIR/test-input.md', 'utf-8');
    const compressed = smartCompress(input, 50);
    writeFileSync('$TEST_DIR/compressed-output.md', compressed);

    console.log('원본 크기:', input.length, 'bytes');
    console.log('압축 후 크기:', compressed.length, 'bytes');
    console.log('압축률:', ((1 - compressed.length / input.length) * 100).toFixed(2) + '%');
    "
else
    echo "ERROR: smartCompress 모듈을 찾을 수 없음"
    exit 1
fi

# 3. 간단한 손실률 분석
echo ""
echo "=== 손실률 분석 ==="

python3 -c "
import re

# 파일 읽기
with open('$TEST_DIR/test-input.md', 'r') as f:
    original = f.read()

with open('$TEST_DIR/compressed-output.md', 'r') as f:
    compressed = f.read()

# 수치 추출
orig_numbers = re.findall(r'\d+\.?\d*%?', original)
comp_numbers = re.findall(r'\d+\.?\d*%?', compressed)

# 팀 언급 추출
orig_teams = re.findall(r'(Council|Infra|Record|Career|Brand|Academy)', original, re.IGNORECASE)
comp_teams = re.findall(r'(Council|Infra|Record|Career|Brand|Academy)', compressed, re.IGNORECASE)

# 권고사항 개수
orig_recs = len(re.findall(r'^[0-9]+\.', original, re.MULTILINE))
comp_recs = len(re.findall(r'^[0-9]+\.', compressed, re.MULTILINE))

print(f'📊 손실률 분석 결과:')
print(f'- 원본 길이: {len(original)} bytes')
print(f'- 압축 후 길이: {len(compressed)} bytes')
print(f'- 압축률: {((1 - len(compressed) / len(original)) * 100):.1f}%')
print(f'- 수치 데이터: {len(orig_numbers)} -> {len(comp_numbers)} ({len(orig_numbers) - len(comp_numbers)} 손실)')
print(f'- 팀 언급: {len(orig_teams)} -> {len(comp_teams)} ({len(orig_teams) - len(comp_teams)} 손실)')
print(f'- 권고사항: {orig_recs} -> {comp_recs} ({orig_recs - comp_recs} 손실)')

# 텍스트 유사도 (간단 버전)
from difflib import SequenceMatcher
similarity = SequenceMatcher(None, original, compressed).ratio()
print(f'- 전체 유사도: {similarity:.1%}')
print(f'- 정보 손실률: {(1-similarity)*100:.1f}%')

if (1-similarity)*100 < 10:
    print('✅ 정보 손실률이 양호합니다')
elif (1-similarity)*100 < 20:
    print('⚠️ 정보 손실률이 주의 수준입니다')
else:
    print('❌ 정보 손실률이 높습니다')
"

echo ""
echo "=== 파일 확인 ==="
echo "원본 파일: $TEST_DIR/test-input.md"
echo "압축 파일: $TEST_DIR/compressed-output.md"

echo ""
echo "압축된 내용 미리보기:"
echo "======================"
head -15 "$TEST_DIR/compressed-output.md"

echo ""
echo "=== 테스트 완료 ==="