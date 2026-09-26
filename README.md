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
- **Persistent tasks and schedules** — save multi-step work, run a background worker,
  and resume pending approvals. [Task guide](docs/tasks.md).

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
  ui.rs            ui_dump (ReadOnly) · app_open/ui_tap/ui_tap_text/ui_type/ui_back (Mutating) — companion AccessibilityService, default
  companion.rs     notif_list (ReadOnly) · notif_reply (Mutating) — bridge, default (kakao_read)
tui.rs             inline ratatui input box + streamed, plain-stdout transcript
  editor.rs        UTF-8 line editor (multiline, history, word keys)
  markdown.rs      markdown → styled lines (headings, code blocks, lists, inline)
skills/
  sms_reply.md     example skill (summarize recent SMS + draft a reply)
```

The Android companion app lives in a **separate repo** ([usix-companion](https://github.com/yanghoeg/usix-companion)) — see "Companion app" below.

## Prerequisites

- **Termux** with the Rust toolchain: `pkg install rust`
- **Backend** (one of):
  - **llama.cpp** (default): `pkg install llama-cpp llama-cpp-backend-opencl` plus one
    GGUF model. Hammer2.1-3b Q4_K_M is the default — best tool-calling judgment among
    on-device 3B models; `setup` downloads it automatically (`llama-model-get hammer`).
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
exit), and downloads the model (Hammer2.1-3b Q4 for llama.cpp, or the tag for ollama).
`doctor` prints a per-backend checklist.

## Usage

```bash
usix-termux            # interactive TUI
usix-termux setup      # install backend + download model + start server
usix-termux doctor     # check prerequisites
usix-termux -c "..."   # one-shot query (non-interactive; mutating tools auto-denied)
usix-termux task --help # saved tasks, delayed work, recurring schedules, and recovery
usix-termux worker     # process due tasks; changing actions wait for human approval
```

### Environment

| Variable       | Default                                            | Meaning                                   |
| -------------- | -------------------------------------------------- | ----------------------------------------- |
| `USIX_BACKEND` | `llama`                                            | `llama` (llama.cpp) or `ollama`           |
| `USIX_MODEL`   | `~/models/Qwen3.5-2B-Q5_K_M.gguf` (llama)          | GGUF path (llama) or model tag (ollama)   |
|                | `qwen2.5:1.5b-instruct-q5_K_M` (ollama)            |                                           |

```bash
# smaller/faster GGUF
USIX_MODEL=~/models/qwen2.5-1.5b-instruct-q5_k_m.gguf usix-termux
# ollama backend
USIX_BACKEND=ollama USIX_MODEL=qwen2.5:1.5b-instruct-q5_K_M usix-termux
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

Experimental phone-UI and mail tools, registered by default (see below):

| Tool        | Class    | Approval  |
| ----------- | -------- | --------- |
| `ui_dump`   | ReadOnly | automatic |
| `app_open`  | Mutating | `y/N`     |
| `ui_tap`    | Mutating | `y/N`     |
| `ui_tap_text` | Mutating | `y/N`   |
| `ui_type`   | Mutating | `y/N`     |
| `ui_back`   | Mutating | `y/N`     |
| `ui_scroll` | Mutating | `y/N`     |
| `email_open` | Mutating | `y/N`    |
| `email_compose` | Mutating | `y/N` |

Companion notification tools (registered by default; see below):

| Tool          | Class    | Approval  |
| ------------- | -------- | --------- |
| `notif_list`  | ReadOnly | automatic |
| `notif_reply` | Mutating | `y/N`     |

## Phone UI control (experimental)

Beyond `termux-api`, the agent can read and operate the visible phone UI through the separate
**[usix-companion](https://github.com/yanghoeg/usix-companion)** app's Android
`AccessibilityService`. It needs no root or adb and can drive arbitrary visible app flows
(KakaoTalk, Line, …).

Setup (one-time):

```bash
# Install and launch usix-companion; enable its Accessibility service in Android Settings.
# In the companion app, tap "토큰 복사", then in Termux:
usix-termux pair                    # reads the clipboard, or paste when prompted
USIX_UI=1 usix-termux doctor         # bridge/token/accessibility ✅
usix-termux                          # UI tools are registered by default
```

UI tools are registered by default: `ui_dump` reads the current screen; `app_open`,
`ui_tap`, `ui_tap_text`, `ui_type`, `ui_back`, and `ui_scroll` open or control an app.
The bundled `kakao_read` skill first checks notifications and opens the conversation
when no suitable notification is available. Scrolling makes older messages and
longer content accessible. Use `package` with `ui_dump`, `ui_scroll`, and `ui_type`
to select the intended app.

Honest caveats:

- **Only what's visible.** Accessibility exposes the current UI hierarchy and visible text;
  it **cannot** read another app's private database or full chat history.
- **Explicit approval.** Opening an app, tapping, typing, and going back are mutating actions
  and require `y/N` approval. Text is sent to the currently focused visible field.
- **Brittle.** UI layouts and coordinates vary per device; a small local model reliably
  handles only short, scripted flows.

## Thunderbird mail without notifications

Update both the companion APK and `usix-termux`. Sign in to the mail account in
Thunderbird for Android, unlock the phone, and enable companion accessibility.
The agent uses the account already in Thunderbird; no separate IMAP/SMTP password
is needed. The account domain does not have to be a public webmail provider.

- `email_open` opens Thunderbird, then `ui_dump(package=net.thunderbird.android)`
  reads the mailbox or currently displayed message.
- `email_compose(to, subject, body)` prepares a new message. It **does not send** it.
- `ui_scroll(direction=down|up, package=net.thunderbird.android)` navigates a mail
  list or long body. `ui_type` can restrict typing to the mail app's focused editor.
- To reply, open the original message and use its Reply button so the thread and
  recipients are retained. Check the sender account and recipient before sending,
  and confirm the result in Thunderbird.

Try: “Thunderbird에서 최근 메일 읽어줘” or “이 메일에 답장 초안 작성해줘”. A send
request uses the app's Send button through the existing mutating-tool approval.
Mail opening and composition also accept an optional `package` for another app.

The bundled mail workflow is available after updating the binary without rerunning
setup. User-edited skills are preserved. The exact former stock notification-only
Kakao skill is upgraded in memory; its legacy copy exists only for that comparison.
Reading depends on the app's accessible screen content and does not provide a
background mailbox API. Live-device verification is needed for the installed app.

## Companion app — notifications & reply (experimental)

The UI bridge reads the *screen* but can't read another app's notifications or fire an inline reply.
The separate **[usix-companion](https://github.com/yanghoeg/usix-companion)** app (a tiny
Kotlin `NotificationListenerService`) does both, with **no
root and no adb**: it captures incoming notifications (KakaoTalk, Line, …) and can send an
app's inline **RemoteInput** reply. It exposes a loopback-only HTTP bridge on
`127.0.0.1:8760`, which the Termux agent drives via two tools:

- `notif_list` (ReadOnly) — recent notifications (`pkg`, `title`, `text`, `key`, `canReply`)
- `notif_reply` (Mutating, `y/N`) — send an inline reply to a notification `key`

Notifications allow replies in the background without switching apps. When no
replyable notification is available, the bundled `kakao_read` skill opens the
conversation and uses its reply field and Send button. Missing notifications do
not prove there are no unread messages. Both routes keep the existing tool
approval behavior.

Setup:

```bash
# 1. Get the companion APK (separate repo):
#    - recommended: download the latest app-debug.apk from
#      https://github.com/yanghoeg/usix-companion/releases
#    - or build it yourself (needs a local Gradle 8.10.2 + the Android SDK):
#        git clone https://github.com/yanghoeg/usix-companion && cd usix-companion
#        gradle assembleDebug            # or open in Android Studio
# 2. Install it, launch once, and grant "Notification access" (and "Accessibility access"
#    when using the phone UI); the app has buttons for both
# 3. Pair once: tap "토큰 복사" (copy token) in the app, then in Termux:
usix-termux pair            # reads the clipboard, or paste when prompted
# 4. Back in Termux:
usix-termux doctor          # bridge 127.0.0.1:8760 ✅ · token paired ✅
usix-termux                 # notif_list / notif_reply registered by default
```

Honest caveats:

- **Notifications only.** It sees what a notification carries (sender + latest line) and can
  reply *only* if the app attached a RemoteInput action (`canReply`). It cannot read full
  chat history — that still needs root.
- **Same-device loopback, token-gated.** The bridge binds `127.0.0.1` only; the APK must be
  running (the listener service keeps it alive) for the tools to respond. Android apps share
  one loopback interface, so binding alone can't tell callers apart — every request carries a
  bearer token the app generates on first launch (`~/.usix/companion_token` on the Termux
  side, written by `usix-termux pair`). Requests without it get `401`; only `/health` is open.
- **No Gradle wrapper committed.** The usix-companion repo omits the wrapper jar; CI builds
  with a pinned Gradle version, and local builds use a system `gradle` or Android Studio.

## Skills

Skills are markdown procedures in `~/.usix/skills/*.md` that teach the model how to chain
existing tools — **no recompile needed**. Each file has a small frontmatter (`name`,
`description`) plus a step-by-step body. On each request, only the skills relevant to that
request (keyword-matched against name/description/body) are appended to the system prompt,
up to 8 — this keeps the small local model's context focused on the task at hand.

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

v0 — two backends (llama.cpp default / ollama), device and file tools, companion
notifications, phone-UI control, Thunderbird mail workflows, and a streaming markdown
TUI. Mutating tools require approval. Licensed under MIT.
