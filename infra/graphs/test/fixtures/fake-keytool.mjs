// fake-keytool.mjs — 시험용 keytool·firebase(gostop-release). 'node fake-keytool.mjs <제어파일> <원래 인자…>'
//   keytool -printcert -jarfile <apk> → 제어 파일 { sha256 } 의 지문으로 인증서 출력(가짜 키)
//   firebase appdistribution:distribute <apk> --app … --groups … → '<제어파일>.fad' 에 한 줄
import fs from "node:fs";
const [ctlFile, ...args] = process.argv.slice(2);
const ctl = fs.existsSync(ctlFile) ? JSON.parse(fs.readFileSync(ctlFile, "utf8")) : {};
if (args[0] === "-printcert") {
  process.stdout.write(`Signer #1:\n\nCertificate #1:\nOwner: CN=Fake, O=Fake\nCertificate fingerprints:\n\t SHA1: 00:11\n\t SHA256: ${ctl.sha256 ?? "00"}\nSignature algorithm name: SHA256withRSA\n`);
  process.exit(0);
}
if (args[0] === "appdistribution:distribute") {
  fs.appendFileSync(ctl.fadTrace ?? `${ctlFile}.fad`, `${args.join(" ")}\n`);
  process.stdout.write("✔ uploaded\n");
  process.exit(0);
}
process.stderr.write(`모르는 인자 ${args[0]}\n`);
process.exit(2);
