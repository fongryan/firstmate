#!/usr/bin/env node
/*
 * Codex App bridge control-plane primitives.
 *
 * A Firstmate Codex task is owned by a durable task/thread lease.  It is
 * deliberately not owned by the PID of `codex app-server`: Codex Desktop
 * shares that process among unrelated visible threads, so PID ownership would
 * merge independent control planes.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

function fail(message, code = 1) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const positional = [];
  const flags = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (!value.startsWith('--')) {
      positional.push(value);
      continue;
    }
    const key = value.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) fail(`missing value for --${key}`, 2);
    flags.set(key, next);
    i += 1;
  }
  return { positional, flags };
}

function required(flags, key) {
  const value = flags.get(key);
  if (!value) fail(`--${key} is required`, 2);
  return value;
}

function safeTaskId(value) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) {
    fail(`unsafe task id '${value}'`, 2);
  }
  return value;
}

function leasePath(home, taskId) {
  const state = path.resolve(home, 'state', 'codex-app', 'leases');
  const target = path.resolve(state, `${safeTaskId(taskId)}.json`);
  if (!target.startsWith(`${state}${path.sep}`)) fail('lease path escaped Firstmate state', 2);
  fs.mkdirSync(state, { recursive: true, mode: 0o700 });
  return target;
}

function readLease(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || typeof parsed !== 'object') throw new Error('not an object');
    return parsed;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    fail(`invalid lease at ${file}: ${error.message}`);
  }
}

function writeExclusive(file, lease) {
  const fd = fs.openSync(file, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(lease)}\n`, { encoding: 'utf8' });
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function replaceLease(file, lease) {
  const temp = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(lease)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(temp, file);
}

function ttl(flags) {
  const raw = Number(flags.get('ttl-ms') ?? '120000');
  if (!Number.isInteger(raw) || raw < 1000 || raw > 24 * 60 * 60 * 1000) {
    fail('--ttl-ms must be an integer from 1000 to 86400000', 2);
  }
  return raw;
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function leaseAcquire(flags) {
  const home = required(flags, 'home');
  const taskId = safeTaskId(required(flags, 'task'));
  const threadId = required(flags, 'thread');
  emit(acquireLease(home, taskId, threadId, ttl(flags)));
}

function acquireLease(home, taskId, threadId, ttlMs, statusPath = null) {
  const file = leasePath(home, taskId);
  const now = Date.now();
  const lease = {
    version: 1,
    taskId,
    threadId,
    token: crypto.randomBytes(24).toString('hex'),
    acquiredAtMs: now,
    renewedAtMs: now,
    expiresAtMs: now + ttlMs,
  };
  if (statusPath) lease.statusPath = statusPath;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      writeExclusive(file, lease);
      return lease;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const current = readLease(file);
    if (!current) continue;
    if (Number(current.expiresAtMs) > now) {
      fail(`lease held for task ${taskId} by thread ${current.threadId} until ${current.expiresAtMs}`);
    }
    const tombstone = `${file}.expired.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
    try {
      fs.renameSync(file, tombstone);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  fail(`could not acquire task lease for ${taskId}; concurrent ownership changed`);
}

function requireOwnedLease(flags) {
  const home = required(flags, 'home');
  const taskId = safeTaskId(required(flags, 'task'));
  const token = required(flags, 'token');
  const file = leasePath(home, taskId);
  const current = readLease(file);
  if (!current) fail(`no lease for task ${taskId}`);
  if (current.token !== token) fail(`lease token does not own task ${taskId}`);
  return { file, current };
}

function leaseRenew(flags) {
  const { file, current } = requireOwnedLease(flags);
  const now = Date.now();
  if (Number(current.expiresAtMs) <= now) fail(`lease for task ${current.taskId} has expired`);
  current.renewedAtMs = now;
  current.expiresAtMs = now + ttl(flags);
  replaceLease(file, current);
  emit(current);
}

function leaseRelease(flags) {
  const { file, current } = requireOwnedLease(flags);
  fs.unlinkSync(file);
  emit({ released: true, taskId: current.taskId, threadId: current.threadId });
}

class AppServerSession {
  constructor() {
    this.child = null;
    this.pending = new Map();
    this.buffer = '';
    this.nextId = 1;
    this.onNotification = null;
  }

  async start() {
    const { spawn } = await import('node:child_process');
    const bin = process.env.FM_CODEX_APP_BIN || 'codex';
    this.child = spawn(bin, ['app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this.consume(chunk));
    // App-server emits MCP/plugin diagnostics on stderr. Drain it so a
    // long-running task cannot deadlock when that pipe fills.
    this.child.stderr.on('data', () => {});
    this.child.on('error', (error) => this.rejectAll(error));
    this.child.on('exit', (code, signal) => this.rejectAll(new Error(`app-server exited (${code ?? signal ?? 'unknown'})`)));
    await this.request('initialize', { clientInfo: { name: 'firstmate-codex-app-bridge', version: '1' } });
    this.notify('initialized', {});
  }

  consume(chunk) {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf('\n');
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (message.id === undefined) {
        this.onNotification?.(message);
        continue;
      }
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      else pending.resolve(message.result);
    }
  }

  request(method, params, timeoutMs = 15000) {
    if (!this.child?.stdin?.writable) return Promise.reject(new Error('app-server is not writable'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }

  notify(method, params) {
    if (this.child?.stdin?.writable) this.child.stdin.write(`${JSON.stringify({ method, params })}\n`);
  }

  rejectAll(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }

  close() {
    if (!this.child) return;
    this.child.stdin.end();
    this.child.kill();
    this.child = null;
  }
}

async function rpcRead(flags) {
  const threadId = required(flags, 'thread');
  const rpc = new AppServerSession();
  try {
    await rpc.start();
    // A durable rollout is not automatically loaded into a fresh app-server
    // process. Resume is therefore part of the read contract, not a fallback.
    await rpc.request('thread/resume', { threadId });
    const result = await rpc.request('thread/read', { threadId, includeTurns: true });
    emit(result);
  } finally {
    rpc.close();
  }
}

function bridgeRoot(home) {
  const root = path.resolve(home, 'state', 'codex-app');
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  return root;
}

function bridgeSocket(home) {
  // macOS Unix sockets cap paths near 104 bytes. Firstmate homes can live in
  // long worktree paths, so a socket below that home is not portable. The
  // opaque hash keeps the socket per-home without putting mutable authority in
  // /tmp: authority remains the lease under <FM_HOME>/state/codex-app.
  const digest = crypto.createHash('sha256').update(path.resolve(home)).digest('hex').slice(0, 24);
  return path.join(path.resolve(tmpdir()), `fm-codex-app-${digest}.sock`);
}

function bridgePidFile(home) {
  return path.join(bridgeRoot(home), 'bridge.pid');
}

function safeStatusPath(home, candidate) {
  if (!candidate) return null;
  const state = path.resolve(home, 'state');
  const target = path.resolve(candidate);
  if (!target.startsWith(`${state}${path.sep}`)) throw new Error('status path must be inside Firstmate state/');
  return target;
}

function appendStatus(statusPath, line) {
  if (!statusPath) return;
  fs.mkdirSync(path.dirname(statusPath), { recursive: true, mode: 0o700 });
  fs.appendFileSync(statusPath, `${line}\n`, { encoding: 'utf8', mode: 0o600 });
}

function transcriptText(thread, lines) {
  const values = [];
  for (const turn of thread?.turns || []) {
    for (const item of turn?.items || []) {
      if (typeof item?.text === 'string') values.push(item.text);
      if (typeof item?.content === 'string') values.push(item.content);
    }
  }
  return values.join('\n').split('\n').slice(-lines).join('\n');
}

class BridgeDaemon {
  constructor(home) {
    this.home = path.resolve(home);
    this.socket = bridgeSocket(this.home);
    this.sessions = new Map();
    this.server = null;
  }

  async sessionFor(threadId) {
    let rpc = this.sessions.get(threadId);
    if (rpc) return rpc;
    rpc = new AppServerSession();
    await rpc.start();
    await rpc.request('thread/resume', { threadId });
    this.sessions.set(threadId, rpc);
    return rpc;
  }

  tokenFor(taskId, token) {
    const file = leasePath(this.home, taskId);
    const lease = readLease(file);
    if (!lease) throw new Error(`no lease for task ${taskId}`);
    if (lease.token !== token) throw new Error(`lease token does not own task ${taskId}`);
    if (Number(lease.expiresAtMs) <= Date.now()) throw new Error(`lease for task ${taskId} has expired`);
    return lease;
  }

  async handle(request) {
    const { action } = request;
    if (action === 'create') {
      const taskId = safeTaskId(request.task);
      const cwd = request.cwd;
      const prompt = request.prompt;
      const statusPath = safeStatusPath(this.home, request.status);
      if (!cwd || !prompt) throw new Error('create requires cwd and prompt');
      const rpc = new AppServerSession();
      await rpc.start();
      let threadId;
      let lease;
      try {
        const started = await rpc.request('thread/start', { cwd });
        threadId = started?.thread?.id;
        if (!threadId) throw new Error('thread/start did not return a durable thread id');
        lease = acquireLease(this.home, taskId, threadId, Number(request.ttlMs || 120000), statusPath);
        rpc.onNotification = (event) => {
          if (event.method !== 'turn/completed') return;
          const status = event.params?.turn?.status;
          appendStatus(statusPath, status === 'completed' ? 'done: Codex App turn completed' : `blocked: Codex App turn ended (${status || 'unknown'})`);
        };
        appendStatus(statusPath, 'working: Codex App thread started');
        await rpc.request('turn/start', { threadId, input: [{ type: 'text', text: prompt }] });
        this.sessions.set(threadId, rpc);
        return { taskId, threadId, token: lease.token, expiresAtMs: lease.expiresAtMs };
      } catch (error) {
        if (lease) {
          try { fs.unlinkSync(leasePath(this.home, taskId)); } catch { /* best effort */ }
        }
        rpc.close();
        throw error;
      }
    }
    if (action === 'read' || action === 'capture') {
      const threadId = request.thread;
      if (!threadId) throw new Error(`${action} requires thread`);
      const rpc = await this.sessionFor(threadId);
      const result = await rpc.request('thread/read', { threadId, includeTurns: true });
      if (action === 'capture') return { text: transcriptText(result.thread, Number(request.lines || 40)) };
      return result;
    }
    if (action === 'send') {
      const lease = this.tokenFor(safeTaskId(request.task), request.token);
      if (!request.text) throw new Error('send requires text');
      const rpc = await this.sessionFor(lease.threadId);
      const current = await rpc.request('thread/read', { threadId: lease.threadId, includeTurns: false });
      const method = current?.thread?.status?.type === 'active' ? 'turn/steer' : 'turn/start';
      await rpc.request(method, { threadId: lease.threadId, input: [{ type: 'text', text: request.text }] });
      return { accepted: true, threadId: lease.threadId, delivery: method === 'turn/steer' ? 'steered' : 'started' };
    }
    if (action === 'archive') {
      const lease = this.tokenFor(safeTaskId(request.task), request.token);
      const rpc = await this.sessionFor(lease.threadId);
      await rpc.request('thread/archive', { threadId: lease.threadId });
      try { fs.unlinkSync(leasePath(this.home, lease.taskId)); } catch { /* best effort */ }
      rpc.close();
      this.sessions.delete(lease.threadId);
      return { archived: true, threadId: lease.threadId };
    }
    if (action === 'exists') {
      const threadId = request.thread;
      if (!threadId) throw new Error('exists requires thread');
      const rpc = await this.sessionFor(threadId);
      const result = await rpc.request('thread/read', { threadId, includeTurns: false });
      return { exists: Boolean(result?.thread?.id), threadId };
    }
    throw new Error(`unknown bridge action '${action || ''}'`);
  }

  async listen() {
    const net = await import('node:net');
    try { fs.unlinkSync(this.socket); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.server = net.createServer((socket) => {
      socket.setEncoding('utf8');
      let buffer = '';
      socket.on('data', async (chunk) => {
        buffer += chunk;
        let newline;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
          if (!line) continue;
          try { socket.write(`${JSON.stringify({ ok: true, result: await this.handle(JSON.parse(line)) })}\n`); }
          catch (error) { socket.write(`${JSON.stringify({ ok: false, error: error.message || String(error) })}\n`); }
        }
      });
    });
    await new Promise((resolve, reject) => { this.server.once('error', reject); this.server.listen(this.socket, resolve); });
    fs.writeFileSync(bridgePidFile(this.home), `${process.pid}\n`, { mode: 0o600 });
  }

  stop() {
    for (const rpc of this.sessions.values()) rpc.close();
    this.server?.close();
    try { fs.unlinkSync(this.socket); } catch { /* best effort */ }
    try { fs.unlinkSync(bridgePidFile(this.home)); } catch { /* best effort */ }
  }
}

async function requestBridge(socket, request, timeoutMs = 5000) {
  const net = await import('node:net');
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socket);
    let buffer = '';
    const timer = setTimeout(() => { client.destroy(); reject(new Error('timeout waiting for bridge daemon')); }, timeoutMs);
    client.setEncoding('utf8');
    client.on('error', (error) => { clearTimeout(timer); reject(error); });
    client.on('connect', () => client.write(`${JSON.stringify(request)}\n`));
    client.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      clearTimeout(timer);
      client.end();
      try {
        const response = JSON.parse(buffer.slice(0, newline));
        if (!response.ok) reject(new Error(response.error));
        else resolve(response.result);
      } catch (error) { reject(error); }
    });
  });
}

async function ensureBridge(home) {
  const socket = bridgeSocket(home);
  try { await requestBridge(socket, { action: '__ping__' }, 500); return socket; } catch { /* start below */ }
  const { spawn } = await import('node:child_process');
  const log = path.join(bridgeRoot(home), 'bridge.log');
  const fd = fs.openSync(log, 'a', 0o600);
  const child = spawn(process.execPath, [process.argv[1], 'daemon', '--home', home], {
    detached: true, stdio: ['ignore', fd, fd], env: process.env,
  });
  child.unref();
  for (let attempt = 0; attempt < 25; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    try { await requestBridge(socket, { action: '__ping__' }, 500); return socket; } catch { /* retry */ }
  }
  throw new Error(`bridge daemon did not start; inspect ${log}`);
}

async function callBridge(flags) {
  const home = required(flags, 'home');
  const action = required(flags, 'action');
  const request = {
    action,
    task: flags.get('task'),
    thread: flags.get('thread'),
    token: flags.get('token'),
    cwd: flags.get('cwd'),
    prompt: flags.get('prompt'),
    text: flags.get('text'),
    status: flags.get('status'),
    lines: flags.get('lines'),
    ttlMs: flags.get('ttl-ms'),
  };
  const socket = await ensureBridge(home);
  emit(await requestBridge(socket, request));
}

async function runDaemon(flags) {
  const home = required(flags, 'home');
  const daemon = new BridgeDaemon(home);
  const stop = () => { daemon.stop(); process.exit(0); };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  const original = daemon.handle.bind(daemon);
  daemon.handle = async (request) => request.action === '__ping__' ? { pong: true } : original(request);
  await daemon.listen();
}

function stopDaemon(flags) {
  const home = required(flags, 'home');
  const pid = Number(fs.readFileSync(bridgePidFile(home), 'utf8').trim());
  if (Number.isInteger(pid) && pid > 1) {
    try { process.kill(pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  try { fs.unlinkSync(bridgeSocket(home)); } catch { /* best effort */ }
  try { fs.unlinkSync(bridgePidFile(home)); } catch { /* best effort */ }
  emit({ stopped: true });
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  if (positional[0] === 'lease' && ['acquire', 'renew', 'release'].includes(positional[1])) {
    if (positional[1] === 'acquire') leaseAcquire(flags);
    if (positional[1] === 'renew') leaseRenew(flags);
    if (positional[1] === 'release') leaseRelease(flags);
    return;
  }
  if (positional[0] === 'rpc' && positional[1] === 'read') {
    await rpcRead(flags);
    return;
  }
  if (positional[0] === 'daemon') {
    await runDaemon(flags);
    return;
  }
  if (positional[0] === 'daemon-stop') {
    stopDaemon(flags);
    return;
  }
  if (positional[0] === 'call') {
    await callBridge(flags);
    return;
  }
  fail('usage: fm-codex-app-bridge.mjs lease <acquire|renew|release> ... | rpc read --thread <id> | call --home <FM_HOME> --action <create|send|read|capture|archive|exists> ...', 2);
}

main().catch((error) => fail(error.message || String(error)));
