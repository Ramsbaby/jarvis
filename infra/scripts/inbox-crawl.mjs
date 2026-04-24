#!/usr/bin/env node
/**
 * Jarvis Inbox Crawler — standalone (Puppeteer + API)
 * Chrome 확장 없이 독립 실행. 수집 결과를 JSON + Discord로 전송.
 *
 * Usage: node inbox-crawl.mjs [--discord] [--json-only]
 */

import puppeteer from 'puppeteer-core';
import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { discordSend } from '../lib/discord-notify.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
// 2026-04-23 경로 통일 — inbox-match.mjs / inbox-apply.mjs 와 SSoT 일치 ("state/inbox")
// 기존 "state/inbox-crawl" 은 match 가 읽지 못해 3일 전 stale 파일 고정 사용 → 매일 같은 Notion 리포트 원인
const RESULT_DIR = join(BOT_HOME, 'state', 'inbox');
const RESULT_FILE = join(RESULT_DIR, 'latest.json');
const SEEN_FILE = join(RESULT_DIR, 'seen.json');
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sendToDiscord = process.argv.includes('--discord');
const jsonOnly = process.argv.includes('--json-only');

mkdirSync(RESULT_DIR, { recursive: true });

// ─── 대상 사이트 (private/config 분리 — PII 격리) ──────────────────────────
// SSoT: ~/jarvis/private/config/inbox-targets.json (gitignored)
// 파일 없으면 크롤링 0건 graceful fallback — OSS 사용자는 본인 타겟을 여기에 정의
const TARGETS_PATH = join(homedir(), 'jarvis', 'private', 'config', 'inbox-targets.json');
let SITES = [];
let GREETINGHR_SITES = [];
let NINEHIRE_SITES = [];
let WANTED_CFG = null;
let JUMPIT_CFG = null;
let LINKEDIN_CFG = null;
try {
  if (existsSync(TARGETS_PATH)) {
    const cfg = JSON.parse(readFileSync(TARGETS_PATH, 'utf-8'));
    SITES = Array.isArray(cfg.sites) ? cfg.sites : [];
    GREETINGHR_SITES = Array.isArray(cfg.greetinghr_sites) ? cfg.greetinghr_sites : [];
    NINEHIRE_SITES = Array.isArray(cfg.ninehire_sites) ? cfg.ninehire_sites : [];
    WANTED_CFG = (cfg.wanted && cfg.wanted.enabled) ? cfg.wanted : null;
    JUMPIT_CFG = (cfg.jumpit && cfg.jumpit.enabled) ? cfg.jumpit : null;
    LINKEDIN_CFG = (cfg.linkedin && cfg.linkedin.enabled) ? cfg.linkedin : null;
    console.log(`📂 타겟 로드: ${SITES.length} sites + ${GREETINGHR_SITES.length} greetinghr + ${NINEHIRE_SITES.length} ninehire${WANTED_CFG ? ' + wanted' : ''}${JUMPIT_CFG ? ' + jumpit' : ''}${LINKEDIN_CFG ? ' + linkedin' : ''}`);
  } else {
    console.warn(`⚠️ ${TARGETS_PATH} 없음 — 크롤링 대상 0건. 샘플: private/config/inbox-crawl-targets.example.json 참고`);
  }
} catch (e) {
  console.warn(`⚠️ inbox-targets.json 로드 실패 (${e.message}) — 크롤링 대상 0건으로 동작`);
}

// ── 키워드 ─────────────────────────────────────────────────────────────────
const BACKEND_KW = [
  'java', 'spring', '백엔드', 'backend', '서버 개발', '서버개발',
  'springboot', 'webflux', 'jvm', 'msa', 'microservice', '마이크로서비스',
  'server 엔지니어', 'platform engineer', '플랫폼 개발',
  '서버 엔지니어', '서버엔지니어', '서버개발자', '서버 개발자',
  'kotlin', 'golang', 'go 언어', 'node.js', 'nodejs', 'python',
  '시스템 개발', '시스템개발', 'api 개발', '클라우드 엔지니어',
];
const EXCLUDE_KW = [
  '석사', '박사', 'phd', '석·박사', '석박사',
  '연구원', 'research engineer', 'research scientist', 'researcher',
  '프론트엔드', 'frontend', 'front-end',
  'ios', 'android', '모바일 앱',
  'data scientist', 'ml engineer', 'machine learning engineer',
  '디자이너', 'designer', 'devrel', '기술영업', '솔루션즈 아키텍트',
];

function isBackendJob(title) {
  if (!title) return false;
  const lower = title.toLowerCase();
  if (EXCLUDE_KW.some(k => lower.includes(k.toLowerCase()))) return false;
  return BACKEND_KW.some(k => lower.includes(k.toLowerCase()));
}

function makeId(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

function loadSeen() {
  try { return new Set(JSON.parse(readFileSync(SEEN_FILE, 'utf-8'))); } catch { return new Set(); }
}
function saveSeen(seen) {
  writeFileSync(SEEN_FILE, JSON.stringify([...seen].slice(-3000)));
}

// ── API 크롤링 (GreetingHR) ───────────────────────────────────────────────
async function crawlGreetingHR(site) {
  try {
    const r = await fetch(`https://api.greetinghr.com/ats/career/workspaces/${site.wid}/openings?page=0&pageSize=100`);
    const d = await r.json();
    return (d?.data?.datas || [])
      .filter(o => o.title && (o.openingId || o.id))
      .map(o => ({ title: o.title, url: `${site.baseUrl}${o.openingId || o.id}`, company: site.company }));
  } catch (e) {
    console.error(`  [API] ${site.company} 실패: ${e.message}`);
    return [];
  }
}

// ── API 크롤링 (Wanted 어그리게이터) ──────────────────────────────────────
// 원티드 chaos navigation API — 공개·인증불필요. 2026-04-24 실측:
//   - job_group_id=518 (개발) 서버측 필터 작동 (parent=518 전부 반환)
//   - years/positions/subCategories 파라미터 **서버측 무시** → 클라이언트 필터
//   - limit=20 고정, offset pagination 정상(중복 0 확인)
async function crawlWanted(cfg) {
  const {
    job_group_id = 518,
    max_offset = 500,
    min_annual_to = 3,      // 연차 상한이 3년 미만인 공고 제외 (주니어 전용)
    max_annual_from = 12,   // 연차 하한이 12년 초과인 공고 제외 (시니어 전용)
  } = cfg;
  const results = [];
  const seenIds = new Set();
  let offset = 0;
  const PAGE = 20;
  try {
    while (offset <= max_offset) {
      const url = `https://www.wanted.co.kr/api/chaos/navigation/v1/results?job_sort=job.latest_order&locations=all&job_group_id=${job_group_id}&country=kr&limit=${PAGE}&offset=${offset}`;
      const r = await fetch(url, {
        headers: {
          'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
          'wanted-client-id': 'web',
          'accept': 'application/json',
        },
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      const data = d?.data || [];
      if (data.length === 0) break;
      for (const j of data) {
        if (seenIds.has(j.id)) continue;
        seenIds.add(j.id);
        const annualFrom = j.annual_from ?? 0;
        const annualTo = j.annual_to ?? 99;
        // 연차 필터: 오너 경력(9년차) 기준, to<3 or from>12 제외
        if (annualTo < min_annual_to) continue;
        if (annualFrom > max_annual_from) continue;
        results.push({
          title: j.position || '',
          url: `https://www.wanted.co.kr/wd/${j.id}`,
          company: `[원티드] ${j.company?.name || '?'}`,
          annualFrom, annualTo,
        });
      }
      offset += PAGE;
    }
  } catch (e) {
    console.error(`  [API] Wanted 실패: ${e.message}`);
  }
  return results;
}

// ── API 크롤링 (LinkedIn guest API) ────────────────────────────────────────
// LinkedIn 공개 /jobs-guest/ 엔드포인트 — 2026-04-24 실측:
//   - HTML fragment 응답, <li> 블록 × 10/페이지
//   - f_E=3,4,5 서버측 경력 필터 작동 (Associate/Mid-Senior/Director)
//   - start 파라미터 pagination 확인 (start=300도 10건 반환)
//   - 인증·로그인 불필요, user-agent만 필수
async function crawlLinkedIn(cfg) {
  const {
    keywords = ['backend', 'server developer'],
    location = 'South Korea',
    experience_levels = '3,4,5',
    max_start = 200,
  } = cfg;
  const results = [];
  const seenIds = new Set();
  try {
    for (const kw of keywords) {
      for (let start = 0; start <= max_start; start += 10) {
        const url = `https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=${encodeURIComponent(kw)}&location=${encodeURIComponent(location)}&f_E=${experience_levels}&start=${start}`;
        const r = await fetch(url, {
          headers: {
            'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36',
            'accept': 'text/html,application/xhtml+xml',
          },
        });
        if (!r.ok) break;
        const html = await r.text();
        const blocks = html.match(/<li[\s\S]*?<\/li>/g) || [];
        if (blocks.length === 0) break;
        for (const b of blocks) {
          const urnM = b.match(/data-entity-urn="urn:li:jobPosting:(\d+)"/);
          const titleM = b.match(/<h3[^>]*class="base-search-card__title"[^>]*>\s*([^<]+)/);
          const compM = b.match(/<h4[^>]*class="base-search-card__subtitle"[\s\S]*?<a[^>]*>\s*([^<]+)/);
          if (!urnM || !titleM) continue;
          const id = urnM[1];
          if (seenIds.has(id)) continue;
          seenIds.add(id);
          const title = titleM[1].replace(/&amp;/g, '&').trim();
          const company = compM ? compM[1].replace(/&amp;/g, '&').trim() : '?';
          results.push({
            title,
            url: `https://www.linkedin.com/jobs/view/${id}`,
            company: `[LinkedIn] ${company}`,
          });
        }
      }
    }
  } catch (e) {
    console.error(`  [API] LinkedIn 실패: ${e.message}`);
  }
  return results;
}

// ── API 크롤링 (점핏 어그리게이터) ─────────────────────────────────────────
// 점핏 공개 API (jumpit-api.saramin.co.kr) — 2026-04-24 실측:
//   - jobCategory=1 = 서버/백엔드 (총 175건)
//   - page pagination, 1페이지 16건
//   - minCareer/maxCareer 파라미터는 **서버측 무시** → 클라이언트 필터
async function crawlJumpit(cfg) {
  const { job_category = 1, max_pages = 20, min_career_range = 3, max_career_range = 12 } = cfg;
  const results = [];
  const seenIds = new Set();
  try {
    for (let page = 1; page <= max_pages; page++) {
      const url = `https://jumpit-api.saramin.co.kr/api/positions?jobCategory=${job_category}&page=${page}`;
      const r = await fetch(url, { headers: { 'user-agent': 'Mozilla/5.0', 'accept': 'application/json' } });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      const positions = d?.result?.positions || [];
      if (positions.length === 0) break;
      for (const p of positions) {
        if (seenIds.has(p.id)) continue;
        seenIds.add(p.id);
        const minC = p.minCareer ?? 0;
        const maxC = p.maxCareer ?? 99;
        // 경력 필터: 오너(9년차) 기준 3~12년 범위와 겹치는 공고만
        if (maxC < min_career_range) continue;
        if (minC > max_career_range) continue;
        results.push({
          title: p.title || '',
          url: `https://jumpit.saramin.co.kr/position/${p.id}`,
          company: `[점핏] ${p.companyName || '?'}`,
          minCareer: minC, maxCareer: maxC,
        });
      }
    }
  } catch (e) {
    console.error(`  [API] Jumpit 실패: ${e.message}`);
  }
  return results;
}

// ── API 크롤링 (NineHire) ─────────────────────────────────────────────────
async function crawlNineHire(site) {
  try {
    const r = await fetch(site.apiUrl);
    const d = await r.json();
    return (d?.results || [])
      .filter(o => o.addressKey && o.title)
      .map(o => ({ title: o.title, url: `${site.baseUrl}${o.addressKey}`, company: site.company }));
  } catch (e) {
    console.error(`  [API] ${site.company} 실패: ${e.message}`);
    return [];
  }
}

// ── Puppeteer DOM 크롤링 ──────────────────────────────────────────────────
async function crawlWithBrowser(browser, site) {
  const page = await browser.newPage();
  try {
    await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
    await page.goto(site.url, { waitUntil: 'networkidle2', timeout: 30000 });
    // SPA 렌더링 대기
    await new Promise(r => setTimeout(r, 5000));

    const jobs = await page.evaluate((siteData) => {
      const results = [];
      const seen = new Set();

      function extractTitle(a) {
        const h = a.querySelector('h1,h2,h3,h4,h5');
        if (h) { const t = h.textContent.trim(); if (t.length > 3 && t.length < 100) return t; }
        const titleEl = a.querySelector('[class*="position"],[class*="Position"],[class*="title"],[class*="Title"],[class*="name"],[class*="Name"]');
        if (titleEl) { const t = titleEl.textContent.trim(); if (t.length > 3 && t.length < 100) return t; }
        const full = a.textContent.replace(/\s+/g, ' ').trim();
        return full.split(/[・|/\t\n]/)[0].trim().slice(0, 80);
      }

      if (siteData.parser === 'link' && siteData.linkPattern) {
        document.querySelectorAll(`a[href*="${siteData.linkPattern}"]`).forEach(a => {
          const title = extractTitle(a);
          const url = a.href;
          if (title && title.length > 3 && title.length < 150 && !title.includes('<') && !seen.has(url)) {
            seen.add(url);
            results.push({ title, url, company: siteData.company });
          }
        });
        // onclick fallback
        if (results.length === 0) {
          document.querySelectorAll('[onclick]').forEach(el => {
            const onclick = el.getAttribute('onclick') || '';
            const m = onclick.match(/location\.href\s*=\s*['"]([^'"]+)['"]/);
            if (!m || !m[1].includes(siteData.linkPattern)) return;
            const title = extractTitle(el);
            const url = m[1].startsWith('http') ? m[1] : location.origin + m[1];
            if (title && title.length > 3 && !seen.has(url)) { seen.add(url); results.push({ title, url, company: siteData.company }); }
          });
        }
      }

      // auto-detect fallback
      if (results.length === 0) {
        const LINK_KW = ['opening', 'position', 'apply', 'listings', 'openings', 'roles', 'opportunities'];
        document.querySelectorAll('a[href]').forEach(a => {
          const fullUrl = a.href;
          if (!fullUrl || !fullUrl.startsWith('http')) return;
          try {
            const u = new URL(fullUrl);
            const path = u.pathname;
            if (/\.(css|js|png|jpg|gif|svg|ico|woff|pdf)$/i.test(path)) return;
            if (path.split('/').filter(Boolean).length < 2) return;
            const hasNumId = /\/\d{3,}/.test(path) || /[?&](id|seq|no|idx)=\d+/.test(u.search);
            const hasKw = LINK_KW.some(k => (path + u.search).toLowerCase().includes(k));
            if (!hasNumId && !hasKw) return;
            if (seen.has(fullUrl)) return;
            seen.add(fullUrl);
            const title = extractTitle(a);
            if (title && title.length > 3 && title.length < 150 && !title.includes('<')) {
              results.push({ title, url: fullUrl, company: siteData.company });
            }
          } catch {}
        });
      }

      return results;
    }, { parser: site.parser, linkPattern: site.linkPattern, company: site.company });

    return jobs;
  } catch (e) {
    console.error(`  [Browser] ${site.company} 실패: ${e.message}`);
    return [];
  } finally {
    await page.close();
  }
}

// sendDiscordMsg → SSoT: lib/discord-notify.mjs discordSend
const sendDiscordMsg = (content) => discordSend(content, 'jarvis-inbox', { username: 'Jarvis Crawler' });

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  console.log(`🤖 Jarvis Inbox Crawler — standalone (${new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })})`);

  const seen = loadSeen();
  const allJobs = [];
  const siteResults = [];

  // Phase 1: API 직접 호출 (빠름, 브라우저 불필요)
  console.log('\n📡 Phase 1: API 직접 호출...');

  // Wanted 어그리게이터 (수백 회사 커버)
  if (WANTED_CFG) {
    const jobs = await crawlWanted(WANTED_CFG);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    const byCompany = new Map();
    for (const j of backend) byCompany.set(j.company, (byCompany.get(j.company) || 0) + 1);
    siteResults.push({ company: `원티드 (${byCompany.size}개사)`, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ 원티드: 전체 ${jobs.length}건 (백엔드 ${backend.length}건 / ${byCompany.size}개사, 신규 ${newJobs.length})`);
  }

  // LinkedIn 어그리게이터 (글로벌·대기업급 커버)
  if (LINKEDIN_CFG) {
    const jobs = await crawlLinkedIn(LINKEDIN_CFG);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    const byCompany = new Map();
    for (const j of backend) byCompany.set(j.company, (byCompany.get(j.company) || 0) + 1);
    siteResults.push({ company: `LinkedIn (${byCompany.size}개사)`, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ LinkedIn: 전체 ${jobs.length}건 (백엔드 ${backend.length}건 / ${byCompany.size}개사, 신규 ${newJobs.length})`);
  }

  // Jumpit 어그리게이터 (IT 전문, ~175건 백엔드)
  if (JUMPIT_CFG) {
    const jobs = await crawlJumpit(JUMPIT_CFG);
    // 점핏은 이미 서버/백엔드 카테고리로 필터 완료 — 제목 매칭 스킵
    const newJobs = jobs.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...jobs.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    const byCompany = new Map();
    for (const j of jobs) byCompany.set(j.company, (byCompany.get(j.company) || 0) + 1);
    siteResults.push({ company: `점핏 (${byCompany.size}개사)`, total: jobs.length, backend: jobs.length, new: newJobs.length });
    console.log(`  ✅ 점핏: 전체 ${jobs.length}건 (백엔드 ${jobs.length}건 / ${byCompany.size}개사, 신규 ${newJobs.length})`);
  }

  for (const site of GREETINGHR_SITES) {
    const jobs = await crawlGreetingHR(site);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
  }

  for (const site of NINEHIRE_SITES) {
    const jobs = await crawlNineHire(site);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
  }

  // Phase 2: Puppeteer 브라우저 크롤링
  console.log('\n🌐 Phase 2: 브라우저 크롤링...');
  const browser = await puppeteer.launch({
    executablePath: CHROME_PATH,
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-blink-features=AutomationControlled'],
  });

  const BATCH = 3;
  for (let i = 0; i < SITES.length; i += BATCH) {
    const batch = SITES.slice(i, i + BATCH);
    const results = await Promise.all(batch.map(s => crawlWithBrowser(browser, s)));

    for (let k = 0; k < batch.length; k++) {
      const site = batch[k];
      const jobs = results[k];
      const backend = jobs.filter(j => isBackendJob(j.title));
      const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
      allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
      const emoji = jobs.length > 0 ? '✅' : '⚠️';
      siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
      console.log(`  ${emoji} ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
    }
  }

  await browser.close();
  saveSeen(seen);

  // 결과 저장
  const result = {
    timestamp: new Date().toISOString(),
    totalBackend: allJobs.length,
    totalNew: allJobs.filter(j => j.isNew).length,
    jobs: allJobs,
    siteResults,
  };
  writeFileSync(RESULT_FILE, JSON.stringify(result, null, 2));
  console.log(`\n📊 결과: 백엔드 ${result.totalBackend}건 (신규 ${result.totalNew}건)`);
  console.log(`💾 저장: ${RESULT_FILE}`);

  // Discord 전송
  if (sendToDiscord && !jsonOnly) {
    const lines = siteResults.map(r => {
      if (r.total < 0) return `- ❌ ${r.company}: 오류`;
      if (r.total === 0) return `- ⚠️ ${r.company}: 0건`;
      if (r.new === 0) return `- 🔵 ${r.company}: ${r.total}건 (백엔드 ${r.backend}), 신규 없음`;
      return `- ✅ ${r.company}: ${r.total}건 (백엔드 ${r.backend}), 🆕 ${r.new}건`;
    });
    await sendDiscordMsg(`🤖 **크롤링 완료** (${new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })})\n백엔드 매칭: **${result.totalBackend}건** (🆕 신규 ${result.totalNew}건)\n\n${lines.join('\n')}`);
  }
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });