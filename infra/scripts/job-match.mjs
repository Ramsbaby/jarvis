#!/usr/bin/env node
/**
 * Jarvis Job Matcher — 크롤링 결과 vs 이력서 데이터 매칭
 *
 * Usage: node job-match.mjs [--discord] [--detail]
 * --detail: 각 공고 상세 페이지까지 접속하여 요구사항 정밀 매칭
 * --discord: 결과를 #jarvis Discord 채널에 전송
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import puppeteer from 'puppeteer-core';
import { discordSend } from '../lib/discord-notify.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const CRAWL_DIR = join(BOT_HOME, 'state', 'job-crawl');
const LATEST = join(CRAWL_DIR, 'latest.json');
const MATCHED = join(CRAWL_DIR, 'matched.json');
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Notion 연동 상수 (SSoT)
// DB 자체에는 integration 공유가 없어 query/insert 불가 → 부모 페이지 아래 일일 리포트 페이지로 저장
const NOTION_TOKEN = process.env.NOTION_TOKEN || '';
const NOTION_VERSION = '2022-06-28';

// ── Private 설정 로드 (티어·Notion Page ID 등 민감 식별자) ────────────────
// private/config/job-tiers.json은 gitignored — 회사 리터럴·Page ID는 이 파일에만 존재해야 함.
// 파일 없거나 로드 실패 시: tier/role 가산점 0점, Notion 전송 스킵으로 graceful fallback.
const JOB_TIERS_PATH = join(homedir(), 'jarvis', 'private', 'config', 'job-tiers.json');
let JOB_TIERS_CONFIG = { tiers: {}, tierBonus: {}, roleBonus: {}, notion: {} };
try {
  if (existsSync(JOB_TIERS_PATH)) {
    JOB_TIERS_CONFIG = JSON.parse(readFileSync(JOB_TIERS_PATH, 'utf-8'));
  } else {
    console.warn(`⚠️ ${JOB_TIERS_PATH} 없음 — 티어/역할 가산점 0점으로 동작`);
  }
} catch (e) {
  console.warn(`⚠️ job-tiers.json 로드 실패: ${e.message} — 가산점 0점 fallback`);
}
const NOTION_JOB_PARENT_PAGE_ID = JOB_TIERS_CONFIG.notion?.parentPageId || '';

const doDiscord = process.argv.includes('--discord');
const doDetail = process.argv.includes('--detail');
const doNotion = process.argv.includes('--notion') || (doDiscord && NOTION_TOKEN && NOTION_JOB_PARENT_PAGE_ID); // --discord + 설정 모두 있을 때만 자동

// ── 이력서 키워드 (resume-data.md 기반 하드코딩 — SSoT) ───────────────────
const MY_SKILLS = {
  languages: ['java', 'kotlin', 'javascript', 'typescript', 'python', 'node.js', 'nodejs'],
  frameworks: ['spring', 'spring boot', 'springboot', 'spring 6', 'webflux', 'jpa', 'mybatis', 'r2dbc'],
  infra: ['aws', 'docker', 'kubernetes', 'k8s', 'redis', 'kafka', 'rabbitmq', 'sqs', 'lambda',
          'datadog', 'cloudwatch', 'elasticsearch', 'nginx', 'jenkins', 'github actions'],
  db: ['mysql', 'mariadb', 'postgresql', 'mongodb', 'lancedb', 'rdbms', 'dynamodb'],
  arch: ['msa', 'microservice', '마이크로서비스', 'eda', 'event driven', '이벤트 기반',
         'grpc', 'graphql', 'rest', 'api'],
  domain: ['saas', 'iot', 'o2o', '플랫폼', '결제', '정산', '커머스', '메신저',
           '백엔드', 'backend', '서버', 'server'],
};

const MY_EXPERIENCE_YEARS = 9; // 2016.05 ~ 현재

// 전체 스킬 키워드 flat
const ALL_SKILLS = Object.values(MY_SKILLS).flat();

// ── 회사 티어 가산점 (JOB_TIERS_CONFIG 에서 로드, fallback 0점) ───────────
function getTierBonus(company) {
  const tiers = JOB_TIERS_CONFIG.tiers || {};
  const bonuses = JOB_TIERS_CONFIG.tierBonus || {};
  const lower = (company || '').toLowerCase();
  for (const [tier, list] of Object.entries(tiers)) {
    if (!Array.isArray(list)) continue;
    if (list.some(c => lower.includes(String(c).toLowerCase()))) {
      return { tier, bonus: bonuses[tier] || 0 };
    }
  }
  return { tier: null, bonus: 0 };
}

// ── 직군 정확도 보너스 (JOB_TIERS_CONFIG.roleBonus 에서 로드, fallback 0점) ─
function getRoleBonus(title) {
  const roles = JOB_TIERS_CONFIG.roleBonus || {};
  const lower = (title || '').toLowerCase();
  for (const spec of Object.values(roles)) {
    if (!spec?.pattern) continue;
    try {
      if (new RegExp(spec.pattern).test(lower)) return spec.points || 0;
    } catch { /* invalid regex → skip */ }
  }
  return 0;
}

// ── 매칭 로직 ─────────────────────────────────────────────────────────────
function matchJob(job, detailText = '') {
  const text = `${job.title} ${detailText}`.toLowerCase();

  // 키워드 매칭
  const matched = [];
  const missed = [];
  const checked = new Set();

  for (const skill of ALL_SKILLS) {
    if (checked.has(skill)) continue;
    checked.add(skill);
    if (text.includes(skill.toLowerCase())) {
      matched.push(skill);
    }
  }

  // 경력 연수 매칭
  const yearMatch = text.match(/(\d+)\s*년\s*(이상|경력)/);
  const requiredYears = yearMatch ? parseInt(yearMatch[1]) : 0;
  const yearScore = requiredYears > 0
    ? (MY_EXPERIENCE_YEARS >= requiredYears ? 20 : Math.max(0, 20 - (requiredYears - MY_EXPERIENCE_YEARS) * 5))
    : 10; // 연수 미명시 시 기본점

  // 키워드 카테고리별 매칭 (다양성 보너스)
  const catMatched = new Set();
  for (const [cat, skills] of Object.entries(MY_SKILLS)) {
    if (skills.some(s => text.includes(s.toLowerCase()))) catMatched.add(cat);
  }
  const diversityBonus = catMatched.size * 5; // 카테고리당 5점

  // 최종 점수 (100점 만점)
  const keywordScore = Math.min(40, matched.length * 8); // 키워드당 8점, 최대 40
  const { tier, bonus: tierBonus } = getTierBonus(job.company);
  const roleBonus = getRoleBonus(job.title);
  const score = Math.min(100, keywordScore + yearScore + diversityBonus + tierBonus + roleBonus);

  return {
    ...job,
    score,
    matchedSkills: matched,
    requiredYears,
    yearOk: requiredYears === 0 || MY_EXPERIENCE_YEARS >= requiredYears,
    categories: [...catMatched],
    tier,
    tierBonus,
    roleBonus,
  };
}

// ── 상세 페이지 텍스트 추출 (--detail) ────────────────────────────────────
async function fetchDetailText(browser, url) {
  const page = await browser.newPage();
  try {
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 20000 });
    await new Promise(r => setTimeout(r, 3000));
    const text = await page.evaluate(() => document.body.innerText.slice(0, 5000));
    return text;
  } catch {
    return '';
  } finally {
    await page.close();
  }
}

// sendDiscord → SSoT: lib/discord-notify.mjs discordSend (줄경계 청킹 포함)
const sendDiscord = (content) => discordSend(content, 'jarvis-career', { username: 'Jarvis Job Matcher' });

// ── Notion DB 연동 ────────────────────────────────────────────────────────
async function notionApi(path, method = 'GET', body = null) {
  const res = await fetch(`https://api.notion.com/v1/${path}`, {
    method,
    headers: {
      'Authorization': `Bearer ${NOTION_TOKEN}`,
      'Notion-Version': NOTION_VERSION,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Notion ${method} ${path} failed: ${res.status} ${text.slice(0, 200)}`);
  }
  return res.json();
}

function buildReportBlocks(results) {
  const grouped = { S: [], A: [], B: [], none: [] };
  for (const r of results) grouped[r.tier || 'none'].push(r);

  const blocks = [];
  const push = (b) => blocks.push({ object: 'block', ...b });

  // 요약
  push({
    type: 'callout',
    callout: {
      icon: { emoji: '📊' },
      rich_text: [{ type: 'text', text: { content:
        `총 ${results.length}건 · S티어 ${grouped.S.length} / A티어 ${grouped.A.length} / B티어 ${grouped.B.length} / 기타 ${grouped.none.length}`
      } }]
    }
  });

  const tierLabel = { S: '🟢 S티어 (타겟 대기업)', A: '🟡 A티어 (유니콘·유망)', B: '🔵 B티어 (대기업 그룹사)', none: '⚪ 기타' };

  for (const tier of ['S', 'A', 'B', 'none']) {
    const list = grouped[tier];
    if (!list.length) continue;
    push({
      type: 'heading_2',
      heading_2: { rich_text: [{ type: 'text', text: { content: `${tierLabel[tier]} (${list.length}건)` } }] }
    });
    for (const r of list) {
      const skills = r.matchedSkills.slice(0, 6).join(', ') || '—';
      const yearTag = r.requiredYears > 0 ? (r.yearOk ? ` · ${r.requiredYears}년+✅` : ` · ${r.requiredYears}년+❌`) : '';
      push({
        type: 'bulleted_list_item',
        bulleted_list_item: {
          rich_text: [
            { type: 'text', text: { content: `${r.score}점 `, link: null }, annotations: { bold: true } },
            { type: 'text', text: { content: `[${r.company}] ${r.title}`, link: r.url ? { url: r.url } : null } },
            { type: 'text', text: { content: ` — ${skills}${yearTag}` } },
          ]
        }
      });
    }
  }

  return blocks;
}

async function sendNotion(results) {
  if (!NOTION_TOKEN) {
    console.log('⚠️ NOTION_TOKEN 없음, Notion 전송 스킵');
    return { pageUrl: null, count: 0 };
  }
  if (!results.length) return { pageUrl: null, count: 0 };

  const today = new Date().toISOString().slice(0, 10);
  const title = `📋 채용 매칭 리포트 ${today} (${results.length}건)`;
  const allBlocks = buildReportBlocks(results);

  // Notion은 페이지 생성 시 children 100개 이하만 허용 → 초과분은 append 로 분할
  const BATCH = 90;
  const firstBatch = allBlocks.slice(0, BATCH);
  const rest = allBlocks.slice(BATCH);

  const page = await notionApi('pages', 'POST', {
    parent: { page_id: NOTION_JOB_PARENT_PAGE_ID },
    icon: { emoji: '📋' },
    properties: {
      title: { title: [{ type: 'text', text: { content: title } }] }
    },
    children: firstBatch,
  });

  for (let i = 0; i < rest.length; i += BATCH) {
    await notionApi(`blocks/${page.id}/children`, 'PATCH', {
      children: rest.slice(i, i + BATCH)
    });
  }

  return { pageUrl: page.url, count: results.length };
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  if (!existsSync(LATEST)) {
    console.error('latest.json 없음. 먼저 job-crawl.mjs를 실행하세요.');
    process.exit(1);
  }

  const data = JSON.parse(readFileSync(LATEST, 'utf-8'));
  console.log(`🎯 매칭 시작 — ${data.jobs.length}건 백엔드 공고\n`);

  let browser;
  if (doDetail) {
    console.log('📄 상세 페이지 분석 모드 (시간이 더 걸립니다)...\n');
    browser = await puppeteer.launch({ executablePath: CHROME_PATH, headless: 'new' });
  }

  const results = [];
  for (const job of data.jobs) {
    let detailText = '';
    if (doDetail && browser) {
      detailText = await fetchDetailText(browser, job.url);
    }
    results.push(matchJob(job, detailText));
  }

  if (browser) await browser.close();

  // 점수 내림차순 정렬
  results.sort((a, b) => b.score - a.score);

  // 결과 저장
  writeFileSync(MATCHED, JSON.stringify({ timestamp: new Date().toISOString(), results }, null, 2));

  // 출력
  const grade = (s) => s >= 70 ? '🟢' : s >= 50 ? '🟡' : s >= 35 ? '🔵' : '⚪';
  console.log('📊 매칭 결과 (점수순)\n');
  for (const r of results) {
    const skills = r.matchedSkills.slice(0, 6).map(s => `${s}✅`).join(' ');
    const yearTag = r.requiredYears > 0 ? (r.yearOk ? `경력${r.requiredYears}년+✅` : `경력${r.requiredYears}년+❌`) : '';
    const tierTag = r.tier ? `[${r.tier}티어]` : '';
    console.log(`${grade(r.score)} ${r.score}점 ${tierTag} [${r.company}] ${r.title}`);
    console.log(`   매칭: ${skills} ${yearTag}`);
    console.log(`   ${r.url}\n`);
  }

  const THRESHOLD = 35;
  const top = results.filter(r => r.score >= THRESHOLD);
  console.log(`\n📋 요약: ${results.length}건 중 ${top.length}건 매칭 (${THRESHOLD}점+)`);

  // Notion 상세 저장 (먼저 실행 — Discord 에서 페이지 URL 참조)
  let notionResult = { pageUrl: null, count: 0 };
  if (doNotion) {
    try {
      notionResult = await sendNotion(top);
      if (notionResult.pageUrl) {
        console.log(`✅ Notion: ${notionResult.count}건 리포트 페이지 생성 → ${notionResult.pageUrl}`);
      }
    } catch (e) {
      console.error(`❌ Notion 전송 실패: ${e.message}`);
    }
  }

  // Discord 약식 전송
  if (doDiscord) {
    const tierCount = { S: 0, A: 0, B: 0, none: 0 };
    for (const r of top) tierCount[r.tier || 'none']++;

    const top3 = top.slice(0, 3).map(r => {
      const tierTag = r.tier ? `\`${r.tier}티어\` ` : '';
      const title = r.title.length > 45 ? r.title.slice(0, 42) + '…' : r.title;
      return `${grade(r.score)} **${r.score}점** ${tierTag}[${r.company}] ${title}`;
    }).join('\n');

    const tierLine = `🟢 S티어 ${tierCount.S} · 🟡 A티어 ${tierCount.A} · 🔵 B티어 ${tierCount.B}`;
    const notionLine = notionResult.pageUrl
      ? `\n\n📋 **상세 전체 (${notionResult.count}건)**: <${notionResult.pageUrl}>`
      : '';

    const header = `🎯 **채용 매칭** — ${data.jobs.length}건 중 **${top.length}건** 매칭 (${THRESHOLD}점+)`;
    const msg = top.length > 0
      ? `${header}\n${tierLine}\n\n**🔝 TOP 3**\n${top3}${notionLine}`
      : `${header}\n\n(금일 매칭 공고 없음 — 내일 다시 크롤링됩니다)`;

    await sendDiscord(msg);
    console.log('✅ Discord 약식 전송 완료');
  }
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });