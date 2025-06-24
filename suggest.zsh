# Only run in interactive shells
if [[ ! -o interactive ]]; then
  echo "Shell is not interactive, AI suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

AI_SHELL_PATH="$HOME/.ai-shell/ai-shell.py"
AI_SUGGESTION=""

AI_IDLE_TIMEOUT=1 # seconds of idle before showing suggestion
AI_IDLE_TIMER=0

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

# On special character input
function ai_wrap_self_insert_ñ() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
  fi
  LBUFFER+="ñ"
}

# On backspace
function ai_wrap_backward_delete_char() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
  fi
  zle .backward-delete-char
}

function bind_ai_wrap_self_insert() {
for code in {32..126}; do
  key=$(printf "\\$(printf '%03o' $code)")
  if [[ "$key" != "-" ]]; then
    bindkey -- "$key" ai_wrap_self_insert
  fi
done
bindkey -- "ñ" ai_wrap_self_insert_ñ
}

# Define widgets
zle -N ai_preview_suggestion
zle -N ai_accept_suggestion
zle -N ai_wrap_self_insert
zle -N ai_wrap_self_insert_ñ
zle -N ai_wrap_backward_delete_char

# Bind keys
bind_ai_wrap_self_insert
bindkey '^?' ai_wrap_backward_delete_char # Backspace
bindkey '^I' ai_accept_suggestion # Tab
bindkey '^[p' ai_preview_suggestion # Alt+P preview
