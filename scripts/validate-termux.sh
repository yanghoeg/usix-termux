#!/bin/sh
# Native Android gates; an optional existing GGUF exercises real local inference.
set -eu

model=
case "$#" in
  0) ;;
  2) [ "$1" = "--model" ] || { echo 'Usage: sh scripts/validate-termux.sh [--model /path/model.gguf]' >&2; exit 2; }
     model=$2 ;;
  *) echo 'Usage: sh scripts/validate-termux.sh [--model /path/model.gguf]' >&2; exit 2 ;;
esac

for program in rustc cargo python3 bash timeout; do
  command -v "$program" >/dev/null 2>&1 || { echo "Missing $program" >&2; exit 1; }
done
case "$(rustc -vV)" in
  *linux-android*) ;;
  *) echo 'Run this validation natively inside Android Termux.' >&2; exit 1 ;;
esac
if [ -n "$model" ]; then
  [ -f "$model" ] || { echo 'The supplied GGUF must already exist.' >&2; exit 1; }
  model=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$model")
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
python3 tests/architecture.py
cargo fmt --check
cargo check --locked --all-targets
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
python3 tests/install_smoke.py
cargo build --locked
target_dir=$(cargo metadata --offline --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
binary="$target_dir/debug/usix-code"
"$binary" --version

if [ -n "$model" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  trap 'exit 1' HUP INT TERM
  marker="termux-native-$$-$(date +%s)"
  printf '%s\n' "$marker" > "$scratch/marker.txt"
  cd "$scratch"
  timeout 10m env USIX_BACKEND=llama USIX_MODEL="$model" USIX_TASKS_DIR="$scratch/tasks" \
    "$binary" -c 'Use read_file to read marker.txt and answer with its exact content.' > result.txt
  python3 - "$scratch/result.txt" "$marker" <<'PY'
import pathlib, sys
assert sys.argv[2] in pathlib.Path(sys.argv[1]).read_text(), "Local inference did not return the file marker"
print("Native GGUF inference and local file workflow passed.")
PY
else
  echo 'Native build and fixture checks passed. Supply --model with an existing GGUF to verify the model engine.'
fi
