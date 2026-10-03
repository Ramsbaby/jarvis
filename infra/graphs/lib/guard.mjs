// guard.mjs — 실행 시 차단층. 그래프 코드는 어떤 길로든(createRequire·process.getBuiltinModule·문자열 조합 동적 import·
// 프로세스를 띄우는 npm 패키지·worker·process.binding) 프로세스를 직접 띄우지 못한다. 정적 검사(check-graph-rules)는 정규식이라
// 속을 수 있다 — 이 층이 실제로 막는다(0b 검토 상1, 재현으로 확인한 우회로).
// 방법: child_process 의 내보낸 함수를 감싸 '허가 범위'(AsyncLocalStorage) 밖이면 던진다. 내보내기 객체 하나를 바꾸므로
//   require·import(이름·기본)·getBuiltinModule 모두 같은 함수를 받는다(syncBuiltinESMExports). 실행기 내부(lib/)만 allowSpawn 으로 띄운다.
// 한계(정직): 같은 프로세스 안이라 파일 쓰기·네트워크는 막지 않는다(정적 검사가 본다). 완전한 격리는 별도 프로세스·sandbox-exec(1b).
import { AsyncLocalStorage } from "node:async_hooks";
import cp from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import wt from "node:worker_threads";

const scope = new AsyncLocalStorage();
let installed = false;

export class SpawnBlocked extends Error {
  constructor(what) {
    super(`${what} 직접 실행 금지 — 명령은 run(cmdId) 허용 목록 입구로만(S10)`);
    this.name = "SpawnBlocked";
    this.codeDefect = true; // 재시도해도 같다 — 코드가 바뀔 때까지 보류
  }
}

// 실행기 내부가 프로세스를 띄울 때만 쓴다. fn 은 띄우기만 하고 바로 돌아와야 한다(그래프 코드를 이 안에서 부르지 않는다).
export const allowSpawn = (fn) => scope.run(true, fn);
export const guardInstalled = () => installed;

export function installGuard() {
  if (installed) return;
  installed = true;
  for (const f of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
    const orig = cp[f];
    cp[f] = function guardedChildProcess(...args) {
      if (!scope.getStore()) throw new SpawnBlocked(`child_process.${f}`);
      return orig.apply(this, args);
    };
  }
  const W = wt.Worker;
  wt.Worker = class GuardedWorker extends W {
    constructor(...args) {
      if (!scope.getStore()) throw new SpawnBlocked("worker_threads.Worker"); // 새 스레드는 감싸지 않은 child_process 를 새로 얻는다
      super(...args);
    }
  };
  syncBuiltinESMExports();
  const binding = process.binding;
  process.binding = function guardedBinding(name) {
    if (/^(spawn_sync|process_wrap)$/.test(String(name)) && !scope.getStore()) throw new SpawnBlocked(`process.binding(${name})`);
    return binding.call(this, name);
  };
  for (const k of ["dlopen", "execve"]) { // 네이티브 애드온(better-sqlite3)은 이미 적재됐다 — 이후의 적재·프로세스 교체는 막는다
    const orig = process[k];
    if (typeof orig !== "function") continue;
    process[k] = function guardedProcess(...args) {
      if (!scope.getStore()) throw new SpawnBlocked(`process.${k}`);
      return orig.apply(this, args);
    };
  }
}
