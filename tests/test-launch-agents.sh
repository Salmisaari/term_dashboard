#!/usr/bin/env bash
# tests/test-launch-agents.sh — validates Quick Add harness registration and commands
# Usage: bash tests/test-launch-agents.sh

set -euo pipefail

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/menubar/td-menubar.swift"
WORKSPACE="${ROOT}/menubar/td-workspace.swift"

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_source() {
  local description="$1"
  local pattern="$2"
  if grep -Fq "$pattern" "$SRC"; then
    ok "$description"
  else
    fail "$description"
  fi
}

echo ""
echo "Test 1: menu bar source typechecks"
if swiftc -typecheck "$SRC"; then
  ok "Swift source typechecks"
else
  fail "Swift source failed to typecheck"
fi

echo ""
echo "Test 2: Hermes is registered in the launch cycle"
assert_source "Hermes enum case exists" "case hermes"
assert_source "Launch cycle includes Hermes" "[.claude, .claudex, .codex, .hermes, .grok]"
assert_source "Hermes display name is configured" 'case .hermes: return "Hermes"'

echo ""
echo "Test 3: Hermes uses its documented approval-bypass flag"
assert_source "Hermes launches with --yolo in classic interactive mode" 'case .hermes: return "hermes --yolo --cli"'
if command -v hermes >/dev/null 2>&1; then
  if hermes --yolo --cli --help >/dev/null; then
    ok "Installed Hermes accepts --yolo --cli"
  else
    fail "Installed Hermes rejected --yolo --cli"
  fi
else
  fail "Hermes executable is not installed"
fi

echo ""
echo "Test 4: Hermes initial prompts are typed after interactive launch"
assert_source "Hermes prompt delivery is delayed until after launch" 'let promptAfterLaunch = agent == .hermes && !prompt.isEmpty'
assert_source "Hermes waits for interactive startup" 'delay 3'
assert_source "Hermes prompt is sent through iTerm after launch" 'write text "\(appleScriptEscaped(prompt))"'

echo ""
echo ""
echo "Test 5: Grok is registered in the launch cycle"
assert_source "Grok enum case exists" "case grok"
assert_source "Launch cycle includes Grok" "[.claude, .claudex, .codex, .hermes, .grok]"
assert_source "Grok display name is configured" 'case .grok: return "Grok"'
assert_source "Grok launches with --always-approve" 'case .grok: return "grok --always-approve"'
if grep -Fq '["claude", "claudex", "codex", "hermes", "grok"]' "$WORKSPACE"; then
  ok "Native workspace cycle includes Grok"
else
  fail "Native workspace cycle includes Grok"
fi
if grep -Fq '"grok": ["grok", "--always-approve"]' "$ROOT/dashboard/native.py"; then
  ok "Native launch command uses grok --always-approve"
else
  fail "Native launch command uses grok --always-approve"
fi
if command -v grok >/dev/null 2>&1; then
  if grok --always-approve --help >/dev/null; then
    ok "Installed Grok accepts --always-approve"
  else
    fail "Installed Grok rejected --always-approve"
  fi
else
  fail "Grok executable is not installed"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
