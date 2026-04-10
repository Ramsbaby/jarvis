import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const LOUNGE_FILE = join(BOT_HOME, 'state', 'lounge.json');
const PRUNE_THRESHOLD = 600000; // 10 minutes in milliseconds

/**
 * Load lounge state from file, or return empty state if file doesn't exist
 */
function loadState() {
  try {
    const content = readFileSync(LOUNGE_FILE, 'utf-8');
    return JSON.parse(content);
  } catch {
    return { activities: [] };
  }
}

/**
 * Save lounge state to file
 */
function saveState(state) {
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  writeFileSync(LOUNGE_FILE, JSON.stringify(state, null, 2), 'utf-8');
}

/**
 * Prune entries older than PRUNE_THRESHOLD
 */
function pruneOldEntries(activities) {
  const now = Date.now();
  return activities.filter((entry) => now - entry.ts < PRUNE_THRESHOLD);
}

/**
 * Announce a task activity
 */
export function announce(taskId, activity) {
  const state = loadState();
  state.activities = pruneOldEntries(state.activities);

  // Remove existing entry for this taskId if present
  state.activities = state.activities.filter((entry) => entry.taskId !== taskId);

  // Add new entry
  state.activities.push({
    taskId,
    activity,
    ts: Date.now(),
  });

  saveState(state);
}

/**
 * Mark task as completed (remove entry)
 */
export function complete(taskId) {
  const state = loadState();
  state.activities = state.activities.filter((entry) => entry.taskId !== taskId);
  saveState(state);
}

/**
 * Get all active activities
 */
export function getActivities() {
  const state = loadState();
  state.activities = pruneOldEntries(state.activities);
  saveState(state);
  return state.activities;
}

/**
 * Get formatted lounge context for injection
 */
export function getLoungeContext() {
  const activities = getActivities();

  if (activities.length === 0) {
    return '';
  }

  const lines = ['[AI Lounge — Active Tasks]'];
  activities.forEach((entry) => {
    lines.push(`- [${entry.taskId}] ${entry.activity}`);
  });

  return lines.join('\n');
}
