#!/usr/bin/env node
/**
 * mcp-nexus.mjs — Context Intelligence Gateway (orchestrator)
 *
 * 원시 출력(315KB) → 압축(5.4KB) → Claude 컨텍스트
 * TTL 캐시 / 지능형 압축 / 멀티 게이트웨이 라우팅 / MCP Resources
 *
 * 게이트웨이 분리 구조:
 *   nexus/exec-gateway.mjs    — exec, scan, cache_exec, log_tail, file_peek
 *   nexus/rag-gateway.mjs     — rag_search
 *   nexus/health-gateway.mjs  — health
 *   nexus/extras-gateway.mjs  — discord_send, run_cron, get_memory
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import * as execGateway   from './nexus/exec-gateway.mjs';
import * as ragGateway    from './nexus/rag-gateway.mjs';
import * as healthGateway from './nexus/health-gateway.mjs';
import * as extrasGateway from './nexus/extras-gateway.mjs';
import { BOT_HOME, LOGS_DIR, mkError, logTelemetry } from './nexus/shared.mjs';

// Gateway registry — order matters for routing
const GATEWAYS = [execGateway, ragGateway, healthGateway, extrasGateway];

// Flat tool list (merged from all gateways)
const ALL_TOOLS = GATEWAYS.flatMap(g => g.TOOLS);

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------
const server = new Server(
  { name: 'nexus-cig', version: '3.0.0' },
  { capabilities: { tools: {}, resources: {} } },
);

// ---------------------------------------------------------------------------
// Tools: ListTools
// ---------------------------------------------------------------------------
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: ALL_TOOLS }));

// ---------------------------------------------------------------------------
// Tools: CallTool — route to correct gateway
// ---------------------------------------------------------------------------
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const start = Date.now();

  try {
    for (const gateway of GATEWAYS) {
      const result = await gateway.handle(name, args, start);
      if (result !== null) return result;
    }
    logTelemetry(name, Date.now() - start, { error: 'unknown_tool' });
    return mkError(`알 수 없는 도구: ${name}`, { tool: name });
  } catch (err) {
    logTelemetry(name, Date.now() - start, { error: err.message });
    return mkError(`오류: ${err.message}`, { tool: name });
  }
});

// ---------------------------------------------------------------------------
// Resources: ListResources (Task #26)
// ---------------------------------------------------------------------------
const RESOURCES = [
  {
    uri: 'jarvis://health',
    name: 'Jarvis 시스템 상태',
    description: 'health.json — 서비스 상태, 크론 이력, 임계값 (읽기 전용)',
    mimeType: 'application/json',
  },
  {
    uri: 'jarvis://logs',
    name: '로그 파일 목록',
    description: 'logs/ 디렉토리의 모든 로그 파일 (이름, 크기, 수정시각)',
    mimeType: 'application/json',
  },
  {
    uri: 'jarvis://cache/stats',
    name: '캐시 메트릭',
    description: 'Nexus TTL 캐시 현재 상태 (엔트리 수, 활성/만료)',
    mimeType: 'application/json',
  },
];

server.setRequestHandler(ListResourcesRequestSchema, async () => ({ resources: RESOURCES }));

// ---------------------------------------------------------------------------
// Resources: ReadResource (Task #26)
// ---------------------------------------------------------------------------
server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const { uri } = request.params;

  if (uri === 'jarvis://health') {
    const healthPath = join(BOT_HOME, 'state', 'health.json');
    if (!existsSync(healthPath)) {
      return {
        contents: [{ uri, mimeType: 'application/json', text: JSON.stringify({ error: 'health.json 없음' }) }],
      };
    }
    const raw = readFileSync(healthPath, 'utf-8');
    return { contents: [{ uri, mimeType: 'application/json', text: raw }] };
  }

  if (uri === 'jarvis://logs') {
    const { readdirSync, statSync } = await import('node:fs');
    let entries = [];
    try {
      entries = readdirSync(LOGS_DIR)
        .filter(f => f.endsWith('.log') || f.endsWith('.jsonl'))
        .map(f => {
          const p = join(LOGS_DIR, f);
          const s = statSync(p);
          return { name: f, size_kb: Math.round(s.size / 1024), mtime: s.mtime.toISOString() };
        })
        .sort((a, b) => b.mtime.localeCompare(a.mtime));
    } catch { /* logs dir not found */ }
    return {
      contents: [{
        uri,
        mimeType: 'application/json',
        text: JSON.stringify({ log_count: entries.length, logs: entries }, null, 2),
      }],
    };
  }

  if (uri === 'jarvis://cache/stats') {
    const stats = execGateway.getCacheStats();
    return {
      contents: [{
        uri,
        mimeType: 'application/json',
        text: JSON.stringify({ ...stats, ts: new Date().toISOString() }, null, 2),
      }],
    };
  }

  return {
    contents: [{ uri, mimeType: 'application/json', text: JSON.stringify({ error: `알 수 없는 리소스: ${uri}` }) }],
  };
});

// ---------------------------------------------------------------------------
// Connect
// ---------------------------------------------------------------------------
const transport = new StdioServerTransport();
await server.connect(transport);
