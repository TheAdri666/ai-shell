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
    for line in lines:
        if ";" in line:
            parts = line.split(";", 1)
            command = parts[1].strip()
            commands.append(command)
    return commands

def is_syntax_valid(command: str) -> bool:
    try:
        subprocess.run(
            ["zsh", "-n", "-c", command],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True
        )
        return True
    except subprocess.CalledProcessError:
        return False

def is_likely_valid_command(command: str, original: str) -> bool:
    # Quitar espacios al principio y final
    command = command.strip()
    
    # Rechazar si contiene saltos de línea (probable explicación o bloque)
    if "\n" in command:
        return False
    
    # Rechazar si contiene palabras que delaten explicación
    banned_words = ["this", "command", "will", "does", "you can", "try", "note", "sorry"]
    if any(word in command.lower() for word in banned_words):
        return False

    # Rechazar si el comando es idéntico al original (no ha completado nada)
    if command.strip() == original.strip():
        return False

    # Rechazar si el comando no contiene el original
    if original.strip() not in command:
        return False

    # Validar sintaxis zsh
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

    for attempt in range(MAX_RETRIES):
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
        print("")  # Empty output for empty input
        return

    current_input = " ".join(sys.argv[1:]).strip()
    recent = extract_recent_commands()

    suggestion = await get_ai_suggestion(current_input, recent)
    print(suggestion)

if __name__ == "__main__":
    asyncio.run(main())

