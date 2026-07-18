#!/usr/bin/env node

// Route one autonomous Firstmate task through Brain's canonical execution
// profile router. This adapter is deliberately metadata-only: it never writes
// Brain state, activates a generation, or grants authority. The returned
// selection is a bounded receipt that downstream harness adapters may consume.

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

const [taskId, repo, phase, harness, ...textParts] = process.argv.slice(2);
const text = textParts.join(" ").trim();
if (!taskId || !repo || !text) {
  console.error("usage: fm-agent-profile-route.mjs <task-id> <repo> <phase> <harness> <task text>");
  process.exit(2);
}

const brainRoot = [process.env.BRAIN_ROOT, "/opt/brain", "/Users/ryanfong/workspace/brain"]
  .filter(Boolean)
  .find((candidate) => existsSync(`${candidate}/tools/brain-cli.mjs`)) || process.env.BRAIN_ROOT || "/opt/brain";
const brainCli = process.env.BRAIN_CLI || `${brainRoot}/tools/brain-cli.mjs`;
const packet = {
  schemaVersion: "agent-task-packet@1",
  taskId: String(taskId).slice(0, 80),
  outcome: text.slice(0, 4000),
  pain: text.slice(0, 4000),
  constraints: `Autonomous Firstmate dispatch for repo ${repo}; preserve unrelated work and stop at the proof gate.`,
  proof: "repo-native proof gate and receipt",
  stopRule: "stop on proof failure, authority boundary, or one exact blocker",
  escalate: "escalate production, private, destructive, family, and live-trading actions",
  repo,
  phase: ["investigate", "design", "implement", "repair", "review", "release", "supervise"].includes(phase) ? phase : "implement",
  harness: ["claude-code", "codex", "hermes", "opencode", "factory-api"].includes(harness) ? harness : "opencode",
  autonomy: "autonomous",
  privacy: "public",
  riskClass: "medium",
  capabilityGrants: ["repo.read", "repo.write", "test.run"],
  evidenceRefs: [`firstmate.${taskId}`],
};

let result;
try {
  const output = execFileSync(process.execPath, [brainCli, "agent-profile", "route", "--json", "--task-packet", JSON.stringify(packet)], {
    cwd: brainRoot,
    env: { ...process.env, BRAIN_ROOT: brainRoot },
    encoding: "utf8",
    timeout: Number(process.env.FM_PROFILE_ROUTE_TIMEOUT_MS || 15_000),
    stdio: ["ignore", "pipe", "pipe"],
  });
  result = JSON.parse(output);
} catch (error) {
  result = {
    schemaVersion: "agent-profile-route-receipt@1",
    taskId,
    repo,
    profileId: "plan",
    selectionMode: "safe-fallback",
    confidence: 0,
    reasonCodes: ["brain-router-unavailable", "safe-fallback:plan"],
    routerVersion: null,
    routerHash: null,
    degraded: true,
    error: String(error?.stderr || error?.message || error).trim().slice(0, 240),
  };
}

const decision = result?.decision || {};
process.stdout.write(`${JSON.stringify({
  schemaVersion: "agent-profile-route-receipt@1",
  taskId,
  repo,
  profileId: decision.profileId || result.profileId || "plan",
  selectionMode: decision.selectionMode || result.selectionMode || "safe-fallback",
  confidence: Number.isFinite(decision.confidence) ? decision.confidence : 0,
  reasonCodes: Array.isArray(decision.reasonCodes) ? decision.reasonCodes : ["safe-fallback:plan"],
  routerVersion: decision.routerVersion || null,
  routerHash: decision.routerHash || null,
  harness,
  degraded: result.degraded === true,
  ...(result.error ? { error: result.error } : {}),
})}\n`);
