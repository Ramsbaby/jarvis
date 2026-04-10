사용자 메모리 만료 정리를 실행한다.

bash 실행:
node -e "
const fs = require('fs');
const stateDir = process.env.HOME + '/.jarvis/state/users';
if (!fs.existsSync(stateDir)) process.exit(0);
const now = Date.now();
const EXPIRE_MS = 90 * 24 * 60 * 60 * 1000;
let archived = 0;
fs.readdirSync(stateDir).filter(f => f.endsWith('.json')).forEach(file => {
  const path = stateDir + '/' + file;
  const data = JSON.parse(fs.readFileSync(path, 'utf-8'));
  if (!data.facts) return;
  const keep = [], expire = [];
  data.facts.forEach(f => {
    const ts = f.addedAt ? new Date(f.addedAt).getTime() : 0;
    (ts && (now - ts) > EXPIRE_MS ? expire : keep).push(f);
  });
  if (expire.length > 0) {
    data.facts = keep;
    data.archived_facts = [...(data.archived_facts || []), ...expire];
    fs.writeFileSync(path, JSON.stringify(data, null, 2));
    archived += expire.length;
  }
});
console.log('archived:' + archived);
"

결과를 '기억 만료 아카이브 완료: N건' 형식으로 출력.