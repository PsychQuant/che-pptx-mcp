#!/bin/bash
# ci-and-release-docs.sh — regression test for PsychQuant/che-pptx-mcp#4.
#
# 1. A CI workflow exists that, on push and pull_request, runs every
#    scripts/tests/*.sh (by glob, so a new harness is picked up without
#    editing the workflow) plus shellcheck — and never signs, notarizes,
#    uploads or reads secrets.
# 2. README's "Release 流程" section describes the pipeline scripts/release.sh
#    actually runs: every "→ [n/7]" step label in the script appears in the
#    README, together with the isolated-worktree / SOURCE_HEAD / drift-gate
#    design PR #3 added. A step added to the script without the README
#    following fails here.
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

if [[ ! -f "$WORKFLOW" ]]; then
    fail "missing $WORKFLOW"
else
    grep -qE '^[[:space:]]*push:' "$WORKFLOW" || fail "workflow does not run on push"
    grep -qE '^[[:space:]]*pull_request:' "$WORKFLOW" || fail "workflow does not run on pull_request"
    grep -q 'scripts/tests/\*\.sh' "$WORKFLOW" || fail "workflow does not run scripts/tests/*.sh by glob"
    grep -qE '^[[:space:]]*(run: )?shellcheck ' "$WORKFLOW" || fail "workflow does not run shellcheck"
    # No signing, notarization, upload or secrets in CI (release stays a
    # maintainer-run, keychain-backed step).
    if grep -nE 'codesign|notarytool|scripts/release\.sh|gh release|secrets\.' "$WORKFLOW" \
        | grep -vE '^[0-9]+:[[:space:]]*#'; then
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
echo "PASS: CI runs every scripts/tests harness + shellcheck without signing, and README's Release section matches release.sh"
