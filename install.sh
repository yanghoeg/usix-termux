#!/bin/sh
# Build the native harness. Backend/model setup is a separate, explicit command.
set -eu

usage() {
    echo "Usage: sh install.sh [--prefix DIR]"
    echo "Installs usix-code into DIR/bin (default: ~/.local on Linux, \$PREFIX in Termux)."
    echo "Requires Cargo/Rust and a native C toolchain. Run usix-code setup afterward."
}

install_root=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "--prefix needs a directory" >&2; exit 2; fi
            install_root=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$(uname -s)" in
    Linux) ;;
    *) echo "Supported native hosts: Linux and Android Termux. Other systems need a Host adapter." >&2; exit 1 ;;
esac

if [ -n "${TERMUX_VERSION:-}" ] || [ "${PREFIX:-}" = "/data/data/com.termux/files/usr" ]; then
    install_root=${install_root:-${PREFIX:?Termux PREFIX is missing}}
    dependency_hint="pkg install rust clang make git curl bash coreutils"
else
    install_root=${install_root:-${HOME:?HOME is missing}/.local}
    dependency_hint="Install current stable Rust (https://rustup.rs), a C/C++ toolchain, and Make."
fi

for cmd in cargo rustc cc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing $cmd. $dependency_hint" >&2
        exit 1
    fi
done

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# An absolute root also makes the PATH hint usable when --prefix is relative.
mkdir -p "$install_root"
install_root=$(CDPATH= cd -- "$install_root" && pwd)
cargo install --locked --path "$repo_dir" --root "$install_root"
printf '\nInstalled: %s/bin/usix-code\n' "$install_root"
case ":${PATH:-}:" in
    *":$install_root/bin:"*) ;;
    *) printf 'Add this directory to PATH: %s/bin\n' "$install_root" ;;
esac
printf 'Next: %s/bin/usix-code setup\n' "$install_root"
