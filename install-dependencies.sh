#!/bin/bash

# Verify Zsh installation.
if ! command -v zsh &> /dev/null; then
    echo "Zsh is not installed. Installing..."
    sudo apt install zsh -y || sudo pacman -S zsh
else 
    echo "Zsh is already installed."
fi

# Verify Python 3 installation.

if ! command -v python3 &> /dev/null; then
    echo "Python 3 is not installed. Installing..."
    sudo apt install python3 -y || sudo pacman -S python
else 
    echo "Python 3 is already installed."
fi

# Verify Ollama (and curl) instalation.
if ! command -v ollama &> /dev/null; then
    if ! command -v curl &> /dev/null; then
        echo "Curl is not installed. Installing..."
        sudo apt install curl -y || sudo pacman -S curl
    else
        echo "Curl is already installed."
    fi
    echo "Ollama is not installed. Installing..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "Ollama is already installed."
fi

