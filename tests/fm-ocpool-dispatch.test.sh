#!/usr/bin/env bash
# Behavior tests for bin/fm-ocpool-dispatch.mjs, the bridge from one
# opencode-pool task to flowstate's local-agent-runner.
#
# No real opencode, treehouse, or flowstate code runs here: FM_FLOWSTATE_ROOT
# points at a fixture "flowstate" checkout whose scripts/lib/local-agent-
# runner.mjs is a stub that captures what it was called with and returns a
# canned receipt shaped by FM_OCPOOL_TEST_STUB_STATUS. Everything written
# happens under this test's own tmp root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-ocpool-dispatch.mjs"
TMP_ROOT=$(fm_test_tmproot fm-ocpool-dispatch-tests)

STUB_ROOT="$TMP_ROOT/flowstate-stub"
mkdir -p "$STUB_ROOT/scripts/lib"
cat > "$STUB_ROOT/scripts/lib/local-agent-runner.mjs" <<'JS'
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function executeLocalTask(task, options) {
  if (process.env.FM_OCPOOL_TEST_STUB_CAPTURE) {
    writeFileSync(process.env.FM_OCPOOL_TEST_STUB_CAPTURE, JSON.stringify({
      task,
      runId: options?.runId ?? null,
      stateRoot: options?.stateRoot ?? null,
      env: {
        FLOWSTATE_RESOURCE_GUARD_MODE: process.env.FLOWSTATE_RESOURCE_GUARD_MODE ?? null,
        AGENT_ORCH_DEPTH: process.env.AGENT_ORCH_DEPTH ?? null,
      },
    }, null, 2));
  }
  const status = process.env.FM_OCPOOL_TEST_STUB_STATUS || "verified";
  const result = {
    id: task.id,
    repo: task.repo,
    repoName: "stub-repo",
    executor: task.executor,
    status,
    startedAt: "2026-01-01T00:00:00.000Z",
    finishedAt: "2026-01-01T00:00:01.000Z",
    sourceSha: "deadbeef",
    worktree: "/tmp/stub-worktree",
    proof: [],
    error: status === "verified" ? null : (process.env.FM_OCPOOL_TEST_STUB_ERROR || `stub status ${status}`),
  };
  // Mirrors local-agent-runner.mjs's own writeReceipt only when the test
  // opts in, so tests can exercise both the "persisted" and "not persisted"
  // receiptPath branches against the real filesystem.
  if (process.env.FM_OCPOOL_TEST_STUB_WRITE_RECEIPT === "1" && options?.stateRoot && options?.runId) {
    const dir = join(options.stateRoot, "runs", options.runId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${task.id}.receipt.json`), `${JSON.stringify(result, null, 2)}\n`);
  }
  return result;
}
JS

# A real, existing directory to pass as --repo; the stub never runs real git,
# so it does not need to be a git repo.
REPO_DIR="$TMP_ROOT/repo"
mkdir -p "$REPO_DIR"

PROMPT_FILE="$TMP_ROOT/prompt.txt"
printf 'Implement the thing.\nSecond line.\n' > "$PROMPT_FILE"

run_dispatch() {
  local capture=$1
  shift
  FM_FLOWSTATE_ROOT="$STUB_ROOT" FM_OCPOOL_TEST_STUB_CAPTURE="$capture" \
    node "$CLI" "$@"
}

test_exit_code_mapping() {
  local status expected out status_code capture
  for pair in "verified:0" "blocked:2" "proof_failed:3" "failed:4" "some-unknown-status:4"; do
    status=${pair%%:*}
    expected=${pair##*:}
    capture="$TMP_ROOT/capture-$status.json"
    out=$(FM_OCPOOL_TEST_STUB_STATUS="$status" run_dispatch "$capture" \
      --task-id "map-$status" --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE")
    status_code=$?
    expect_code "$expected" "$status_code" "receipt status $status should map to exit $expected"
    assert_contains "$out" "\"status\": \"$status\"" "receipt for $status missing its own status field"
  done
  pass "receipt status maps to the documented exit code, including an unrecognized status falling back to 4"
}

test_missing_flowstate_diagnostic() {
  local out err status
  out=$(FM_FLOWSTATE_ROOT="$TMP_ROOT/does-not-exist" node "$CLI" \
    --task-id missing-fs --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$TMP_ROOT/missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing.err")
  expect_code 5 "$status" "missing flowstate runner should exit 5"
  assert_contains "$err" "MISSING: flowstate runner at " "missing flowstate runner should print the one-line MISSING diagnostic"
  assert_contains "$err" "does-not-exist/scripts/lib/local-agent-runner.mjs" \
    "missing flowstate runner diagnostic should name the resolved runner path"
  [ -z "$out" ] || fail "missing flowstate runner should not print anything to stdout: $out"
  pass "absent flowstate runner fails closed with a one-line MISSING diagnostic and exit 5"
}

test_agent_orch_depth_refusal() {
  local capture out err status
  capture="$TMP_ROOT/capture-depth-cap.json"
  err_file="$TMP_ROOT/depth-cap.err"
  out=$(AGENT_ORCH_DEPTH=2 FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$capture" \
    --task-id depth-cap --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$err_file")
  status=$?
  err=$(cat "$err_file")
  expect_code 5 "$status" "AGENT_ORCH_DEPTH already at 2 should refuse (mirrors compass-frozen-replay.mjs's parentDepth >= 2)"
  assert_contains "$err" "at or past the spawn-safety hard cap of 2" "depth-cap refusal should name the hard cap"
  [ ! -e "$capture" ] || fail "depth-cap refusal must refuse before ever calling executeLocalTask"

  capture="$TMP_ROOT/capture-depth-ok.json"
  out=$(AGENT_ORCH_DEPTH=1 FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$capture" \
    --task-id depth-ok --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE")
  status=$?
  expect_code 0 "$status" "AGENT_ORCH_DEPTH 1 -> 2 sits exactly at the hard cap and should be allowed"
  assert_present "$capture" "allowed depth boundary should have reached the stub"
  assert_grep '"AGENT_ORCH_DEPTH": "2"' "$capture" "allowed depth boundary should forward the incremented depth"
  pass "AGENT_ORCH_DEPTH refuses only once the child depth would exceed the hard cap of 2"
}

test_prompt_file_not_argv() {
  local capture out status
  capture="$TMP_ROOT/capture-prompt.json"
  out=$(FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$capture" \
    --task-id prompt-delivery --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE")
  expect_code 0 "$?" "prompt-file delivery run should verify"
  assert_present "$capture" "prompt delivery should reach the stub"
  assert_grep 'Implement the thing.' "$capture" "task outcome should carry the prompt file content"
  assert_grep 'Second line.' "$capture" "task outcome should carry every line of the prompt file"

  out=$(node "$CLI" --task-id x --repo "$REPO_DIR" --prompt "inline text should not exist as a flag" 2>&1)
  status=$?
  expect_code 5 "$status" "there must be no --prompt (argv) flag, only --prompt-file"
  assert_contains "$out" "unrecognized argument" "a bare --prompt flag should be rejected as unrecognized, proving no argv prompt path exists"
  pass "prompt text reaches the task packet only via --prompt-file; no argv-based prompt flag exists"
}

test_enforce_mode_defaulting() {
  local capture
  capture="$TMP_ROOT/capture-enforce-default.json"
  run_dispatch "$capture" --task-id enforce-default --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" >/dev/null
  assert_grep '"FLOWSTATE_RESOURCE_GUARD_MODE": "enforce"' "$capture" \
    "FLOWSTATE_RESOURCE_GUARD_MODE should default to enforce when the caller left it unset"

  capture="$TMP_ROOT/capture-enforce-preset.json"
  FLOWSTATE_RESOURCE_GUARD_MODE=report run_dispatch "$capture" \
    --task-id enforce-preset --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" >/dev/null
  assert_grep '"FLOWSTATE_RESOURCE_GUARD_MODE": "report"' "$capture" \
    "an explicitly set FLOWSTATE_RESOURCE_GUARD_MODE should never be overridden"
  pass "FLOWSTATE_RESOURCE_GUARD_MODE defaults to enforce only when the caller did not already set it"
}

test_proof_file_default_and_parsing() {
  local capture
  capture="$TMP_ROOT/capture-proof-default.json"
  run_dispatch "$capture" --task-id proof-default --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" >/dev/null
  assert_grep '"proof": [' "$capture" "default proof should still populate the proof array"
  assert_grep '"git",' "$capture" "default proof should fall back to the documented git status --porcelain sanity command"
  assert_grep '"status",' "$capture" "default proof command should be git status"
  assert_grep '"--porcelain"' "$capture" "default proof command should be git status --porcelain"

  local proof_file="$TMP_ROOT/proof.txt"
  cat > "$proof_file" <<'TXT'
# a comment line, and a blank line follow

["npm", "test"]
["git", "diff", "--check"]
TXT
  capture="$TMP_ROOT/capture-proof-custom.json"
  run_dispatch "$capture" --task-id proof-custom --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" \
    --proof-file "$proof_file" >/dev/null
  assert_grep '"npm",' "$capture" "custom proof file first command should reach the packet"
  assert_grep '"diff",' "$capture" "custom proof file second command should reach the packet"
  pass "proof file defaults to a sanity command and parses one JSON argv array per line, skipping blanks and comments"
}

test_usage_errors() {
  local out status
  out=$(node "$CLI" --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>&1)
  status=$?
  expect_code 5 "$status" "missing --task-id should exit 5"
  assert_contains "$out" "--task-id is required" "missing --task-id should name the flag"

  out=$(node "$CLI" --task-id t --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" --bogus-flag value 2>&1)
  status=$?
  expect_code 5 "$status" "unrecognized flag should exit 5"
  assert_contains "$out" "unrecognized argument: --bogus-flag" "unrecognized flag should be named in the error"
  pass "missing required flags and unrecognized flags are rejected as usage errors with exit 5"
}

test_help() {
  local out status
  out=$(node "$CLI" --help)
  status=$?
  expect_code 0 "$status" "--help should exit 0"
  assert_contains "$out" "Usage:" "help text should include a Usage section"
  assert_contains "$out" "Exit codes:" "help text should document exit codes"
  pass "--help prints usage and exits 0"
}

test_repo_resolved_to_absolute() {
  local capture cwd repo_physical
  capture="$TMP_ROOT/capture-repo-abs.json"
  cwd=$(pwd)
  cd "$TMP_ROOT" || fail "could not cd into TMP_ROOT $TMP_ROOT"
  # node's process.cwd() (and therefore path.resolve()) reports the physical
  # path, which differs from $TMP_ROOT on macOS where /var is a symlink to
  # /private/var; compare against the same physical path node will resolve.
  repo_physical=$(cd repo && pwd -P)
  run_dispatch "$capture" --task-id repo-abs --repo "./repo" --prompt-file "$PROMPT_FILE" >/dev/null
  cd "$cwd" || fail "could not cd back to $cwd"
  assert_grep "\"repo\": \"$repo_physical\"" "$capture" "a relative --repo should be resolved to an absolute path before reaching the packet"
  pass "relative --repo values are resolved to absolute paths"
}

test_model_default_and_override() {
  local capture
  capture="$TMP_ROOT/capture-model-default.json"
  run_dispatch "$capture" --task-id model-default --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" >/dev/null
  assert_grep '"model": "minimax/MiniMax-M3"' "$capture" "model should default to minimax/MiniMax-M3 per the routing contract"

  capture="$TMP_ROOT/capture-model-override.json"
  run_dispatch "$capture" --task-id model-override --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" \
    --model claude-sonnet-5 >/dev/null
  assert_grep '"model": "claude-sonnet-5"' "$capture" "an explicit --model should override the default"
  pass "model defaults to MiniMax-M3 and is overridable via --model"
}

test_json_vs_pretty_output() {
  local pretty compact
  pretty=$(FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$TMP_ROOT/capture-pretty.json" \
    --task-id fmt-pretty --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE")
  compact=$(FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$TMP_ROOT/capture-compact.json" \
    --task-id fmt-compact --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" --json)
  [ "$(printf '%s\n' "$pretty" | wc -l | tr -d ' ')" -gt 1 ] || fail "default output should be pretty-printed across multiple lines"
  [ "$(printf '%s\n' "$compact" | wc -l | tr -d ' ')" -eq 1 ] || fail "--json output should be exactly one line"
  pass "default output is pretty-printed JSON; --json prints one compact line"
}

test_stdout_is_exactly_the_receipt() {
  local out err_file capture
  capture="$TMP_ROOT/capture-stdout-pretty.json"
  err_file="$TMP_ROOT/stdout-pretty.err"
  out=$(FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$capture" \
    --task-id stdout-pretty --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$err_file")
  expect_code 0 "$?" "pretty-mode run should verify"
  printf '%s' "$out" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' \
    || fail "default-mode stdout must parse as exactly one JSON value"
  assert_not_contains "$out" "receiptPath" "stdout must never carry the receiptPath diagnostic"
  assert_grep "receiptPath:" "$err_file" "receiptPath diagnostic should land on stderr in default mode"

  capture="$TMP_ROOT/capture-stdout-json.json"
  err_file="$TMP_ROOT/stdout-json.err"
  out=$(FM_OCPOOL_TEST_STUB_STATUS=verified run_dispatch "$capture" \
    --task-id stdout-json --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" --json 2>"$err_file")
  expect_code 0 "$?" "--json run should verify"
  printf '%s' "$out" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' \
    || fail "--json stdout must parse as exactly one JSON value"
  assert_not_contains "$out" "receiptPath" "stdout must never carry the receiptPath diagnostic in --json mode either"
  assert_grep "receiptPath:" "$err_file" "receiptPath diagnostic should land on stderr in --json mode too"
  pass "stdout is exactly the receipt JSON object in both modes; the receiptPath diagnostic only ever goes to stderr"
}

test_receipt_path_diagnostic_reflects_reality() {
  local state_root capture err_file receipt_file

  # Default: the stub does not persist a receipt file, so the diagnostic
  # must say so honestly rather than just printing the theoretical path.
  # state_root is normalized through the same path.resolve() the bridge
  # itself applies to FM_OCPOOL_DISPATCH_STATE_ROOT - TMP_ROOT can carry a
  # literal double slash on macOS (TMPDIR already ends in "/"), which
  # path.resolve() collapses; comparing against the raw un-normalized string
  # would fail even though the paths are identical on disk.
  state_root=$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$TMP_ROOT/state-root-unwritten")
  capture="$TMP_ROOT/capture-receiptpath-unwritten.json"
  err_file="$TMP_ROOT/receiptpath-unwritten.err"
  FM_OCPOOL_DISPATCH_STATE_ROOT="$state_root" FM_OCPOOL_DISPATCH_RUN_ID="run-unwritten" \
    FM_OCPOOL_TEST_STUB_STATUS=blocked run_dispatch "$capture" \
    --task-id receiptpath-unwritten --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$err_file" >/dev/null
  assert_grep "receiptPath: $state_root/runs/run-unwritten/receiptpath-unwritten.receipt.json (not written to disk for this outcome)" \
    "$err_file" "unwritten receipt should be reported honestly, not assumed present"

  # Opt-in: the stub persists a receipt file exactly like local-agent-
  # runner.mjs's writeReceipt does; the diagnostic must confirm it exists,
  # verified against the real filesystem, not just against receipt status.
  state_root=$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$TMP_ROOT/state-root-written")
  capture="$TMP_ROOT/capture-receiptpath-written.json"
  err_file="$TMP_ROOT/receiptpath-written.err"
  FM_OCPOOL_DISPATCH_STATE_ROOT="$state_root" FM_OCPOOL_DISPATCH_RUN_ID="run-written" \
    FM_OCPOOL_TEST_STUB_STATUS=verified FM_OCPOOL_TEST_STUB_WRITE_RECEIPT=1 run_dispatch "$capture" \
    --task-id receiptpath-written --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$err_file" >/dev/null
  receipt_file="$state_root/runs/run-written/receiptpath-written.receipt.json"
  assert_present "$receipt_file" "test stub should have actually written the receipt file"
  assert_grep "receiptPath: $receipt_file" "$err_file" "written receipt path should be reported"
  assert_no_grep "not written to disk" "$err_file" "written receipt should not carry the not-written caveat"
  pass "the receiptPath diagnostic is checked against the real filesystem, not guessed from receipt status"
}

test_dirty_checkout_needs_captain_not_requeue() {
  local capture err_file out status
  capture="$TMP_ROOT/capture-dirty.json"
  err_file="$TMP_ROOT/dirty.err"
  out=$(FM_OCPOOL_TEST_STUB_STATUS=blocked \
    FM_OCPOOL_TEST_STUB_ERROR="source checkout is dirty; commit/stash it or set allowDirtySource=true explicitly" \
    run_dispatch "$capture" --task-id dirty-checkout --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE" 2>"$err_file")
  status=$?
  expect_code 5 "$status" "a dirty-checkout blocked receipt should exit 5 (needs-captain), not 2 (requeue)"
  assert_contains "$out" '"status": "blocked"' "the receipt itself should still be printed and still say blocked"
  assert_grep "needs captain attention, not an automatic requeue" "$err_file" \
    "dirty-checkout refusal should say plainly why the pool must not just requeue it"

  # Contrast: an ordinary blocked reason (not the dirty-checkout string)
  # keeps the normal requeue-safe exit 2, already covered by
  # test_exit_code_mapping's generic "blocked" case; this just documents the
  # boundary is the error text, not the status alone.
  capture="$TMP_ROOT/capture-not-dirty.json"
  out=$(FM_OCPOOL_TEST_STUB_STATUS=blocked FM_OCPOOL_TEST_STUB_ERROR="resource guard refused spawn: free memory 5% is below 12%" \
    run_dispatch "$capture" --task-id not-dirty-checkout --repo "$REPO_DIR" --prompt-file "$PROMPT_FILE")
  status=$?
  expect_code 2 "$status" "a non-dirty-checkout blocked reason should stay requeue-safe exit 2"
  pass "only the dirty-source-checkout blocked reason is remapped to needs-captain exit 5; other blocked reasons stay requeue-safe exit 2"
}

test_exit_code_mapping
test_missing_flowstate_diagnostic
test_agent_orch_depth_refusal
test_prompt_file_not_argv
test_enforce_mode_defaulting
test_proof_file_default_and_parsing
test_usage_errors
test_help
test_repo_resolved_to_absolute
test_model_default_and_override
test_json_vs_pretty_output
test_stdout_is_exactly_the_receipt
test_receipt_path_diagnostic_reflects_reality
test_dirty_checkout_needs_captain_not_requeue

echo "# all fm-ocpool-dispatch tests passed"
