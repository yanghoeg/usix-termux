# usix-termux

**English** · [한국어](README.ko.md)

A local-LLM phone agent for Android [Termux](https://termux.dev). It distills the
design of [usix](https://github.com/) — **function-calling tools + ApprovalClass
permission gating + a hexagonal ports/adapters core** — down to phone scale, letting a
local LLM (**llama.cpp** by default, ollama optional) drive `termux-api` tools.

Tools own the numbers and side effects; the LLM is used only for natural-language
interpretation and tool selection. **Mutating actions** (sending an SMS, placing a call)
**require human approval before they run.**

Answers stream token-by-token, one line at a time.

## Demo

<!-- Record on device and drop the GIF here: ![demo](docs/demo.gif) -->

```text
> summarize my recent texts and reply to mom that I'll be home by 7
Thinking… (2s)
3 new — mom: "did you eat?", bank OTP, courier ETA 6pm.
Draft to mom (010-…): "Home by 7 — love you"
approval needed: sms_send {"number":"010-…","text":"Home by 7 — love you"}  [y/N] y
Sent.
```

## Quick start

```bash
pkg install rust git
git clone https://github.com/yanghoeg/usix-termux && cd usix-termux
cargo build --release && ./target/release/usix-termux setup
```

One `setup` installs the backend, downloads the model, starts the server, and seeds the
example skill. Phone tools also need the **Termux:API app** (F-Droid) — see
[Prerequisites](#prerequisites).

## Features

- 🧠 **Local LLM**, no cloud — llama.cpp (`llama-server`, OpenAI-compatible) or ollama
- 🔧 **Function calling** — the model calls real phone tools via `termux-api`
- 🔒 **Approval gate** — read-only tools run automatically; mutating tools ask `y/N` first
- 📱 **Phone-scale TUI** — inline input box, live `Thinking…` timer, streaming markdown
- 🧩 **Hexagonal core** — swap the LLM backend or add tools without touching the domain

## Architecture

```
main.rs            DI: backend selection + subcommands
bootstrap.rs       setup/doctor — install backend, start server, prepare model
ports.rs           contracts: Llm / Tool / ApprovalClass
adapters/
  llama.rs         llama-server OpenAI /v1/chat/completions (streaming, default)
  ollama.rs        local ollama /api/chat (ureq sync HTTP, no TLS)
  termux.rs        runs termux-* commands (with a timeout guard)
domain/
  registry.rs      tool registry + tools schema
  agent.rs         function-calling loop + approval gate
  skills.rs        markdown skill loader (~/.usix/skills/*.md → system prompt)
tools/
  read.rs          sms_list, call_log, battery, contacts   (ReadOnly, automatic)
  comms.rs         sms_send, call, reminder                (Mutating, approval required)
  shell.rs         read_file, list_dir (ReadOnly) · shell, write_file (Mutating)
  ui.rs            ui_dump (ReadOnly) · app_open (Mutating)  — adb, opt-in USIX_UI
tui.rs             inline ratatui input box + streamed, plain-stdout transcript
  editor.rs        UTF-8 line editor (multiline, history, word keys)
  markdown.rs      markdown → styled lines (headings, code blocks, lists, inline)
skills/
  sms_reply.md     example skill (summarize recent SMS + draft a reply)
```

## Prerequisites

- **Termux** with the Rust toolchain: `pkg install rust`
- **Backend** (one of):
  - **llama.cpp** (default): `pkg install llama-cpp llama-cpp-backend-opencl` plus one
    GGUF model. Qwen2.5-3B-Instruct Q5_K_M is recommended for tool-calling reliability.
    On Adreno GPUs the server must be launched with the `llama-gpu` wrapper (native
    Qualcomm OpenCL, `-ngl 99`) — the Vulkan/clvk path emits garbage tokens.
  - **ollama**: install ollama and set `USIX_BACKEND=ollama`.
- **termux-api** for phone tools:
  - `pkg install termux-api` (the CLI package), **and**
  - the separate **Termux:API app** from [F-Droid](https://f-droid.org/packages/com.termux.api/),
    launched once and granted SMS / phone / battery permissions.
  - Without the app, `termux-*` tools do not respond even though the CLI is installed —
    `usix-termux doctor` verifies both.

> On non-rooted Android there is no `sysfs`/`dumpsys` fallback for battery or SMS; the
> Termux:API app is the only path.

## Install

```bash
git clone <repo-url> usix-termux
cd usix-termux
cargo build --release
./target/release/usix-termux setup    # install backend + start server (llama.cpp, GPU)
./target/release/usix-termux doctor   # check prerequisites
```

`setup` installs the backend, starts the server in the background (surviving launcher
exit), and — for ollama — pulls the model. `doctor` prints a per-backend checklist.

## Usage

```bash
usix-termux            # interactive TUI
usix-termux setup      # install backend + start server (+ pull model on ollama)
usix-termux doctor     # check prerequisites
usix-termux -c "..."   # one-shot query (non-interactive; mutating tools auto-denied)
```

### Environment

| Variable       | Default                                            | Meaning                                   |
| -------------- | -------------------------------------------------- | ----------------------------------------- |
| `USIX_BACKEND` | `llama`                                            | `llama` (llama.cpp) or `ollama`           |
| `USIX_MODEL`   | `~/models/qwen2.5-3b-instruct-q5_k_m.gguf` (llama) | GGUF path (llama) or model tag (ollama)   |
|                | `qwen2.5:1.5b-instruct-q5_K_M` (ollama)            |                                           |

```bash
# smaller/faster GGUF
USIX_MODEL=~/models/qwen2.5-1.5b-instruct-q5_k_m.gguf usix-termux
# ollama backend
USIX_BACKEND=ollama USIX_MODEL=qwen2.5:1.5b usix-termux
```

### TUI keys

| Key                 | Action                          |
| ------------------- | ------------------------------- |
| `Enter`             | submit                          |
| `Ctrl+J`            | newline (multiline input)       |
| `↑` / `↓`           | history                         |
| `! <cmd>`           | run a local shell command       |
| `exit` / `quit`     | leave the session               |
| `Esc` / `Ctrl+D`    | leave the session (empty input) |
| `Ctrl+A` / `Ctrl+E` | line start / end                |
| `Ctrl+W` / `Ctrl+U` | delete word / to line start     |
| `Alt+←` / `Alt+→`   | move by word                    |

### Example

```
> How much battery is left?
Thinking… (2s)
Battery is at 62%, charging.

> Text 010-1234-5678 "running 10 min late"
approval needed: sms_send {"number":"010-1234-5678","text":"running 10 min late"}  [y/N] y
Sent to 010-1234-5678.
```

## Tools

| Tool       | Class    | Approval  |
| ---------- | -------- | --------- |
| `sms_list` | ReadOnly | automatic |
| `call_log` | ReadOnly | automatic |
| `battery`  | ReadOnly | automatic |
| `contacts`   | ReadOnly | automatic |
| `read_file`  | ReadOnly | automatic |
| `list_dir`   | ReadOnly | automatic |
| `sms_send`   | Mutating | `y/N`     |
| `call`       | Mutating | `y/N`     |
| `reminder`   | Mutating | `y/N`     |
| `shell`      | Mutating | `y/N`     |
| `write_file` | Mutating | `y/N`     |

Experimental phone-UI tools, registered only when `USIX_UI` is set (see below):

| Tool        | Class    | Approval  |
| ----------- | -------- | --------- |
| `ui_dump`   | ReadOnly | automatic |
| `app_open`  | Mutating | `y/N`     |

## Phone UI control (experimental)

Beyond `termux-api`, the agent can read the screen and launch apps via **on-device adb**
over Android **wireless debugging** — no root. This drives arbitrary apps (KakaoTalk, Line,
…) at the UI level.

Setup (one-time; some devices require re-pairing after reboot):

```bash
pkg install android-tools
# Settings → Developer options → Wireless debugging → Pair device with pairing code
adb pair localhost:PAIR_PORT       # enter the 6-digit code
adb connect localhost:CONNECT_PORT
USIX_UI=1 usix-termux doctor        # adb ✅, device connected ✅
USIX_UI=1 usix-termux               # UI tools now registered
```

When `USIX_UI` is set, two tools are added: `ui_dump` (ReadOnly — reads on-screen text and
element coordinates via `uiautomator`) and `app_open` (Mutating — launches an app by
package). The bundled `kakao_read` skill uses them to open KakaoTalk and summarize the
visible chat.

Honest caveats:

- **Read-only for now.** Tapping/typing (`ui_tap`/`ui_type`) is a future cut; the current
  cut opens apps and reads the screen but does not send replies.
- **Only what's visible.** adb runs as the `shell` user, which can drive UI and read the
  screen but **cannot** read another app's private database — full chat history still needs
  root.
- **Brittle.** UI layouts and coordinates vary per device; a small local model reliably
  handles only short, scripted flows.

## Skills

Skills are markdown procedures in `~/.usix/skills/*.md` that teach the model how to chain
existing tools — **no recompile needed**. Each file has a small frontmatter (`name`,
`description`) plus a step-by-step body, which is appended to the system prompt. Up to 8
are active at once (to protect the small local model's context).

`setup` seeds one example, **`sms_reply`** — "summarize my recent texts and help me reply":
it reads via `sms_list`, summarizes, and (on request) drafts an SMS and sends it through
`sms_send`, which still asks `y/N` before sending. Drop another `.md` in the folder to add
a skill.

```
> summarize my recent texts and reply to mom that I'll be home by 7
(reads sms_list, summarizes) … Draft to 010-…: "Home by 7, love you"
approval needed: sms_send {"number":"010-…","text":"Home by 7, love you"}  [y/N] y
Sent.
```

## Status

v0 — two backends (llama.cpp default / ollama), six read tools + five mutating tools
(approval-gated), plus experimental adb phone-UI tools behind `USIX_UI`, streaming markdown
TUI. Licensed under MIT.
