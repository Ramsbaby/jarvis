#!/usr/bin/env node
// team-desk.mjs — 팀 데스크 데이터 로더
// team.yml + lounge.json + board-minutes 통합

import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';

const JARVIS_HOME = process.env.JARVIS_HOME || process.env.BOT_HOME || path.join(process.env.HOME, '.jarvis');
const TEAMS_DIR = path.join(JARVIS_HOME, 'teams');
const LOUNGE_FILE = path.join(JARVIS_HOME, 'state', 'lounge.json');
const BOARD_MINUTES_DIR = path.join(JARVIS_HOME, 'state', 'board-minutes');

// 간단한 YAML 파서 (team.yml은 단순 구조라 별도 라이브러리 불필요)
function parseSimpleYaml(text) {
  const result = {};
  let currentKey = null;
  let listItems = [];

  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    // 리스트 아이템
    if (trimmed.startsWith('- ')) {
      listItems.push(trimmed.slice(2).trim());
      continue;
    }

    // 이전 리스트 저장
    if (currentKey && listItems.length > 0) {
      result[currentKey] = listItems;
      listItems = [];
    }

    const match = trimmed.match(/^(\w+):\s*(.*)$/);
    if (match) {
      const [, key, val] = match;
      if (val === '' || val === undefined) {
        currentKey = key;
      } else {
        result[key] = val.replace(/^["']|["']$/g, '');
        currentKey = null;
      }
    }
  }
  if (currentKey && listItems.length > 0) {
    result[currentKey] = listItems;
  }
  return result;
}

// 모든 팀 로드
export function loadTeams() {
  const teams = [];
  if (!fs.existsSync(TEAMS_DIR)) return teams;

  for (const dir of fs.readdirSync(TEAMS_DIR)) {
    const teamYml = path.join(TEAMS_DIR, dir, 'team.yml');
    const systemMd = path.join(TEAMS_DIR, dir, 'system.md');
    if (!fs.existsSync(teamYml)) continue;

    try {
      const config = parseSimpleYaml(fs.readFileSync(teamYml, 'utf8'));
      teams.push({
        id: dir,
        name: config.name || dir,
        taskId: config.taskId || dir,
        discord: config.discord || null,
        maxTurns: parseInt(config.maxTurns) || 3,
        model: config.model || 'default',
        hasSystemPrompt: fs.existsSync(systemMd),
        systemPromptPath: systemMd,
      });
    } catch { /* skip broken team */ }
  }
  return teams;
}

// 라운지 활동 상태 로드
export function loadActivities() {
  try {
    const data = JSON.parse(fs.readFileSync(LOUNGE_FILE, 'utf8'));
    const now = Date.now();
    // 10분 이내 활동만
    return (data.activities || []).filter(a => (now - a.ts) < 600_000);
  } catch {
    return [];
  }
}

// 팀 상태 결정: running / idle / off
export function getTeamStatus(team, activities) {
  const activity = activities.find(a =>
    a.taskId === team.taskId || a.taskId?.includes(team.id)
  );
  if (activity) return { status: 'running', activity: activity.activity || 'working...' };
  return { status: 'idle', activity: '' };
}

// 최신 보드 회의록에서 팀 관련 내용 추출
export function getTeamBoardSummary(teamName) {
  try {
    if (!fs.existsSync(BOARD_MINUTES_DIR)) return null;
    const files = fs.readdirSync(BOARD_MINUTES_DIR)
      .filter(f => f.endsWith('.md'))
      .sort()
      .reverse();
    if (files.length === 0) return null;

    const latest = fs.readFileSync(path.join(BOARD_MINUTES_DIR, files[0]), 'utf8');
    const lines = latest.split('\n');

    // 팀명 주변 텍스트 추출 (앞뒤 3줄)
    const matches = [];
    const searchName = teamName.toLowerCase();
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().includes(searchName)) {
        const start = Math.max(0, i - 1);
        const end = Math.min(lines.length, i + 3);
        matches.push(lines.slice(start, end).join('\n'));
      }
    }
    return {
      date: files[0].replace('.md', ''),
      excerpts: matches.slice(0, 3),
    };
  } catch {
    return null;
  }
}

// 전체 상태 스냅샷
export function getOfficeSnapshot() {
  const teams = loadTeams();
  const activities = loadActivities();

  return teams.map(team => ({
    ...team,
    ...getTeamStatus(team, activities),
  }));
}
