/**
 * Jarvis Job Crawler — Background Service Worker
 * MV3 기반, chrome.alarms로 4시간마다 실행
 * 실제 탭을 열어 DOM 파싱 → 봇 감지 우회
 */

// ─── 설정 ──────────────────────────────────────────────────────────────────
// Discord 봇 토큰 + jarvis-career 채널 ID
// Set these in the extension options or via environment
const DISCORD_BOT_TOKEN = ''; // Your Discord bot token
const DISCORD_CHANNEL_ID = ''; // Target Discord channel ID
const ALARM_NAME = 'job-crawl';
const INTERVAL_HOURS = 4; // 매 4시간

// 크롤링 대상 사이트 목록 (URL 200 확인된 것만)
const SITES = [
  {
    id: 'hyundai-autoever',
    company: '현대오토에버',
    url: 'https://career.hyundai-autoever.com/ko/apply',
    parser: 'hyundai-autoever',
  },
  {
    id: 'skcareers',
    company: 'SK(텔레콤/하이닉스)',
    // SK그룹 공통 포털 — IT/백엔드 검색
    url: 'https://www.skcareers.com/Recruit/Index?searchText=백엔드',
    parser: 'skt',
  },
  // Add your target company career pages here
  // Example:
  // {
  //   id: 'company-name',
  //   company: 'Company Name',
  //   url: 'https://careers.example.com/jobs',
  //   parser: 'example',
  // },
  {
    id: 'naver',
    company: '네이버',
    url: 'https://recruit.navercorp.com/rcrt/list.do?entTypeCd=&jobCd=3010001%2C3010002%2C3010003&sysType=normal',
    parser: 'naver',
  },
  {
    id: 'krafton',
    company: '크래프톤',
    url: 'https://krafton.com/careers/jobs/?category=Engineering',  // company-crawler.mjs 검증 URL
    parser: 'krafton',
  },
  {
    id: 'toss',
    company: '토스',
    url: 'https://toss.im/career/jobs',
    parser: 'toss',
  },
  {
    id: 'daangn',
    company: '당근',
    url: 'https://about.daangn.com/jobs/',
    parser: 'daangn',
  },
  // ── 추가 대기업 ──────────────────────────────────────────────────────────
  {
    id: 'woowa',
    company: '우아한형제들(배민)',
    url: 'https://career.woowahan.com/recruitment/?category=jobGroupCode&tag=BA005001',
    parser: 'woowa',
  },
  {
    id: 'lgcns',
    company: 'LG CNS',
    url: 'https://www.lgcns.com/content/lgcns/kr/careers/jobs.html',
    parser: 'lgcns',
  },
  {
    id: 'kt',
    company: 'KT',
    url: 'https://recruit.kt.com',
    parser: 'kt',
  },
  {
    id: 'samsung-sds',
    company: '삼성SDS',
    url: 'https://www.samsungsds.com/kr/career/list.html',
    parser: 'samsung-sds',
  },
  {
    id: 'samsung-elec',
    company: '삼성전자',
    url: 'https://careers.samsung.com/listPage',
    parser: 'samsung-elec',
  },
  {
    id: 'hanwha-systems',
    company: '한화시스템',
    url: 'https://recruit.hanwhasystems.com/apply/main.do',
    parser: 'hanwha',
  },

  // ── 빅테크/핀테크 ────────────────────────────────────────────────────────
  {
    id: 'line',
    company: '라인(LINE)',
    url: 'https://careers.linecorp.com/jobs?co=Korea&cl=Engineering',
    parser: 'line',
  },
  {
    id: 'coupang',
    company: '쿠팡',
    url: 'https://www.coupang.jobs/contents/job-search/?search_keyword=backend&search_area=true',
    parser: 'coupang',
  },
  {
    id: 'dunamu',
    company: '두나무(업비트)',
    url: 'https://careers.dunamu.com/jobs',
    parser: 'dunamu',
  },
  {
    id: 'yanolja',
    company: '야놀자',
    url: 'https://careers.yanolja.co/jobs',
    parser: 'yanolja',
  },
  {
    id: 'kurly',
    company: '컬리',
    url: 'https://career.kurly.com/jobs',
    parser: 'kurly',
  },
  {
    id: 'nhn',
    company: 'NHN',
    url: 'https://careers.nhn.com/jobs',
    parser: 'nhn',
  },

  // ── 게임 ─────────────────────────────────────────────────────────────────
  {
    id: 'nexon',
    company: '넥슨',
    url: 'https://career.nexon.com/common/list',
    parser: 'nexon',
  },
  {
    id: 'netmarble',
    company: '넷마블',
    url: 'https://career.netmarble.net/list',
    parser: 'netmarble',
  },
  {
    id: 'ncsoft',
    company: 'NC소프트',
    url: 'https://careers.ncsoft.com/jobs',
    parser: 'ncsoft',
  },

  // ── 금융/커머스 ──────────────────────────────────────────────────────────
  {
    id: 'hyundaicard',
    company: '현대카드',
    url: 'https://talent.hyundaicard.com/recruit/jobList.do',
    parser: 'hyundaicard',
  },
  {
    id: 'lguplus',
    company: 'LG유플러스',
    url: 'https://careers.lguplus.com/jobs',
    parser: 'lguplus',
  },
  {
    id: 'poscodx',
    company: '포스코DX',
    url: 'https://www.poscodx.com/kor/recruit/notice/list.do',
    parser: 'poscodx',
  },
];

// 백엔드 관련 키워드
const BACKEND_KEYWORDS = [
  'java', 'spring', '백엔드', 'backend', '서버 개발', '서버개발',
  'springboot', 'webflux', 'jvm', 'msa', 'microservice', '마이크로서비스',
  'server 엔지니어', 'platform engineer', '플랫폼 개발',
  // 추가: 자주 쓰이는 한국어 직함 변형
  '서버 엔지니어', '서버엔지니어', '서버개발자', '서버 개발자',
  'kotlin', 'golang', 'go 언어', 'node.js', 'nodejs', 'python',
  '시스템 개발', '시스템개발', 'api 개발', '클라우드 엔지니어',
];

// 제외 키워드
const EXCLUDE_KEYWORDS = [
  '석사', '박사', 'phd', '석·박사', '석박사',
  '연구원', 'research engineer', 'research scientist', 'researcher',
  '프론트엔드', 'frontend', 'front-end',
  'ios', 'android', '모바일 앱',
  'data scientist', 'ml engineer', 'machine learning engineer',
  '디자이너', 'designer',
  'devrel', '기술영업', '솔루션즈 아키텍트',
];

// ─── background 컨텍스트용 isBackendJob (runCrawl에서 사용) ──────────────
function isBackendJob(title) {
  if (!title) return false;
  const lower = title.toLowerCase();
  if (EXCLUDE_KEYWORDS.some(k => lower.includes(k.toLowerCase()))) return false;
  return BACKEND_KEYWORDS.some(k => lower.includes(k.toLowerCase()));
}

// ─── 알람 초기화 ────────────────────────────────────────────────────────────
chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(ALARM_NAME, {
    delayInMinutes: 1,           // 설치 1분 후 첫 실행
    periodInMinutes: INTERVAL_HOURS * 60,
  });
  console.log('[Jarvis] 크롤러 알람 등록 완료');
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    console.log('[Jarvis] 알람 발생 → 크롤링 시작');
    runCrawl();
  }
});

// ─── 메인 크롤 ─────────────────────────────────────────────────────────────
async function runCrawl() {
  const seen = await loadSeen();
  const allNewJobs = [];
  const siteResults = []; // 디버그용 사이트별 결과

  for (const site of SITES) {
    try {
      console.log(`[Jarvis] ${site.company} 크롤링 중...`);
      const jobs = await crawlSite(site);
      const newJobs = jobs.filter(j => {
        const id = makeId(j.url || (site.id + '|' + j.title));
        if (seen.has(id)) return false;
        if (!isBackendJob(j.title)) return false;
        seen.add(id);
        return true;
      });
      allNewJobs.push(...newJobs);
      siteResults.push({ company: site.company, total: jobs.length, newCount: newJobs.length });
      console.log(`[Jarvis] ${site.company}: 전체 ${jobs.length}건, 신규 ${newJobs.length}건`);
    } catch (e) {
      siteResults.push({ company: site.company, total: -1, newCount: 0, error: e.message });
      console.error(`[Jarvis] ${site.company} 실패:`, e.message);
    }
    await sleep(1000); // 22개 사이트 기준 전체 소요 ~2분 목표
  }

  await saveSeen(seen);

  // 항상 Discord에 실행 결과 보고
  const now = new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' });
  if (allNewJobs.length > 0) {
    await sendDiscord(allNewJobs);
  }

  // 실행 요약 보고 (신규 없어도 전송)
  const summaryLines = siteResults.map(r => {
    if (r.error) return `- ❌ ${r.company}: 오류 (${r.error.slice(0, 60)})`;
    if (r.total === 0) return `- ⚠️ ${r.company}: 링크 0건 (URL패턴 불일치)`;
    if (r.newCount === 0) return `- 🔵 ${r.company}: ${r.total}건 파싱, 신규 없음`;
    return `- ✅ ${r.company}: ${r.total}건 파싱, 🆕 신규 ${r.newCount}건`;
  });
  const summary = `🤖 **크롤링 완료** (${now})\n신규 공고: **${allNewJobs.length}건**\n\n${summaryLines.join('\n')}`;
  await sendDiscordRaw(summary);
}

// ─── 탭 기반 크롤링 ────────────────────────────────────────────────────────
async function crawlSite(site) {
  return new Promise((resolve) => {
    let tab;
    const timeout = setTimeout(() => {
      if (tab) chrome.tabs.remove(tab.id).catch(() => {});
      resolve([]);
    }, 45000); // 45초 타임아웃 (4초 대기 + 페이지 로드 시간)

    chrome.tabs.create({ url: site.url, active: false }, (newTab) => {
      tab = newTab;

      const listener = (tabId, changeInfo) => {
        if (tabId !== tab.id || changeInfo.status !== 'complete') return;
        chrome.tabs.onUpdated.removeListener(listener);

        // 페이지 로딩 후 4초 대기 (React SPA API 로딩 시간)
        setTimeout(async () => {
          try {
            const results = await chrome.scripting.executeScript({
              target: { tabId: tab.id },
              func: parseJobsFromPage,
              args: [site.parser, BACKEND_KEYWORDS, EXCLUDE_KEYWORDS],
            });
            clearTimeout(timeout);
            chrome.tabs.remove(tab.id).catch(() => {});
            resolve(results?.[0]?.result || []);
          } catch (e) {
            clearTimeout(timeout);
            chrome.tabs.remove(tab.id).catch(() => {});
            resolve([]);
          }
        }, 4000);
      };

      chrome.tabs.onUpdated.addListener(listener);
    });
  });
}

// ─── 페이지 내 파싱 함수 (content script로 inject됨) ─────────────────────
// 이 함수는 탭 컨텍스트에서 실행됨 (DOM 접근 가능)
function parseJobsFromPage(parser, backendKeywords, excludeKeywords) {
  const jobs = [];

  function isBackend(title) {
    if (!title) return false;
    const lower = title.toLowerCase();
    if (excludeKeywords.some(k => lower.includes(k.toLowerCase()))) return false;
    return backendKeywords.some(k => lower.includes(k.toLowerCase()));
  }

  function getText(el) {
    return el ? el.textContent.trim() : '';
  }

  // ── URL 패턴 기반 범용 파서 (company-crawler.mjs 검증 방식) ──────────────
  // isBackend 필터 없이 전체 수집 → runCrawl에서 필터 (total 카운트 정확도 확보)
  function parseByLinkPattern(linkPattern, company, baseUrl) {
    document.querySelectorAll(`a[href*="${linkPattern}"]`).forEach(a => {
      // 링크 텍스트 추출: 직접 텍스트 → 자식 heading/title 요소 순서로 시도
      const childTitle = a.querySelector('h1,h2,h3,h4,h5,strong,b,[class*="title"],[class*="Title"],[class*="name"],[class*="Name"]');
      const title = (childTitle ? getText(childTitle) : '') || getText(a);
      const cleanTitle = title.replace(/\s+/g, ' ').trim();
      const url = a.href.startsWith('http') ? a.href : baseUrl + a.getAttribute('href');
      // HTML 태그 포함(Gatsby noscript 오염) 또는 비정상 길이 제외
      if (cleanTitle && cleanTitle.length > 3 && cleanTitle.length < 150 && !cleanTitle.includes('<')) {
        jobs.push({ title: cleanTitle, url, company });
      }
    });
  }

  try {
    if (parser === 'hyundai-autoever') {
      // 현대오토에버 — career.hyundai-autoever.com/ko/apply
      // 확인된 셀렉터: .PqSxf (OpeningListItemTitle), 링크: /ko/o/[ID]
      const items = document.querySelectorAll('.PqSxf, [class*="OpeningListItemTitle"], [class*="OpeningItem"]');
      items.forEach(item => {
        const title = getText(item.querySelector('[class*="Title"]') || item);
        const link = item.closest('a') || item.parentElement?.querySelector('a');
        const href = link ? (link.href.startsWith('http') ? link.href : 'https://career.hyundai-autoever.com' + link.getAttribute('href')) : location.href;
        if (title && isBackend(title)) {
          jobs.push({ title, url: href, company: '현대오토에버' });
        }
      });
      // 폴백: 모든 a 태그에서 /ko/o/ 패턴
      if (jobs.length === 0) {
        document.querySelectorAll('a[href*="/ko/o/"]').forEach(a => {
          const title = getText(a);
          if (title && isBackend(title)) {
            jobs.push({ title, url: a.href, company: '현대오토에버' });
          }
        });
      }

    } else if (parser === 'naver') {
      // 네이버: onclick="show('RCRTNO')" 패턴 + a 링크 혼용
      document.querySelectorAll('[onclick*="show("]').forEach(el => {
        const m = el.getAttribute('onclick')?.match(/show\(['"]([\w]+)['"]\)/);
        const title = getText(el);
        if (m && title && isBackend(title)) {
          jobs.push({ title, url: `https://recruit.navercorp.com/rcrt/view.do?rcrtNo=${m[1]}`, company: '네이버' });
        }
      });
      if (jobs.length === 0) {
        parseByLinkPattern('/rcrt/', '네이버', 'https://recruit.navercorp.com');
      }

    } else if (parser === 'krafton') {
      // /careers/jobs/12345 형태 — 슬래시 없이 jobs/ 로 매칭 (company-crawler.mjs 방식)
      parseByLinkPattern('jobs/', '크래프톤', 'https://krafton.com');

    } else if (parser === 'toss') {
      parseByLinkPattern('job-detail', '토스', 'https://toss.im');

    } else if (parser === 'daangn') {
      parseByLinkPattern('/jobs/', '당근', 'https://about.daangn.com');

    } else if (parser === 'skt') {
      // SK Careers 공통 포털 — /Recruit/Detail/{id} 형태
      parseByLinkPattern('/Recruit/Detail/', 'SK그룹', 'https://www.skcareers.com');
      if (jobs.length === 0) parseByLinkPattern('/Recruit/', 'SK그룹', 'https://www.skcareers.com');

    } else if (parser === 'woowa') {
      // 우아한형제들(배민) — /recruitment/ 패턴 (company-crawler.mjs 검증)
      parseByLinkPattern('recruitment', '우아한형제들', 'https://career.woowahan.com');

    } else if (parser === 'lgcns') {
      // LG CNS — /careers/ 패턴
      parseByLinkPattern('careers', 'LG CNS', 'https://www.lgcns.com');
      if (jobs.length === 0) parseByLinkPattern('recruit', 'LG CNS', 'https://www.lgcns.com');

    } else if (parser === 'kt') {
      // KT — /pos/ 또는 /recruit/ 패턴 (company-crawler.mjs 검증)
      parseByLinkPattern('/pos/', 'KT', 'https://recruit.kt.com');
      if (jobs.length === 0) parseByLinkPattern('/recruit/', 'KT', 'https://recruit.kt.com');

    } else if (parser === 'samsung-sds') {
      // 삼성SDS — /career/ 패턴
      parseByLinkPattern('/career/', '삼성SDS', 'https://www.samsungsds.com');

    } else if (parser === 'samsung-elec') {
      // 삼성전자 — /job/ 또는 /jobs/ 패턴 시도
      parseByLinkPattern('/job/', '삼성전자', 'https://careers.samsung.com');
      if (jobs.length === 0) parseByLinkPattern('/jobs/', '삼성전자', 'https://careers.samsung.com');

    } else if (parser === 'hanwha') {
      // 한화시스템 — /apply/ 패턴
      parseByLinkPattern('/apply/', '한화시스템', 'https://recruit.hanwhasystems.com');
      if (jobs.length === 0) parseByLinkPattern('/recruit/', '한화시스템', 'https://recruit.hanwhasystems.com');

    // ── 빅테크/핀테크 ──────────────────────────────────────────────────────
    } else if (parser === 'line') {
      parseByLinkPattern('/jobs/', '라인', 'https://careers.linecorp.com');

    } else if (parser === 'coupang') {
      // 쿠팡 — job-detail 또는 job_id 패턴
      parseByLinkPattern('job_id', '쿠팡', 'https://www.coupang.jobs');
      if (jobs.length === 0) parseByLinkPattern('/careers/', '쿠팡', 'https://www.coupang.jobs');

    } else if (parser === 'dunamu') {
      parseByLinkPattern('/jobs/', '두나무', 'https://careers.dunamu.com');

    } else if (parser === 'yanolja') {
      parseByLinkPattern('/jobs/', '야놀자', 'https://careers.yanolja.co');

    } else if (parser === 'kurly') {
      parseByLinkPattern('/jobs/', '컬리', 'https://career.kurly.com');

    } else if (parser === 'nhn') {
      parseByLinkPattern('/jobs/', 'NHN', 'https://careers.nhn.com');
      if (jobs.length === 0) parseByLinkPattern('/recruit/', 'NHN', 'https://careers.nhn.com');

    // ── 게임 ────────────────────────────────────────────────────────────────
    } else if (parser === 'nexon') {
      // 넥슨 — /common/list 하위 상세 패턴
      parseByLinkPattern('/detail/', '넥슨', 'https://career.nexon.com');
      if (jobs.length === 0) parseByLinkPattern('/common/', '넥슨', 'https://career.nexon.com');

    } else if (parser === 'netmarble') {
      parseByLinkPattern('/list/', '넷마블', 'https://career.netmarble.net');
      if (jobs.length === 0) parseByLinkPattern('/detail/', '넷마블', 'https://career.netmarble.net');

    } else if (parser === 'ncsoft') {
      parseByLinkPattern('/jobs/', 'NC소프트', 'https://careers.ncsoft.com');

    // ── 금융/커머스 ─────────────────────────────────────────────────────────
    } else if (parser === 'hyundaicard') {
      parseByLinkPattern('/recruit/', '현대카드', 'https://talent.hyundaicard.com');
      if (jobs.length === 0) parseByLinkPattern('jobList', '현대카드', 'https://talent.hyundaicard.com');

    } else if (parser === 'lguplus') {
      parseByLinkPattern('/jobs/', 'LG유플러스', 'https://careers.lguplus.com');
      if (jobs.length === 0) parseByLinkPattern('/career/', 'LG유플러스', 'https://careers.lguplus.com');

    } else if (parser === 'poscodx') {
      parseByLinkPattern('/notice/', '포스코DX', 'https://www.poscodx.com');
      if (jobs.length === 0) parseByLinkPattern('/recruit/', '포스코DX', 'https://www.poscodx.com');
    }

  } catch (e) {
    console.error('[Jarvis Parser] 오류:', e.message);
  }

  return jobs;
}

// ─── Discord 전송 — localhost:7779 relay 경유 (CSP/CORS 우회) ─────────────
const RELAY_URL = 'http://127.0.0.1:7779/api/relay-discord';

async function sendDiscordRaw(content) {
  try {
    const res = await fetch(RELAY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content }),
    });
    if (!res.ok) {
      const err = await res.text();
      console.error('[Jarvis] relay 오류:', err);
    }
  } catch (e) {
    console.error('[Jarvis] relay 전송 실패:', e.message);
  }
}

async function sendDiscord(jobs) {
  const chunks = chunkArray(jobs, 5);
  for (const chunk of chunks) {
    const lines = chunk.map(j => `- **[${j.company}]** ${j.title}\n  ${j.url}`);
    const content = `🔔 **채용 알림 — ${jobs.length}건** (${new Date().toLocaleDateString('ko-KR')})\n\n${lines.join('\n')}`;
    await sendDiscordRaw(content);
    await sleep(500);
  }
}

// ─── Seen ID 관리 ─────────────────────────────────────────────────────────
async function loadSeen() {
  const result = await chrome.storage.local.get('seenIds');
  return new Set(result.seenIds || []);
}

async function saveSeen(seenSet) {
  const arr = [...seenSet].slice(-3000); // 최대 3000개 유지
  await chrome.storage.local.set({ seenIds: arr, updatedAt: new Date().toISOString() });
}

function makeId(str) {
  // 간단한 해시 (crypto.subtle은 async라 여기선 단순 처리)
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

// ─── 유틸 ─────────────────────────────────────────────────────────────────
function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

function chunkArray(arr, size) {
  const result = [];
  for (let i = 0; i < arr.length; i += size) result.push(arr.slice(i, i + size));
  return result;
}

// ─── 팝업에서 수동 실행 요청 수신 ─────────────────────────────────────────
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === 'RUN_NOW') {
    console.log('[Jarvis] 수동 실행 요청');
    runCrawl().then(() => sendResponse({ ok: true }));
    return true; // async response
  }
  if (msg.type === 'GET_STATUS') {
    chrome.storage.local.get(['updatedAt', 'seenIds'], (data) => {
      sendResponse({
        lastRun: data.updatedAt || '없음',
        seenCount: (data.seenIds || []).length,
      });
    });
    return true;
  }
});
