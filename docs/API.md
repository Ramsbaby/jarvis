# Jarvis API Reference

> Core module public APIs. All paths relative to `$BOT_HOME`.

---

## lib/task-store.mjs

SQLite-backed FSM task queue.

### Functions

#### `addTask(task)`
Add a new task to the queue.

```js
import { addTask } from './lib/task-store.mjs';

addTask({
  id: 'my-task',
  status: 'queued',       // pending | queued | running | done | failed | skipped
  priority: 1,            // higher = runs first
  retries: 0,
  depends: [],            // array of task IDs that must be done first
  name: 'Task display name',
  prompt: 'What claude should do',
  completionCheck: 'bash -n ~/.jarvis/scripts/my-script.sh',
  maxBudget: '0.30',      // USD
  timeout: 180,           // seconds
  allowedTools: 'Bash,Read,Write',
  maxRetries: 2,
  createdAt: new Date().toISOString(),
});
```

#### `getTask(id)`
Retrieve a task by ID. Returns `null` if not found.

```js
const task = getTask('my-task');
// { id, status, priority, retries, depends, name, prompt, ... }
```

#### `transition(id, toStatus, options?)`
Transition task to a new FSM state.

```js
transition('my-task', 'running', { triggeredBy: 'dev-runner', extra: {} });
```

**Valid transitions:**
| From | To |
|------|----|
| pending | queued, skipped |
| queued | running, skipped, pending |
| running | done, failed, queued |
| failed | queued |
| skipped | pending, queued |

#### `getReadyTasks()`
Returns tasks that are `queued`, dependencies satisfied, and retries < maxRetries.

#### `listTasks()`
Returns all tasks sorted by priority and update time.

### CLI Usage

```bash
node lib/task-store.mjs get <id>
node lib/task-store.mjs transition <id> <to> [triggeredBy]
node lib/task-store.mjs force-done <id>   # bypass FSM rules
node lib/task-store.mjs pick              # print highest-priority ready task ID
node lib/task-store.mjs list
node lib/task-store.mjs fsm-summary
node lib/task-store.mjs cb-status <id>
node lib/task-store.mjs check-deps <id> [windowHours]
```

---

## lib/rag-engine.mjs

Local RAG engine using LanceDB + Xenova embeddings.

### Functions

#### `search(query, options?)`
Hybrid BM25 + vector search.

```js
import { search } from './lib/rag-engine.mjs';

const results = await search('kakao calendar token', {
  limit: 5,         // max results (default: 5)
  threshold: 0.3,   // minimum similarity score
  namespace: null,  // filter by namespace
});
// [{ content, score, metadata, ... }]
```

#### `ingest(docs, options?)`
Index documents into RAG.

```js
await ingest([
  { content: 'Document text', metadata: { source: 'my-file.md', date: '2026-03-19' } }
]);
```

---

## lib/task-fsm.mjs

Pure FSM logic (no DB dependency).

```js
import { canTransition, applyTransition, pickNextTask } from './lib/task-fsm.mjs';

canTransition('queued', 'running');     // true
canTransition('queued', 'done');        // false — must go through running

const nextTask = pickNextTask(tasks);   // returns highest-priority ready task
```

---

## scripts/kakao-calendar-add.sh

Register an event to Kakao Calendar.

```bash
bash scripts/kakao-calendar-add.sh "YYYY-MM-DD" "제목" ["설명"]

# Example:
bash scripts/kakao-calendar-add.sh "2026-05-10" "휴대폰요금제프로모션종료"
```

**Prerequisites:** `config/secrets/kakao.json` with valid tokens.
**Auto-refresh:** Detects 401 and refreshes access_token automatically.

---

## scripts/kakao-token-refresh.sh

Refresh Kakao access_token using refresh_token.

```bash
bash scripts/kakao-token-refresh.sh
```

Reads from and writes to `config/secrets/kakao.json`. Called automatically by LaunchAgent every 5 hours.

---

## bin/bot-cron.sh

Main cron dispatcher.

```bash
BOT_HOME=~/.jarvis bash bin/bot-cron.sh <task-id>
```

Reads task config from `config/tasks.json`, routes to appropriate script, handles circuit breaker, posts results to Discord.

---

## bin/dev-runner.sh

Autonomous AI development queue runner.

```bash
bash bin/dev-runner.sh
```

Picks the highest-priority `queued` task → runs `completionCheck` → if already done, marks done; otherwise calls `claude -p` with the task prompt → runs `completionCheck` again → commits and pushes if passed.

**State transitions:** `queued → running → done | failed → queued (retry)`

---

## config/tasks.json

Task definitions for `bot-cron.sh`.

```json
{
  "version": 1,
  "tasks": [
    {
      "id": "my-task",
      "schedule": "0 9 * * *",
      "enabled": true,
      "timeout": 120,
      "discordChannel": "jarvis",
      "description": "Task description",
      "script": "/Users/yourname/.jarvis/scripts/my-script.sh"
    }
  ]
}
```

---

## MCP Tools (Nexus)

Available via Claude Code MCP integration.

| Tool | Description |
|------|-------------|
| `mcp__nexus__exec` | Execute bash command |
| `mcp__nexus__log_tail` | Tail log files |
| `mcp__nexus__health` | System health check |
| `mcp__nexus__cache_exec` | Cached command execution (TTL) |
| `mcp__nexus__scan` | Parallel file/directory scan |
| `mcp__nexus__rag_search` | Search RAG memory |
| `mcp__nexus__discord_send` | Send Discord message |
| `mcp__nexus__dev_queue` | View dev-runner task queue |
