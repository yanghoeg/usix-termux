#!/bin/sh
set -eu

case "$1" in
    llama) package=llama-cpp ;;
    ollama) package=ollama ;;
    *) echo "Unknown backend: $1" >&2; exit 1 ;;
esac
pkg install -y "$package"
