#!/bin/bash
# release-bin-path.sh — regression test: release.sh must not hard-code the
# universal build product's location. Swift 6.4's build backend writes the
# arm64+x86_64 product to .build/out/Products/Release, not the
# .build/apple/Products/Release this script assumed; a hard-coded path
# silently breaks step 1 ("built binary not found") the moment the
# toolchain relocates its output again. The script must ask SwiftPM via
# `swift build --show-bin-path` instead of guessing the layout.
#
# Same defect, same fix, already hit for real and landed on che-word-mcp
# main at commit 35fd804 (v4.0.11 stopped at step 1 before any signing
# happened). Ported here before PsychQuant/che-pptx-mcp#2 merges so the
# isolated-worktree build this PR adds doesn't inherit the same bug.
#
# Refs PsychQuant/che-pptx-mcp#2, PsychQuant/che-word-mcp#195.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE_SCRIPT="$ROOT/scripts/release.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/release-bin-path-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

BINARY_NAME=$(sed -n 's/^BINARY_NAME="\([^"]*\)"/\1/p' "$SOURCE_SCRIPT" | head -1)
TEST_VERSION=$(grep -h 'static let serverVersion' "$ROOT"/Sources/*/Server.swift 2>/dev/null \
    | sed -n 's/.*"\([0-9][^"]*\)".*/\1/p' | head -1 || true)
[ -n "$TEST_VERSION" ] || TEST_VERSION=9.9.9

REPO="$TEST_ROOT/repo"
FAKE_PATH="$TEST_ROOT/fake-path"
EVENT_LOG="$TEST_ROOT/events.log"
mkdir -p "$REPO/scripts" "$FAKE_PATH"
cp "$SOURCE_SCRIPT" "$REPO/scripts/release.sh"
echo original > "$REPO/source.txt"
echo '.build/' > "$REPO/.gitignore"
SERVER_FILE=$(grep -l 'static let serverVersion' "$ROOT"/Sources/*/Server.swift 2>/dev/null | head -1 || true)
if [ -n "$SERVER_FILE" ]; then
    SERVER_RELATIVE=${SERVER_FILE#"$ROOT"/}
    mkdir -p "$REPO/$(dirname "$SERVER_RELATIVE")"
    cp "$SERVER_FILE" "$REPO/$SERVER_RELATIVE"
fi

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm baseline
git init -q --bare "$TEST_ROOT/origin.git"
git -C "$REPO" remote add origin "$TEST_ROOT/origin.git"

cat > "$FAKE_PATH/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ]; then exit 0; fi
exec /usr/bin/git "$@"
EOF

# Simulates the Swift 6.4 build backend: the universal product lands under
# .build/out/Products/Release (NOT .build/apple/Products/Release), and the
# only way to learn that without hard-coding it is `--show-bin-path`.
cat > "$FAKE_PATH/swift" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "test" ]; then exit 0; fi
for arg in "$@"; do
    if [ "$arg" = "--show-bin-path" ]; then
        echo "$(pwd)/.build/out/Products/Release"
        exit 0
    fi
done
mkdir -p .build/out/Products/Release
cat > ".build/out/Products/Release/$BINARY_NAME" <<'BIN'
#!/bin/bash
echo test-binary
BIN
chmod +x ".build/out/Products/Release/$BINARY_NAME"
EOF

cat > "$FAKE_PATH/codesign" <<'EOF'
#!/bin/bash
echo codesign >> "$EVENT_LOG"
exit 0
EOF

cat > "$FAKE_PATH/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun:$*" >> "$EVENT_LOG"
if [ "${2:-}" = "submit" ]; then echo 'status: Accepted'; fi
exit 0
EOF

cat > "$FAKE_PATH/lipo" <<'EOF'
#!/bin/bash
echo 'arm64 x86_64'
EOF

cat > "$FAKE_PATH/ditto" <<'EOF'
#!/bin/bash
last=""
for last in "$@"; do :; done
: > "$last"
EOF

cat > "$FAKE_PATH/gh" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then exit 1; fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "create" ]; then
    echo "gh-release-create:$*" >> "$EVENT_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_PATH"/*

: > "$EVENT_LOG"
set +e
(
    cd "$REPO"
    EVENT_LOG="$EVENT_LOG" BINARY_NAME="$BINARY_NAME" PATH="$FAKE_PATH:$PATH" \
        bash scripts/release.sh "$TEST_VERSION"
) >"$TEST_ROOT/output.log" 2>&1
RC=$?
set -e

[[ "$RC" -eq 0 ]] || {
    echo "FAIL: release.sh could not find the built binary once the toolchain's build output moved to .build/out/Products/Release; got exit $RC (hard-coded path assumption?)" >&2
    cat "$TEST_ROOT/output.log" >&2
    exit 1
}
grep -q '^codesign$' "$EVENT_LOG"
grep -q "^gh-release-create:" "$EVENT_LOG"

echo "PASS: release.sh resolves the binary path via 'swift build --show-bin-path' instead of a hard-coded location"
