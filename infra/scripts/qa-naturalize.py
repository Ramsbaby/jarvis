#!/usr/bin/env python3
"""
qa-naturalize.py — 면접 Q&A 답변 입말 자연스러움 다듬기

배경: 202개 Q&A의 approvedAnswer.content가 LLM 생성 후 후처리 없이
      쌓여 있어, 면접에서 발화하기 부자연스러운 어구·중복 문장 다수.
      각 답변을 면접 현장 격식체로 다듬되 사실은 절대 보존.

사용:
  python3 qa-naturalize.py --sample 10              # 10개 샘플 다듬어서 diff 출력
  python3 qa-naturalize.py --apply                  # 전체 다듬어서 SSoT 업데이트 (백업 자동)
  python3 qa-naturalize.py --apply --ids v92-S001   # 특정 ID만
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

# .env 로드
env_path = Path.home() / 'jarvis/runtime/.env'
if env_path.exists():
    for line in env_path.read_text().splitlines():
        for k in ('OPENAI_API_KEY',):
            if line.startswith(f'{k}='):
                os.environ[k] = line.split('=', 1)[1].strip().strip('"').strip("'")

from openai import OpenAI  # noqa: E402

SCENARIO_PATH = Path.home() / 'jarvis/runtime/state/scenarios/samsung-cnt.json'
MODEL = 'gpt-4o'  # 한국어 자연스러움 + 비용 균형
# 가격 (2025-04 기준): $2.50 IN / $10.00 OUT per M tokens
PRICE_IN = 2.50
PRICE_OUT = 10.00

SYSTEM_PROMPT = """당신은 면접 발표 답변을 자연스러운 입말로 다듬는 전문가입니다.

## 입력
백엔드 9년차 면접자([OWNER])의 답변 텍스트. [TARGET_COMPANY] 면접 대비.

## 목표
**면접관이 질문한 직후, 텍스트를 그대로 읽기만 해도 줄줄 말할 수 있는 인간 발화체**로 다듬는다.
종이에 쓴 글이 아니라 입 밖으로 나오는 말이다.
**문장 수가 줄어도 좋다.** 군더더기·중복·딱딱한 문어체 표현 제거가 핵심.

## 절대 보존 (변경 금지)
- 모든 수치 (5천만 건, 30대→5~8대, 75%, 20배, 0% 등)
- 회사명: [COMPANY_A], [PRODUCT_A], [COMPANY_B], [TARGET_COMPANY], 헥토, AWS
- 기술명: Redis, INCR, SET, Kafka, MySQL, gRPC, WebFlux, R2DBC, Spring Batch, HikariCP, ElastiCache, DLQ, SQS, Lambda, Datadog, CloudWatch, Redisson, Virtual Thread, JDBC Template, batchUpdate, JSON, Parquet 등
- 마크다운 **굵게** 표기 (개수·위치 모두 그대로)
- 줄바꿈 구조 (단락 구분)

## 톤 (보수 면접 - 삼성물산)
- 격식체: ~입니다, ~합니다, ~했습니다, ~드리겠습니다
- 정중하지만 단도직입
- 군말 제거: "음", "어", "이제", "그러니까"

## 금지 표현
- 친근체: ~이고요, ~인데요, ~거든요, ~잖아요, ~네요
- 추측/창작: 새로운 사실·수치·기술명 절대 추가 금지
- 같은 의미 중복: "그래서 그래서", "결과는 결과적으로"

## 허용 작업
- 문장 압축 (2~3문장 → 1문장)
- 어순 재조정 (주어-술어 가까이)
- 이중 주어 정리
- 부자연스러운 관형절 풀어쓰기

## 출력 형식 (JSON)
반드시 아래 JSON 한 객체만 출력. 마크다운 코드블록(```) 금지.
{
  "naturalized": "다듬은 전체 텍스트",
  "summary": "주요 변경 1줄 요약 (한국어, 30자 이내)"
}
"""


def call_llm(client, content):
    """단일 답변 다듬기. 실패 시 None 반환."""
    try:
        msg = client.chat.completions.create(
            model=MODEL,
            max_tokens=4096,
            temperature=0,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": content},
            ],
        )
        text = msg.choices[0].message.content.strip()
        data = json.loads(text)
        return data.get('naturalized'), data.get('summary'), msg.usage
    except Exception as e:
        print(f"  ❌ LLM 호출 실패: {e}", file=sys.stderr)
        return None, None, None


def safety_check(original, naturalized):
    """안전 검증. 통과 못하면 원본 유지."""
    issues = []
    # 길이 30% 이상 축소 금지
    orig_len, new_len = len(original), len(naturalized)
    if new_len < orig_len * 0.5:
        issues.append(f'길이 50%↓ ({orig_len}→{new_len})')
    # 수치 보존 (단순 검사: 핵심 수치들)
    KEY_NUMBERS = ['5천만', '30대', '5~8', '75', '20배', '3시간', '9분', '20초', '1억', '20만', '500',
                   '90', '45', '30초', '90초', '0%', '3%', '5도구', '5종', '100개', '10개', '50개',
                   '2주', '2일', '1주', '27만', '6개', '1만 호실', '1,500']
    orig_nums = set(n for n in KEY_NUMBERS if n in original)
    missing_nums = orig_nums - set(n for n in KEY_NUMBERS if n in naturalized)
    if missing_nums:
        issues.append(f'수치 누락: {missing_nums}')
    # 회사명/기술명 보존
    KEY_TERMS = ['[COMPANY_A]', '[PRODUCT_A]', '[COMPANY_B]', 'Redis', 'Kafka', 'gRPC', 'WebFlux',
                 'Spring Batch', 'HikariCP', 'ElastiCache', 'DLQ', 'Datadog', 'Redisson']
    for term in KEY_TERMS:
        if term in original and term not in naturalized:
            issues.append(f'키워드 누락: {term}')
    # 마크다운 굵게 개수
    orig_bold = original.count('**')
    new_bold = naturalized.count('**')
    if abs(orig_bold - new_bold) > 4:
        issues.append(f'**굵게 개수 변동 ({orig_bold}→{new_bold})')
    return issues


def select_sample(qs, n=10):
    """그룹별 골고루 + 길이 상위 1개"""
    by_group = {}
    for q in qs:
        g = q.get('group', '')
        by_group.setdefault(g, []).append(q)
    sample = []
    for g, items in by_group.items():
        if items and len(sample) < n - 1:
            sample.append(items[0])
    # 길이 상위 1개 추가
    longest = max(qs, key=lambda q: len((q.get('approvedAnswer') or {}).get('content', '')))
    if longest not in sample:
        sample.append(longest)
    return sample[:n]


def diff_summary(original, naturalized):
    """앞 200자 / 뒤 100자 보여주기"""
    def trim(t, n=180):
        return t.replace('\n', ' / ')[:n] + ('...' if len(t) > n else '')
    return f"  [원본 {len(original)}자]: {trim(original)}\n  [수정 {len(naturalized)}자]: {trim(naturalized)}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sample', type=int, default=0, help='샘플 N개만 다듬기 (출력만)')
    ap.add_argument('--apply', action='store_true', help='전체 다듬어서 SSoT 업데이트')
    ap.add_argument('--ids', nargs='+', help='특정 ID만')
    args = ap.parse_args()

    if not os.environ.get('OPENAI_API_KEY'):
        print('❌ OPENAI_API_KEY 미설정', file=sys.stderr)
        sys.exit(2)

    client = OpenAI()
    data = json.loads(SCENARIO_PATH.read_text())
    qs = data.get('qnaQuestions', [])
    print(f'전체 문항: {len(qs)}개')

    # 처리 대상 선정
    if args.sample:
        targets = select_sample(qs, args.sample)
        print(f'샘플 모드: {len(targets)}개 선정 (그룹별 골고루)')
    elif args.ids:
        targets = [q for q in qs if q.get('id') in args.ids]
    elif args.apply:
        targets = qs
        print(f'전체 적용 모드: {len(targets)}개')
    else:
        print('--sample N 또는 --apply 중 하나 필요', file=sys.stderr)
        sys.exit(1)

    # 백업
    if args.apply:
        ts = datetime.now().strftime('%Y%m%d-%H%M%S')
        backup = SCENARIO_PATH.with_suffix(f'.json.bak-naturalize-{ts}')
        backup.write_text(SCENARIO_PATH.read_text())
        print(f'✅ 백업: {backup}')

    total_in_tok = total_out_tok = 0
    applied = skipped = failed = 0
    detail_log = []  # 샘플 모드: 상세 결과 저장용

    for i, q in enumerate(targets, 1):
        qid = q.get('id', f'#{i}')
        content = (q.get('approvedAnswer') or {}).get('content', '')
        if not content.strip():
            print(f'[{i}/{len(targets)}] {qid}: 답변 없음, 건너뜀')
            continue

        print(f'\n[{i}/{len(targets)}] {qid} ({q.get("group", "")}) - {len(content)}자')
        nat, summary, usage = call_llm(client, content)
        if not nat:
            failed += 1
            continue

        if usage:
            total_in_tok += usage.prompt_tokens
            total_out_tok += usage.completion_tokens

        issues = safety_check(content, nat)
        status = 'BLOCKED' if issues else 'OK'
        if issues:
            print(f'  ⚠️ 안전검증 실패 → 원본 유지: {issues}')
            skipped += 1
        else:
            print(f'  ✅ {summary or "다듬음"}')
            if not args.sample:
                q['approvedAnswer']['content'] = nat
                applied += 1

        # 샘플 모드: 상세 로그 기록
        detail_log.append({
            'id': q.get('id'),
            'group': q.get('group'),
            'status': status,
            'issues': issues,
            'summary': summary,
            'orig_len': len(content),
            'new_len': len(nat),
            'original': content,
            'naturalized': nat,
        })

        time.sleep(0.3)  # rate limit 여유

    # 비용 추정
    cost = (total_in_tok / 1_000_000) * PRICE_IN + (total_out_tok / 1_000_000) * PRICE_OUT
    print(f'\n=== 완료 ===')
    print(f'토큰: in {total_in_tok:,} + out {total_out_tok:,}')
    print(f'비용: 약 ${cost:.3f}')
    print(f'적용 {applied} / 건너뜀 {skipped} / 실패 {failed}')

    if args.apply and applied > 0:
        SCENARIO_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        print(f'✅ 저장: {SCENARIO_PATH}')

    # 샘플/적용 공통: 상세 로그 저장
    if detail_log:
        ts = datetime.now().strftime('%Y%m%d-%H%M%S')
        log_path = Path.home() / f'jarvis/runtime/state/scenarios/qa-naturalize-log-{ts}.json'
        log_path.write_text(json.dumps(detail_log, ensure_ascii=False, indent=2))
        print(f'📋 상세 로그: {log_path}')


if __name__ == '__main__':
    main()
