#!/usr/bin/env python3
# preply-delivery-audit.py — 교재 제작 파일 vs 채널 업로드 대사(맞춰보기) 감사
# 용도: preply-materials 최근 N시간 파일이 #jarvis-preply-tutor에 실제 업로드됐는지 확인
# 배경: 2026-07-17 백그라운드 위임 블랙홀 사고(찰리·체리·캐서린 미업로드) 후 재발 감지용
# 사용: python3 preply-delivery-audit.py [시간창=48] [이력페이지=4]
import os, re, subprocess, json, sys, time

HOURS = int(sys.argv[1]) if len(sys.argv) > 1 else 48
PAGES = int(sys.argv[2]) if len(sys.argv) > 2 else 4
CH = '1470011814803935274'
NAMES = {'시몬':['simon','simone'],'마르코':['marco'],'찰리':['charlie'],'체리':['cheri','cherilyn'],
         '캐서린':['katherine'],'미쉘':['michelle'],'라라':['lara'],'테일러':['taylor'],
         '쥬리':['julie','jurie'],'한나':['hannah','biz_meeting','biz_sns'],'마흘리':['mahlee'],
         '파울라':['paula'],'알리사':['alyssa'],'엘리사':['elisa'],'질리안':['jillian'],
         '케이리':['kaylie'],'다이애나':['diana'],'로빈':['robin'],'루시':['lucy','luz'],'울라':['ula'],
         '보루이':['borui'],'엘리스':['elise'],'애니':['annie'],'안나':['anna'],'시르샤':['shirsha','sirsha']}

token = None
for l in open(os.path.expanduser('~/jarvis/runtime/discord/.env')):
    m = re.match(r'^DISCORD_TOKEN\s*=\s*(.+)$', l.strip())
    if m: token = m.group(1).strip().strip('"\''); break
if not token: sys.exit('DISCORD_TOKEN 미발견')

blobs, before = [], None
for _ in range(PAGES):
    url = f'https://discord.com/api/v10/channels/{CH}/messages?limit=100' + (f'&before={before}' if before else '')
    r = subprocess.run(['curl','-sS',url,'-H',f'Authorization: Bot {token}'], capture_output=True, text=True, timeout=20)
    msgs = json.loads(r.stdout)
    if not isinstance(msgs, list) or not msgs: break
    for m in msgs:
        if m.get('attachments'):
            blobs.append(((m.get('content','')+' '+' '.join(a['filename'] for a in m['attachments'])).lower(), m['timestamp'][:16]))
    before = msgs[-1]['id']

D = os.path.expanduser('~/jarvis/runtime/preply-materials')
cutoff = time.time() - HOURS*3600
groups = {}
for f in os.listdir(D):
    p = os.path.join(D, f)
    if not (os.path.isfile(p) and os.path.getmtime(p) > cutoff): continue
    if re.search(r'backup|_old|_tmp|_v\d+\.', f, re.I): continue  # 작업 사본 제외
    fl = f.lower()
    st = next((k for k in NAMES if k in f), None) or next((k for k,vs in NAMES.items() if any(v in fl for v in vs)), '?')
    mu = re.search(r'unit\s?_?(\d)', fl)
    groups.setdefault((st, f"unit{mu.group(1)}" if mu else '(유닛무관)'), []).append(f)

issues = []
print(f"{'학생':6} {'유닛':10} {'파일':3}  판정  (창={HOURS}h, 이력={len(blobs)}건)")
for (st, un), files in sorted(groups.items()):
    toks = ([st.lower()] + NAMES.get(st, [])) if st != '?' else []
    def hit(b):
        name_ok = (not toks) or any(t in b for t in toks)
        unit_ok = un == '(유닛무관)' or un in b or un.replace('unit','unit ') in b
        return name_ok and unit_ok and toks  # 학생 미상('?')은 판정 불가 → 이슈로
    d = next((d for b, d in blobs if hit(b)), None)
    print(f"{st:6} {un:10} {len(files):2}개  {'✅ '+d if d else '❌ 미확인'}")
    if not d: issues.append((st, un, files))
print()
if issues:
    print(f"⚠️ 미확인 {len(issues)}그룹 — 파일 목록:")
    for st, un, files in issues:
        for f in files: print(f"  - {f}")
    sys.exit(1)
print("✅ 전량 납품 확인")
