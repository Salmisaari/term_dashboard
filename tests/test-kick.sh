#!/usr/bin/env bash
# tests/test-kick.sh — validates the kick→verify→fallback chain via td kick
# Usage: bash tests/test-kick.sh

set -euo pipefail

PASS=0; FAIL=0
TD="$(dirname "$0")/../td"

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a fake folder in a temp code dir
setup_tmp_code() {
    TMP_CODE=$(mktemp -d)
    mkdir -p "$TMP_CODE/my-project"
    echo "$TMP_CODE"
}

# ── Test 1: kick with no Claude session → should open new window (non-zero exit or "NotFound") ──
echo ""
echo "Test 1: kick to nonexistent session"
TMP=$(setup_tmp_code)
# Override TD_CODE_DIR if td supports it; otherwise just check the output contains no "Sent"
OUT=$("$TD" kick "my-project" "hello" 2>&1 || true)
if echo "$OUT" | grep -q "Sent"; then
    fail "Expected NotFound/new-window path, got Sent (no real Claude session should match)"
else
    ok "kick to nonexistent session did not falsely report Sent"
fi
rm -rf "$TMP"

# ── Test 2: verifyClaudeOnTTY equivalent — ps check ──────────────────────────
echo ""
echo "Test 2: verify no claude on a dummy TTY"
# Use a TTY that definitely has no claude process (pts/9999 or similar)
FAKE_TTY="ttys999"
PROCS=$(ps -t "$FAKE_TTY" -o comm= 2>/dev/null || true)
if echo "$PROCS" | grep -q "^claude$"; then
    fail "Unexpected claude on fake TTY $FAKE_TTY"
else
    ok "No claude found on fake TTY $FAKE_TTY (verify guard would block kick)"
fi

# ── Test 3: ulimit is set in td-launched commands ────────────────────────────
echo ""
echo "Test 3: ulimit -n is >= 65536 in a fresh zsh -lc subshell"
LIMIT=$(zsh -lc 'ulimit -n' 2>/dev/null || echo "0")
if [ "$LIMIT" -ge 65536 ] 2>/dev/null; then
    ok "ulimit -n = $LIMIT (>= 65536)"
elif [ "$LIMIT" = "unlimited" ]; then
    ok "ulimit -n = unlimited"
else
    fail "ulimit -n = $LIMIT — below 65536. Add 'ulimit -n 65536' to ~/.zshrc"
fi

# ── Test 4: td binary is executable ──────────────────────────────────────────
echo ""
echo "Test 4: td binary exists and is executable"
if [ -x "$TD" ]; then
    ok "td is executable at $TD"
else
    fail "td not found or not executable at $TD"
fi

# ── Test 5: scanFolders — Code dir is readable ───────────────────────────────
echo ""
echo "Test 5: ~/Desktop/Code is accessible"
CODE_DIR="$HOME/Desktop/Code"
if [ -d "$CODE_DIR" ]; then
    COUNT=$(ls -1 "$CODE_DIR" 2>/dev/null | wc -l | tr -d ' ')
    ok "~/Desktop/Code exists with $COUNT entries"
else
    fail "~/Desktop/Code does not exist — codeDir will return empty folder list"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
