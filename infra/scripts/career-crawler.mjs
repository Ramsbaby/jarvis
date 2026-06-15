#!/usr/bin/env node
/**
 * career-crawler.mjs — 대기업 백엔드 채용 크롤러 (SPA 우회 = 내부 JSON API 직접 호출)
 *
 * 배경: 카카오/네이버 등은 화면을 JS로 그리는 SPA라 검색엔진/WebFetch로는
 *       옛 캐시만 보이고 죽은 링크를 잡는다. 해결책은 그 뒤에서 도는 JSON API를
 *       직접 때리는 것. 2026-06-15 아래 소스 전부 실측 검증함.
 *
 * 검증 소스:
 *   - 카카오  : careers.kakao.com/public/api/job-list  (GET, jobList[], closeFlag로 마감 필터, 계열사 포함)
 *   - 네이버  : recruit.navercorp.com/rcrt/loadJobList.do (GET, 쿠키 세션 필요, res.list[], 본사+랩스+웹툰+클라우드)
 *   - Greenhouse ATS : boards-api.greenhouse.io/v1/boards/{token}/jobs (GET, jobs[], 글로벌→한국 필터)
 *       검증된 토큰: coupang(쿠팡) daangn(당근) krafton(크래프톤) sendbird(센드버드)
 *
 * 사용:
 *   node career-crawler.mjs            # 사람이 보기 좋은 요약
 *   node career-crawler.mjs --json     # 정규화 JSON 배열 (태스크/파이프 연동용)
 *
 * 토큰 추가법(중요): 새 Greenhouse 회사를 넣기 전 반드시
 *   curl -s "https://boards-api.greenhouse.io/v1/boards/<token>/jobs" | head
 *   로 HTTP 200 + jobs 배열을 확인하고 GREENHOUSE 배열에 추가할 것. (검증 없는 추가 금지)
 *
 * 확장 후보(자체 사이트 — 어댑터 추가 필요): 토스(toss.im), 우아한형제들(woowahan.com),
 *   라인(careers.linecorp.com), 무신사/야놀자(greetinghr ATS). 각각 API 역추적 후 어댑터 추가.
 */

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)';
// 백엔드성 직무만 (제목/직무명에서 매칭)
const BE = /백엔드|서버|back ?end|server|플랫폼|platform|인프라|infra|MSA|분산|distributed/i;
// 글로벌 ATS용 한국 위치 필터
const KR = /seoul|korea|서울|대한민국|판교|성남|경기/i;
// 테스트/템플릿 공고 제외 (Greenhouse 더미 데이터)
const NOISE = /z-test|template|테스트 공고|dummy/i;

// Greenhouse 토큰 — 실측 검증 완료된 것만. 추가 시 위 "토큰 추가법" 준수.
const GREENHOUSE = ['coupang', 'daangn', 'krafton', 'sendbird'];
// 원티드(집계)로 우회 수집할 대기업/유니콘 — 자체 SPA라 직접 API 역추적이 아직 안 된 곳들.
// (회사명 접두 매칭. 카카오/네이버/쿠팡/당근/크래프톤/센드버드는 자체 API로 이미 잡으므로 제외)
const WANTED_BIG = ['토스', '비바리퍼블리카', '우아한', '배달의민족', '라인', '무신사', '야놀자', '직방',
  '오늘의집', '버킷플레이스', '컬리', '쏘카', '두나무', '업비트', '하이퍼커넥트', '넥슨', '엔씨소프트',
  '넷마블', '펄어비스', '스마일게이트', '리디주식회사', '뱅크샐러드', '왓챠', '몰로코'];

async function getJSON(url, headers = {}) {
  const res = await fetch(url, { headers: { 'User-Agent': UA, 'Accept': 'application/json', ...headers }, redirect: 'follow' });
  if (!res.ok) throw new Error('HTTP ' + res.status + ' @ ' + url);
  return res.json();
}

// ---------------- 카카오 ----------------
async function crawlKakao() {
  const out = [];
  for (let p = 1; p <= 8; p++) {
    let d;
    try {
      d = await getJSON(`https://careers.kakao.com/public/api/job-list?skillSet=&part=TECHNOLOGY&company=ALL&keyword=&employeeType=&page=${p}`);
    } catch { break; }
    const list = d.jobList || [];
    if (!list.length) break;
    for (const x of list) {
      if (x.closeFlag) continue;                       // 마감 공고 제외
      if (!BE.test(x.jobOfferTitle || '')) continue;   // 백엔드성만
      out.push({
        source: 'kakao', company: x.companyName || '카카오', title: x.jobOfferTitle,
        url: 'https://careers.kakao.com/jobs/' + x.realId,
        location: x.locationName || '', deadline: x.resumeSubmissionEndDatetime || '상시',
        employment: x.employeeTypeName || '',
      });
    }
  }
  return out;
}

// ---------------- 네이버 (쿠키 세션 + GET) ----------------
async function crawlNaver() {
  const out = [];
  // 1) list.do 진입으로 egov 세션 쿠키 확보 (이게 없으면 loadJobList가 "접근권한 없음")
  const first = await fetch('https://recruit.navercorp.com/rcrt/list.do', { headers: { 'User-Agent': UA } });
  const cookie = (first.headers.getSetCookie() || []).map(c => c.split(';')[0]).join('; ');
  // 2) GET 방식으로 페이지네이션 (POST는 막힘)
  for (let fi = 0; fi < 200; fi += 10) {
    let d;
    try {
      d = await getJSON(
        `https://recruit.navercorp.com/rcrt/loadJobList.do?sw=&subJobCdArr=&sysCompanyCdArr=&empTypeCdArr=&entTypeCdArr=&workAreaCdArr=&annoId=&firstIndex=${fi}`,
        { Cookie: cookie, 'X-Requested-With': 'XMLHttpRequest', 'Referer': 'https://recruit.navercorp.com/rcrt/list.do' }
      );
    } catch { break; }
    const list = d.list || [];
    if (!list.length) break;
    for (const x of list) {
      const blob = [x.annoSubject, x.subJobCdNm, x.classCdNm, x.annoKeyword].filter(Boolean).join(' ');
      if (!BE.test(blob)) continue;
      out.push({
        source: 'naver', company: x.sysCompanyCdNm || '네이버', title: x.annoSubject,
        url: (x.jobDetailLink && x.jobDetailLink.startsWith('http')) ? x.jobDetailLink
          : 'https://recruit.navercorp.com/rcrt/view.do?annoId=' + x.annoId,
        location: x.workAreaCd || '', deadline: x.endYmd || '상시',
        employment: x.entTypeCdNm || '',
      });
    }
    if (list.length < 10) break;
  }
  return out;
}

// ---------------- Greenhouse ATS (글로벌 → 한국 백엔드 필터) ----------------
async function crawlGreenhouse(token) {
  const out = [];
  let d;
  try { d = await getJSON(`https://boards-api.greenhouse.io/v1/boards/${token}/jobs`); }
  catch { return out; }
  for (const x of (d.jobs || [])) {
    const loc = (x.location && x.location.name) || '';
    if (!BE.test(x.title || '')) continue;
    if (!KR.test(loc)) continue;                          // 한국 공고만
    if (NOISE.test(x.title) || NOISE.test(loc)) continue; // 더미 제외
    out.push({
      source: 'greenhouse:' + token, company: token, title: x.title,
      url: x.absolute_url, location: loc, deadline: '상시', employment: '',
    });
  }
  return out;
}

// ---------------- 원티드 (집계 — 자체 SPA 대기업 우회 수집) ----------------
async function crawlWanted() {
  const out = [];
  let d;
  // job_ids=872 = 백엔드 개발자 직무 태그 (원티드 표준)
  try { d = await getJSON('https://www.wanted.co.kr/api/chaos/navigation/v1/results?job_ids=872&country=kr&job_sort=job.latest_order&years=-1&locations=all&limit=500'); }
  catch { return out; }
  for (const x of (d.data || [])) {
    const co = (x.company && x.company.name) || '';
    if (!WANTED_BIG.some(b => co.startsWith(b))) continue;   // 대기업/유니콘만 (중소 노이즈 컷)
    out.push({
      source: 'wanted', company: co, title: x.position || x.title || '',
      url: 'https://www.wanted.co.kr/wd/' + x.id,
      location: (x.address && x.address.location) || '', deadline: '상시', employment: '',
    });
  }
  return out;
}

async function main() {
  const jsonMode = process.argv.includes('--json');
  const tasks = [crawlKakao(), crawlNaver(), crawlWanted(), ...GREENHOUSE.map(crawlGreenhouse)];
  const settled = await Promise.allSettled(tasks);
  const raw = settled.flatMap(r => (r.status === 'fulfilled' ? r.value : []));
  // 자체 API와 원티드 양쪽에 같은 공고가 잡히면 회사+제목으로 중복 제거
  const seen = new Set();
  const results = raw.filter(j => { const k = j.company + '|' + j.title; if (seen.has(k)) return false; seen.add(k); return true; });
  const failed = settled.map((r, i) => (r.status === 'rejected' ? i : -1)).filter(i => i >= 0);

  if (jsonMode) {
    console.log(JSON.stringify({ crawledAt: new Date().toISOString(), count: results.length, jobs: results }, null, 2));
    return;
  }

  const byCompany = {};
  for (const j of results) (byCompany[j.company] = byCompany[j.company] || []).push(j);
  console.log(`크롤링 완료: ${results.length}건 / ${Object.keys(byCompany).length}개사` + (failed.length ? ` (어댑터 ${failed.length}개 실패)` : ''));
  console.log('');
  for (const [co, jobs] of Object.entries(byCompany).sort((a, b) => b[1].length - a[1].length)) {
    console.log(`■ ${co} (${jobs.length}건)`);
    for (const j of jobs) {
      console.log(`   ${j.title}${j.employment ? ' [' + j.employment + ']' : ''} | ${j.location || '-'} | 마감:${j.deadline}`);
      console.log(`     ${j.url}`);
    }
  }
}

main().catch(e => { console.error('FATAL', e); process.exit(1); });
