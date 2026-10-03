// netspy.mjs — node --import 로 먼저 실어 모든 네트워크 시도를 NETSPY_LOG 에 적는다(실물 시험 4 에서 옮김).
import dc from "node:diagnostics_channel";
import net from "node:net";
import dns from "node:dns";
import fs from "node:fs";

const LOG = process.env.NETSPY_LOG;
const rec = (kind, detail) => { if (LOG) fs.appendFileSync(LOG, `${JSON.stringify({ pid: process.pid, kind, detail })}\n`); };

const origConnect = net.Socket.prototype.connect; // http·https·tls·undici(fetch) 모두 여기를 지난다
net.Socket.prototype.connect = function (...args) {
  const a = Array.isArray(args[0]) ? args[0][0] : args[0];
  const d = typeof a === "object" && a !== null ? { host: a.host, port: a.port, path: a.path } : { port: a, host: args[1] };
  if (!d.path) rec("net.connect", d); // 유닉스 소켓(로컬 IPC)은 네트워크가 아니다
  return origConnect.apply(this, args);
};
for (const fn of ["lookup", "resolve", "resolve4", "resolve6"]) {
  const o = dns[fn];
  dns[fn] = function (h, ...r) { rec(`dns.${fn}`, h); return o.call(this, h, ...r); };
}
const pl = dns.promises.lookup;
dns.promises.lookup = function (h, ...r) { rec("dns.promises.lookup", h); return pl.call(this, h, ...r); };
const of = globalThis.fetch;
globalThis.fetch = function (input, init) { rec("fetch", String(input?.url ?? input)); return of.call(this, input, init); };
dc.subscribe("undici:request:create", ({ request }) => rec("undici.request", { origin: request.origin, path: request.path }));
dc.subscribe("http.client.request.start", ({ request }) => rec("http.request", { host: request.host, path: request.path }));
rec("spy.loaded", { node: process.version });
