#!/usr/bin/env node
/**
 * career-crawler.mjs — 백엔드 채용 크롤러 (SPA 우회 = 내부 JSON API 직접 호출)
 *
 * 배경: 대형 채용 사이트 상당수는 화면을 JS 로 그리는 SPA 라 검색엔진·WebFetch 로는
 *       옛 캐시만 보이고 죽은 링크를 잡는다. 해결책은 그 뒤에서 도는 JSON API 를
 *       직접 때리는 것. 2026-06-15 대상 소스 전부 실측 검증함.
 *
 * 대상 목록은 코드가 아니라 설정에 있다 — infra/config/career-targets.json
 *   어느 회사를 보고 있는지는 개인 구직 정보이므로 이 저장소(공개)에 두지 않는다.
 *   구조 설명과 예시: infra/config/career-targets.example.json
 *   (2026-08-23 분리. 그 전에는 회사명이 코드에 하드코딩돼 공개 상태였다.)
 *
 * 어댑터 유형(shape):
 *   - jobList      : 페이지 파라미터만으로 목록이 열리는 API
 *   - sessionList  : 먼저 세션 쿠키를 받아야 목록 API 가 열리는 유형
 *   - Greenhouse ATS : boards-api.greenhouse.io/v1/boards/{token}/jobs (GET, jobs[], 글로벌→한국 필터)
 *   - 집계 사이트    : 자체 API 역추적이 안 된 곳을 회사명 접두 매칭으로 우회 수집
 *
 * 사용:
 *   node career-crawler.mjs            # 사람이 보기 좋은 요약
 *   node career-crawler.mjs --json     # 정규화 JSON 배열 (태스크/파이프 연동용)
 */

import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = process.env.CAREER_TARGETS_CONFIG || join(HERE, '..', 'config', 'career-targets.json');

function loadConfig() {
  try {
    return JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
  } catch (e) {
    console.error(`FATAL: 대상 설정을 읽을 수 없습니다 — ${CONFIG_PATH}`);
    console.error(`  ${e.message}`);
    console.error('  복구: cp infra/config/career-targets.example.json infra/config/career-targets.json 후 값을 채우세요.');
    process.exit(1);
  }
}

const CFG = loadConfig();
const GREENHOUSE = CFG.greenhouseTokens || [];
const WANTED_BIG = CFG.wantedCompanyPrefixes || [];
const ADAPTERS = (CFG.adapters || []).filter(a => a.enabled);

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)';
// 백엔드성 직무만 (제목/직무명에서 매칭)
const BE = /백엔드|서버|back ?end|server|플랫폼|platform|인프라|infra|MSA|분산|distributed/i;
// 글로벌 ATS용 한국 위치 필터
const KR = /seoul|korea|서울|대한민국|판교|성남|경기/i;
// 테스트/템플릿 공고 제외 (Greenhouse 더미 데이터)
const NOISE = /z-test|template|테스트 공고|dummy/i;

async function getJSON(url, headers = {}) {
  const res = await fetch(url, { headers: { 'User-Agent': UA, 'Accept': 'application/json', ...headers }, redirect: 'follow' });
  if (!res.ok) throw new Error('HTTP ' + res.status + ' @ ' + url);
  return res.json();
}

// ---------------- shape: jobList (페이지 파라미터만) ----------------
async function crawlJobListShape(a) {
  const out = [];
  const maxPages = a.maxPages || 8;
  for (let p = 1; p <= maxPages; p++) {
    let d;
    try {
      d = await getJSON(a.listUrlTemplate.replace('{page}', String(p)));
    } catch { break; }
    const list = d.jobList || [];
    if (!list.length) break;
    for (const x of list) {
      if (x.closeFlag) continue;                       // 마감 공고 제외
      if (!BE.test(x.jobOfferTitle || '')) continue;   // 백엔드성만
      out.push({
        source: a.sourceId, company: x.companyName || a.defaultCompany, title: x.jobOfferTitle,
        url: a.detailUrlPrefix + x.realId,
        location: x.locationName || '', deadline: x.resumeSubmissionEndDatetime || '상시',
        employment: x.employeeTypeName || '',
      });
    }
  }
  return out;
}

// ---------------- shape: sessionList (세션 쿠키 선취득 + GET) ----------------
async function crawlSessionListShape(a) {
  const out = [];
  // 1) 진입 페이지로 세션 쿠키 확보 (없으면 목록 API 가 "접근권한 없음")
  const first = await fetch(a.sessionUrl, { headers: { 'User-Agent': UA } });
  const cookie = (first.headers.getSetCookie() || []).map(c => c.split(';')[0]).join('; ');
  const pageSize = a.pageSize || 10;
  const maxIndex = a.maxIndex || 200;
  // 2) GET 방식으로 페이지네이션 (POST 는 막힘)
  for (let fi = 0; fi < maxIndex; fi += pageSize) {
    let d;
    try {
      d = await getJSON(
        a.listUrlTemplate.replace('{index}', String(fi)),
        { Cookie: cookie, 'X-Requested-With': 'XMLHttpRequest', 'Referer': a.sessionUrl }
      );
    } catch { break; }
    const list = d.list || [];
    if (!list.length) break;
    for (const x of list) {
      const blob = [x.annoSubject, x.subJobCdNm, x.classCdNm, x.annoKeyword].filter(Boolean).join(' ');
      if (!BE.test(blob)) continue;
      out.push({
        source: a.sourceId, company: x.sysCompanyCdNm || a.defaultCompany, title: x.annoSubject,
        url: (x.jobDetailLink && x.jobDetailLink.startsWith('http')) ? x.jobDetailLink
          : a.detailUrlPrefix + x.annoId,
        location: x.workAreaCd || '', deadline: x.endYmd || '상시',
        employment: x.entTypeCdNm || '',
      });
    }
    if (list.length < pageSize) break;
  }
  return out;
}

function runAdapter(a) {
  if (a.shape === 'jobList') return crawlJobListShape(a);
  if (a.shape === 'sessionList') return crawlSessionListShape(a);
  return Promise.reject(new Error(`알 수 없는 어댑터 shape: ${a.shape} (${a.id})`));
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

// ---------------- 집계 사이트 (자체 SPA 대기업 우회 수집) ----------------
async function crawlAggregator() {
  const out = [];
  let d;
  // job_ids=872 = 백엔드 개발자 직무 태그
  try { d = await getJSON('https://www.wanted.co.kr/api/chaos/navigation/v1/results?job_ids=872&country=kr&job_sort=job.latest_order&years=-1&locations=all&limit=500'); }
  catch { return out; }
  for (const x of (d.data || [])) {
    const co = (x.company && x.company.name) || '';
    if (!WANTED_BIG.some(b => co.startsWith(b))) continue;   // 설정된 접두만 (중소 노이즈 컷)
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
  const tasks = [...ADAPTERS.map(runAdapter), crawlAggregator(), ...GREENHOUSE.map(crawlGreenhouse)];
  const settled = await Promise.allSettled(tasks);
  const raw = settled.flatMap(r => (r.status === 'fulfilled' ? r.value : []));
  // 자체 API 와 집계 양쪽에 같은 공고가 잡히면 회사+제목으로 중복 제거
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
