#!/usr/bin/env python3
"""
script-pdfaware-naturalize.py — 발표 스크립트 PDF 정합 + 입말 다듬기 (gpt-5.5-pro vision)

배경: 발표 스크립트 v11이 9차 검수 + PDF 정합 복원까지 거쳤으나,
      LLM에게 PDF 슬라이드 이미지 직접 보여주고 정합 검토 + 자연스러움 동시 다듬기.

특징:
- gpt-5.5-pro (Responses API, vision)
- 광범위 분석: PDF visible 텍스트 추출 → 충돌 식별 → B안 다듬기
- 비용 무관, 결과 품질 우선

사용:
  python3 script-pdfaware-naturalize.py
"""

import base64
import html
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

env_path = Path.home() / 'jarvis/runtime/.env'
for line in env_path.read_text().splitlines():
    if line.startswith('OPENAI_API_KEY='):
        os.environ['OPENAI_API_KEY'] = line.split('=', 1)[1].strip().strip('"').strip("'")

from openai import OpenAI  # noqa: E402

MODEL = 'gpt-5.5-pro'  # 최고 성능. Responses API 전용.
PDF_DIR = Path('/tmp/script-pdf-pages')
SCRIPT_MD = Path.home() / 'jarvis/runtime/career/samsung-cnt-2026-04-v3/20-presentation-script-v11.md'

SYSTEM_PROMPT = """당신은 면접 발표 스크립트 정합성·자연스러움 분석 전문가입니다.

## 입력 (한 슬라이드)
1) PDF 슬라이드 이미지 — 면접에서 청중에게 visible한 시각 자료. 변경 불가.
2) 현재 발표 스크립트 발화 텍스트 v11 — 9차 검수 + 사용자 직접 수정 + 1차 PDF 정합 복원이 끝난 상태.

## 목표
PDF 시각 자료와 발화 텍스트를 동시에 분석해서, 다음을 모두 수행한다:
1. PDF에 visible한 모든 핵심 텍스트(제목·부제·박스·강조어·수치·각주) 전수 식별
2. 발화 텍스트에서 PDF 키워드가 누락됐는지 검사 (청중이 슬라이드 보면서 발화와 어긋남 인지하는 위험)
3. 발화 텍스트에 있지만 PDF에 없는 단어 식별 (창작·과장·환각 위험)
4. 어휘·뜻·강도 측면 충돌 탐지 (예: PDF "검토 중" vs 발화 "그대로 적용 가능")
5. 입말 자연스러움 측면 어색 포인트 (군더더기·이중 주어·문어체)
6. 위 모든 분석을 반영해 발화 텍스트를 다듬는다 (B안 생성)

## 다듬기 원칙 (B안 생성 시)
- PDF visible 키워드는 발화에 반드시 등장 (보존)
- 사실·수치·회사명·기술명·"다음." 호출 신호 절대 변경 금지
- 격식체 (~입니다, ~합니다)
- 친근체 금지 (~이고요, ~인데요)
- 군더더기·중복·문어체 제거
- 길이 ±15% 이내 유지 (시간 분배 영향 최소화)
- 마크다운 **굵게** 보존 (강조 신호)

## 출력 형식 (JSON 한 객체. 코드블록 금지)
{
  "slide_visible_keywords": ["PDF 슬라이드에 visible한 핵심 텍스트 추출 (어절·구·박스 텍스트)"],
  "missing_in_speech": ["발화에 누락된 PDF 키워드"],
  "fabricated_in_speech": ["발화에는 있지만 PDF에 없는 의심 단어 (창작·환각 위험)"],
  "alignment_conflicts": [
    {"pdf": "PDF 표현", "speech": "발화 표현", "severity": "high|medium|low", "reason": "왜 충돌인지"}
  ],
  "naturalness_issues": ["입말 어색 포인트 (이중 주어, 문어체, 군더더기 등)"],
  "naturalized": "PDF 정합 + 자연스러움 동시 만족하는 다듬은 발화 텍스트 (마크다운 굵게 포함)",
  "summary": "주요 변경 1줄 요약 (한국어, 60자 이내)",
  "risk_for_interviewer_digging": ["면접관이 디깅 시 위험 포인트 (있다면, 없으면 빈 배열)"]
}
"""

def call_responses_api(client, image_path, slide_num, slide_title, seconds, body):
    """Responses API + vision으로 PDF + 발화 동시 분석"""
    with open(image_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode()
    user_text = f"""## 슬라이드 {slide_num} — {slide_title} ({seconds}초)

[현재 v11 발화 텍스트]
{body}

위 발화 텍스트를 첨부 PDF 슬라이드 이미지와 함께 분석하십시오.
"""
    response = client.responses.create(
        model=MODEL,
        input=[
            {'role': 'system', 'content': SYSTEM_PROMPT},
            {
                'role': 'user',
                'content': [
                    {'type': 'input_text', 'text': user_text},
                    {'type': 'input_image', 'image_url': f'data:image/png;base64,{b64}', 'detail': 'high'},
                ],
            },
        ],
        reasoning={'effort': 'medium'},
        text={'format': {'type': 'json_object'}},
    )
    return response

def parse_response(response):
    """Responses API output에서 텍스트 추출"""
    if hasattr(response, 'output_text') and response.output_text:
        text = response.output_text
    else:
        # output array 순회
        text = ''
        for item in response.output:
            if hasattr(item, 'content'):
                for c in item.content:
                    if hasattr(c, 'text'):
                        text += c.text
    text = text.strip()
    text = re.sub(r'^```(?:json)?\s*', '', text)
    text = re.sub(r'\s*```\s*$', '', text)
    return json.loads(text), response.usage

def parse_slides_from_md(md_path):
    text = md_path.read_text()
    slides = []
    pattern = re.compile(r'^## 슬라이드 (\d+) — (.+?) \((\d+)초.*?\)\n+(.+?)(?=^## 슬라이드 |\n# |\Z)', re.MULTILINE | re.DOTALL)
    for m in pattern.finditer(text):
        body_lines = []
        for line in m.group(4).split('\n'):
            if line.startswith('> '):
                body_lines.append(line[2:].rstrip())
            elif line == '>':
                body_lines.append('')
            elif line.startswith('---'):
                break
        slides.append({
            'num': int(m.group(1)),
            'title': m.group(2).strip(),
            'seconds': int(m.group(3)),
            'body': '\n'.join(body_lines).strip(),
        })
    return slides

def main():
    if not os.environ.get('OPENAI_API_KEY'):
        print('❌ OPENAI_API_KEY 미설정', file=sys.stderr)
        sys.exit(2)

    client = OpenAI()
    slides = parse_slides_from_md(SCRIPT_MD)
    print(f'슬라이드 {len(slides)}개 로드')
    print(f'PDF 이미지 디렉토리: {PDF_DIR}')

    results = []
    total_in = total_out = 0
    for s in slides:
        img_path = PDF_DIR / f'slide-{s["num"]:02d}.png'
        if not img_path.exists():
            print(f'❌ S{s["num"]}: 이미지 없음 ({img_path})')
            continue
        print(f'\n[S{s["num"]}] {s["title"]} ({s["seconds"]}초, {len(s["body"])}자)')
        try:
            response = call_responses_api(client, img_path, s['num'], s['title'], s['seconds'], s['body'])
            data, usage = parse_response(response)
            total_in += usage.input_tokens
            total_out += usage.output_tokens

            print(f'  ✅ {data.get("summary","-")}')
            mismatch_n = len(data.get('alignment_conflicts', []))
            missing_n = len(data.get('missing_in_speech', []))
            fab_n = len(data.get('fabricated_in_speech', []))
            print(f'  📊 충돌 {mismatch_n} · 누락 {missing_n} · 창작의심 {fab_n}')
            if data.get('alignment_conflicts'):
                for c in data['alignment_conflicts'][:3]:
                    print(f'    ⚠️ [{c.get("severity","?")}] PDF "{c.get("pdf","")}" vs 발화 "{c.get("speech","")}"')

            results.append({
                'num': s['num'], 'title': s['title'], 'seconds': s['seconds'],
                'orig_len': len(s['body']), 'new_len': len(data.get('naturalized', '')),
                'original': s['body'],
                **data,
            })
        except Exception as e:
            print(f'  ❌ 실패: {e}')
            import traceback; traceback.print_exc()
            results.append({'num': s['num'], 'title': s['title'], 'error': str(e)})

    cost = total_in/1e6 * 5.00 + total_out/1e6 * 25.00  # gpt-5.5-pro 추정 단가
    print(f'\n=== 완료 ===')
    print(f'토큰: in {total_in:,} + out {total_out:,}')
    print(f'비용: 약 ${cost:.2f} (실제 청구는 OpenAI 대시보드 확인)')

    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    log_path = Path.home() / f'jarvis/runtime/state/script-pdfaware-log-{ts}.json'
    log_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f'로그: {log_path}')
    return results, ts

if __name__ == '__main__':
    main()
