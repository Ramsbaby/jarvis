#!/usr/bin/env node
/**
 * Jarvis Job Apply — Claude in Chrome 브라우저 자동 지원
 *
 * Usage:
 *   node job-apply.mjs <URL>                    # URL 직접 지원
 *   node job-apply.mjs <회사명 또는 키워드>      # matched.json에서 검색 후 지원
 *   node job-apply.mjs                          # matched.json 전체 목록 출력
 *
 * Examples:
 *   node job-apply.mjs https://kurly.career.greetinghr.com/ko/o/168026
 *   node job-apply.mjs 컬리
 *   node job-apply.mjs "컬리 풀필먼트"
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execSync, spawn } from 'node:child_process';
import { discordSend } from '../lib/discord-notify.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const CONFIG_FILE = join(BOT_HOME, 'config', 'applicant.json');
const CRAWL_DIR = join(BOT_HOME, 'state', 'job-crawl');
const MATCHED_FILE = join(CRAWL_DIR, 'matched.json');
const APPS_FILE = join(CRAWL_DIR, 'applications.json');

mkdirSync(CRAWL_DIR, { recursive: true });

const arg = process.argv.slice(2).join(' ').trim();

// ── 이력서 데이터 로드 ────────────────────────────────────────────────────
function loadApplicant() {
  if (!existsSync(CONFIG_FILE)) {
    console.error(`❌ 지원자 정보 파일이 없습니다: ${CONFIG_FILE}`);
    console.error('   예시 파일을 생성하려면 README 참고.');
    process.exit(1);
  }
  return JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
}

// ── matched.json 로드 ─────────────────────────────────────────────────────
function loadMatched() {
  if (!existsSync(MATCHED_FILE)) return null;
  try {
    return JSON.parse(readFileSync(MATCHED_FILE, 'utf-8'));
  } catch { return null; }
}

// ── 회사명/키워드로 공고 검색 ──────────────────────────────────────────────
function searchJob(query) {
  const matched = loadMatched();
  if (!matched?.results) {
    console.error('❌ matched.json이 없습니다. 먼저 크롤링/매칭을 실행하세요.');
    process.exit(1);
  }

  const keywords = query.toLowerCase().split(/\s+/).filter(Boolean);
  const results = matched.results.filter(job => {
    const haystack = `${job.company} ${job.title}`.toLowerCase();
    return keywords.every(kw => haystack.includes(kw));
  });

  return results;
}

// ── 지원 이력 저장 ───────────────────────────────────────────────────────
function saveApplication(entry) {
  let apps = [];
  try { apps = JSON.parse(readFileSync(APPS_FILE, 'utf-8')); } catch {}
  apps.push({ ...entry, timestamp: new Date().toISOString() });
  writeFileSync(APPS_FILE, JSON.stringify(apps, null, 2));
}

// ── 중복 지원 확인 ───────────────────────────────────────────────────────
function isAlreadyApplied(url) {
  try {
    const apps = JSON.parse(readFileSync(APPS_FILE, 'utf-8'));
    return apps.some(a => a.url === url && !a.error);
  } catch { return false; }
}

// sendDiscord → SSoT: lib/discord-notify.mjs discordSend
const sendDiscord = (content) => discordSend(content, 'jarvis-system', { username: 'Jarvis Job Apply' });

// ── Claude in Chrome 프롬프트 생성 ───────────────────────────────────────
function buildChromePrompt(applicant, jobInfo) {
  const b = applicant.basic;
  const c = applicant.career;
  const e = applicant.education;
  const m = applicant.military;
  const d = applicant.diversity;
  const a = applicant.applyDefaults;

  return `현재 Chrome에 열려있는 채용 지원 페이지에서 "지원하기" 또는 "Apply" 버튼을 찾아 클릭한 후, 아래 정보로 지원 폼을 채워줘.

## 공고 정보
- 회사: ${jobInfo.company || '(알 수 없음)'}
- 포지션: ${jobInfo.title || '(알 수 없음)'}
- URL: ${jobInfo.url}

## 지원자 정보
- 이름: ${b.name}
- 이메일: ${b.email}
- 전화번호: ${b.phone} (하이픈 없이) / ${b.phoneWithDash} (하이픈 포함)
- 생년월일: ${b.birthDate}
- 주소: ${b.address}
- GitHub: ${b.github}
- 블로그/포트폴리오: ${b.blog}

## 경력
- 총 경력: ${c.totalYears}
- 현 직장: ${c.currentCompany}
- 현 직무: ${c.currentRole}
- 기술스택: ${c.skills}
- 요약: ${c.summary}

## 학력
- 학력: ${e.degreeLevel}
- 학교: ${e.university}
- 학과: ${e.major}
- 전공계열: ${e.majorCategory}
- 학위: ${e.degree}
- 입학: ${e.enrollDate}
- 졸업: ${e.graduateDate}
- 학점: ${e.gpa} / 기준학점: ${e.gpaScale}

## 병역
- 병역 상태: ${m.status} (필역)
- 군종: ${m.type} ${m.role}
- 복무 기간: ${m.startDate} ~ ${m.endDate}

## 장애/보훈
- 장애사항: ${d.disability}
- 보훈여부: ${d.veteran}

## 자격증
${applicant.certifications.map(c => `- ${c.name} (${c.year})`).join('\n')}

## 이력서 파일
- PDF: ${applicant.files.resumePdf}

## 폼 채움 규칙
1. 드롭다운/셀렉박스: 클릭해서 옵션을 선택. 단순 type 금지.
2. 검색형 입력 필드 (학교명, 전공, 회사명 등): 텍스트 입력 → 나타난 검색 결과 항목을 **반드시 클릭**해서 확정.
3. 라디오 버튼 (신입/경력, 병역 대상/비대상): 해당 항목을 클릭.
4. 날짜 필드 (YYYY.MM): 입학/졸업일을 정확한 포맷으로 입력.
5. 경력 선택: "경력" 라디오 버튼 클릭.
6. 이력서 PDF 파일 업로드: ${applicant.files.resumePdf} 경로의 파일 업로드.
7. 포트폴리오: "${a.portfolioType}" 방식 선택 → ${a.portfolioUrl} 입력.
8. 지원 경로 질문: "${a.applyChannel}" 선택.
9. 개인정보 동의: "필수" 표시된 체크박스만 모두 체크. 선택은 건너뛰어도 됨.
10. 자기소개/지원동기 textarea가 있으면 위 "요약" 내용 기반으로 3~5줄 작성.

## ⚠️ 절대 금지
- 제출/지원 완료/Submit 버튼 클릭 금지
- 폼 채움만 완료하고 멈춰야 함

## 완료 후
어떤 필드를 채웠는지 한국어로 요약해줘.`;
}

// ── Chrome 제어: URL 열기 ───────────────────────────────────────────────
function openInChrome(url) {
  try {
    execSync(`osascript -e '
tell application "Google Chrome"
    activate
    if (count of windows) = 0 then
        make new window
    end if
    set newTab to make new tab at end of tabs of window 1 with properties {URL:"${url}"}
end tell
'`, { stdio: 'pipe' });
    return true;
  } catch (e) {
    console.error(`[Chrome] URL 열기 실패: ${e.message}`);
    return false;
  }
}

// ── Phase 3: Claude in Chrome으로 폼 채움 ───────────────────────────────
async function applyViaChrome(applicant, jobInfo) {
  console.log(`\n🚀 지원 시작: ${jobInfo.company || ''} - ${jobInfo.title || ''}`);
  console.log(`   URL: ${jobInfo.url}\n`);

  // 중복 체크
  if (isAlreadyApplied(jobInfo.url)) {
    console.log('⚠️  이미 지원한 공고입니다. 중단.');
    return;
  }

  // 1. Chrome에서 공고 페이지 열기
  console.log('🖥️  Chrome에서 공고 페이지 열기...');
  if (!openInChrome(jobInfo.url)) return;

  console.log('⏳ 페이지 로딩 대기 (5초)...');
  await new Promise(r => setTimeout(r, 5000));

  // 2. claude --chrome으로 폼 채움
  console.log('🤖 Claude in Chrome으로 폼 채움 시작...');
  console.log('   (Claude가 화면을 보면서 직접 클릭/입력합니다. 3-5분 소요)\n');

  const prompt = buildChromePrompt(applicant, jobInfo);

  const result = await new Promise((resolve) => {
    const proc = spawn('claude', ['--chrome', '-p', '--dangerously-skip-permissions'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', d => {
      const chunk = d.toString();
      stdout += chunk;
      process.stdout.write(chunk);
    });
    proc.stderr.on('data', d => { stderr += d.toString(); });

    proc.on('close', code => resolve({ code, stdout, stderr }));
    proc.on('error', err => resolve({ code: -1, stdout, stderr: err.message }));

    proc.stdin.write(prompt);
    proc.stdin.end();
  });

  if (result.code !== 0) {
    console.error(`\n❌ Claude in Chrome 실패 (exit ${result.code})`);
    if (result.stderr) console.error(result.stderr);
    console.log('\n💡 확인사항:');
    console.log('   1. Chrome에 Claude 확장이 설치되어 있나요?');
    console.log('   2. 확장에서 Claude 계정 로그인 되어 있나요?');
    console.log('   3. Claude 사용량 한도를 초과하지 않았나요?');

    saveApplication({ ...jobInfo, method: 'claude-chrome', error: result.stderr || `exit ${result.code}` });
    return;
  }

  await sendDiscord(
    `📝 **채용 폼 자동 채움 완료 (Claude in Chrome)**\n` +
    `회사: ${jobInfo.company || '?'}\n` +
    `포지션: ${jobInfo.title || '?'}\n` +
    `URL: ${jobInfo.url}\n\n` +
    `✅ Chrome에서 내용 확인 후 직접 제출 버튼을 눌러주세요.`,
  );

  saveApplication({ ...jobInfo, method: 'claude-chrome', success: true, resultSnippet: result.stdout.slice(0, 500) });

  console.log('\n✅ 완료. Chrome에서 폼 내용 확인 후 직접 제출해주세요.');
}

// ── 목록 출력 ───────────────────────────────────────────────────────────
function printList(results, title = '📋 매칭된 공고') {
  console.log(`\n${title} (${results.length}건)\n`);
  results.slice(0, 30).forEach((job, i) => {
    const icon = job.score >= 80 ? '🟢' : job.score >= 60 ? '🟡' : '⚪';
    const applied = isAlreadyApplied(job.url) ? ' [지원완료]' : '';
    console.log(`${i + 1}. ${icon} ${job.score}점 [${job.company}] ${job.title}${applied}`);
    console.log(`   ${job.url}`);
  });
}

// ── 메인 ─────────────────────────────────────────────────────────────────
async function main() {
  const applicant = loadApplicant();
  console.log(`🚀 Jarvis Job Apply (지원자: ${applicant.basic.name})`);

  // 인자 없음 → 매칭 목록 전체 출력
  if (!arg) {
    const matched = loadMatched();
    if (!matched?.results) {
      console.error('❌ matched.json이 없습니다. 먼저 크롤링/매칭을 실행하세요.');
      console.error('   cd ~/jarvis/infra && node scripts/job-crawl.mjs && node scripts/job-match.mjs --detail');
      process.exit(1);
    }
    printList(matched.results.filter(j => j.score >= 60), '📋 매칭 결과 (60점 이상)');
    console.log('\n💡 사용법:');
    console.log('   node job-apply.mjs <URL>               # URL 직접 지원');
    console.log('   node job-apply.mjs 컬리                 # 회사명으로 검색 후 지원');
    console.log('   node job-apply.mjs "컬리 풀필먼트"       # 여러 키워드 AND 검색');
    return;
  }

  // URL 직접 지원
  if (arg.startsWith('http://') || arg.startsWith('https://')) {
    const matched = loadMatched();
    const job = matched?.results?.find(j => j.url === arg) || { url: arg };
    await applyViaChrome(applicant, job);
    return;
  }

  // 회사명/키워드 검색
  const results = searchJob(arg);

  if (results.length === 0) {
    console.error(`❌ "${arg}" 매칭 결과 없음`);
    process.exit(1);
  }

  if (results.length === 1) {
    await applyViaChrome(applicant, results[0]);
    return;
  }

  // 여러 건 → 목록 출력 후 첫 번째 자동 지원 X, 사용자 확인 필요
  printList(results, `🔍 "${arg}" 검색 결과`);
  console.log('\n⚠️  여러 건 매칭. 더 구체적인 키워드를 사용하거나 URL을 직접 지정하세요.');
  console.log('   예: node job-apply.mjs "컬리 풀필먼트"');
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
