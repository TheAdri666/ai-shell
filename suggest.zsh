# Only run in interactive shells with ZLE
if  [[ ! -o interactive ]]; then
  echo "Shell is not interactive, ai suggestions are unavailable." | tee /tmp/ai-shell.log
  return
fi

# Path to AI shell script
AI_SHELL_PATH="$HOME/.ai-shell/ai-shell.py"

# Variable for suggestion
AI_SUGGESTION=""

function ai_preview_suggestion() {
  local input="$LBUFFER"
  local output addition

  # Run AI script
  output="$(python3 "$AI_SHELL_PATH" "$input")"

  # Always clear old suggestion first:
  echo -ne "\e7"          # save cursor
  echo -ne "\e[0K"        # clear to end of line

  # Only show suggestion if output is valid and extends input
  if [[ -n "$output" && "$output" != "$input" && "$output" == "$input"* ]]; then
    addition="${output#$input}"

    # Save cursor
    echoti sc
    # Clear to end of line
    echoti el
    # Display suggestion in gray
    printf "\e[90m%s\e[0m" "$addition"
    # Restore cursor
    echoti rc
  fi

  # Store suggestion globally
  AI_SUGGESTION="$output"
}

function ai_accept_suggestion() {
  local input="$LBUFFER"
  if [[ -n "$AI_SUGGESTION" && "$AI_SUGGESTION" != "$input" && "$AI_SUGGESTION" == "$input"* ]]; then
    local addition="${AI_SUGGESTION#$input}"
    LBUFFER+="$addition"
    zle reset-prompt
  else
    # Optionally fallback to normal Tab behavior
    zle expand-or-complete
  fi
}


# Now define widgets
zle -N ai_preview_suggestion
zle -N ai_accept_suggestion

# Bind keys
bindkey '^[p' ai_preview_suggestion
bindkey '^I' ai_accept_suggestion