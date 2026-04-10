/**
 * team-loader.mjs — Load team definitions from YAML + .md templates.
 *
 * Reads ~/.jarvis/teams/{name}/team.yml, system.md, prompt.md
 * and returns a TEAMS object compatible with company-agent.mjs.
 */

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { parse as parseYaml } from 'yaml';

const NEXUS_TOOLS = [
  'mcp__nexus__exec', 'mcp__nexus__scan', 'mcp__nexus__cache_exec',
  'mcp__nexus__log_tail', 'mcp__nexus__health', 'mcp__nexus__file_peek',
];

/**
 * Replace {{VAR}} placeholders with values from the vars object.
 */
function renderTemplate(text, vars) {
  return text.replace(/\{\{(\w+)\}\}/g, (_, key) => vars[key] ?? `{{${key}}}`);
}

/**
 * Expand tool shorthand "nexus" into the full NEXUS_TOOLS array.
 */
function expandTools(tools) {
  const result = [];
  for (const t of tools) {
    if (t === 'nexus') {
      result.push(...NEXUS_TOOLS);
    } else {
      result.push(t);
    }
  }
  return result;
}

/**
 * Load all teams from teamsDir. Returns a TEAMS object keyed by team name.
 *
 * @param {string} teamsDir - Path to teams/ directory
 * @param {object} vars - Template variables: DATE, WEEK, OWNER_NAME, BOT_HOME, etc.
 * @param {string} reportsDir - Path to reports directory (for auto-setting report path)
 */
export function loadTeams(teamsDir, vars, reportsDir) {
  const teams = {};

  if (!existsSync(teamsDir)) return teams;

  for (const entry of readdirSync(teamsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith('.')) continue;

    const teamDir = join(teamsDir, entry.name);
    const ymlPath = join(teamDir, 'team.yml');

    if (!existsSync(ymlPath)) continue;

    try {
      const yml = parseYaml(readFileSync(ymlPath, 'utf-8'));
      const name = entry.name;

      // Read system.md and prompt.md
      const systemPath = join(teamDir, 'system.md');
      const promptPath = join(teamDir, 'prompt.md');

      const systemText = existsSync(systemPath)
        ? renderTemplate(readFileSync(systemPath, 'utf-8').trim(), vars)
        : '';
      const promptText = existsSync(promptPath)
        ? renderTemplate(readFileSync(promptPath, 'utf-8').trim(), vars)
        : yml.prompt || '';

      // Build report path
      let report = null;
      if (yml.taskId && reportsDir) {
        const isWeekly = yml.taskId.includes('weekly') || yml.taskId.includes('brand') || yml.taskId.includes('academy');
        const suffix = isWeekly ? vars.WEEK : vars.DATE;
        report = join(reportsDir, `${name}-${suffix}.md`);
      }

      // Expand tools
      const tools = expandTools(yml.tools || []);

      // Build agents (if any)
      let agents;
      if (yml.agents) {
        agents = {};
        for (const [agentName, agentDef] of Object.entries(yml.agents)) {
          agents[agentName] = {
            description: renderTemplate(agentDef.description || '', vars),
            prompt: renderTemplate(agentDef.prompt || agentDef.description || '', vars),
            tools: agentDef.tools || ['Read', 'Glob'],
          };
        }
      }

      teams[name] = {
        name: renderTemplate(yml.name || entry.name, vars),
        taskId: yml.taskId,
        discord: yml.discord === 'null' || yml.discord === null ? null : yml.discord,
        report,
        maxTurns: yml.maxTurns || 20,
        tools,
        system: systemText,
        prompt: promptText,
        ...(yml.model && { model: yml.model }),
        ...(agents && { agents }),
      };
    } catch (err) {
      console.error(`[team-loader] Failed to load ${entry.name}: ${err.message}`);
    }
  }

  return teams;
}
