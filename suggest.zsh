# Only run in interactive shells
if [[ ! -o interactive ]]; then
  echo "Shell is not interactive, AI suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

# Check dependencies
command -v python3 >/dev/null || {
    echo "python3 not found"
    return
}

command -v ollama >/dev/null || {
    echo "ollama not found"
    return
}

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
AI_PY_OUTPUT_FILE=$(mktemp)
AI_PY_RUNNING=0

# Check if backend exists
[[ -x "$AI_SHELL_PATH" ]] || {
    echo "Backend not found: $AI_SHELL_PATH"
    return
}

# Clear suggestion from display
function clear_suggestion_display() {
  printf '\e7'    # Save cursor
  printf '\e[0K'  # Clear to end of line
  printf '\e8'    # Restore cursor
}

# Show gray suggestion only if input changed since last time
# Runs python asynchronously without blocking
function generate_suggestion() {
  local input="$BUFFER"

  # Don't generate suggestions for an empty command
  [[ -z "$input" ]] && return

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

  # Remove previous output file if it still exists
  [[ -n "$AI_PY_OUTPUT_FILE" ]] && rm -f "$AI_PY_OUTPUT_FILE"

  # Create a fresh temporary file
  AI_PY_OUTPUT_FILE=$(mktemp)

  # Run python async, silently redirect output to temp file
  python3 "$AI_SHELL_PATH" "$input" > "$AI_PY_OUTPUT_FILE" 2>/dev/null &

  AI_PY_PID=$!
  disown

  # Re-enable job control messages
  set -m
}

# Accept suggestion
function accept_suggestion() {
  local input="$BUFFER"
  if [[ -n "$AI_SUGGESTION" && "$AI_SUGGESTION" == "$input"* ]]; then
    BUFFER="$AI_SUGGESTION"
    CURSOR=${#BUFFER}
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
    zle reset-prompt
  else
    zle ai_wrap_expand_or_complete
  fi
  AI_PREVIEW_GENERATED=0
}

function hide_suggestion() {
  if [[ -n "$AI_SUGGESTION" ]]; then
    clear_suggestion_display
    AI_SUGGESTION=""
    AI_LAST_INPUT=""
  fi
  AI_PREVIEW_GENERATED=0
  AI_COMPLETION_ACTIVE=0
}

# On backspace: reset timer & clear suggestion
function ai_wrap_backward_delete_char() {
  reset_idle_timer
  hide_suggestion
  zle .backward-delete-char
}

# on enter: clear suggestion
function ai_wrap_accept_line() {
  reset_idle_timer
  hide_suggestion
  zle .accept-line
}

function ai_wrap_expand_or_complete() {
  AI_COMPLETION_ACTIVE=1
  zle expand-or-complete
}

function ai_wrap_up_line_or_beginning_search() {
  reset_idle_timer
  hide_suggestion
  zle .up-line-or-beginning-search
}

function ai_wrap_up_line_or_history() {
  reset_idle_timer
  hide_suggestion
  zle .up-line-or-history
}

function ai_wrap_down_line_or_beginning_search() {
  reset_idle_timer
  hide_suggestion
  zle .down-line-or-beginning-search
}

function ai_wrap_down_line_or_history() {
  reset_idle_timer
  hide_suggestion
  zle .down-line-or-history
}

function ai_wrap_self_insert() {
  reset_idle_timer
  hide_suggestion
  zle .self-insert
}

handle_sigint() {
  hide_suggestion
  if (( AI_PY_RUNNING )) && kill -0 $AI_PY_PID 2>/dev/null; then
    kill $AI_PY_PID 2>/dev/null
    wait $AI_PY_PID 2>/dev/null
    AI_PY_RUNNING=0
  fi
  LBUFFER=""
  RBUFFER=""
  zle reset-prompt
  print
}

function TRAPINT() {
  if zle -M "" 2>/dev/null; then
    zle handle_sigint
  fi
}

# Called by periodic timer (via zle -F)
function idle_check() {
  # Drain the FIFO so future timer events can be detected correctly.
  read -r -t 0.01 <&$AI_IDLE_TIMER_FD || true

  local now=$EPOCHREALTIME
  local elapsed=$(( EPOCHREALTIME - AI_LAST_INPUT_TIME ))

  # Check if python process finished
  if (( AI_PY_RUNNING )); then
    if ! kill -0 $AI_PY_PID 2>/dev/null; then
      # Python finished
      AI_PY_RUNNING=0
      if [[ -f "$AI_PY_OUTPUT_FILE" ]]; then
        local output input="$AI_LAST_INPUT" addition
        # "<" is a zsh shortcut for cat, faster since it avoids spawning the cat program
        output=$(<"$AI_PY_OUTPUT_FILE")
        rm -f "$AI_PY_OUTPUT_FILE"

        if [[ -n "$output" && "$output" != "$input" && "$output" == "$input"* ]]; then
          addition="${output#$input}"

          clear_suggestion_display
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
      reset_idle_timer
      return
    fi
  fi

  # If no python running and idle time passed, start new preview
  if (( elapsed >= AI_IDLE_TIMEOUT && AI_PREVIEW_GENERATED == 0 && AI_COMPLETION_ACTIVE == 0 && AI_PY_RUNNING == 0 )); then
    zle -M ""  # Clear messages
    zle generate_suggestion
    reset_idle_timer
  fi
}

# Reset last input time on any input
function reset_idle_timer() {
  AI_LAST_INPUT_TIME=$EPOCHREALTIME
}

# Define new widgets
zle -N generate_suggestion
zle -N accept_suggestion
zle -N ai_wrap_expand_or_complete
zle -N handle_sigint

# Some widgets are not defined by default, so we store them before overriding
zle -N .up-line-or-beginning-search up-line-or-beginning-search
zle -N .down-line-or-beginning-search down-line-or-beginning-search

# Override widgets with their wrappers
zle -N backward-delete-char ai_wrap_backward_delete_char
zle -N accept-line ai_wrap_accept_line
zle -N up-line-or-beginning-search ai_wrap_up_line_or_beginning_search
zle -N up-line-or-history ai_wrap_up_line_or_history
zle -N down-line-or-history ai_wrap_down_line_or_history
zle -N down-line-or-beginning-search ai_wrap_down_line_or_beginning_search
zle -N self-insert ai_wrap_self_insert

bindkey '^I' accept_suggestion           # Tab
bindkey '^[p' generate_suggestion         # Alt+P preview

# Load datetime module
zmodload zsh/datetime

# Initialize timer
reset_idle_timer

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
zle -F $AI_IDLE_TIMER_FD idle_check

# Cleanup on shell exit
function cleanup() {
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
TRAPEXIT() { cleanup }
