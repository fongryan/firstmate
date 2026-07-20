#!/usr/bin/env bash
#!/usr/bin/env bash
# fm-profile-inject.sh — Captain Prompt Profile injector (Phase 3)
#
# Appends a "Captain preferences" section to a brief.md file based on the
# current PROFILE.compact.md at brain/vault/60_Concepts/captain-prompt-profile/.
#
# Called from:
#   - fm-brief.sh after scaffold (every ship/scout/secondmate brief)
#   - fm-spawn.sh before launch (runtime override — re-injects latest profile)
#
# Per-brief section selection (locked 2026-07-10):
#   ship briefs       → autonomy_ramp, output_style, anti_patterns, communication_protocol
#   scout briefs      → topic_map, prioritization, decision_style, anti_patterns
#   planning briefs   → prompt_shape, communication_protocol, prioritization
#   review briefs     → feedback_grammar, anti_patterns, output_style
#   secondmate charter → all 12 fields (the home is the captain's runtime)
#   default           → output_style, anti_patterns
#
# Per captain-stack rule 11 (no parallel authority): this script READS the
# canonical PROFILE.compact.md; it does NOT write back to it. The distiller
# (brain/src/brain/profile-distiller.mjs) is the sole owner of PROFILE.md.
#
# Locking: this script never mutates firstmate state (no .meta writes,
# no lock acquisition). It's read-only against the brain vault.

set -euo pipefail

# Resolve brain vault root. Search in priority order:
#   1. BRAIN_ROOT env var (set by callers like firstmate)
#   2. Firstmate's canonical clone (where ships land)
#   3. Captain's hot checkout at /Users/ryanfong/workspace/brain
BRAIN_ROOT="${BRAIN_ROOT:-}"
if [ -z "$BRAIN_ROOT" ]; then
  for candidate in \
    "/Users/ryanfong/workspace/firstmate/projects/brain" \
    "/Users/ryanfong/workspace/brain"; do
    if [ -d "$candidate/vault/60_Concepts/captain-prompt-profile" ]; then
      BRAIN_ROOT="$candidate"
      break
    fi
  done
fi
if [ -z "$BRAIN_ROOT" ]; then
  echo "warn: cannot locate brain vault; profile not injected" >&2
  exit 0
fi

PROFILE_PATH="$BRAIN_ROOT/vault/60_Concepts/captain-prompt-profile/PROFILE.md"
PROFILE_COMPACT_PATH="$BRAIN_ROOT/vault/60_Concepts/captain-prompt-profile/PROFILE.compact.md"

BRIEF_PATH="${1:?usage: fm-profile-inject.sh <brief-path> [<kind>]}"
KIND="${2:-ship}"

if [ ! -f "$BRIEF_PATH" ]; then
  echo "warn: brief not found at $BRIEF_PATH; skipping profile inject" >&2
  exit 0
fi

# Detect kind from brief content if not passed
if [ "${2:-}" = "" ]; then
  if grep -q "SCOUT task" "$BRIEF_PATH"; then KIND="scout"
  elif grep -q "persistent domain supervisor\|secondmate" "$BRIEF_PATH"; then KIND="secondmate"
  elif grep -q "review.*profile\|feedback.*grammar" "$BRIEF_PATH"; then KIND="review"
  elif grep -q "plan.*architecture\|planning.*agent" "$BRIEF_PATH"; then KIND="planning"
  else KIND="ship"
  fi
fi

# Section selection
case "$KIND" in
  ship)       SECTIONS="autonomy_ramp output_style anti_patterns communication_protocol" ;;
  scout)      SECTIONS="topic_map prioritization decision_style anti_patterns" ;;
  planning)   SECTIONS="prompt_shape communication_protocol prioritization" ;;
  review)     SECTIONS="feedback_grammar anti_patterns output_style" ;;
  secondmate) SECTIONS="autonomy_ramp output_style anti_patterns prompt_shape feedback_grammar" ;;
  *)          SECTIONS="output_style anti_patterns" ;;
esac

# Don't re-inject if already present
if grep -q "^# Captain preferences (auto-injected" "$BRIEF_PATH"; then
  exit 0
fi

INJECT=""
if [ -f "$PROFILE_COMPACT_PATH" ]; then
  # Compact profile exists — use the whole file as the injection.
  # The compact file is already <500 tokens; fits any crewmate's context.
  INJECT="$(cat "$PROFILE_COMPACT_PATH")"
elif [ -f "$PROFILE_PATH" ]; then
  # Fallback: extract per-section from the full PROFILE.md via awk.
  INJECT="$(awk -v sections="$SECTIONS" '
    BEGIN { in_section = 0; out = "" }
    /^### / {
      if (match($0, /^### +[0-9]*\.?([a-z_]+)/, m)) {
        section = m[1]
        in_section = 1
        out = ""
        next
      }
    }
    in_section && /^```yaml/ { in_yaml = 1; next }
    in_section && /^```/ {
      in_yaml = 0
      # Emit
      n = split(sections, a, " ")
      for (i = 1; i <= n; i++) if (section == a[i]) { printf "### %s\n%s\n\n", section, out; break }
      in_section = 0
      next
    }
    in_yaml { out = out $0 "\n" }
  ' "$PROFILE_PATH")"
fi

if [ -z "$INJECT" ]; then
  echo "warn: profile not found; brief at $BRIEF_PATH will not get profile injection" >&2
  exit 0
fi

# Append. Use printf to preserve literal content.
{
  printf '\n# Captain preferences (auto-injected from PROFILE.compact.md)\n\n'
  printf '%s\n' "$INJECT"
  printf '\n> Auto-injected by fm-profile-inject.sh at %s. Source: %s.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROFILE_COMPACT_PATH"
  printf '> Sections selected for kind=%s: %s\n' "$KIND" "$SECTIONS"
} >> "$BRIEF_PATH"

echo "ok: profile injected into $BRIEF_PATH (kind=$KIND, sections=$SECTIONS)" >&2
