# Persistent phone tasks

USIX can keep multi-step phone work outside an interactive chat session. The Termux
agent owns tasks, model calls, approval decisions, and schedules. The Android
companion supplies its existing screen, mail, and notification tools; this feature
does not require a new companion API or OpenClaw.

## Start a task

```sh
usix-termux task add "Check my battery and summarize recent notifications"
usix-termux worker --once
usix-termux task list
usix-termux task show 1
```

Use the ID returned by `task add` in later commands. `worker --once` processes a
snapshot of tasks currently due. It uses the configured local model and saves the
result of every tool step. It does not approve phone-changing actions.

For a task that requires approval, inspect and resume it:

```sh
usix-termux task run 1
```

The command shows the exact tool and arguments before each changing action.
Approval requires an interactive terminal. A non-interactive invocation leaves the
task waiting. Declining an action cancels that task, its remaining calls, and its
repeat schedule. Read the tool results and check the phone for actions such as
sending mail; a model's final text is not independent proof of delivery.

## Schedule work

```sh
usix-termux task schedule --after 10m "Summarize my recent notifications"
usix-termux task schedule --every 1h "Check battery level and charging status"
usix-termux task schedule --after 5m --every 1d "Summarize recent notifications"
usix-termux worker
```

Durations accept seconds, minutes, hours, or days (`30s`, `10m`, `1h`, `1d`), up to
one year. Repeat intervals must be at least 60 seconds. A repeat starts after its
interval unless `--after` specifies a different first delay. Its next run is due
one interval after successful completion. Missed intervals are combined into one
run when the worker returns; they do not produce a burst of repeated work. These
are duration-based schedules, not calendar or cron expressions.

The worker checks every five seconds while idle and must remain running. A simple
Termux launch that survives closing the launching shell is:

```sh
mkdir -p ~/.usix/tasks
chmod 700 ~/.usix/tasks
nohup usix-termux worker > ~/.usix/tasks/worker.log 2>&1 < /dev/null &
```

Android can still stop Termux or defer work while the phone sleeps. Restart the
worker to recover saved schedules; no boot service or exact-time alarm is installed.
The worker emits a best-effort local Termux:API notification when a task finishes,
fails, or needs approval. Saved task results remain available if notification
delivery is unavailable.

## Create schedules in chat

Interactive chat includes `task_create`, `task_list`, and `task_cancel`. For example:

> In ten minutes, summarize my recent notifications.

The model can propose a `task_create` call containing the complete prompt and
`delay_seconds: 600`. Scheduling and cancelling require the existing human approval
gate. Queuing a task does not start a worker. A schedule does not grant future
permission to send messages, tap the screen, run shell commands, or change files.
Each such action pauses for a new approval, including on repeated runs.

An interactive chat session owns the phone execution lock until it exits. A worker
waits while that session is open; `worker --once` reports that the phone is busy.
This also prevents two task runners from interleaving phone actions. Only one worker
may run against a task store.

## Inspect, cancel, and recover

```sh
usix-termux task show 1
usix-termux task cancel 1
usix-termux task retry 1
usix-termux task remove 1
```

`task run` starts queued work immediately or resumes saved work, including after a
model error. Completed tool results remain in its checkpoint. `task retry` instead
queues a stopped task from the beginning; it can repeat work already performed.
`task remove` deletes a stopped task's record and result. Cancel a live schedule
before removing it. A running task cannot be cancelled mid-tool; stop its runner
first, then let a worker or `task run` recover its interrupted state.

Screen-dependent calls are planned again when a task resumes: screen indexes and
focus can expire while it is paused. The previous unexecuted call batch is marked
as not executed, and the runtime requests a fresh screen reading before the model
proposes replacement actions. Their approvals are requested again. Screen caches
are cleared between tasks.

If execution stops during an approved action, the next runner marks the task
`interrupted` and refuses to replay the action: a phone operation and its checkpoint
cannot be committed atomically. Inspect the actual phone state before deciding
whether to retry from the beginning. Approvals are never remembered as blanket
permission for a later run. Failed or interrupted tasks pause until explicitly
resumed or retried; the worker does not repeatedly retry them.

State lives in `~/.usix/tasks/state.json`. `USIX_TASKS_DIR` can select a separate
dedicated directory. The store uses private files, atomic replacement, and OS locks
that release when the process exits. It holds up to 256 tasks and 32 MiB total;
remove obsolete task records when needed. Each run is bounded to 16 normal model
steps and at most 32 calls in one model response. Task checkpoints provide working
memory for that task; ordinary chat history is still session-local.

Phone UI work still needs the companion's accessibility permission and an unlocked
phone. Notification work needs notification access. Resume UI tasks with attention
to the current screen, since a screen can change while a task is waiting.
