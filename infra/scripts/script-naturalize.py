#!/usr/bin/env python3
"""
script-naturalize.py — 발표 스크립트 입말 다듬기 (GPT-5.1) + AB 비교 HTML 생성

배경: 발표 스크립트 v11 (12장)이 9차 검수 + 사용자 직접 line-by-line 수정 +
      PDF 정합성 복원까지 거쳤음. GPT-5.1로 한 번 더 다듬어 AB 테스트.

원칙: 사실·수치·PDF 키워드 절대 보존. 어순 정리·중복 제거·격식체 유지만 허용.

사용:
  python3 script-naturalize.py --build      # B안 생성 (gpt-5.1) + AB 비교 HTML
"""

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

env_path = Path.home() / 'jarvis/runtime/.env'
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if line.startswith('OPENAI_API_KEY='):
            os.environ['OPENAI_API_KEY'] = line.split('=', 1)[1].strip().strip('"').strip("'")

from openai import OpenAI  # noqa: E402

MODEL = os.environ.get('NATURALIZE_MODEL', 'gpt-5.5-pro')  # 최신 + 최고 성능
PRICE_IN = 5.00   # gpt-5.5-pro 추정 단가 (실제 청구 기준 사후 정정)
PRICE_OUT = 25.00

SYSTEM_PROMPT = """당신은 면접 발표 스크립트의 입말 자연스러움을 다듬는 전문가입니다.

## 입력
백엔드 9년차 [OWNER]의 [TARGET_COMPANY] 면접 발표 스크립트 한 슬라이드.
이미 9차 검수 + 사용자 직접 line-by-line 수정 + PDF 정합성 복원이 끝난 v11 텍스트입니다.

## 목표
**발표자가 면접 현장에서 그대로 읽기만 해도 자연스럽게 흘러가는 입말**로 다듬는다.
**문장 수가 살짝 줄어도 좋다.** 단, 사실 손실은 절대 금지.

## 절대 보존 (변경 금지)
- 모든 수치 (5천만, 30대, 5~8대, 75%, 20배, 0%, 3시간 12분, 9분 20초, 1ms, 27만 건, 1만 호실, 1,500호실, 6개, 2주, 2일, 1주, 100개, 10개, 50개 등)
- 회사명: [COMPANY_A], [PRODUCT_A], [COMPANY_B], [TARGET_COMPANY], 핵토 가상계좌
- 제품/서비스: 에피소드, eRoom
- 기술명 (PDF 슬라이드에 박혀 visible 한 키워드 — 절대 누락 금지):
  - Virtual Thread, HikariCP, WebFlux, gRPC, R2DBC
  - Spring Batch, JDBC Template, batchUpdate, EXPLAIN, range
  - Redis (INCR, SET), ElastiCache, Redisson, Lambda
  - Kafka (acks, 브로커, 복제본, 파티션), DLQ, SQS, 가시성 타임아웃, 멱등성
  - Multi-AZ, ALB, AWS, Datadog, CloudWatch
  - JSON, Parquet, JPA, MyBatis, QueryDSL
  - 코레오그래피 사가, 서킷브레이커, 아웃박스, 대조 스케줄러
- 마크다운 **굵게** 표기 (강조 신호 — 발표자가 살짝 톤 올리는 부분)
- "다음." 진행자 호출 신호 (마지막 줄)

## 톤 (보수적 대기업 면접)
- 격식체: ~입니다, ~합니다, ~했습니다, ~드리겠습니다
- 보고체. 정중하지만 단도직입.
- 추측형 ("~라고 봅니다") → 단호형 ("~합니다") 가능

## 절대 금지
- 친근체: ~이고요, ~인데요, ~거든요, ~잖아요, ~네요
- 추측/창작: 새로운 사실·수치·기술명·회사명 추가 절대 금지
- 정직 가드 삭제: "학습 영역으로 두고", "후임과 합의해 인계", "직접 운영해 본" 같은 정직 가드 표현 삭제 금지

## 허용 작업
- 문장 압축 (2~3문장 → 1문장)
- 어순 재조정 (주어-술어 가까이)
- 이중 주어 정리
- 부자연스러운 관형절 풀어쓰기
- 불필요한 부연 ("정말로", "솔직히") 제거

## 길이 제약
원본의 85~110% 범위 유지. 시간 분배 (각 슬라이드 60~105초)가 어긋나면 안 됨.

## 출력 형식 (JSON)
반드시 아래 JSON 한 객체만 출력. 마크다운 코드블록(```) 금지.
{
  "naturalized": "다듬은 슬라이드 전체 텍스트",
  "summary": "주요 변경 1줄 요약 (한국어, 40자 이내)"
}
"""

# 발표 스크립트 v11에서 슬라이드 추출
def parse_slides_from_md(md_path):
    """MD 파일에서 슬라이드 12개 추출. 각 슬라이드 본문(인용 부호 > 제거된 평문)."""
    text = md_path.read_text()
    slides = []
    # ## 슬라이드 N 패턴
    pattern = re.compile(r'^## 슬라이드 (\d+) — (.+?) \((\d+)초.*?\)\n+(.+?)(?=^## 슬라이드 |\n# |\Z)', re.MULTILINE | re.DOTALL)
    for m in pattern.finditer(text):
        num = int(m.group(1))
        title = m.group(2).strip()
        seconds = int(m.group(3))
        body = m.group(4).strip()
        # > 인용 부호 제거하고 본문만 추출
        lines = []
        for line in body.split('\n'):
            line = line.rstrip()
            if line.startswith('> '):
                lines.append(line[2:])
            elif line == '>':
                lines.append('')
            elif line.startswith('---'):
                break  # 다음 슬라이드 구분선
        clean = '\n'.join(lines).strip()
        slides.append({'num': num, 'title': title, 'seconds': seconds, 'body': clean})
    return slides

def call_llm(client, content):
    # gpt-5.1: max_completion_tokens 사용, temperature 미지원
    msg = client.chat.completions.create(
        model=MODEL,
        max_completion_tokens=4096,
        response_format={'type': 'json_object'},
        messages=[
            {'role': 'system', 'content': SYSTEM_PROMPT},
            {'role': 'user', 'content': content},
        ],
    )
    text = msg.choices[0].message.content.strip()
    data = json.loads(text)
    return data.get('naturalized'), data.get('summary'), msg.usage

def safety_check(orig, new):
    issues = []
    # 길이 ±15% 이내
    ratio = len(new) / len(orig)
    if ratio < 0.85:
        issues.append(f'길이 15%↓ ({len(orig)}→{len(new)})')
    elif ratio > 1.15:
        issues.append(f'길이 15%↑ ({len(orig)}→{len(new)})')
    # PDF 핵심 키워드 보존
    PDF_KEYWORDS = [
        'Virtual Thread', 'HikariCP', 'WebFlux', 'gRPC',
        'Spring Batch', 'JDBC Template', 'batchUpdate', 'EXPLAIN', 'range',
        'Redis', 'ElastiCache', 'Redisson', 'Lambda',
        'Kafka', 'DLQ', 'SQS', '멱등성',
        'Multi-AZ', 'ALB', 'Datadog', 'CloudWatch',
        'JSON', 'Parquet',
        '코레오그래피 사가', '서킷브레이커', '아웃박스', '대조 스케줄러',
        '핵토', 'eRoom',
        '[COMPANY_A]', '[PRODUCT_A]', '[COMPANY_B]',
        '학습 영역',
    ]
    for kw in PDF_KEYWORDS:
        if kw in orig and kw not in new:
            issues.append(f'PDF 키워드 누락: {kw}')
    # 핵심 수치 보존
    KEY_NUMS = ['5천만', '30대', '5~8', '75', '20배', '3시간', '9분', '20초', '1억',
                '20만', '500', '90', '45', '30초', '0%', '3%', '5종', '100개',
                '10개', '50개', '2주', '2일', '1주', '27만', '6개', '1만', '1,500']
    for num in KEY_NUMS:
        if num in orig and num not in new:
            issues.append(f'수치 누락: {num}')
    # "다음." 보존
    if '다음.' in orig and '다음.' not in new:
        issues.append('다음. 호출 신호 누락')
    return issues

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', action='store_true')
    args = ap.parse_args()

    if not os.environ.get('OPENAI_API_KEY'):
        print('❌ OPENAI_API_KEY 미설정', file=sys.stderr)
        sys.exit(2)

    client = OpenAI()
    md_path = Path.home() / 'jarvis/runtime/career/samsung-cnt-2026-04-v3/20-presentation-script-v11.md'
    slides = parse_slides_from_md(md_path)
    print(f'슬라이드 {len(slides)}개 추출 완료')

    results = []
    total_in = total_out = 0
    for s in slides:
        print(f'\n[S{s["num"]}] {s["title"]} ({s["seconds"]}초, {len(s["body"])}자)')
        try:
            nat, summary, usage = call_llm(client, s['body'])
            total_in += usage.prompt_tokens
            total_out += usage.completion_tokens
            issues = safety_check(s['body'], nat)
            ok = not issues
            print(f'  {"✅" if ok else "⚠️"} {summary}')
            if issues:
                print(f'    {issues}')
            results.append({
                'num': s['num'], 'title': s['title'], 'seconds': s['seconds'],
                'original': s['body'], 'b_version': nat, 'summary': summary,
                'issues': issues, 'ok': ok,
                'orig_len': len(s['body']), 'new_len': len(nat),
            })
        except Exception as e:
            print(f'  ❌ 실패: {e}')
            results.append({
                'num': s['num'], 'title': s['title'], 'seconds': s['seconds'],
                'original': s['body'], 'b_version': None, 'error': str(e),
            })

    cost = total_in/1e6*PRICE_IN + total_out/1e6*PRICE_OUT
    print(f'\n=== 완료 ===')
    print(f'토큰: in {total_in:,} + out {total_out:,}')
    print(f'비용: ${cost:.3f}')

    # 결과 저장
    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    log_path = Path.home() / f'jarvis/runtime/state/script-naturalize-log-{ts}.json'
    log_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f'로그: {log_path}')

    # AB 비교 HTML 생성
    build_ab_html(results, ts)

def build_ab_html(results, ts):
    import difflib
    def render_diff(orig, new):
        if not new: return html.escape(orig), ''
        o_words = orig.split(' ')
        n_words = new.split(' ')
        sm = difflib.SequenceMatcher(None, o_words, n_words)
        o_html, n_html = [], []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            o_chunk = ' '.join(o_words[i1:i2])
            n_chunk = ' '.join(n_words[j1:j2])
            if tag == 'equal':
                o_html.append(html.escape(o_chunk))
                n_html.append(html.escape(n_chunk))
            elif tag == 'replace':
                o_html.append(f'<span class="del">{html.escape(o_chunk)}</span>')
                n_html.append(f'<span class="add">{html.escape(n_chunk)}</span>')
            elif tag == 'delete':
                o_html.append(f'<span class="del">{html.escape(o_chunk)}</span>')
            elif tag == 'insert':
                n_html.append(f'<span class="add">{html.escape(n_chunk)}</span>')
        return ' '.join(o_html), ' '.join(n_html)

    def md_to_html(text):
        s = html.escape(text)
        s = re.sub(r'\*\*([^*\n]+?)\*\*', r'<strong>\1</strong>', s)
        return s.replace('\n\n', '</p><p>').replace('\n', '<br>')

    cards = []
    for r in results:
        if not r.get('b_version'):
            continue
        ok = r.get('ok', False)
        badge = '✅ 안전 통과' if ok else '⚠️ 안전검증 경고'
        badge_cls = 'ok' if ok else 'warn'
        issues_html = ''
        if r.get('issues'):
            issues_html = f'<div class="issues">⚠️ {html.escape(", ".join(r["issues"]))}</div>'
        o_diff, n_diff = render_diff(r['original'], r['b_version'])
        # diff 결과에 마크다운 굵게 보존하기 위해 별도 렌더
        o_md = md_to_html(r['original'])
        n_md = md_to_html(r['b_version'])
        cards.append(f'''
<section class="case" id="s{r['num']}">
  <header class="case-h">
    <span class="cid">슬라이드 {r['num']}</span>
    <span class="ctitle">{html.escape(r['title'])}</span>
    <span class="cmeta">⏱ {r['seconds']}초 · {r['orig_len']}→{r['new_len']}자</span>
    <span class="badge {badge_cls}">{badge}</span>
  </header>
  <div class="summary">📝 {html.escape(r.get('summary') or '-')}</div>
  {issues_html}
  <div class="cols">
    <div class="col">
      <div class="col-h">A안 (현재 v11 — 사용자 검수 + PDF 정합 완료)</div>
      <div class="col-body">{o_md}</div>
    </div>
    <div class="col">
      <div class="col-h">B안 (gpt-5.1 다듬기)</div>
      <div class="col-body">{n_md}</div>
    </div>
  </div>
  <div class="diff-toggle">
    <button onclick="toggleDiff({r['num']})">🔍 단어 단위 차이 보기</button>
    <div class="diff-view" id="diff-{r['num']}" style="display:none">
      <div class="cols">
        <div class="col"><div class="col-h">A안 (삭제 = 빨강)</div><div class="col-body">{o_diff}</div></div>
        <div class="col"><div class="col-h">B안 (추가 = 녹색)</div><div class="col-body">{n_diff}</div></div>
      </div>
    </div>
  </div>
  <div class="choice">
    <label><input type="radio" name="c{r['num']}" value="A" checked> A안 유지</label>
    <label><input type="radio" name="c{r['num']}" value="B"> B안 채택</label>
  </div>
</section>''')

    HTML = f'''<!DOCTYPE html>
<html lang="ko"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>발표 스크립트 AB 테스트 — v11 vs gpt-5.1</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:Georgia,'Nanum Myeongjo',serif;background:#F4F1EA;color:#2C2417;font-size:14px;line-height:1.75}}
.topbar{{position:sticky;top:0;z-index:10;background:#2C2417;color:#F4F1EA;padding:14px 28px;border-bottom:3px solid #D4622A}}
.topbar h1{{font-size:1.15rem}}
.topbar .sub{{font-size:0.78rem;color:#c8bfad;font-style:italic}}
.summary-bar{{background:#FDFAF5;padding:14px 28px;border-bottom:1px solid #D8D0C4;font-size:0.88rem;display:flex;gap:22px;flex-wrap:wrap}}
.summary-bar b{{color:#D4622A}}
.case-list{{padding:18px 24px 60px}}
.case{{background:#FDFAF5;border:1px solid #D8D0C4;border-radius:5px;padding:16px 20px;margin-bottom:20px;box-shadow:0 1px 3px rgba(44,36,23,0.08)}}
.case-h{{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding-bottom:10px;border-bottom:1px solid #EBE7DE;margin-bottom:10px}}
.cid{{font-weight:bold;color:#D4622A;font-size:1rem}}
.ctitle{{font-size:0.95rem;color:#2C2417}}
.cmeta{{color:#8C7B68;font-size:0.82rem;font-style:italic}}
.badge{{padding:2px 10px;border-radius:14px;font-size:0.74rem;font-weight:bold;margin-left:auto}}
.badge.ok{{background:#DEEDD9;color:#2D7D46;border:1px solid #B8D9AF}}
.badge.warn{{background:#FFF3D6;color:#C9760A;border:1px solid #F0C040}}
.summary{{font-size:0.88rem;color:#5C4E3A;margin-bottom:8px}}
.issues{{background:#FFF3D6;color:#C9760A;border-left:4px solid #C9760A;padding:8px 12px;font-size:0.82rem;margin-bottom:10px;border-radius:0 3px 3px 0}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:6px}}
.col{{background:#FAF7F0;border:1px solid #EBE7DE;border-radius:4px;overflow:hidden}}
.col-h{{background:#EBE7DE;color:#5C4E3A;padding:6px 12px;font-size:0.78rem;font-weight:bold}}
.col-body{{padding:12px 14px;font-size:0.9rem;line-height:1.8}}
.col-body p{{margin-bottom:10px}}
.col-body strong{{color:#2C2417;font-weight:bold}}
.del{{background:#FFE0DC;color:#B82828;text-decoration:line-through;padding:0 2px;border-radius:2px}}
.add{{background:#DEEDD9;color:#2D7D46;padding:0 2px;border-radius:2px;font-weight:500}}
.diff-toggle{{margin-top:10px}}
.diff-toggle button{{padding:5px 13px;background:#FDFAF5;border:1px solid #D8D0C4;border-radius:3px;font-size:0.78rem;cursor:pointer;color:#5C4E3A;font-family:Georgia,serif}}
.diff-toggle button:hover{{background:#fff}}
.diff-view{{margin-top:10px}}
.choice{{margin-top:14px;padding-top:10px;border-top:1px solid #EBE7DE;display:flex;gap:18px;font-size:0.9rem}}
.choice label{{cursor:pointer;display:flex;align-items:center;gap:6px}}
.choice input{{cursor:pointer}}
.apply-bar{{position:sticky;bottom:0;background:#2C2417;color:#F4F1EA;padding:14px 28px;border-top:3px solid #D4622A;display:flex;gap:14px;align-items:center;justify-content:space-between}}
.apply-bar button{{padding:8px 20px;background:#D4622A;color:#fff;border:none;border-radius:4px;font-size:0.95rem;cursor:pointer;font-family:Georgia,serif;font-weight:bold}}
.apply-bar button:hover{{background:#B5511F}}
.tally{{font-size:0.85rem}}
@media (max-width:900px){{.cols{{grid-template-columns:1fr}}}}
</style></head><body>
<div class="topbar">
  <h1>발표 스크립트 AB 테스트 — v11 (현재) vs gpt-5.1 다듬기</h1>
  <span class="sub">슬라이드별로 골라가며 채택. 하단 "선택 결과 출력" 버튼으로 최종 확인.</span>
</div>
<div class="summary-bar">
  <span><b>{len(results)}장</b> 비교</span>
  <span>모델: <b>gpt-5.1</b></span>
  <span><b>A안</b>: 9차 검수 + 사용자 직접 line-by-line + PDF 정합 복원</span>
  <span><b>B안</b>: gpt-5.1로 한 번 더 다듬기</span>
  <span style="margin-left:auto"><span class="del">빨강</span> 삭제 / <span class="add">녹색</span> 추가</span>
</div>
<div class="case-list">{''.join(cards)}</div>
<div class="apply-bar">
  <span class="tally" id="tally">A 12 / B 0</span>
  <button onclick="exportChoice()">📋 선택 결과 출력</button>
</div>
<script>
function toggleDiff(num) {{
  const d = document.getElementById('diff-'+num);
  d.style.display = d.style.display === 'none' ? 'block' : 'none';
}}
function updateTally() {{
  let a=0, b=0;
  document.querySelectorAll('input[type=radio]:checked').forEach(r => {{
    if(r.value==='A') a++; else b++;
  }});
  document.getElementById('tally').textContent = `A ${{a}} / B ${{b}}`;
}}
document.querySelectorAll('input[type=radio]').forEach(r => r.addEventListener('change', updateTally));
function exportChoice() {{
  const choices = [];
  document.querySelectorAll('section.case').forEach(s => {{
    const num = s.id.replace('s','');
    const checked = s.querySelector('input[type=radio]:checked');
    choices.push(`S${{num}}: ${{checked ? checked.value : 'A'}}`);
  }});
  const text = '발표 스크립트 AB 선택 결과:\\n\\n' + choices.join('\\n');
  navigator.clipboard.writeText(text).then(() => alert('클립보드에 복사됨:\\n\\n'+text));
}}
</script></body></html>'''
    out_path = Path.home() / f'Desktop/script-ab-비교-{MODEL}.html'
    out_path.write_text(HTML, encoding='utf-8')
    print(f'\n✅ AB 비교: {out_path}')

if __name__ == '__main__':
    main()
