# Only run in interactive shells
if [[ ! -o interactive ]]; then
  echo "Shell is not interactive, AI suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

AI_SHELL_PATH="$HOME/.ai-shell/ai-shell.py"
AI_SUGGESTION=""
AI_LAST_INPUT=""
AI_IDLE_TIMEOUT=1  # seconds idle before showing suggestion
AI_IDLE_TIMER_FD=0
AI_LAST_INPUT_TIME=0
AI_TIMER_FIFO="/tmp/ai_idle_timer_fifo_$$"
AI_PREVIEW_GENERATED=0
AI_COMPLETION_ACTIVE=0

# Clear suggestion from display
function ai_clear_suggestion_display() {
  printf '\e7'    # Save cursor
  printf '\e[0K'  # Clear to end of line
  printf '\e8'    # Restore cursor
}

# Show gray suggestion only if input changed since last time
function ai_preview_suggestion() {
  local input="$LBUFFER"

  if (( AI_COMPLETION_ACTIVE )) || [[ "$input" == "$AI_LAST_INPUT" || $AI_PREVIEW_GENERATED == 1 ]]; then
    return
  fi

  AI_PREVIEW_GENERATED=1
  AI_LAST_INPUT="$input"

  local output addition
  output="$(python3 "$AI_SHELL_PATH" "$input")"

  ai_clear_suggestion_display

  if [[ -n "$output" && "$output" != "$input" && "$output" == "$input"* ]]; then
    addition="${output#$input}"
    printf '\e7'
    printf '\e[90m%s\e[0m' "$addition"
    printf '\e8'
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
    AI_LAST_INPUT=""
    zle reset-prompt
  else
    zle ai_wrap_expand_or_complete
  fi
  AI_PREVIEW_GENERATED=0
}

# On any input: reset idle timer & clear suggestion
function ai_wrap_self_insert() {
  ai_reset_idle_timer
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
  fi
  zle .self-insert
  AI_PREVIEW_GENERATED=0
  AI_COMPLETION_ACTIVE=0
}

# Special char ñ input
function ai_wrap_self_insert_ñ() {
  ai_reset_idle_timer
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
  fi
  LBUFFER+="ñ"
  AI_PREVIEW_GENERATED=0
  AI_COMPLETION_ACTIVE=0
}

# On backspace: reset timer & clear suggestion
function ai_wrap_backward_delete_char() {
  ai_reset_idle_timer
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
  fi
  zle .backward-delete-char
  AI_PREVIEW_GENERATED=0
  AI_COMPLETION_ACTIVE=0
}

# On enter: clear suggestion
function ai_wrap_accept_line() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
  fi
  AI_PREVIEW_GENERATED=0
  AI_COMPLETION_ACTIVE=0
  zle .accept-line
}

function ai_wrap_expand_or_complete() {
  AI_COMPLETION_ACTIVE=1
  zle expand-or-complete
}

# Called by periodic timer (via zle -F)
function ai_idle_check() {
  # Drain FIFO input to prevent blocking
  read -r -t 0.01 <&$AI_IDLE_TIMER_FD || true

  local now=$(date +%s)
  local elapsed=$(( now - AI_LAST_INPUT_TIME ))

  if (( elapsed >= AI_IDLE_TIMEOUT  && AI_PREVIEW_GENERATED == 0 && AI_COMPLETION_ACTIVE == 0 )); then
    zle -M ""  # Clear messages
    zle ai_preview_suggestion
    ai_reset_idle_timer
  fi
}

# Reset last input time on any input
function ai_reset_idle_timer() {
  AI_LAST_INPUT_TIME=$(date +%s)
}

# Define widgets
zle -N ai_preview_suggestion
zle -N ai_accept_suggestion
zle -N ai_wrap_self_insert
zle -N ai_wrap_self_insert_ñ
zle -N ai_wrap_backward_delete_char
zle -N ai_wrap_accept_line
zle -N ai_wrap_expand_or_complete

# Bind keys
function bind_ai_wrap_self_insert() {
  for code in {32..126}; do
    local key=$(printf "\\$(printf '%03o' $code)")
    if [[ "$key" != "-" ]]; then
      bindkey -- "$key" ai_wrap_self_insert
    fi
  done
  bindkey -- "ñ" ai_wrap_self_insert_ñ
}
bind_ai_wrap_self_insert

bindkey '^?' ai_wrap_backward_delete_char # Backspace
bindkey '^I' ai_accept_suggestion # Tab
bindkey '^[p' ai_preview_suggestion # Alt+P preview
bindkey '^M' ai_wrap_accept_line # Enter

# Load datetime module
zmodload zsh/datetime

# Initialize timer
ai_reset_idle_timer

# Create named FIFO for timer events
if [[ -p $AI_TIMER_FIFO ]]; then
  rm -f $AI_TIMER_FIFO
fi
mkfifo $AI_TIMER_FIFO

# Background loop sending newlines into FIFO
(
  while true; do
    sleep $AI_IDLE_TIMEOUT
    echo > $AI_TIMER_FIFO
  done
) &!

# Save PID to kill later
AI_TIMER_PID=$!


# Open FIFO fd for reading, save to AI_IDLE_TIMER_FD
exec {AI_IDLE_TIMER_FD}<>$AI_TIMER_FIFO

# Register fd watcher for zle to call idle check on timer events
zle -F $AI_IDLE_TIMER_FD ai_idle_check

# Cleanup on shell exit
function ai_cleanup() {
  zle -F $AI_IDLE_TIMER_FD
  exec {AI_IDLE_TIMER_FD}>&-
  kill $AI_TIMER_PID 2>/dev/null
  rm -f $AI_TIMER_FIFO
}
TRAPEXIT() { ai_cleanup }
