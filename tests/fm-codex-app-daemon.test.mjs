#!/usr/bin/env node
// An active Codex turn must outlive the short-lived Firstmate shell command.
// The bridge daemon owns the RPC connection; a durable lease owns authority.
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const bridge = join(root, 'bin', 'fm-codex-app-bridge.mjs');
const temp = mkdtempSync(join(tmpdir(), 'fm-codex-app-daemon-'));
const home = join(temp, 'home');
const fakeCodex = join(temp, 'codex');
mkdirSync(join(home, 'state'), { recursive: true });
writeFileSync(fakeCodex, `#!/usr/bin/env node
let input = ''; let threadId = 'thread-from-fake';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; let i; while ((i = input.indexOf('\\n')) >= 0) {
  const line = input.slice(0, i); input = input.slice(i + 1); if (!line) continue;
  const r = JSON.parse(line);
  if (r.method === 'initialize') console.log(JSON.stringify({id:r.id,result:{ok:true}}));
  if (r.method === 'thread/start') console.log(JSON.stringify({id:r.id,result:{thread:{id:threadId,status:{type:'idle'}}}}));
  if (r.method === 'thread/resume') console.log(JSON.stringify({id:r.id,result:{thread:{id:r.params.threadId,status:{type:'idle'},turns:[]}}}));
  if (r.method === 'turn/start') console.log(JSON.stringify({id:r.id,result:{turn:{id:'turn-1',status:'inProgress'}}}));
  if (r.method === 'thread/read') console.log(JSON.stringify({id:r.id,result:{thread:{id:r.params.threadId,status:{type:'idle'},turns:[{items:[{type:'agentMessage',text:'daemon transcript'}]}]}}}));
  if (r.method === 'thread/archive') console.log(JSON.stringify({id:r.id,result:{}}));
}});
`);
chmodSync(fakeCodex, 0o755);
const env = { ...process.env, FM_CODEX_APP_BIN: fakeCodex };
function call(...args) {
  const result = spawnSync(process.execPath, [bridge, 'call', '--home', home, ...args], { env, encoding: 'utf8', timeout: 15000 });
  return { ...result, json: result.stdout.trim() ? JSON.parse(result.stdout) : null };
}
try {
  const created = call('--action', 'create', '--task', 'alpha', '--cwd', home, '--prompt', 'test prompt');
  assert.equal(created.status, 0, created.stderr);
  assert.equal(created.json.threadId, 'thread-from-fake');
  assert.match(created.json.token, /^[a-f0-9]{32,}$/);

  const sent = call('--action', 'send', '--task', 'alpha', '--token', created.json.token, '--text', 'operator follow-up');
  assert.equal(sent.status, 0, sent.stderr);
  assert.equal(sent.json.accepted, true);
  assert.equal(sent.json.delivery, 'started');

  const read = call('--action', 'read', '--thread', created.json.threadId);
  assert.equal(read.status, 0, read.stderr);
  assert.equal(read.json.thread.turns[0].items[0].text, 'daemon transcript');

  const archived = call('--action', 'archive', '--task', 'alpha', '--token', created.json.token);
  assert.equal(archived.status, 0, archived.stderr);
  assert.equal(archived.json.archived, true);
  console.log('ok - codex-app daemon keeps RPC state alive while shell callers return and archives through the task lease');
} finally {
  spawnSync(process.execPath, [bridge, 'daemon-stop', '--home', home], { env });
  rmSync(temp, { recursive: true, force: true });
}
