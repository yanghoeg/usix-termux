# Optional Android tools in Termux

These tools extend the same local harness used on Linux. They are registered only
by the Termux host adapter and are not prerequisites for local file or coding work.

Install the CLI with `pkg install termux-api` and install the separate
[Termux:API app](https://f-droid.org/packages/com.termux.api/). Grant the permissions
needed by the tools you use. `usix-code doctor` checks the bridge on Termux.

| Tools | Approval |
| --- | --- |
| `sms_list`, `call_log`, `battery`, `contacts` | Automatic |
| `sms_send`, `call`, `reminder` | Required |
| `ui_dump`, `notif_list` | Automatic |
| `app_open`, `ui_tap`, `ui_tap_text`, `ui_type`, `ui_back`, `ui_scroll` | Required |
| `email_open`, `email_compose`, `notif_reply` | Required |

The `sms_reply`, `kakao_read`, and `mail` skills are available in Termux. Edited
skills in `~/.usix/skills` are preserved. A `llama-gpu` wrapper already on PATH is
used for a device-specific OpenCL setup; without it, `llama-server` runs directly.
GPU packages are optional and should match the device.

## Native validation

CI compiles and links an Android ARM64 executable with the NDK. It does not run
inside Termux or verify phone permissions. From the repository on a Termux device:

```sh
pkg install python
sh scripts/validate-termux.sh
sh scripts/validate-termux.sh --model /path/to/existing.gguf
```

The script checks architecture boundaries, formatting, compilation, Rust tests,
Clippy, installer fixtures, and the CLI. The optional model check reads a temporary
file through real local inference and verifies its marker. It uses an existing
GGUF and does not download a model. Phone tools still need their own permission
and application checks. No boot service is installed.

## Phone UI control (experimental)

Beyond `termux-api`, the agent can read and operate the visible phone UI through the separate
**[usix-companion](https://github.com/yanghoeg/usix-companion)** app's Android
`AccessibilityService`. It needs no root or adb and can drive arbitrary visible app flows
(KakaoTalk, Line, …).

Setup (one-time):

```bash
# Install and launch usix-companion; enable its Accessibility service in Android Settings.
# In the companion app, tap "토큰 복사", then in Termux:
usix-code pair                    # reads the clipboard, or paste when prompted
USIX_UI=1 usix-code doctor         # bridge/token/accessibility ✅
usix-code                          # UI tools are registered by default
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

Update both the companion APK and `usix-code`. Sign in to the mail account in
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
usix-code pair            # reads the clipboard, or paste when prompted
# 4. Back in Termux:
usix-code doctor          # bridge 127.0.0.1:8760 ✅ · token paired ✅
usix-code                 # notif_list / notif_reply registered by default
```

Honest caveats:

- **Notifications only.** It sees what a notification carries (sender + latest line) and can
  reply *only* if the app attached a RemoteInput action (`canReply`). It cannot read full
  chat history — that still needs root.
- **Same-device loopback, token-gated.** The bridge binds `127.0.0.1` only; the APK must be
  running (the listener service keeps it alive) for the tools to respond. Android apps share
  one loopback interface, so binding alone can't tell callers apart — every request carries a
  bearer token the app generates on first launch (`~/.usix/companion_token` on the Termux
  side, written by `usix-code pair`). Requests without it get `401`; only `/health` is open.
- **No Gradle wrapper committed.** The usix-companion repo omits the wrapper jar; CI builds
  with a pinned Gradle version, and local builds use a system `gradle` or Android Studio.
