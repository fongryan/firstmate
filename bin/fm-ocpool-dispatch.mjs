#!/usr/bin/env node
// Bridge one opencode-pool task to flowstate's local-agent-runner and print
// its receipt. This is the ONLY thing this script does: build a task packet,
// call executeLocalTask, report the outcome. It owns no lifecycle, no
// firstmate state/ or data/ writes, and no retry logic - the fm-ocpool.sh
// loop owns all of that.
//
// Usage:
//   fm-ocpool-dispatch.mjs --task-id <id> --repo <abs-path> \
//     --prompt-file <path> [--model <model>] [--timeout-minutes <n>] \
//     [--proof-file <path>] [--json]
//
// Flags:
//   --task-id <id>            required; becomes the task packet's id
//   --repo <path>             required; resolved to an absolute path before
//                              being handed to the runner, which requires an
//                              absolute, existing git repo root
//   --prompt-file <path>      required; file content becomes the task
//                              packet's `outcome` field (see "Packet mapping"
//                              below - flowstate has no bare `prompt` field)
//   --model <model>           optional; default minimax/MiniMax-M3 per the
//                              captain's model-routing contract (gruntwork
//                              goes to MiniMax)
//   --timeout-minutes <n>     optional; default 60; bounds (1-240) are
//                              enforced once, by local-agent-runner.mjs -
//                              this bridge does not restate them
//   --proof-file <path>       optional; see "Proof file format" below. When
//                              omitted, a placeholder sanity-only proof is
//                              used (see below) - pass this flag for any
//                              task where proof needs to mean something
//   --json                    print the receipt as one compact JSON line
//                              instead of the default indented (pretty)
//                              JSON
//   -h, --help                print this text and exit 0
//
// Proof file format:
//   One argv command per non-empty, non-"#"-prefixed line, each line a JSON
//   array of strings, e.g.:
//     ["npm", "test"]
//     ["git", "diff", "--check"]
//   This bridge does no semantic validation of proof commands beyond parsing
//   JSON - local-agent-runner.mjs's validateProof is the single owner of
//   which binaries/subcommands/flags are allowed and stays that way.
//   Omitting --proof-file falls back to a single placeholder command,
//   ["git", "status", "--porcelain"], which always exits 0 and therefore
//   proves nothing about task outcome - it exists only because the runner's
//   task-packet contract requires at least one proof command. Pass
//   --proof-file whenever the caller actually needs a real gate.
//
// Packet mapping (flowstate's task packet has no `prompt` field):
//   local-agent-runner.mjs's task packet is { id, repo, outcome, constraints,
//   proof, stopRule, escalate, model, executor, timeoutMinutes,
//   allowDirtySource }; the runner itself composes the final worker prompt
//   from outcome + constraints + proof + stopRule + escalate via
//   buildTaskPrompt. This bridge maps --prompt-file's content to `outcome`,
//   leaves `constraints` at the runner's own default ([]), supplies a fixed
//   `stopRule`, and leaves `escalate` at the runner's own built-in default.
//   `executor` is always "opencode" (the only validated local-executors.mjs
//   adapter); there is no --executor flag.
//
// Locating flowstate:
//   FM_FLOWSTATE_ROOT overrides the flowstate checkout root; default is the
//   sibling `flowstate` directory next to this firstmate checkout. If
//   scripts/lib/local-agent-runner.mjs is not found under that root, this
//   prints one line, `MISSING: flowstate runner at <path>`, to stderr and
//   exits 5 - fail-closed, no partial packet is ever built past that point.
//
// Other env knobs:
//   FM_OCPOOL_DISPATCH_STATE_ROOT   overrides executeLocalTask's stateRoot
//                                   (default: flowstate's own default,
//                                   $HOME/.flowstate/opencode-runs)
//   FM_OCPOOL_DISPATCH_RUN_ID       overrides the runId (default:
//                                   "<task-id>-<epoch-ms>")
//   FLOWSTATE_RESOURCE_GUARD_MODE   forced to "enforce" by this bridge
//                                   UNLESS the caller's environment already
//                                   sets this key (to any value, including
//                                   empty) - resource-guardian.mjs is the
//                                   single authority on what "enforce" does
//   AGENT_ORCH_DEPTH                read from the caller's environment,
//                                   clamped like flowstate's own
//                                   compass-frozen-replay.mjs does
//                                   (parseInt, fallback 0, bounds 0-99); this
//                                   bridge refuses to run at all if depth+1
//                                   would exceed the spawn-safety hard cap of
//                                   2 (MODEL-ROUTING.md). NOTE: local-agent-
//                                   runner.mjs's SAFE_ENV_KEYS allowlist for
//                                   the spawned worker's environment does not
//                                   include AGENT_ORCH_DEPTH, so setting it
//                                   here is inert for the opencode worker
//                                   itself; it is set anyway, into this
//                                   process's own env, for contract
//                                   compliance and because it does reach the
//                                   runner's host-side commands (git,
//                                   treehouse, ps). This gap is not new: the
//                                   opencode-pool design doc already flags it
//                                   and accepts the isolated-HOME mitigation.
//
// Exit codes:
//   0   receipt status "verified"
//   2   receipt status "blocked" (admission refused by the resource guard,
//       or the source checkout was dirty; the caller should requeue this
//       task WITHOUT burning an attempt)
//   3   receipt status "proof_failed"
//   4   receipt status "failed", or any other/unrecognized terminal status
//   5   usage error, missing flowstate root/runner, AGENT_ORCH_DEPTH cap
//       refusal, or a task-packet validation error raised synchronously by
//       local-agent-runner.mjs before it attempts any work
//
// Receipt note: local-agent-runner.mjs does NOT always persist a receipt
// file to <stateRoot>/runs/<runId>/<taskId>.receipt.json - its two earliest
// "blocked" returns (dirty source checkout, resource-guard admission denial)
// return the receipt-shaped object without writing it to disk. This bridge
// therefore always prints the value executeLocalTask returned, never a
// re-read of the on-disk file.

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_MODEL = "minimax/MiniMax-M3";
const DEFAULT_TIMEOUT_MINUTES = 60;
const DEFAULT_STOP_RULE = "Stop once the outcome is met, or after one proof failure that a fix round did not resolve.";
const DEFAULT_PROOF = [["git", "status", "--porcelain"]];
const AGENT_ORCH_DEPTH_CAP = 2;
const EXIT_BY_STATUS = { verified: 0, blocked: 2, proof_failed: 3, failed: 4 };

class UsageError extends Error {}

function usageText() {
  const self = readFileSync(new URL(import.meta.url), "utf8");
  const lines = self.split(/\r?\n/);
  const out = [];
  for (let i = 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (!line.startsWith("//")) break;
    out.push(line.replace(/^\/\/ ?/, ""));
  }
  return out.join("\n");
}

function parseArgs(argv) {
  const out = { json: false };
  const flags = new Map([
    ["--task-id", "taskId"],
    ["--repo", "repo"],
    ["--prompt-file", "promptFile"],
    ["--model", "model"],
    ["--timeout-minutes", "timeoutMinutes"],
    ["--proof-file", "proofFile"],
  ]);
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      out.help = true;
      continue;
    }
    if (arg === "--json") {
      out.json = true;
      continue;
    }
    if (flags.has(arg)) {
      const key = flags.get(arg);
      const value = argv[i + 1];
      if (value === undefined) throw new UsageError(`${arg} requires a value`);
      out[key] = value;
      i += 1;
      continue;
    }
    throw new UsageError(`unrecognized argument: ${arg}`);
  }
  return out;
}

function clampInteger(value, fallback, minimum, maximum) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isInteger(parsed) ? Math.max(minimum, Math.min(maximum, parsed)) : fallback;
}

function parseProofFile(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    throw new UsageError(`cannot read --proof-file ${file}: ${error.message}`);
  }
  const commands = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line || line.startsWith("#")) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      throw new UsageError(`--proof-file ${file} line ${i + 1} is not valid JSON: ${error.message}`);
    }
    if (!Array.isArray(parsed) || parsed.length === 0 || !parsed.every((part) => typeof part === "string")) {
      throw new UsageError(`--proof-file ${file} line ${i + 1} must be a JSON array of strings`);
    }
    commands.push(parsed);
  }
  if (commands.length === 0) throw new UsageError(`--proof-file ${file} contains no proof commands`);
  return commands;
}

function readPromptFile(file) {
  try {
    return readFileSync(file, "utf8");
  } catch (error) {
    throw new UsageError(`cannot read --prompt-file ${file}: ${error.message}`);
  }
}

function resolveFlowstateRoot() {
  if (process.env.FM_FLOWSTATE_ROOT) return path.resolve(process.env.FM_FLOWSTATE_ROOT);
  const repoRoot = path.resolve(import.meta.dirname, "..");
  return path.resolve(repoRoot, "..", "flowstate");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(`${usageText()}\n`);
    return 0;
  }
  for (const [flag, key] of [["--task-id", "taskId"], ["--repo", "repo"], ["--prompt-file", "promptFile"]]) {
    if (!args[key]) throw new UsageError(`${flag} is required`);
  }

  // Spawn-safety depth check first: cheapest possible refusal, and it must
  // fail closed before any flowstate lookup or file read happens.
  const parentDepth = clampInteger(process.env.AGENT_ORCH_DEPTH, 0, 0, 99);
  const childDepth = parentDepth + 1;
  if (childDepth > AGENT_ORCH_DEPTH_CAP) {
    throw new UsageError(
      `AGENT_ORCH_DEPTH would go from ${parentDepth} to ${childDepth}, exceeding the spawn-safety hard cap of ${AGENT_ORCH_DEPTH_CAP}; refusing to dispatch`,
    );
  }

  const flowstateRoot = resolveFlowstateRoot();
  const runnerPath = path.join(flowstateRoot, "scripts", "lib", "local-agent-runner.mjs");
  if (!existsSync(runnerPath)) {
    process.stderr.write(`MISSING: flowstate runner at ${runnerPath}\n`);
    return 5;
  }

  const outcome = readPromptFile(args.promptFile);
  const proof = args.proofFile ? parseProofFile(args.proofFile) : DEFAULT_PROOF;
  const timeoutMinutes = clampInteger(args.timeoutMinutes, DEFAULT_TIMEOUT_MINUTES, 1, 240);

  const task = {
    id: args.taskId,
    repo: path.resolve(args.repo),
    outcome,
    proof,
    stopRule: DEFAULT_STOP_RULE,
    model: args.model || DEFAULT_MODEL,
    executor: "opencode",
    timeoutMinutes,
  };

  process.env.AGENT_ORCH_DEPTH = String(childDepth);
  if (!Object.prototype.hasOwnProperty.call(process.env, "FLOWSTATE_RESOURCE_GUARD_MODE")) {
    process.env.FLOWSTATE_RESOURCE_GUARD_MODE = "enforce";
  }

  const runId = process.env.FM_OCPOOL_DISPATCH_RUN_ID || `${args.taskId}-${Date.now()}`;
  const options = { runId };
  if (process.env.FM_OCPOOL_DISPATCH_STATE_ROOT) options.stateRoot = path.resolve(process.env.FM_OCPOOL_DISPATCH_STATE_ROOT);

  const { executeLocalTask } = await import(pathToFileURL(runnerPath).href);

  let result;
  try {
    result = await executeLocalTask(task, options);
  } catch (error) {
    throw new UsageError(`task packet rejected by local-agent-runner.mjs: ${error.message}`);
  }

  process.stdout.write(args.json ? `${JSON.stringify(result)}\n` : `${JSON.stringify(result, null, 2)}\n`);
  return EXIT_BY_STATUS[result.status] ?? 4;
}

main()
  .then((code) => { process.exitCode = code; })
  .catch((error) => {
    if (error instanceof UsageError) {
      process.stderr.write(`fm-ocpool-dispatch: ${error.message}\n`);
      process.exitCode = 5;
      return;
    }
    process.stderr.write(`fm-ocpool-dispatch: unexpected error: ${error?.stack || error}\n`);
    process.exitCode = 4;
  });
