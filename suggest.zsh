# Only run in interactive shells
if [[ ! -o interactive ]]; then
  echo "Shell is not interactive, AI suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

AI_SHELL_PATH="$HOME/.ai-shell/ai-shell.py"
AI_SUGGESTION=""
AI_LAST_INPUT=""
AI_IDLE_TIMEOUT=2  # seconds idle before showing suggestion
AI_IDLE_TIMER_FD=0
AI_LAST_INPUT_TIME=0
AI_TIMER_FIFO="/tmp/ai_idle_timer_fifo_$$"
AI_PREVIEW_GENERATED=0
AI_COMPLETION_ACTIVE=0

AI_PY_PID=0
AI_PY_OUTPUT_FILE="/tmp/ai_shell_output_$$"
AI_PY_RUNNING=0

# Clear suggestion from display
function ai_clear_suggestion_display() {
  printf '\e7'    # Save cursor
  printf '\e[0K'  # Clear to end of line
  printf '\e8'    # Restore cursor
}

# Show gray suggestion only if input changed since last time
# Runs python asynchronously without blocking
function ai_preview_suggestion() {
  local input="$LBUFFER"

  # Do not preview if completion active, input unchanged, or preview already generated
  if (( AI_COMPLETION_ACTIVE )) || [[ "$input" == "$AI_LAST_INPUT" || $AI_PREVIEW_GENERATED == 1 ]]; then
    return
  fi

  # Only preview if cursor at end of LBUFFER
  if [[ -n "$RBUFFER" ]]; then
    return
  fi

  # Kill previous python job if still running to keep only one
  if (( AI_PY_RUNNING )) && kill -0 $AI_PY_PID 2>/dev/null; then
    kill $AI_PY_PID 2>/dev/null
    wait $AI_PY_PID 2>/dev/null
  fi

  AI_PREVIEW_GENERATED=0
  AI_LAST_INPUT="$input"
  AI_PY_RUNNING=1

  # Disable job control messages
  set +m

  # Run python async, silently redirect output to temp file
  python3 "$AI_SHELL_PATH" "$input" > "$AI_PY_OUTPUT_FILE" 2>/dev/null &

  AI_PY_PID=$!
  disown

  # Re-enable job control messages
  set -m
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

function ai_wrap_forward_char() {
  ai_reset_idle_timer
  zle .forward-char
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

function ai_wrap_backward_char() {
  ai_reset_idle_timer
  zle .backward-char
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

function ai_wrap_up_line() {
  ai_reset_idle_timer
  zle up-line-or-beginning-search
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

function ai_wrap_down_line() {
  ai_reset_idle_timer
  zle down-line-or-beginning-search
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

function ai_wrap_beginning_of_line() {
  ai_reset_idle_timer
  zle .beginning-of-line
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

function ai_wrap_end_of_line() {
  ai_reset_idle_timer
  zle .end-of-line
  AI_COMPLETION_ACTIVE=0
  AI_PREVIEW_GENERATED=0
}

ai_handle_sigint() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    ai_clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
    AI_PREVIEW_GENERATED=0
    AI_COMPLETION_ACTIVE=0
  fi

  LBUFFER=""
  RBUFFER=""
  zle reset-prompt
  print
}

function TRAPINT() {
  if zle -M "" 2>/dev/null; then
    zle ai_handle_sigint
  fi
}

# Called by periodic timer (via zle -F)
function ai_idle_check() {
  # Drain FIFO input to prevent blocking
  read -r -t 0.01 <&$AI_IDLE_TIMER_FD || true

  local now=$(date +%s)
  local elapsed=$(( now - AI_LAST_INPUT_TIME ))

  # Check if python process finished
  if (( AI_PY_RUNNING )); then
    if ! kill -0 $AI_PY_PID 2>/dev/null; then
      # Python finished
      AI_PY_RUNNING=0
      if [[ -f "$AI_PY_OUTPUT_FILE" ]]; then
        local output input="$AI_LAST_INPUT" addition
        output=$(<"$AI_PY_OUTPUT_FILE")
        rm -f "$AI_PY_OUTPUT_FILE"

        if [[ -n "$output" && "$output" != "$input" && "$output" == "$input"* ]]; then
          addition="${output#$input}"

          ai_clear_suggestion_display
          printf '\e7'
          printf '\e[90m%s\e[0m' "$addition"
          printf '\e8'

          AI_SUGGESTION="$output"
          AI_PREVIEW_GENERATED=1
        else
          AI_SUGGESTION=""
          AI_PREVIEW_GENERATED=0
        fi
      fi
      # Reset idle timer so that repeated previews don't flood
      ai_reset_idle_timer
      return
    fi
  fi

  # If no python running and idle time passed, start new preview
  if (( elapsed >= AI_IDLE_TIMEOUT && AI_PREVIEW_GENERATED == 0 && AI_COMPLETION_ACTIVE == 0 && AI_PY_RUNNING == 0 )); then
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
zle -N ai_wrap_forward_char
zle -N ai_wrap_backward_char
zle -N ai_wrap_up_line
zle -N ai_wrap_down_line
zle -N ai_wrap_beginning_of_line 
zle -N ai_wrap_end_of_line
zle -N ai_handle_sigint

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
bindkey '^I' ai_accept_suggestion           # Tab
bindkey '^[p' ai_preview_suggestion         # Alt+P preview
bindkey '^M' ai_wrap_accept_line             # Enter
bindkey '^F' ai_wrap_forward_char            # right arrow
bindkey '^B' ai_wrap_backward_char           # left arrow
bindkey '^[OA' ai_wrap_up_line               # up arrow
bindkey '^[OB' ai_wrap_down_line             # down arrow
bindkey '^[OH' ai_wrap_beginning_of_line    # Ctrl-A for beginning of line
bindkey '^[OF' ai_wrap_end_of_line           # Ctrl-E for end of line

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
  rm -f $AI_PY_OUTPUT_FILE
  # Also kill python job if running
  if (( AI_PY_RUNNING )) && kill -0 $AI_PY_PID 2>/dev/null; then
    kill $AI_PY_PID 2>/dev/null
    wait $AI_PY_PID 2>/dev/null
  fi
}
TRAPEXIT() { ai_cleanup }
