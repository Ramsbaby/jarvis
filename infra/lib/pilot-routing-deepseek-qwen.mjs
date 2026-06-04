#!/usr/bin/env node

/**
 * Pilot Routing Integration: DeepSeek V4-Flash & Qwen 3.6
 *
 * Purpose: Route low-difficulty cron tasks to cost-efficient models
 * - Haiku → DeepSeek V4-Flash (93% cost reduction)
 * - Haiku → Qwen 3.6 (67% cost reduction)
 *
 * Fallback: Auto-retry with Haiku on failure
 * Created: 2026-05-25
 */

import Anthropic from "@anthropic-ai/sdk";
import fetch from "node-fetch";
import fs from "fs";
import path from "path";

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
  deepseek: {
    apiKey: process.env.DEEPSEEK_API_KEY || "",
    baseURL: "https://api.deepseek.com/chat/completions",
    model: "deepseek-v4-flash",
    pricing: { input: 0.14, output: 0.28 }, // per 1M tokens
  },
  qwen: {
    apiKey: process.env.QWEN_API_KEY || "",
    baseURL: "https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation",
    model: "qwen-3.6-plus",
    pricing: { input: 0.325, output: 1.95 }, // per 1M tokens
  },
  claude: {
    apiKey: process.env.ANTHROPIC_API_KEY || "",
    model: "claude-haiku-4-5-20251001",
    pricing: { input: 1.0, output: 5.0 }, // per 1M tokens
  },
  logFile: path.join(
    process.env.HOME || "/tmp",
    ".jarvis/runtime/logs/pilot-routing.jsonl"
  ),
};

// ============================================================================
// Routing Logic
// ============================================================================

const PILOT_ROUTES = {
  "system-health": {
    id: "system-health",
    model: "deepseek",
    maxTokens: 1024,
  },
  "disk-alert": {
    id: "disk-alert",
    model: "deepseek",
    maxTokens: 512,
  },
  "rate-limit-check": {
    id: "rate-limit-check",
    model: "deepseek",
    maxTokens: 512,
  },
  "rag-health": {
    id: "rag-health",
    model: "deepseek",
    maxTokens: 2048,
  },
  "security-scan": {
    id: "security-scan",
    model: "deepseek",
    maxTokens: 1024,
  },
  "session-sync": {
    id: "session-sync",
    model: "qwen",
    maxTokens: 512,
  },
  "qa-consistency-audit": {
    id: "qa-consistency-audit",
    model: "qwen",
    maxTokens: 2048,
  },
  "interview-ssot-audit": {
    id: "interview-ssot-audit",
    model: "qwen",
    maxTokens: 2048,
  },
  "interview-harness-audit": {
    id: "interview-harness-audit",
    model: "qwen",
    maxTokens: 2048,
  },
  "bot-quality-check": {
    id: "bot-quality-check",
    model: "qwen",
    maxTokens: 1024,
  },
  "memory-sync": {
    id: "memory-sync",
    model: "qwen",
    maxTokens: 512,
  },
  "calendar-alert": {
    id: "calendar-alert",
    model: "deepseek",
    maxTokens: 512,
  },
  "weekly-usage-stats": {
    id: "weekly-usage-stats",
    model: "qwen",
    maxTokens: 1024,
  },
  "market-alert": {
    id: "market-alert",
    model: "deepseek",
    maxTokens: 1024,
  },
};

// ============================================================================
// API Wrappers
// ============================================================================

async function callDeepSeek(prompt, maxTokens = 1024) {
  if (!CONFIG.deepseek.apiKey) {
    throw new Error("DEEPSEEK_API_KEY not set");
  }

  const response = await fetch(CONFIG.deepseek.baseURL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${CONFIG.deepseek.apiKey}`,
    },
    body: JSON.stringify({
      model: CONFIG.deepseek.model,
      messages: [{ role: "user", content: prompt }],
      max_tokens: maxTokens,
      temperature: 0.5,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`DeepSeek API error: ${response.status} - ${error}`);
  }

  const data = await response.json();

  return {
    content: data.choices[0].message.content,
    tokens: {
      input: data.usage?.prompt_tokens || 0,
      output: data.usage?.completion_tokens || 0,
    },
  };
}

async function callQwen(prompt, maxTokens = 1024) {
  if (!CONFIG.qwen.apiKey) {
    throw new Error("QWEN_API_KEY not set");
  }

  const response = await fetch(CONFIG.qwen.baseURL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${CONFIG.qwen.apiKey}`,
    },
    body: JSON.stringify({
      model: CONFIG.qwen.model,
      input: {
        prompt: prompt,
        messages: [{ role: "user", content: prompt }],
      },
      parameters: {
        max_tokens: maxTokens,
        temperature: 0.5,
      },
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Qwen API error: ${response.status} - ${error}`);
  }

  const data = await response.json();

  return {
    content: data.output?.text || data.choices?.[0]?.message?.content || "",
    tokens: {
      input: data.usage?.input_tokens || 0,
      output: data.usage?.output_tokens || 0,
    },
  };
}

async function callClaude(prompt, maxTokens = 1024) {
  const client = new Anthropic({
    apiKey: CONFIG.claude.apiKey,
  });

  const response = await client.messages.create({
    model: CONFIG.claude.model,
    max_tokens: maxTokens,
    messages: [{ role: "user", content: prompt }],
  });

  const content =
    response.content[0].type === "text" ? response.content[0].text : "";

  return {
    content,
    tokens: {
      input: response.usage.input_tokens,
      output: response.usage.output_tokens,
    },
  };
}

// ============================================================================
// Routing & Fallback
// ============================================================================

async function routeTask(taskId, prompt) {
  const route = PILOT_ROUTES[taskId];

  if (!route) {
    throw new Error(`Task ${taskId} not in pilot routing map`);
  }

  let attempt = "primary";
  let result;
  let modelUsed = route.model;

  try {
    // Try primary model
    switch (route.model) {
      case "deepseek":
        result = await callDeepSeek(prompt, route.maxTokens);
        break;
      case "qwen":
        result = await callQwen(prompt, route.maxTokens);
        break;
      default:
        throw new Error(`Unknown model: ${route.model}`);
    }
  } catch (primaryError) {
    console.warn(`Primary model ${route.model} failed, falling back to Claude`);

    attempt = "fallback";
    modelUsed = "claude";

    try {
      result = await callClaude(prompt, route.maxTokens);
    } catch (fallbackError) {
      return {
        success: false,
        model: "claude",
        tokens: { input: 0, output: 0 },
        cost: 0,
        error: `Both primary and fallback failed: ${primaryError} -> ${fallbackError}`,
      };
    }
  }

  // Calculate cost
  const pricing = CONFIG[modelUsed];
  const cost =
    (result.tokens.input * pricing.pricing.input +
      result.tokens.output * pricing.pricing.output) /
    1_000_000;

  return {
    success: true,
    content: result.content,
    model: modelUsed,
    tokens: result.tokens,
    cost,
  };
}

// ============================================================================
// Logging & Reporting
// ============================================================================

function logResult(taskId, result) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    taskId,
    ...result,
  };

  // Ensure log directory exists
  const logDir = path.dirname(CONFIG.logFile);
  if (!fs.existsSync(logDir)) {
    fs.mkdirSync(logDir, { recursive: true });
  }

  fs.appendFileSync(CONFIG.logFile, JSON.stringify(logEntry) + "\n");
}

async function generatePilotReport() {
  if (!fs.existsSync(CONFIG.logFile)) {
    console.log("No pilot results yet");
    return;
  }

  const logs = fs
    .readFileSync(CONFIG.logFile, "utf-8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line));

  const stats = {
    totalTasks: logs.length,
    successful: logs.filter((l) => l.success).length,
    failed: logs.filter((l) => !l.success).length,
    byModel: {},
    totalCost: 0,
    tokensSaved: 0,
  };

  logs.forEach((log) => {
    stats.byModel[log.model] = (stats.byModel[log.model] || 0) + 1;
    stats.totalCost += log.cost || 0;

    // Calculate savings vs Claude Haiku
    const haikuCost =
      (log.tokens.input * CONFIG.claude.pricing.input +
        log.tokens.output * CONFIG.claude.pricing.output) /
      1_000_000;
    const saved = haikuCost - (log.cost || 0);
    if (saved > 0) {
      stats.tokensSaved += saved;
    }
  });

  console.log("\n=== PILOT ROUTING REPORT ===\n");
  console.log(`Total Tasks Executed: ${stats.totalTasks}`);
  console.log(`Successful: ${stats.successful} (${((stats.successful / stats.totalTasks) * 100).toFixed(1)}%)`);
  console.log(`Failed: ${stats.failed}`);
  console.log("\nBy Model:");
  Object.entries(stats.byModel).forEach(([model, count]) => {
    console.log(`  ${model}: ${count}`);
  });
  console.log(`\nTotal Cost: $${stats.totalCost.toFixed(4)}`);
  console.log(`Total Savings vs Haiku: $${stats.tokensSaved.toFixed(4)}`);
  console.log("\nFull logs: " + CONFIG.logFile);
}

// ============================================================================
// CLI Interface
// ============================================================================

async function main() {
  const command = process.argv[2];
  const taskId = process.argv[3];
  const prompt = process.argv[4] || "";

  if (command === "test") {
    if (!taskId || !prompt) {
      console.error("Usage: node pilot-routing-deepseek-qwen.mjs test <taskId> <prompt>");
      process.exit(1);
    }

    console.log(`\nRouting task: ${taskId}`);
    console.log(`Prompt: ${prompt.substring(0, 100)}...`);

    try {
      const result = await routeTask(taskId, prompt);
      logResult(taskId, result);

      console.log(`\n✅ Success: ${result.success}`);
      console.log(`Model Used: ${result.model}`);
      console.log(`Tokens - Input: ${result.tokens.input}, Output: ${result.tokens.output}`);
      console.log(`Cost: $${result.cost.toFixed(6)}`);
      if (result.content) {
        console.log(`\nResponse:\n${result.content.substring(0, 500)}`);
      }
    } catch (error) {
      console.error(`❌ Error: ${error.message}`);
      process.exit(1);
    }
  } else if (command === "report") {
    await generatePilotReport();
  } else if (command === "verify-apis") {
    console.log("\n=== API Configuration Verification ===\n");
    console.log(`DeepSeek API Key: ${CONFIG.deepseek.apiKey ? "✅ Set" : "❌ Not set"}`);
    console.log(`Qwen API Key: ${CONFIG.qwen.apiKey ? "✅ Set" : "❌ Not set"}`);
    console.log(`Claude API Key: ${CONFIG.claude.apiKey ? "✅ Set" : "❌ Not set"}`);
    console.log("\nPilot Tasks Configured: " + Object.keys(PILOT_ROUTES).length);
    console.log("Task IDs:\n  " + Object.keys(PILOT_ROUTES).join("\n  "));
  } else {
    console.log(`\nUsage:
  node pilot-routing-deepseek-qwen.mjs test <taskId> <prompt>
  node pilot-routing-deepseek-qwen.mjs report
  node pilot-routing-deepseek-qwen.mjs verify-apis
`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

export { routeTask, PILOT_ROUTES };
