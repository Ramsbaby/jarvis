/**
 * langfuse-client.mjs — Lightweight Langfuse HTTP ingestion client (no SDK dependency)
 *
 * Uses Langfuse /api/public/ingestion endpoint directly.
 * All calls are fire-and-forget — never awaited, never throw.
 *
 * Usage:
 *   import { LangfuseClient } from './lib/langfuse-client.mjs';
 *   const lf = new LangfuseClient();  // reads env vars automatically
 *
 *   // Wrap an LLM call:
 *   const gen = lf.startGeneration({ traceId: 'standup-123', name: 'standup-draft', model: 'claude-opus-4' });
 *   const result = await callLLM(...);
 *   gen.end({ output: result.text, usage: { input: 500, output: 200 } });
 */

const LANGFUSE_BASE_URL = process.env.LANGFUSE_BASE_URL ?? 'http://localhost:3200';
const LANGFUSE_PUBLIC_KEY = process.env.LANGFUSE_PUBLIC_KEY ?? '';
const LANGFUSE_SECRET_KEY = process.env.LANGFUSE_SECRET_KEY ?? '';

function nowIso() {
  return new Date().toISOString();
}

function shortId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/** Post a batch to Langfuse — fire and forget, never throws */
async function postIngestion(batch) {
  if (!LANGFUSE_PUBLIC_KEY || !LANGFUSE_SECRET_KEY) return;
  try {
    const creds = Buffer.from(`${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}`).toString('base64');
    await fetch(`${LANGFUSE_BASE_URL}/api/public/ingestion`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Basic ${creds}`,
      },
      body: JSON.stringify({ batch }),
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    // tracing must never break the caller
  }
}

class GenerationHandle {
  #traceId;
  #genId;
  #name;
  #model;
  #startTime;
  #input;
  #metadata;

  constructor({ traceId, name, model, input, metadata }) {
    this.#traceId = traceId ?? `jarvis-${shortId()}`;
    this.#genId = `gen-${shortId()}`;
    this.#name = name ?? 'llm-call';
    this.#model = model ?? 'unknown';
    this.#startTime = nowIso();
    this.#input = input;
    this.#metadata = metadata ?? {};
  }

  /** Call when generation completes. output = string or object, usage = {input, output} */
  end({ output, usage, level } = {}) {
    const endTime = nowIso();
    const outputStr = typeof output === 'string' ? output.slice(0, 500) : JSON.stringify(output ?? '').slice(0, 500);

    postIngestion([
      {
        id: `ev-gen-${shortId()}`,
        type: 'generation-create',
        timestamp: this.#startTime,
        body: {
          id: this.#genId,
          traceId: this.#traceId,
          name: this.#name,
          model: this.#model,
          startTime: this.#startTime,
          endTime,
          ...(this.#input != null && { input: this.#input }),
          output: outputStr,
          ...(usage && {
            usage: {
              input: usage.input ?? 0,
              output: usage.output ?? 0,
              unit: 'TOKENS',
            },
          }),
          ...(level && { level }),
          metadata: this.#metadata,
        },
      },
    ]);
  }

  /** Call when generation fails */
  error(errorMsg) {
    this.end({ output: String(errorMsg), level: 'ERROR' });
  }
}

export class LangfuseClient {
  /** Check if tracing is active (keys configured) */
  get isEnabled() {
    return Boolean(LANGFUSE_PUBLIC_KEY && LANGFUSE_SECRET_KEY);
  }

  /**
   * Create a trace (logical unit of work, e.g. one Discord message handler)
   * Returns the traceId for use with startGeneration().
   */
  createTrace({ name, userId, sessionId, metadata, tags } = {}) {
    const traceId = `jarvis-${shortId()}`;
    postIngestion([
      {
        id: `ev-trace-${shortId()}`,
        type: 'trace-create',
        timestamp: nowIso(),
        body: {
          id: traceId,
          name: name ?? 'discord-handler',
          ...(userId && { userId }),
          ...(sessionId && { sessionId }),
          metadata: metadata ?? {},
          tags: tags ?? ['jarvis', 'discord'],
        },
      },
    ]);
    return traceId;
  }

  /**
   * Start a generation within a trace.
   * Returns a GenerationHandle — call .end() or .error() when done.
   */
  startGeneration({ traceId, name, model, input, metadata } = {}) {
    return new GenerationHandle({ traceId, name, model, input, metadata });
  }

  /**
   * Log a discrete event (no LLM call, e.g. tool use, DB lookup)
   */
  logEvent({ traceId, name, input, output, metadata } = {}) {
    postIngestion([
      {
        id: `ev-event-${shortId()}`,
        type: 'event-create',
        timestamp: nowIso(),
        body: {
          id: `event-${shortId()}`,
          traceId: traceId ?? `jarvis-${shortId()}`,
          name: name ?? 'event',
          ...(input != null && { input }),
          ...(output != null && { output }),
          metadata: metadata ?? {},
        },
      },
    ]);
  }

  /**
   * Score a trace (e.g. user feedback, auto-eval)
   * value: 0.0–1.0 or numeric
   */
  scoreTrace({ traceId, name, value, comment } = {}) {
    postIngestion([
      {
        id: `ev-score-${shortId()}`,
        type: 'score-create',
        timestamp: nowIso(),
        body: {
          id: `score-${shortId()}`,
          traceId,
          name: name ?? 'quality',
          value: value ?? 1,
          ...(comment && { comment }),
        },
      },
    ]);
  }
}

/** Singleton for convenience */
export const langfuse = new LangfuseClient();
