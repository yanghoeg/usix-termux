#!/bin/sh
set -eu

backend=$1
backend_root=$2
case "$backend" in
    llama)
        for cmd in git cmake make c++; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "Missing $cmd. Install a C++ toolchain, CMake, Make, and Git, then rerun usix-code setup." >&2
                exit 1
            fi
        done
        source_dir="$backend_root/llama.cpp-v0.5.0"
        mkdir -p "$backend_root"
        if [ ! -d "$source_dir/.git" ]; then
            git clone --depth 1 --branch v0.5.0 https://github.com/ggml-org/llama.cpp.git "$source_dir"
        fi
        cmake -S "$source_dir" -B "$source_dir/build" \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
            -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF \
            -DLLAMA_USE_PREBUILT_UI=OFF
        cmake --build "$source_dir/build" --config Release --target llama-server \
            --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
        ;;
    ollama)
        echo "Install Ollama for Linux from https://docs.ollama.com/linux, then rerun USIX_BACKEND=ollama usix-code setup." >&2
        exit 1
        ;;
    *) echo "Unknown backend: $backend" >&2; exit 1 ;;
esac
