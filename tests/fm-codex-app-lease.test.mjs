#!/usr/bin/env node
// Durable ownership contract for the Codex App bridge.  The lock identity is
// a task/thread lease, never the PID of Codex Desktop's shared app-server.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const bridge = join(root, 'bin', 'fm-codex-app-bridge.mjs');
const home = mkdtempSync(join(tmpdir(), 'fm-codex-app-lease-'));
mkdirSync(join(home, 'state'), { recursive: true });

function invoke(...args) {
  const result = spawnSync(process.execPath, [bridge, ...args], {
    encoding: 'utf8',
  });
  return { ...result, json: result.stdout.trim() ? JSON.parse(result.stdout) : null };
}

try {
  const first = invoke('lease', 'acquire', '--home', home, '--task', 'alpha', '--thread', 'thread-a', '--ttl-ms', '60000');
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.json.taskId, 'alpha');
  assert.equal(first.json.threadId, 'thread-a');
  assert.match(first.json.token, /^[a-f0-9]{32,}$/);

  const conflict = invoke('lease', 'acquire', '--home', home, '--task', 'alpha', '--thread', 'thread-b', '--ttl-ms', '60000');
  assert.notEqual(conflict.status, 0, 'a second owner must not replace an unexpired lease');
  assert.match(conflict.stderr, /lease held/i);

  const renew = invoke('lease', 'renew', '--home', home, '--task', 'alpha', '--token', first.json.token, '--ttl-ms', '60000');
  assert.equal(renew.status, 0, renew.stderr);
  assert.equal(renew.json.threadId, 'thread-a');

  const wrongToken = invoke('lease', 'release', '--home', home, '--task', 'alpha', '--token', 'not-the-owner');
  assert.notEqual(wrongToken.status, 0, 'a non-owner cannot release the task lease');

  const release = invoke('lease', 'release', '--home', home, '--task', 'alpha', '--token', first.json.token);
  assert.equal(release.status, 0, release.stderr);

  const second = invoke('lease', 'acquire', '--home', home, '--task', 'alpha', '--thread', 'thread-b', '--ttl-ms', '60000');
  assert.equal(second.status, 0, second.stderr);
  assert.equal(second.json.threadId, 'thread-b');

  console.log('ok - codex-app durable lease rejects conflicting owners and transfers only after owner release');
} finally {
  rmSync(home, { recursive: true, force: true });
}
