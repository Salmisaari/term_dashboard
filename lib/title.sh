# Set iTerm2 window/tab title once, to the folder the session opened in.
# Static: does not update on cd.
if [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
  printf '\033]0;%s\007' "$(basename "$PWD")"
  # Prevent iTerm2's shell integration from overwriting the title later.
  export DISABLE_AUTO_TITLE="true"
fi
