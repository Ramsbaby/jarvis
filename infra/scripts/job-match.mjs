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

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const CRAWL_DIR = join(BOT_HOME, 'state', 'job-crawl');
const LATEST = join(CRAWL_DIR, 'latest.json');
const MATCHED = join(CRAWL_DIR, 'matched.json');
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const doDiscord = process.argv.includes('--discord');
const doDetail = process.argv.includes('--detail');

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
  const keywordScore = Math.min(50, matched.length * 8); // 키워드당 8점, 최대 50
  const score = Math.min(100, keywordScore + yearScore + diversityBonus);

  return {
    ...job,
    score,
    matchedSkills: matched,
    requiredYears,
    yearOk: requiredYears === 0 || MY_EXPERIENCE_YEARS >= requiredYears,
    categories: [...catMatched],
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
const sendDiscord = (content) => discordSend(content, 'jarvis-system', { username: 'Jarvis Job Matcher' });

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
  const grade = (s) => s >= 80 ? '🟢' : s >= 60 ? '🟡' : '⚪';
  console.log('📊 매칭 결과 (점수순)\n');
  for (const r of results) {
    const skills = r.matchedSkills.slice(0, 6).map(s => `${s}✅`).join(' ');
    const yearTag = r.requiredYears > 0 ? (r.yearOk ? `경력${r.requiredYears}년+✅` : `경력${r.requiredYears}년+❌`) : '';
    console.log(`${grade(r.score)} ${r.score}점 [${r.company}] ${r.title}`);
    console.log(`   매칭: ${skills} ${yearTag}`);
    console.log(`   ${r.url}\n`);
  }

  const top = results.filter(r => r.score >= 60);
  console.log(`\n📋 요약: ${results.length}건 중 ${top.length}건 매칭 (60점+)`);

  // Discord
  if (doDiscord) {
    const lines = results.filter(r => r.score >= 50).map(r => {
      const skills = r.matchedSkills.slice(0, 5).map(s => `${s}✅`).join(' ');
      return `${grade(r.score)} **${r.score}점** [${r.company}] ${r.title}\n   ${skills}\n   <${r.url}>`;
    });
    const msg = `🎯 **채용 매칭 결과** — ${data.jobs.length}건 중 ${top.length}건 매칭\n\n${lines.join('\n\n')}`;
    await sendDiscord(msg);
    console.log('✅ Discord 전송 완료');
  }
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
