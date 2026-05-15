#!/usr/bin/env python3
"""
script-pdfaware-compress.py — PDF 정합 + 시간 한계 압축 모드

배경: v12 광범위 다듬기로 PDF 정합성은 살렸으나 5장 분량이 +20% 이상 증가.
      14:30~15:00 시간 한계 넘을 위험. v11 길이의 110% 이내로 재압축 필요.

대상: S4, S6, S9, S10, S11 (시간 영향 큰 5장)
"""

import base64, html, json, os, re, sys, time
from pathlib import Path
from datetime import datetime

env_path = Path.home() / 'jarvis/runtime/.env'
for line in env_path.read_text().splitlines():
    if line.startswith('OPENAI_API_KEY='):
        os.environ['OPENAI_API_KEY'] = line.split('=', 1)[1].strip().strip('"').strip("'")

from openai import OpenAI

MODEL = 'gpt-5.5-pro'
PDF_DIR = Path('/tmp/script-pdf-pages')
SCRIPT_MD_V11 = Path.home() / 'jarvis/runtime/career/samsung-cnt-2026-04-v3/20-presentation-script-v11.md'
PREV_LOG = Path('/Users/ramsbaby/jarvis/runtime/state/script-pdfaware-log-20260505-170655.json')

# 시간 영향 큰 5장
TARGET_SLIDES = [4, 6, 9, 10, 11]

SYSTEM_PROMPT = """당신은 면접 발표 스크립트 압축 전문가입니다.

## 입력
1) PDF 슬라이드 이미지 — 청중에게 visible한 시각 자료
2) 현재 발화 텍스트 (v11) — 사용자가 PDF 정합 복원 + 9차 검수까지 끝낸 상태
3) v12 시도 텍스트 — gpt-5.5-pro가 PDF 정합으로 다듬었으나 분량이 너무 늘어남 (불채택)
4) 길이 제약 — v11 원본 길이의 110% 이내로 마감

## 목표
**시간 한계(14:30~15:00) 안에 들어가는 PDF 정합 + 자연스러움 동시 만족 발화 텍스트** 생성.

## 작업 우선순위
1. **시간 우선** — v11 길이의 110%를 절대 넘지 마라
2. **PDF 핵심 정합** — high severity 충돌만 해소 (low/medium은 후순위)
3. **자연스러움** — 입말 어색만 다듬기
4. **불필요 부연 제거** — 다음 항목은 면접 발화에서 비중 낮음:
   - "예를 들면 ~", "한 가지 더 말씀드리면 ~" 류 부연
   - 같은 슬라이드에서 두 번 이상 언급된 사실
   - 일반론 ("~중요합니다", "~핵심입니다")
   - 보조 사례 (핵심이 아닌 두 번째·세 번째 케이스)
   - 정직 가드는 PDF에 visible 한 것만 한 줄로 압축 (전체 발화 금지)

## 절대 보존
- 핵심 수치 (5천만, 30대, 75%, 20배, 0% 등)
- 회사명·기술명 (PDF 박스에 박힌 visible 키워드)
- "다음." 호출 신호
- 마크다운 **굵게** 강조

## 출력 (JSON 한 객체)
{
  "naturalized": "압축된 발화 텍스트",
  "removed_items": ["제거한 부연·중복 항목 리스트"],
  "kept_pdf_keywords": ["보존한 PDF 핵심 키워드"],
  "char_count": 결과 자수,
  "summary": "압축 전략 한 줄 요약"
}
"""

def parse_slides(md_path):
    text = md_path.read_text()
    slides = {}
    pattern = re.compile(r'^## 슬라이드 (\d+) — (.+?) \((\d+)초.*?\)\n+(.+?)(?=^## 슬라이드 |\n# |\Z)', re.MULTILINE | re.DOTALL)
    for m in pattern.finditer(text):
        body_lines = []
        for line in m.group(4).split('\n'):
            if line.startswith('> '): body_lines.append(line[2:].rstrip())
            elif line == '>': body_lines.append('')
            elif line.startswith('---'): break
        slides[int(m.group(1))] = {
            'num': int(m.group(1)), 'title': m.group(2).strip(),
            'seconds': int(m.group(3)), 'body': '\n'.join(body_lines).strip(),
        }
    return slides

def call_compress(client, img_path, slide_num, title, seconds, v11_body, v12_body):
    with open(img_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode()
    target_len = int(len(v11_body) * 1.10)
    user_text = f"""## 슬라이드 {slide_num} — {title} ({seconds}초)

### v11 원본 ({len(v11_body)}자) — 사용자 검수 완료, 시간 분배 통과한 길이
{v11_body}

### v12 시도 ({len(v12_body)}자) — PDF 정합 복원했으나 너무 길어짐 (불채택)
{v12_body}

### 길이 제약
**결과는 v11 길이({len(v11_body)}자)의 110% 이내, 즉 {target_len}자 이하로 마감하라.**

### 작업
v12의 PDF 정합 보강은 high severity 항목만 살리고, 나머지는 v11 분량으로 되돌리거나 제거하라.
부연·중복·일반론은 과감히 잘라라.
"""
    response = client.responses.create(
        model=MODEL,
        input=[
            {'role': 'system', 'content': SYSTEM_PROMPT},
            {'role': 'user', 'content': [
                {'type': 'input_text', 'text': user_text},
                {'type': 'input_image', 'image_url': f'data:image/png;base64,{b64}', 'detail': 'high'},
            ]},
        ],
        reasoning={'effort': 'medium'},
        text={'format': {'type': 'json_object'}},
    )
    text = response.output_text.strip()
    text = re.sub(r'^```(?:json)?\s*', '', text)
    text = re.sub(r'\s*```\s*$', '', text)
    return json.loads(text), response.usage

def main():
    if not os.environ.get('OPENAI_API_KEY'):
        print('❌ OPENAI_API_KEY 미설정', file=sys.stderr); sys.exit(2)

    client = OpenAI()
    v11_slides = parse_slides(SCRIPT_MD_V11)
    prev_results = json.loads(PREV_LOG.read_text())
    v12_by_num = {r['num']: r['naturalized'] for r in prev_results if 'naturalized' in r}

    results = []
    total_in = total_out = 0
    for num in TARGET_SLIDES:
        s = v11_slides[num]
        v11_body = s['body']
        v12_body = v12_by_num.get(num, v11_body)
        target = int(len(v11_body) * 1.10)
        print(f'\n[S{num}] {s["title"]}')
        print(f'  v11: {len(v11_body)}자, v12 시도: {len(v12_body)}자, 목표: ≤{target}자')
        try:
            t0 = time.time()
            data, usage = call_compress(client, PDF_DIR/f'slide-{num:02d}.png', num, s['title'], s['seconds'], v11_body, v12_body)
            elapsed = time.time() - t0
            total_in += usage.input_tokens
            total_out += usage.output_tokens
            new_text = data.get('naturalized', '')
            new_len = len(new_text)
            ok = new_len <= target
            print(f'  {"✅" if ok else "⚠️"} 결과 {new_len}자 ({(new_len/len(v11_body)-1)*100:+.0f}%) · {elapsed:.0f}초')
            print(f'  📝 {data.get("summary","-")}')
            if data.get('removed_items'):
                print(f'  🗑️ 제거: {", ".join(data["removed_items"][:5])}')
            results.append({
                'num': num, 'title': s['title'], 'seconds': s['seconds'],
                'v11_body': v11_body, 'v12_body': v12_body,
                'v12_compressed': new_text,
                'v11_len': len(v11_body), 'v12_len': len(v12_body), 'new_len': new_len,
                'target_len': target, 'within_limit': ok,
                **{k: v for k, v in data.items() if k != 'naturalized'},
            })
        except Exception as e:
            print(f'  ❌ 실패: {e}')
            import traceback; traceback.print_exc()

    cost = total_in/1e6*5.00 + total_out/1e6*25.00
    print(f'\n=== 완료 ===')
    print(f'토큰: in {total_in:,} + out {total_out:,}')
    print(f'비용: 약 ${cost:.2f}')

    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    log_path = Path.home() / f'jarvis/runtime/state/script-pdfaware-compress-log-{ts}.json'
    log_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f'로그: {log_path}')

if __name__ == '__main__':
    main()
