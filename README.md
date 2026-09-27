# usix-code

**English** · [한국어](README.ko.md)

A **fully local coding and automation harness** for laptops, desktops, and Android
Termux. Model inference, tool execution, approvals, and saved tasks run on your own
device. A hexagonal core connects to operating systems and model engines through
ports and adapters.

The default engine is **llama.cpp**, with local **Ollama** support. No cloud inference
fallback or API key is required. Installation and model downloads need internet;
a prepared local setup can run offline. User-approved tools such as shell commands
or Android messaging may use the network for the requested work.

## Install

### x64 Linux

Install current stable [Rust](https://rustup.rs) and a C/C++ toolchain. On
Debian/Ubuntu, install the system dependencies below, then build the harness:

```sh
sudo apt update
sudo apt install build-essential cmake git curl
git clone https://github.com/yanghoeg/usix-code.git
cd usix-code
sh install.sh
export PATH="$HOME/.local/bin:$PATH"
usix-code setup
usix-code doctor
usix-code
```

The binary installs into `~/.local/bin`; add the PATH entry to your shell profile.
`setup` uses `llama-server` from PATH or builds llama.cpp **v0.5.0** for the local CPU
under `~/.usix/backends`. It needs Git, CMake, Make, and a C++ compiler. Builds use
two jobs by default; `CMAKE_BUILD_PARALLEL_LEVEL` overrides that.

No GPU or system service is required. For GPU acceleration, provide a suitable
`llama-server` on PATH or start your local server first. See the upstream
[build guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).

### Android Termux

Build natively inside [Termux](https://termux.dev):

```sh
pkg update
pkg install rust clang make git curl bash coreutils
git clone https://github.com/yanghoeg/usix-code.git
cd usix-code
sh install.sh
usix-code setup
usix-code doctor
usix-code
```

The binary installs into `$PREFIX/bin`. Setup installs `llama-cpp` with `pkg` if
missing. Termux:API and the companion app are optional phone extensions; local
coding does not require them. See [Android tools](docs/termux.md).

Both hosts use the same Rust package and installer. Change the destination with
`sh install.sh --prefix /your/directory`, or use `cargo install --locked --path .`
for Cargo's standard install location. Each host needs a native binary; an x64
Linux executable cannot be copied to an ARM Android phone.

## Local models

Setup downloads [Qwen3.5-2B Q5_K_M](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/main/Qwen3.5-2B-Q5_K_M.gguf)
(about 1.44 GB) to `~/models/Qwen3.5-2B-Q5_K_M.gguf` if absent. It downloads to a
partial file before installing the model. For a different local GGUF:

```sh
export USIX_MODEL="$HOME/models/my-local-model.gguf"
usix-code setup
usix-code
```

Custom GGUF files must already exist and support chat and tool calling. Use a
larger model when your laptop or desktop has sufficient memory; the bundled 2B
model is a small starting point. Quality and memory use depend on the model.

To use local Ollama:

```sh
export USIX_BACKEND=ollama
export USIX_MODEL=qwen2.5:1.5b-instruct-q5_K_M
usix-code setup
usix-code
```

Termux setup can install `ollama`. On Linux, follow the
[Ollama Linux instructions](https://docs.ollama.com/linux) first. Harness-started
Ollama processes set `OLLAMA_NO_CLOUD=1` and bind to `127.0.0.1:11434`. Use downloaded
local model tags; disable cloud features yourself when managing the server.
llama.cpp binds to `127.0.0.1:8080`. Model HTTP requests do not follow redirects.

Logs live in `~/.usix/logs`. Setup leaves its server running. Chat and workers stop
only the server process they started; an existing server stays running. There is
no automatic startup service.

## Usage and tools

```sh
cd /path/to/project
usix-code                  # interactive TUI, streamed answers
usix-code -c "Read README.md and summarize this project"
usix-code task --help      # saved work and schedules
usix-code worker --once    # process currently due work
```

| Shared tool | Approval |
| --- | --- |
| `read_file`, `list_dir`, `task_list` | Automatic |
| `shell`, `write_file`, `task_create`, `task_cancel` | Required |

Changing actions require human approval. One-shot queries deny them; background
tasks wait for approval through `usix-code task run ID`. Tools use your OS account's
access; approval is not a filesystem sandbox. [Task guide](docs/tasks.md).

Skills are Markdown procedures in `~/.usix/skills`. Both hosts include a local
coding workflow; Termux adds SMS, mail, and chat workflows. User-edited skills are
preserved. Ordinary chat history is session-local; saved tasks persist.

TUI: `Enter` submits, `Ctrl+J` inserts a newline, `↑`/`↓` browse history,
`Ctrl+A`/`Ctrl+E` move to line boundaries, and `! command` proposes a shell command.
`exit`, `quit`, or `Ctrl+D` on an empty input leaves the session.

## Hexagonal architecture

```text
CLI / TUI / task worker
          │
          ▼
   Agent + approvals + task runner
          │
          ▼
   Llm / Tool / Host ports
          │
     ┌────┴──────────────┐
     ▼                   ▼
Linux / Termux       llama.cpp / Ollama
host adapters       loopback LLM adapters
```

- `domain/`: agent, registry, skill parsing/selection; no OS detection, filesystem
  skill loading, package commands, or concrete adapter imports.
- `ports.rs`: `Llm`, `Tool`, and `Host` contracts. Approval decisions stay in the core.
- `adapters/host/`: installation, tools, bundled skills, diagnostics, pairing,
  task notifications, and device state reset for each host.
- `adapters/skills.rs`, `adapters/runtime.rs`: filesystem and process I/O.
- `bootstrap.rs`: setup and backend lifecycle through the selected host.
- `main.rs`: selects and injects the host through `adapters::host::current`.

A new environment implements `Host` and any required I/O adapters; the agent and
task runner stay unchanged. Current process/file adapters target Unix. Other OS
support requires adapters and validation, not just another installer label.

## Development and migration

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
python3 tests/install_smoke.py
```

CI runs native Linux tests and an Android ARM64 compile check. Device testing is
still needed for Termux model execution and Android tools.

The former `usix-termux` package and executable are now `usix-code`. Existing
`~/.usix` skills, tasks, and companion tokens keep their paths. Update aliases and
worker launch commands; the installer does not remove an older binary. MIT license.
