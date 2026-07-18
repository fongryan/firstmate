#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="$ROOT/bin/fm-agent-profile-route.mjs"
output="$(node "$ROUTER" route-test flowstate implement opencode 'fix a failing regression test' )"
node -e '
const value = JSON.parse(process.argv[1]);
if (value.schemaVersion !== "agent-profile-route-receipt@1") throw new Error("wrong receipt schema");
if (!value.profileId) throw new Error("missing profile id");
if (!Array.isArray(value.reasonCodes)) throw new Error("missing reason codes");
if (!value.degraded && value.profileId !== "implement") throw new Error(`unexpected route: ${value.profileId}`);
console.log(`ok - route receipt profile=${value.profileId} degraded=${value.degraded}`);
' "$output"
