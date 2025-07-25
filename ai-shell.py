#!/usr/bin/env python3
import sys
import asyncio
import subprocess
import os

HISTORY_PATH = os.path.expanduser("~/.zsh_history")
MAX_RETRIES = 3

def extract_recent_commands(num_commands=30) -> list[str]:
    if not os.path.exists(HISTORY_PATH):
        return []

    with open(HISTORY_PATH, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()[-num_commands:]

    commands = []
    for line in lines: # Read actual command, ignore timestamps.
        if ";" in line:
            parts = line.split(";", 1)
            command = parts[1].strip()
            commands.append(command)
    return commands

def is_syntax_valid(command: str) -> bool:
    try:
        subprocess.run( # Read command (-c) without running it (-n) and check for errors.
            ["zsh", "-n", "-c", command],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True
        )
        return True
    except subprocess.CalledProcessError:
        return False

def is_likely_valid_command(command: str, original: str) -> bool:
    # Remove spaces at the beginning and end. 
    command = command.strip()
    
    # Reject if output command contains line breaks (probable explanation or block).
    if "\n" in command:
        return False
    
    # Reject if output command contains words that indicate an explanation.
    banned_words = ["this", "command", "will", "does", "you can", "try", "note", "sorry"]
    if any(word in command.lower() for word in banned_words):
        return False

    # Reject if the command is identical to the original (nothing was completed).
    if command.strip() == original.strip():
        return False

    # Reject if output command does not contain the original. 
    if original.strip() not in command:
        return False

    # Validate zsh syntax
    return is_syntax_valid(command)

async def get_ai_suggestion(prompt: str, recent_commands: list[str]) -> str:
    context = "\n".join(recent_commands)

    full_prompt = f"""
You are an expert Zsh shell assistant.
Given the partial command below, respond with a single valid, executable Zsh command that extends or completes it meaningfully.
You must:
- Include the entire original input command,
- Add relevant flags, options, or arguments to make it a useful, practical command,
- Never just repeat the input command without additions,
- Output only one valid command, no explanations or comments.
- Not include any styling such as markdown.
- Verify whether or not the context given is useful to autocomplete the command and use it if it is.

Examples:
Current command: cd /home/user
Completion: cd /home/user && ls -lah

Current command: git status
Completion: git status --short

Current command: ls
Completion: ls -lh --color=auto

Now complete the following command:

Current command: {prompt}
Recent commands: {context}
"""

    for _attempt in range(MAX_RETRIES): # Try to generate a valid suggestion MAX_RETRIES times.
        process = await asyncio.create_subprocess_exec(
            "ollama", "run", "deepseek-coder-v2:16b",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )

        stdout, _ = await process.communicate(full_prompt.encode())
        suggestion = stdout.decode().strip()

        if is_likely_valid_command(suggestion, prompt):
            return suggestion

    return ""  # Fallback if all retries fail

async def main():
    if len(sys.argv) < 2:
        print("")  # Empty output for empty input.
        return

    current_input = " ".join(sys.argv[1:]).strip() # Current command in input.
    recent = extract_recent_commands()

    suggestion = await get_ai_suggestion(current_input, recent)
    print(suggestion)

if __name__ == "__main__":
    asyncio.run(main())

