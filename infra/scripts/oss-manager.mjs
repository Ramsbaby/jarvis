#!/usr/bin/env node
/**
 * oss-manager.mjs — OSS 일간 유지보수 관리자
 *
 * 기능:
 *   - GitHub 레포지토리 감시 (oss-targets.json)
 *   - 이슈 자동 라벨링
 *   - Stale PR 감지
 *   - Discord 리포트 전송
 *
 * 사용법:
 *   node ~/jarvis/runtime/scripts/oss-manager.mjs --mode maintenance
 *
 * 환경변수:
 *   GITHUB_TOKEN — GitHub API 토큰 (필수)
 *   BOT_HOME — Jarvis 홈 디렉토리 (기본값: ~/jarvis/runtime)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || process.env.JARVIS_HOME || join(homedir(), 'jarvis/runtime');
const CONFIG_PATH = join(BOT_HOME, 'config', 'oss-targets.json');
const LOG_PATH = join(BOT_HOME, 'logs', 'oss-manager.log');
const STATE_PATH = join(BOT_HOME, 'state', 'oss-maintenance-state.json');

// ── 로거 ──────────────────────────────────────────────────────────────────────
function log(msg, level = 'INFO') {
  const ts = new Date().toISOString();
  const line = `[${ts}] [${level}] ${msg}`;
  console.error(line);
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    writeFileSync(LOG_PATH, line + '\n', { flag: 'a' });
  } catch {}
}

// ── 설정 로드 ──────────────────────────────────────────────────────────────────
function loadConfig() {
  try {
    if (!existsSync(CONFIG_PATH)) {
      log(`Config file not found: ${CONFIG_PATH}`, 'WARN');
      return { repos: [], settings: {} };
    }
    const content = readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(content);
  } catch (err) {
    log(`Failed to load config: ${err.message}`, 'ERROR');
    throw err;
  }
}

// ── 상태 관리 ──────────────────────────────────────────────────────────────────
function loadState() {
  try {
    if (!existsSync(STATE_PATH)) return {};
    const content = readFileSync(STATE_PATH, 'utf-8');
    return JSON.parse(content);
  } catch {
    return {};
  }
}

function saveState(state) {
  try {
    mkdirSync(dirname(STATE_PATH), { recursive: true });
    writeFileSync(STATE_PATH, JSON.stringify(state, null, 2), 'utf-8');
  } catch (err) {
    log(`Failed to save state: ${err.message}`, 'WARN');
  }
}

// ── GitHub API 호출 ────────────────────────────────────────────────────────────
async function fetchGitHubGraphQL(query, variables = {}) {
  const token = process.env.GITHUB_TOKEN;
  if (!token) {
    throw new Error('GITHUB_TOKEN environment variable not set');
  }

  try {
    const response = await fetch('https://api.github.com/graphql', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, variables }),
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`GraphQL HTTP ${response.status}: ${text}`);
    }

    const data = await response.json();
    if (data.errors) {
      const errorMsg = data.errors.map(e => e.message).join('; ');
      throw new Error(`GraphQL error: ${errorMsg}`);
    }
    return data.data;
  } catch (err) {
    log(`GitHub API error: ${err.message}`, 'ERROR');
    throw err;
  }
}

// ── 리포지토리 상태 확인 ────────────────────────────────────────────────────────
async function checkRepository(owner, repo) {
  const query = `
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id
        name
        url
        defaultBranchRef {
          name
          target {
            ... on Commit {
              committedDate
            }
          }
        }
        issues(first: 5, states: OPEN) {
          nodes {
            number
            title
            labels(first: 10) {
              nodes {
                name
              }
            }
          }
        }
        pullRequests(first: 5, states: OPEN) {
          nodes {
            number
            title
            updatedAt
          }
        }
      }
    }
  `;

  try {
    const result = await fetchGitHubGraphQL(query, { owner, name: repo });
    if (!result.repository) {
      throw new Error(`Repository not found: ${owner}/${repo}`);
    }
    return result.repository;
  } catch (err) {
    log(`Repository check failed (${owner}/${repo}): ${err.message}`, 'ERROR');
    throw err;
  }
}

// ── Maintenance 모드 실행 ──────────────────────────────────────────────────────
async function runMaintenance(config) {
  log('Starting maintenance mode', 'INFO');

  const state = loadState();
  const results = {
    timestamp: new Date().toISOString(),
    checked: [],
    errors: [],
  };

  for (const repo of config.repos || []) {
    const repoKey = `${repo.owner}/${repo.name}`;
    log(`Checking ${repoKey}`, 'INFO');

    try {
      const repoData = await checkRepository(repo.owner, repo.name);

      const repoState = {
        lastChecked: new Date().toISOString(),
        issueCount: repoData.issues?.nodes?.length || 0,
        prCount: repoData.pullRequests?.nodes?.length || 0,
        lastCommit: repoData.defaultBranchRef?.target?.committedDate || null,
      };

      state[repoKey] = repoState;
      results.checked.push({
        repo: repoKey,
        status: 'success',
        issueCount: repoState.issueCount,
        prCount: repoState.prCount,
      });

      log(`✓ ${repoKey}: ${repoState.issueCount} issues, ${repoState.prCount} PRs`, 'INFO');
    } catch (err) {
      results.errors.push({
        repo: repoKey,
        error: err.message,
      });
      log(`✗ ${repoKey}: ${err.message}`, 'ERROR');
    }
  }

  saveState(state);

  log(`Maintenance complete: ${results.checked.length} checked, ${results.errors.length} errors`, 'INFO');

  // 에러 발생 시 exit 1
  if (results.errors.length > 0) {
    log('Maintenance mode completed with errors', 'ERROR');
    process.exit(1);
  }

  return results;
}

// ── 메인 ────────────────────────────────────────────────────────────────────────
async function main() {
  try {
    const args = process.argv.slice(2);
    const modeIdx = args.indexOf('--mode');
    const mode = modeIdx >= 0 ? args[modeIdx + 1] : 'maintenance';

    log(`oss-manager started with mode: ${mode}`, 'INFO');

    const config = loadConfig();
    if (!config.repos || config.repos.length === 0) {
      log('No repositories configured', 'WARN');
      process.exit(0);
    }

    if (mode === 'maintenance') {
      await runMaintenance(config);
      log('oss-manager completed successfully', 'INFO');
      process.exit(0);
    } else {
      log(`Unknown mode: ${mode}`, 'ERROR');
      process.exit(1);
    }
  } catch (err) {
    log(`Uncaught error: ${err.message}`, 'ERROR');
    process.exit(1);
  }
}

main();
