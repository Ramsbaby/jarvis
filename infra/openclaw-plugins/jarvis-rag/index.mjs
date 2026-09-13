import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { Type } from "typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const run = promisify(execFile);

const HOME = homedir();
const DEFAULT_SCRIPT = join(HOME, "projects/jarvis/rag/bin/rag-corpus-query.mjs");
// 게이트웨이는 launchd 의 좁은 PATH 로 돈다 — `node` 를 이름으로 찾으면 못 찾거나
// engines 밖 brew node 25 를 잡는다(2026-09-09 jarvis-slots 에서 실측). 절대경로로 고정한다.
const DEFAULT_NODE = join(HOME, ".nvm/versions/node/v24.21.0/bin/node");
// paths.mjs 가 BOT_HOME 없으면 ~/.local/share/jarvis/rag(450행 잔재 DB)로 폴백한다.
// 그러면 검색은 "성공"하는데 결과가 전부 무관해진다 — 실패보다 나쁘다. 명시적으로 넘긴다.
const DEFAULT_BOT_HOME = join(HOME, ".openclaw-data/runtime");

// TypeScript 가 아니라 순수 .mjs 인 이유(2026-09-10):
//   `openclaw plugins install` 은 컴파일된 런타임 출력을 요구한다. .ts 로 두면 설치 기록이
//   안 생기고 Trust 가 record-missing 으로 남는다. 빌드 단계를 만드는 대신 JS 로 쓴다.

export default definePluginEntry({
  id: "jarvis-rag",
  name: "Jarvis RAG Corpus",
  description:
    "자비스 RAG 아카이브(LanceDB 134,055청크)를 memory_search 의 보조 코퍼스로 붙인다",
  register(api) {
    const root = api.config ?? {};
    const cfg = root?.plugins?.entries?.["jarvis-rag"]?.config ?? {};
    const scriptPath = cfg.scriptPath ?? DEFAULT_SCRIPT;
    const nodePath = cfg.nodePath ?? DEFAULT_NODE;
    const botHome = cfg.botHome ?? DEFAULT_BOT_HOME;
    const timeout = cfg.timeoutMs ?? 20000;
    const defaultMax = cfg.maxResults ?? 8;

    async function callAdapter(args) {
      const { stdout } = await run(nodePath, [scriptPath, ...args], {
        timeout,
        maxBuffer: 16 * 1024 * 1024,
        env: { ...process.env, BOT_HOME: botHome, JARVIS_RAG_HOME: join(botHome, "rag") },
      });
      return JSON.parse(stdout || "{}");
    }

    api.registerMemoryCorpusSupplement({
      async search({ query, maxResults }) {
        if (!query?.trim()) return [];
        let payload;
        try {
          payload = await callAdapter([
            "search",
            query,
            String(Math.min(50, Math.max(1, maxResults ?? defaultMax))),
          ]);
        } catch {
          // 보조 코퍼스가 죽어도 본 메모리 검색은 살아야 한다. 조용히 빈 배열을 낸다.
          // (어댑터는 자체 실패도 JSON 으로 내므로 여기까지 오는 건 프로세스 자체 실패다.)
          return [];
        }
        if (!payload?.ok || !Array.isArray(payload.results)) return [];
        return payload.results
          .filter((r) => r?.path && r?.snippet)
          .map((r) => ({
            corpus: r.corpus ?? "jarvis-rag",
            path: r.path,
            title: r.title,
            kind: r.kind,
            score: typeof r.score === "number" ? r.score : 0.5,
            snippet: r.snippet,
            citation: r.citation,
            source: r.source,
            provenanceLabel: r.provenanceLabel ?? "자비스 RAG (아카이브)",
            sourceType: r.sourceType ?? "jarvis-rag",
            sourcePath: r.sourcePath ?? r.path,
          }));
      },

      async get({ lookup, fromLine, lineCount }) {
        if (!lookup?.trim()) return null;
        let payload;
        try {
          payload = await callAdapter([
            "get",
            lookup,
            String(Math.max(1, fromLine ?? 1)),
            String(Math.max(1, lineCount ?? 200)),
          ]);
        } catch {
          return null;
        }
        const r = payload?.ok ? payload.result : null;
        if (!r?.path || typeof r.content !== "string") return null;
        return {
          corpus: r.corpus ?? "jarvis-rag",
          path: r.path,
          title: r.title,
          kind: r.kind,
          content: r.content,
          fromLine: r.fromLine ?? 1,
          lineCount: r.lineCount ?? 0,
          provenanceLabel: "자비스 RAG (아카이브)",
          sourceType: r.sourceType ?? "jarvis-rag",
          sourcePath: r.sourcePath ?? r.path,
        };
      },
    });

    // ── 도구로도 노출한다 ─────────────────────────────────────────────────────
    // 2026-09-10: 코퍼스 보충만으로는 memory_search 가 outcome=not-registered 를 낸다.
    // register() 는 에이전트 스코프마다 돌고(진단 실측 4회) 예외도 없는데 조회 컨텍스트가
    // 그 레지스트리를 못 본다 — runtime-plugins-CCQRXOba.mjs:116 의 워크스페이스 일치 게이트가
    // 유력한 원인이나 확정 못 했다. 원인 규명과 무관하게 목적(아카이브 조회)은 달성해야 하므로
    // 도구로도 낸다. 도구 경로는 jarvis-slots 로 이미 검증된 경로다.
    // 부수 효과로 오히려 낫다 — 기본 memory_search 에 아카이브가 섞이지 않고, 부를 때만 부른다.
    api.registerTool({
      name: "rag_search",
      label: "Jarvis RAG 검색",
      description:
        "자비스 RAG 아카이브(위키·커리어·일일 대화 등 134,055청크)를 의미 검색한다. " +
        "오픈클로 메모리(작업 기억)에 없는 옛 사실·대화·문서를 찾을 때 쓴다. " +
        "정본 순위는 슬롯 > 원문 > 메모리 > RAG이므로, 여기서 나온 값이 위층과 어긋나면 위층이 이긴다.",
      parameters: Type.Object({
        query: Type.String({ description: "검색할 내용" }),
        maxResults: Type.Optional(Type.Number({ description: "반환 개수. 기본 8, 최대 50." })),
      }),
      async execute(_id, params) {
        let payload;
        try {
          payload = await callAdapter([
            "search",
            params.query,
            String(Math.min(50, Math.max(1, params.maxResults ?? defaultMax))),
          ]);
        } catch (err) {
          return {
            content: [{ type: "text", text: `RAG 검색 실패 — 미검증입니다.\n${String(err?.message ?? err).slice(0, 400)}` }],
            details: { error: true },
          };
        }
        if (!payload?.ok) {
          return {
            content: [{ type: "text", text: `RAG 검색 실패 — 미검증입니다.\n${String(payload?.error ?? "알 수 없는 오류").slice(0, 400)}` }],
            details: { error: true },
          };
        }
        const rows = payload.results ?? [];
        if (rows.length === 0) {
          return { content: [{ type: "text", text: "RAG에 해당 내용 없음 (미등재)." }], details: { count: 0 } };
        }
        const text = rows
          .map((r, i) => `### ${i + 1}. ${r.title ?? r.path}  (score ${Number(r.score ?? 0).toFixed(3)})\n📄 ${r.path}\n\n${r.snippet}`)
          .join("\n\n---\n\n");
        return { content: [{ type: "text", text }], details: { count: rows.length } };
      },
    });

    api.registerTool({
      name: "rag_get",
      label: "Jarvis RAG 원문 읽기",
      description:
        "rag_search 가 돌려준 경로의 원문을 읽는다. 청크가 아니라 사람이 읽는 단위로 돌려준다.",
      parameters: Type.Object({
        path: Type.String({ description: "rag_search 결과의 📄 경로 (~ 축약형도 된다)" }),
        fromLine: Type.Optional(Type.Number({ description: "시작 줄. 기본 1." })),
        lineCount: Type.Optional(Type.Number({ description: "읽을 줄 수. 기본 200." })),
      }),
      async execute(_id, params) {
        let payload;
        try {
          payload = await callAdapter([
            "get",
            params.path,
            String(Math.max(1, params.fromLine ?? 1)),
            String(Math.max(1, params.lineCount ?? 200)),
          ]);
        } catch (err) {
          return {
            content: [{ type: "text", text: `원문 읽기 실패 — 미검증입니다.\n${String(err?.message ?? err).slice(0, 400)}` }],
            details: { error: true },
          };
        }
        const r = payload?.ok ? payload.result : null;
        if (!r) {
          return {
            content: [{ type: "text", text: `원문 읽기 실패 — ${String(payload?.error ?? "결과 없음").slice(0, 300)}` }],
            details: { error: true },
          };
        }
        return {
          content: [{ type: "text", text: `📄 ${r.path} (${r.fromLine}~${r.fromLine + r.lineCount - 1}행)\n\n${r.content}` }],
          details: { path: r.path, lineCount: r.lineCount },
        };
      },
    });
  },
});
