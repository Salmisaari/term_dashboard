#!/usr/bin/env bash
# install.sh — symlink td to ~/bin and optionally configure Claude Code hooks
set -euo pipefail

TD_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/bin"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
HOOK_SCRIPT="${HOME}/.config/td/hooks/td-hook.sh"

echo "td — Term Dashboard installer"
echo ""

# ── 1. Symlink td to ~/bin ──────────────────────────────────────────

mkdir -p "$BIN_DIR"

if [[ -L "${BIN_DIR}/td" ]]; then
  echo "Updating symlink: ${BIN_DIR}/td → ${TD_DIR}/td"
  ln -sf "${TD_DIR}/td" "${BIN_DIR}/td"
elif [[ -e "${BIN_DIR}/td" ]]; then
  echo "Warning: ${BIN_DIR}/td already exists and is not a symlink. Skipping."
else
  echo "Creating symlink: ${BIN_DIR}/td → ${TD_DIR}/td"
  ln -s "${TD_DIR}/td" "${BIN_DIR}/td"
fi

# ── 2. Symlink hook script to ~/.config/td/hooks/ ──────────────────

mkdir -p "$(dirname "$HOOK_SCRIPT")"
if [[ -L "$HOOK_SCRIPT" ]]; then
  ln -sf "${TD_DIR}/hooks/td-hook.sh" "$HOOK_SCRIPT"
elif [[ ! -e "$HOOK_SCRIPT" ]]; then
  ln -s "${TD_DIR}/hooks/td-hook.sh" "$HOOK_SCRIPT"
fi
echo "Hook script: $HOOK_SCRIPT"

# ── 3. Replace tile-terms with td tile ──────────────────────────────

if [[ -f "${BIN_DIR}/tile-terms" && ! -L "${BIN_DIR}/tile-terms" ]]; then
  echo ""
  echo "Found standalone tile-terms at ${BIN_DIR}/tile-terms"
  read -rp "Replace with wrapper that calls 'td tile'? [y/N] " answer
  if [[ "$answer" =~ ^[Yy] ]]; then
    mv "${BIN_DIR}/tile-terms" "${BIN_DIR}/tile-terms.bak"
    cat > "${BIN_DIR}/tile-terms" <<'WRAPPER'
#!/usr/bin/env bash
exec td tile "$@"
WRAPPER
    chmod +x "${BIN_DIR}/tile-terms"
    echo "Replaced. Original backed up to tile-terms.bak"
  fi
fi

# ── 4. Configure Claude Code hooks ──────────────────────────────────

echo ""
echo "Claude Code hooks enable status tracking (which session is doing what)."
read -rp "Add td hooks to ${CLAUDE_SETTINGS}? [y/N] " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    echo '{}' > "$CLAUDE_SETTINGS"
  fi

  # Backup existing settings
  cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.backup-td"

  # Add hooks using jq, preserving existing hooks
  # Claude Code hook format: hooks.<Event> is an array of {hooks: [{type, command}]}
  tmp="$(jq --arg hook "$HOOK_SCRIPT" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.Stop //= [] |
    .hooks.UserPromptSubmit //= [] |

    # Only add if not already present (check nested hooks arrays)
    (if ([.hooks.SessionStart[]?.hooks[]? | select(.command | contains("td-hook"))] | length) == 0
     then .hooks.SessionStart += [{"hooks": [{"type": "command", "command": ($hook + " start")}]}]
     else . end) |

    (if ([.hooks.Stop[]?.hooks[]? | select(.command | contains("td-hook"))] | length) == 0
     then .hooks.Stop += [{"hooks": [{"type": "command", "command": ($hook + " stop")}]}]
     else . end) |

    (if ([.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | contains("td-hook"))] | length) == 0
     then .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": ($hook + " prompt")}]}]
     else . end)
  ' "$CLAUDE_SETTINGS")"
  echo "$tmp" > "$CLAUDE_SETTINGS"
  echo "Hooks added to $CLAUDE_SETTINGS"
  echo "(Backup saved to ${CLAUDE_SETTINGS}.backup-td)"
else
  echo "Skipped hook installation. You can add them manually later."
fi

# ── 5. Verify PATH ──────────────────────────────────────────────────

echo ""
if echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
  echo "✓ ${BIN_DIR} is in your PATH"
else
  echo "⚠ ${BIN_DIR} is not in your PATH. Add to your shell profile:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
fi

echo ""
echo "Done! Try 'td help' to get started."
echo "Register projects with: td projects add <name> <path>"
