#!/usr/bin/env node
/**
 * oss-manager.mjs — GitHub OSS 자동 관리 에이전트
 *
 * 모드:
 *   --mode recon        경쟁자 분석 + 기능 갭 리포트 (주간)
 *   --mode maintenance  이슈/PR 트리아지 + 자동 라벨 (일간)
 *   --mode docs         README/문서 갱신 제안 → GitHub Issue 등록 (주간)
 *   --mode promo        릴리즈 노트 + 홍보 초안 생성 (금요일)
 *   (기본값) full       전체 실행
 *
 * 크론:
 *   oss-recon       매주 월 10:30 — scripts/oss-recon.sh
 *   oss-maintenance 매일 09:15  — scripts/oss-maintenance.sh
 *   oss-promo       매주 금 17:00 — scripts/oss-promo.sh
 */

import { spawnSync } from 'node:child_process';
import {
  readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync
} from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { discordSend as _discordNotify } from '../lib/discord-notify.mjs';

// ── 경로 상수 ──────────────────────────────────────────────────────────────────
const HOME       = homedir();
const BOT_HOME   = process.env.JARVIS_HOME ?? join(HOME, '.jarvis');
const LOG_DIR    = join(BOT_HOME, 'logs');
const CONFIG     = JSON.parse(
  readFileSync(join(BOT_HOME, 'config', 'oss-targets.json'), 'utf8')
);
const MONITORING = JSON.parse(
  readFileSync(join(BOT_HOME, 'config', 'monitoring.json'), 'utf8')
);
const LOG_FILE   = join(LOG_DIR, 'oss-manager.log');
const REPORT_DIR = join(BOT_HOME, CONFIG.settings.reportDir ?? 'rag/oss-reports');
const TODAY      = new Date().toISOString().slice(0, 10);

// ── 모드 파싱 ──────────────────────────────────────────────────────────────────
const modeIdx = process.argv.indexOf('--mode');
const MODE = (modeIdx >= 0 ? process.argv[modeIdx + 1] : null)
  ?? process.argv.find(a => a.startsWith('--mode='))?.split('=')[1]
  ?? 'full';

// ── 유틸 ───────────────────────────────────────────────────────────────────────
function log(level, msg) {
  const line = `[${new Date().toISOString()}] [oss-manager] [${level.toUpperCase()}] ${msg}`;
  process.stderr.write(line + '\n');
  try { appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

function gh(...args) {
  const r = spawnSync('gh', args, { encoding: 'utf8', timeout: 30_000 });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`gh ${args[0]} failed: ${(r.stderr || '').trim()}`);
  return r.stdout.trim();
}

function ghJSON(...args) {
  return JSON.parse(gh(...args));
}

function askClaude(prompt, { timeout = 90_000 } = {}) {
  const r = spawnSync('claude', ['-p', prompt], {
    encoding: 'utf8',
    timeout,
    env: { ...process.env }
  });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`claude -p 실패 (exit ${r.status}): ${(r.stderr || '').trim().slice(0, 200)}`);
  return (r.stdout ?? '').trim();
}

/** 스크립트 시작 전 gh 인증 확인 — 미인증 시 Discord 알림 후 즉시 종료 */
function preflight() {
  const r = spawnSync('gh', ['auth', 'status'], { encoding: 'utf8', timeout: 10_000 });
  if (r.status !== 0) {
    const msg = '🚨 **oss-manager** gh CLI 미인증 — 실행 중단. `gh auth login` 필요.';
    discordSend(msg, 'jarvis-system');
    log('error', 'gh auth 실패 — 중단');
    process.exit(1);
  }
}

// SSoT: lib/discord-notify.mjs (_discordNotify). 로컬 wrapper 이름 discordSend 유지.
// caller 사이트들 await 없이 호출 → fire-and-forget (정상).
// channelKey 기본값은 CONFIG 참조가 필요해 래퍼 유지.
function discordSend(content, channelKey) {
  _discordNotify(content, channelKey ?? CONFIG.settings?.discordChannel ?? 'jarvis-blog').catch(
    e => log('warn', `Discord 전송 실패: ${e.message}`),
  );
}

function ensureReportDir() {
  mkdirSync(REPORT_DIR, { recursive: true });
}

// ── 모드 1: RECON — 경쟁자 분석 ───────────────────────────────────────────────
async function runRecon() {
  log('info', '=== RECON 모드 시작 ===');
  ensureReportDir();
  const results = [];

  for (const repo of CONFIG.repos) {
    log('info', `[recon] ${repo.owner}/${repo.name}`);

    // 내 레포 현황
    let myRepo;
    try {
      myRepo = ghJSON('repo', 'view', `${repo.owner}/${repo.name}`,
        '--json', 'name,description,stargazerCount,forkCount,openIssueCount,updatedAt');
    } catch (e) {
      log('error', `레포 조회 실패: ${e.message}`); continue;
    }

    // 경쟁자 레포 스캔
    const competitorData = [];
    for (const comp of (repo.competitors ?? [])) {
      try {
        const parts = comp.split('/');
        if (parts.length !== 2) continue;
        const c = ghJSON('repo', 'view', comp,
          '--json', 'name,description,stargazerCount,forkCount,updatedAt');
        competitorData.push({ repo: comp, ...c });
      } catch (e) {
        log('warn', `경쟁자 조회 실패 ${comp}: ${e.message}`);
      }
    }

    // GitHub 검색 (유사 프로젝트)
    const searchResults = [];
    for (const term of (repo.searchTerms ?? []).slice(0, 2)) {
      try {
        const raw = gh('search', 'repos', term,
          '--limit', '5',
          '--json', 'name,fullName,description,stargazerCount,updatedAt');
        const items = JSON.parse(raw);
        // 내 레포 제외
        items
          .filter(i => i.fullName !== `${repo.owner}/${repo.name}`)
          .slice(0, 3)
          .forEach(i => searchResults.push(i));
      } catch (e) {
        log('warn', `검색 실패 "${term}": ${e.message}`);
      }
    }

    // 현재 README 일부
    let currentReadme = '';
    try {
      const readmeInfo = ghJSON('api', `repos/${repo.owner}/${repo.name}/readme`);
      currentReadme = Buffer.from(readmeInfo.content ?? '', 'base64')
        .toString('utf8').slice(0, 2000);
    } catch (e) {
      log('warn', `README 조회 실패: ${e.message}`);
    }

    const prompt = `GitHub OSS 프로젝트 경쟁 분석 리포트를 작성하라.

## 내 프로젝트
- 이름: ${repo.owner}/${repo.name}
- 설명: ${myRepo.description ?? repo.description}
- Stars: ${myRepo.stargazerCount}, Forks: ${myRepo.forkCount}, Issues: ${myRepo.openIssueCount}
- 카테고리: ${repo.category}

## 직접 경쟁자 (${competitorData.length}개)
${JSON.stringify(competitorData, null, 2)}

## 유사 프로젝트 (GitHub 검색)
${JSON.stringify(searchResults.slice(0, 5), null, 2)}

## 현재 README (일부)
${currentReadme}

## 요청 (한국어, 간결하게)
1. **기능 갭** — 경쟁사 대비 없는 기능 Top 3
2. **차별점** — 우리만의 강점 (README에 더 강조할 것)
3. **README 개선 포인트** — 추가/수정할 섹션 구체적으로
4. **단기 성장 액션** — Stars 늘리기 위한 액션 2개 (실행 가능한 것만)`;

    let analysis = '(분석 실패)';
    try {
      analysis = askClaude(prompt, { timeout: 90_000 });
    } catch (e) {
      log('error', `LLM 분석 실패 ${repo.name}: ${e.message}`);
    }

    results.push({ repo: `${repo.owner}/${repo.name}`, stars: myRepo.stargazerCount, analysis });
    log('info', `[recon] 완료: ${repo.name}`);
  }

  // 리포트 파일 저장
  const reportPath = join(REPORT_DIR, `recon-${TODAY}.md`);
  const reportMd = [
    `# OSS Recon Report — ${TODAY}`, '',
    ...results.map(r => [`## ${r.repo} (★${r.stars})`, '', r.analysis, ''].join('\n'))
  ].join('\n');
  writeFileSync(reportPath, reportMd);
  log('info', `리포트 저장: ${reportPath}`);

  // Discord 전송
  const summary = results
    .map(r => `**${r.repo}** ★${r.stars}\n${r.analysis.slice(0, 350)}`)
    .join('\n\n---\n\n');
  discordSend(`🔍 **OSS Recon — ${TODAY}**\n\n${summary.slice(0, 1900)}`, 'jarvis-market');

  return results;
}

// ── 모드 2: MAINTENANCE — 이슈/PR 트리아지 ────────────────────────────────────
async function runMaintenance() {
  log('info', '=== MAINTENANCE 모드 시작 ===');
  const summary = [];

  for (const repo of CONFIG.repos) {
    log('info', `[maintenance] ${repo.owner}/${repo.name}`);

    // 열린 이슈
    let issues = [];
    try {
      issues = ghJSON('issue', 'list',
        '--repo', `${repo.owner}/${repo.name}`,
        '--state', 'open',
        '--limit', String(CONFIG.settings.maxIssuesPerRepo ?? 20),
        '--json', 'number,title,body,labels,createdAt,author');
    } catch (e) {
      log('warn', `이슈 조회 실패: ${e.message}`); continue;
    }

    const unlabeledIssues = issues.filter(i => (i.labels ?? []).length === 0);
    let labeledCount = 0;
    const labeledDetail = []; // 감사 로그: [{number, label}]

    for (const issue of unlabeledIssues.slice(0, 5)) {
      const prompt = `다음 GitHub 이슈를 분류하라.

이슈 제목: ${issue.title}
이슈 내용: ${(issue.body ?? '').slice(0, 500)}

다음 라벨 중 가장 적합한 것을 정확히 하나만 출력하라 (다른 텍스트 없이):
bug / enhancement / question / documentation / help wanted / invalid / wontfix`;

      try {
        const raw = askClaude(prompt, { timeout: 30_000 });
        const label = raw.trim().toLowerCase().split(/[\s\n]/)[0];
        const validLabels = ['bug', 'enhancement', 'question', 'documentation',
          'help wanted', 'invalid', 'wontfix'];
        if (validLabels.includes(label)) {
          try {
            gh('issue', 'edit', String(issue.number),
              '--repo', `${repo.owner}/${repo.name}`,
              '--add-label', label);
            labeledCount++;
            labeledDetail.push({ number: issue.number, label });
            log('info', `이슈 #${issue.number} → 라벨: ${label}`);
          } catch (e) {
            // 라벨 미존재 시 생성 후 재시도
            try {
              gh('label', 'create', label,
                '--repo', `${repo.owner}/${repo.name}`,
                '--color', 'ededed', '--force');
              gh('issue', 'edit', String(issue.number),
                '--repo', `${repo.owner}/${repo.name}`,
                '--add-label', label);
              labeledCount++;
              labeledDetail.push({ number: issue.number, label });
              log('info', `이슈 #${issue.number} → 라벨: ${label} (신규 라벨 생성)`);
            } catch (e2) {
              log('warn', `라벨 생성 실패 #${issue.number}: ${e2.message}`);
            }
          }
        }
      } catch (e) {
        log('warn', `이슈 분류 실패 #${issue.number}: ${e.message}`);
      }
    }

    // Stale PR 감지 (7일 이상 미활동)
    let stalePRs = [];
    try {
      const prs = ghJSON('pr', 'list',
        '--repo', `${repo.owner}/${repo.name}`,
        '--state', 'open',
        '--limit', '10',
        '--json', 'number,title,updatedAt,author');
      const weekAgo = Date.now() - 7 * 86_400_000;
      stalePRs = prs.filter(p => new Date(p.updatedAt).getTime() < weekAgo);
    } catch (e) {
      log('warn', `PR 조회 실패: ${e.message}`);
    }

    summary.push({
      repo: `${repo.owner}/${repo.name}`,
      openIssues: issues.length,
      labeled: labeledCount,
      labeledDetail,
      stalePRs: stalePRs.length,
      staleList: stalePRs.map(p => `#${p.number} ${p.title}`)
    });
  }

  // Discord 리포트 (채널: tasks.json discordChannel 설정 따름 → jarvis-blog)
  if (summary.length > 0) {
    const lines = summary.map(s => {
      let line = `**${s.repo}**: 이슈 ${s.openIssues}개`;
      if (s.labeled > 0) {
        const detail = s.labeledDetail.map(d => `#${d.number}→${d.label}`).join(', ');
        line += ` (자동 라벨: ${detail})`;
      }
      if (s.stalePRs > 0) line += ` | ⚠️ Stale PR ${s.stalePRs}개`;
      return line;
    }).join('\n');
    discordSend(`🔧 **OSS 유지보수 — ${TODAY}**\n\n${lines}`);
  }

  return summary;
}

// ── 모드 3: DOCS — README 갱신 제안 ──────────────────────────────────────────
async function runDocs() {
  log('info', '=== DOCS 모드 시작 ===');

  for (const repo of CONFIG.repos) {
    log('info', `[docs] ${repo.owner}/${repo.name}`);

    // 최근 N일 커밋
    const since = new Date(Date.now() - (CONFIG.settings.staleCommitDays ?? 7) * 86_400_000)
      .toISOString();
    let commits = [];
    try {
      commits = ghJSON('api',
        `repos/${repo.owner}/${repo.name}/commits?since=${since}&per_page=30`
      ).map(c => ({
        sha: c.sha.slice(0, 7),
        message: c.commit.message.split('\n')[0],
        date: c.commit.author?.date ?? ''
      }));
    } catch (e) {
      log('warn', `커밋 조회 실패: ${e.message}`); continue;
    }

    if (commits.length === 0) {
      log('info', `${repo.name}: 최근 ${CONFIG.settings.staleCommitDays}일 커밋 없음 — 건너뜀`);
      continue;
    }

    // 현재 README
    let currentReadme = '';
    try {
      const info = ghJSON('api', `repos/${repo.owner}/${repo.name}/readme`);
      currentReadme = Buffer.from(info.content ?? '', 'base64').toString('utf8');
    } catch (e) {
      log('warn', `README 조회 실패: ${e.message}`); continue;
    }

    const prompt = `다음 GitHub 레포의 README 개선이 필요한지 분석하고, 개선안을 제시하라.

## 레포: ${repo.owner}/${repo.name}
## 설명: ${repo.description}

## 최근 커밋 (${CONFIG.settings.staleCommitDays}일)
${commits.map(c => `- ${c.sha} ${c.message}`).join('\n')}

## 현재 README
${currentReadme.slice(0, 3500)}

## 지시사항
1. README에 반영되지 않은 최근 변경사항이 있으면 "NEEDS_UPDATE"로 시작하고 개선안을 제시하라
2. 업데이트 불필요 시 "NO_CHANGE"만 출력하라
3. "NEEDS_UPDATE"인 경우, 추가/수정해야 할 구체적인 내용만 작성하라 (전체 README 출력 금지)`;

    let suggestion = '';
    try {
      suggestion = askClaude(prompt, { timeout: 120_000 });
    } catch (e) {
      log('error', `DOCS LLM 실패: ${e.message}`); continue;
    }

    if (suggestion.trim().startsWith('NO_CHANGE')) {
      log('info', `${repo.name}: README 업데이트 불필요`); continue;
    }

    // GitHub Issue로 등록 (직접 수정 대신 — 안전한 방식)
    try {
      const issueTitle = `docs: README 자동 갱신 제안 (${TODAY})`;

      // 중복 이슈 방지: 이번 주 이내에 같은 제목 이슈가 열려있으면 코멘트 추가
      let existingIssueNum = null;
      try {
        const openDocs = ghJSON('issue', 'list',
          '--repo', `${repo.owner}/${repo.name}`,
          '--state', 'open',
          '--label', 'documentation',
          '--limit', '10',
          '--json', 'number,title,createdAt');
        const existing = openDocs.find(i =>
          i.title.startsWith('docs: README 자동 갱신 제안'));
        if (existing) existingIssueNum = existing.number;
      } catch {}

      const issueBody = `> 자동 생성 — oss-manager.mjs docs 모드 (${TODAY})\n\n## 최근 커밋\n${
        commits.slice(0, 8).map(c => `- \`${c.sha}\` ${c.message}`).join('\n')
      }\n\n## 개선 제안\n${suggestion}`;

      if (existingIssueNum) {
        // 기존 이슈에 코멘트 추가
        gh('issue', 'comment', String(existingIssueNum),
          '--repo', `${repo.owner}/${repo.name}`,
          '--body', issueBody);
        log('info', `${repo.name}: 기존 이슈 #${existingIssueNum}에 코멘트 추가`);
        discordSend(`📝 **README 갱신 업데이트** — ${repo.owner}/${repo.name} #${existingIssueNum}\n${suggestion.slice(0, 350)}`);
      } else {
        // documentation 라벨 사전 보장
        try {
          gh('label', 'create', 'documentation',
            '--repo', `${repo.owner}/${repo.name}`,
            '--color', '0075ca', '--force');
        } catch {}
        gh('issue', 'create',
          '--repo', `${repo.owner}/${repo.name}`,
          '--title', issueTitle,
          '--body', issueBody,
          '--label', 'documentation');
        log('info', `${repo.name}: docs 이슈 생성 완료`);
        discordSend(`📝 **README 갱신 이슈 생성** — ${repo.owner}/${repo.name}\n${suggestion.slice(0, 350)}`);
      }
    } catch (e) {
      log('error', `이슈 처리 실패 ${repo.name}: ${e.message}`);
    }
  }
}

// ── 모드 4: PROMO — 홍보 초안 생성 ──────────────────────────────────────────
async function runPromo() {
  log('info', '=== PROMO 모드 시작 ===');
  ensureReportDir();

  for (const repo of CONFIG.repos) {
    log('info', `[promo] ${repo.owner}/${repo.name}`);

    const since = new Date(Date.now() - 7 * 86_400_000).toISOString();
    let commits = [];
    try {
      commits = ghJSON('api',
        `repos/${repo.owner}/${repo.name}/commits?since=${since}&per_page=30`
      ).map(c => c.commit.message.split('\n')[0]);
    } catch (e) {
      log('warn', `커밋 조회 실패: ${e.message}`); continue;
    }

    // 주요 변경 없으면 홍보 스킵 — Conventional Commits 표준만 (add/update/improve 제외: 오탐 과다)
    const meaningful = commits.filter(m =>
      /^(feat|fix|refactor|perf)(\(.+?\))?[!:]?\s/i.test(m));
    if (meaningful.length < 2) {
      log('info', `${repo.name}: 주요 변경 부족 (${meaningful.length}건) — 홍보 스킵`);
      continue;
    }

    let myRepo = { stargazerCount: '?' };
    try {
      myRepo = ghJSON('repo', 'view', `${repo.owner}/${repo.name}`,
        '--json', 'stargazerCount,forkCount');
    } catch {}

    const prompt = `다음 GitHub 프로젝트의 주간 홍보 콘텐츠를 작성하라.

## 프로젝트
- 이름: ${repo.owner}/${repo.name}
- 설명: ${repo.description}
- 카테고리: ${repo.category}
- Stars: ${myRepo.stargazerCount}

## 이번 주 주요 커밋
${meaningful.slice(0, 10).map((m, i) => `${i + 1}. ${m}`).join('\n')}

## 요청 (각 섹션 구분선 ---로 분리)
### 1. GitHub Release Notes (마크다운, 한국어, 3-5줄)
### 2. Twitter/X 홍보 문구 (영어, 280자 이내, #hashtag 포함)
### 3. Reddit r/SideProject 제목 (영어, 클릭 유도, 60자 이내)

형식적 서문 없이 바로 콘텐츠만 출력.`;

    let promo = '';
    try {
      promo = askClaude(prompt, { timeout: 90_000 });
    } catch (e) {
      log('error', `PROMO LLM 실패: ${e.message}`); continue;
    }

    const promoFile = join(REPORT_DIR, `promo-${repo.name}-${TODAY}.md`);
    writeFileSync(promoFile, `# ${repo.name} 홍보 초안 — ${TODAY}\n\n${promo}`);
    log('info', `홍보 초안 저장: ${promoFile}`);

    discordSend(
      `📣 **${repo.name} 주간 홍보 초안 — ${TODAY}**\n\n${promo.slice(0, 1800)}`
    );
  }
}

// ── 메인 ──────────────────────────────────────────────────────────────────────
log('info', `=== oss-manager 시작 (mode: ${MODE}, date: ${TODAY}) ===`);
preflight(); // gh 인증 확인 — 실패 시 Discord 알림 후 즉시 종료

try {
  if (MODE === 'recon'       || MODE === 'full') await runRecon();
  if (MODE === 'maintenance' || MODE === 'full') await runMaintenance();
  if (MODE === 'docs'        || MODE === 'full') await runDocs();
  if (MODE === 'promo'       || MODE === 'full') await runPromo();
  log('info', '=== oss-manager 완료 ===');
} catch (e) {
  log('error', `치명적 오류: ${e.stack ?? e.message}`);
  process.exit(1);
}
