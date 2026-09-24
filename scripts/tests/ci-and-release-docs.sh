#!/bin/bash
# ci-and-release-docs.sh — regression test for PsychQuant/che-pptx-mcp#4.
#
# 1. A CI workflow exists that, on push and pull_request, runs every
#    scripts/tests/*.sh (by glob, so a new harness is picked up without
#    editing the workflow) plus shellcheck — and never signs, notarizes,
#    uploads or reads secrets.
# 2. README's "Release 流程" section covers the pipeline scripts/release.sh
#    actually runs: every "→ [n/7]" step label in the script appears in the
#    README, together with the isolated-worktree / SOURCE_HEAD / drift-gate
#    design PR #3 added. A step added to the script without the README
#    following fails here. (Coverage, not correctness: the prose itself is
#    reviewed by people.)
#
# Refs PsychQuant/che-pptx-mcp#4.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/ci.yml"
README="$ROOT/README.md"
RELEASE="$ROOT/scripts/release.sh"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# --- 1. CI workflow --------------------------------------------------------
#
# A smoke test of the workflow text, not a YAML or Actions validator: full-line
# comments are dropped first, so a pattern only counts where it is live.

if [[ ! -f "$WORKFLOW" ]]; then
    fail "missing $WORKFLOW"
else
    live=$(grep -vE '^[[:space:]]*#' "$WORKFLOW")
    # Triggers: the top-level `on:` block, up to the next top-level key.
    triggers=$(awk '/^on:/{flag=1; next} /^[^[:space:]#]/{flag=0} flag' <<<"$live")
    grep -qE '^[[:space:]]+push:' <<<"$triggers" || fail "workflow's on: block has no push trigger"
    grep -qE '^[[:space:]]+pull_request:' <<<"$triggers" || fail "workflow's on: block has no pull_request trigger"
    grep -qE '\(scripts/tests/\*\.sh\)' <<<"$live" || fail "workflow does not collect scripts/tests/*.sh by glob"
    # shellcheck disable=SC2016  # a literal `$t` in the workflow text, not an expansion
    grep -qF 'bash "$t"' <<<"$live" || fail "workflow does not run each collected harness with bash"
    grep -qE '^[[:space:]]*(run: )?shellcheck scripts/' <<<"$live" || fail "workflow does not run shellcheck on scripts/"
    # No signing, notarization, upload or secrets in CI (release stays a
    # maintainer-run, keychain-backed step).
    if grep -nE 'codesign|notarytool|scripts/release\.sh|gh release|secrets\.' <<<"$live"; then
        fail "workflow must not sign, notarize, release or use secrets (lines above)"
    fi
fi

# --- 2. README Release section matches release.sh --------------------------

section=$(awk '/^## Release/{flag=1; next} /^## /{flag=0} flag' "$README")
[[ -n "$section" ]] || fail "README has no '## Release' section"

steps=$(grep -oE '→ \[[0-9.]+/[0-9]+\]' "$RELEASE" | sed 's/^→ //' | sort -u)
[[ -n "$steps" ]] || fail "no '→ [n/N]' step labels found in scripts/release.sh"
while IFS= read -r step; do
    [[ -z "$step" ]] && continue
    grep -qF "$step" <<<"$section" || fail "README Release section does not describe release.sh step $step"
done <<<"$steps"

for concept in 'SOURCE_HEAD' 'git worktree' 'exit 3' 'scripts/tests/'; do
    grep -qF "$concept" <<<"$section" || fail "README Release section does not mention '$concept'"
done

if (( failures > 0 )); then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "PASS: CI workflow runs every scripts/tests harness + shellcheck without signing; README's Release section covers every release.sh step"
