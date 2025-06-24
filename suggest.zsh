# Only run in interactive shells
if [[ ! -o interactive ]]; then
  echo "Shell is not interactive, AI suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

AI_SHELL_PATH="$HOME/.ai-shell/ai-shell.py"
AI_SUGGESTION=""

# Clear suggestion from display
function ai_clear_suggestion_display() {
  printf '\e7'    # Save cursor
  printf '\e[0K'  # Clear to end of line
  printf '\e8'    # Restore cursor
}

# Show gray suggestion
function ai_preview_suggestion() {
  local input="$LBUFFER"
  local output addition

  # Run AI
  output="$(python3 "$AI_SHELL_PATH" "$input")"

  # Clear old
  ai_clear_suggestion_display

  if [[ -n "$output" && "$output" != "$input" && "$output" == "$input"* ]]; then
    addition="${output#$input}"
    printf '\e7'        # Save cursor
    printf '\e[90m%s\e[0m' "$addition"
    printf '\e8'        # Restore cursor
    AI_SUGGESTION="$output"
  else
    AI_SUGGESTION=""
  fi
}

# Accept suggestion
function ai_accept_suggestion() {
  local input="$LBUFFER"
  if [[ -n "$AI_SUGGESTION" && "$AI_SUGGESTION" == "$input"* ]]; then
    local addition="${AI_SUGGESTION#$input}"
    LBUFFER+="$addition"
    AI_SUGGESTION=""
    zle reset-prompt
  else
    zle expand-or-complete
  fi
}

# On any input
function ai_wrap_self_insert() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
  fi
  zle .self-insert
}

# On backspace
function ai_wrap_backward_delete_char() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
  fi
  zle .backward-delete-char
}

# Define widgets
zle -N ai_preview_suggestion
zle -N ai_accept_suggestion
zle -N ai_wrap_self_insert
zle -N ai_wrap_backward_delete_char

# Bind keys
bindkey self-insert ai_wrap_self_insert # Typing
bindkey '^?' ai_wrap_backward_delete_char # Backspace
bindkey '^I' ai_accept_suggestion # Tab
bindkey '^[p' ai_preview_suggestion # Alt+P preview
