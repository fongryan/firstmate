#!/usr/bin/env node
// The bridge must speak the supported app-server lifecycle, including the
// crucial resume-before-read rule that makes an earlier turn durable.
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const bridge = join(root, 'bin', 'fm-codex-app-bridge.mjs');
const temp = mkdtempSync(join(tmpdir(), 'fm-codex-app-rpc-'));
const fakeCodex = join(temp, 'codex');

writeFileSync(fakeCodex, `#!/usr/bin/env node
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  let index;
  while ((index = input.indexOf('\\n')) >= 0) {
    const line = input.slice(0, index); input = input.slice(index + 1);
    if (!line) continue;
    const request = JSON.parse(line);
    if (request.method === 'initialize') console.log(JSON.stringify({ id: request.id, result: { ok: true } }));
    if (request.method === 'thread/resume') console.log(JSON.stringify({ id: request.id, result: { thread: { id: request.params.threadId, status: { type: 'idle' }, turns: [] } } }));
    if (request.method === 'thread/read') console.log(JSON.stringify({ id: request.id, result: { thread: { id: request.params.threadId, status: { type: 'idle' }, turns: [{ items: [{ type: 'agentMessage', text: 'bridge transcript' }] }] } } }));
  }
});
`);
chmodSync(fakeCodex, 0o755);

try {
  const result = spawnSync(process.execPath, [bridge, 'rpc', 'read', '--thread', 'thread-durable'], {
    env: { ...process.env, FM_CODEX_APP_BIN: fakeCodex },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  const response = JSON.parse(result.stdout);
  assert.equal(response.thread.id, 'thread-durable');
  assert.equal(response.thread.turns[0].items[0].text, 'bridge transcript');
  console.log('ok - codex-app bridge resumes durable threads before reading their transcript');
} finally {
  rmSync(temp, { recursive: true, force: true });
}
