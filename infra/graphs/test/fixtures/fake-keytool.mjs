// fake-keytool.mjs — 시험용 apksigner·firebase(gostop-release). 'node fake-keytool.mjs <제어파일> <원래 인자…>'
//   apksigner verify --print-certs -v <apk> → 제어 파일 { sha256 } 의 지문으로 서명자 출력(가짜 키)
//   firebase appdistribution:distribute <apk> --app … --groups … → '<제어파일>.fad' 에 한 줄
import fs from "node:fs";
const [ctlFile, ...args] = process.argv.slice(2);
const ctl = fs.existsSync(ctlFile) ? JSON.parse(fs.readFileSync(ctlFile, "utf8")) : {};
if (args[0] === "verify") { // apksigner verify --print-certs -v <apk>
  const hex = String(ctl.sha256 ?? "00").replace(/:/g, "").toLowerCase();
  process.stdout.write(`Verifies\nVerified using v1 scheme (JAR signing): false\nVerified using v2 scheme (APK Signature Scheme v2): true\nVerified using v3 scheme (APK Signature Scheme v3): true\nNumber of signers: 1\nSigner #1 certificate DN: CN=Fake\nSigner #1 certificate SHA-256 digest: ${hex}\nSigner #1 certificate SHA-1 digest: 0011\n`);
  process.exit(0);
}
if (args[0] === "appdistribution:distribute") {
  fs.appendFileSync(ctl.fadTrace ?? `${ctlFile}.fad`, `${args.join(" ")}\n`);
  process.stdout.write("✔ uploaded\n");
  process.exit(0);
}
process.stderr.write(`모르는 인자 ${args[0]}\n`);
process.exit(2);
