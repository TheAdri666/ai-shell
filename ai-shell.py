#!/usr/bin/env python3
import sys
import subprocess
import os
import asyncio

def extract_recent_commands(history_file: str, num_commands: int = 30) -> list[str]:
    """
    Extract recent commands from the Zsh history file.

    Args:
        history_file (str): The path to the Zsh history file.
        num_commands (int): The number of commands to extract. Defaults to 30.

    Returns:
        list[str]: A list of recent commands.
    """

    recent_commands: list[str] = []
    try:
        with open(history_file, "r", encoding="utf-8", errors="ignore") as file:
            lines: list[str] = file.readlines()[-num_commands:]
            for line in lines:
                if len(line.split(";")) > 1:
                    _, command, *_ = line.split(";")
                    recent_commands.append(command.strip())
    except FileNotFoundError:
        pass
    return recent_commands

async def get_ai_suggestion(prompt: str, recent_commands: list[str]) -> str: 
    """
    Get an AI generated suggestion based on the prompt given and a list of recent commands if available.

    Args:
        prompt (str): The prompt to generate a suggestion for.
        recent_commands (list[str]): A list of recent commands to use as context.

    Returns:
        str: The AI generated suggestion.
    """

    full_prompt: str = f"""
        You are an intelligent shell command autocomplete assistant. Based on the current command and recent history, suggest a **full command** that is relevant and enhances the input.
        Focus on preserving the original input without changing it at all but making it more specific or complete. 
        Make sure the output is only a complete command that could be ran in the terminal and **nothing else.**
        **Current command:** {prompt}
        **Recent commands for context:** {recent_commands}
        Make sure the suggestion is **relevant** to the current context, and **do not simply repeat** the current input. Use the recent history to make your suggestions more accurate and specific.
        """

    try:
        process: subprocess.CompletedProcess = await asyncio.create_subprocess_exec(
            "ollama", "run", "codegemma", full_prompt,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )

        # Read the output and error (if any)
        stdout, stderr = await process.communicate()
        
        # Check if there were any errors
        if process.returncode != 0:
            print(f"Error: {stderr.decode().strip()}", file=sys.stderr)
            return ""
        
        return stdout.decode().strip()

    except FileNotFoundError:
        print("Ollama is not installed or not in PATH.", file=sys.stderr)
        sys.exit(1)

def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: ai-shell.py <command>")
        sys.exit(1)

    prompt: str = " ".join(sys.argv[1:])

    history_file: str = os.path.expanduser("~/.zsh_history")

    recent_commands: list[str] = extract_recent_commands(history_file)

    ai_suggestion: str = asyncio.run(get_ai_suggestion(prompt, recent_commands))

    print(ai_suggestion)

if __name__ == "__main__":
    main()
