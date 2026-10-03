// env-guard.mjs — run.mjs 의 첫 import. ESM 은 import 순서대로 평가하므로 LangChain 모듈보다 먼저 돈다.
// 추적 변수 하나(LANGSMITH_TRACING=true 등)만 새도 키 없이 밖으로 연결을 시도한다(시험 4: 20회, 종료 84~94초 지연).
export const SCRUB = /^(LANGSMITH|LANGCHAIN)_/;
for (const k of Object.keys(process.env)) if (SCRUB.test(k)) delete process.env[k];

// 상태 파일 600·폴더 700 — 부르는 쪽(게이트웨이)의 umask 와 무관하게.
process.umask(0o077);
