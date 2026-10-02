pub mod runner;

use crate::adapters::clock::SystemClock;
use crate::adapters::task_store::FileStore;
use crate::bootstrap::BackendServeGuard;
use crate::domain::registry::Registry;
use crate::domain::tasks::{duration, Status, Task};
use crate::ports::{Clock, Host};
use anyhow::{bail, ensure, Context, Result};
use serde_json::json;
use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;
use std::time::Duration;

pub const HELP: &str = "Tasks:
  usix-code task add \"prompt\"                         queue a task now
  usix-code task schedule --after 10m \"prompt\"         run once after a delay
  usix-code task schedule --every 1h \"prompt\"          repeat after each completion
  usix-code task list                                  list status and saved results
  usix-code task show ID                               inspect one task
  usix-code task run ID                                run/resume with approval prompts
  usix-code task cancel ID                             cancel a waiting task or schedule
  usix-code task retry ID                              queue a stopped task from the start
  usix-code task bind ID [directory]                   bind a stopped task to a workspace
  usix-code task remove ID                             delete a stopped task and its history
  usix-code worker [--once]                            process due tasks without approvals

Durations: 30s, 10m, 1h, 1d (up to one year; repeating minimum 60s).
Use --after and --every together to set a repeat's first delay.
The worker must be running for scheduled work to execute. Overdue runs are coalesced.
Changing actions pause for `task run ID`; approvals never carry to future runs.
State: ~/.usix/tasks (override with USIX_TASKS_DIR).";

pub fn command(args: &[String], host: &dyn Host) -> Result<()> {
    if args.is_empty() || matches!(args[0].as_str(), "--help" | "-h") {
        println!("{HELP}");
        return Ok(());
    }
    let store = FileStore::default_location()?;
    let clock = SystemClock;
    match args[0].as_str() {
        "add" | "schedule" => {
            let (prompt, delay, interval) = parse_create(args)?;
            let task = store.create(&prompt, current_workspace()?, delay, interval, clock.now())?;
            print_task(&task)?;
            eprintln!("Queued. Run `usix-code worker` to execute scheduled tasks.");
        }
        "list" => {
            ensure!(args.len() == 1, "usage: task list");
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &store.list()?.iter().map(Task::summary).collect::<Vec<_>>()
                )?
            );
        }
        "show" => print_task(&store.get(parse_id(args)?)?)?,
        "cancel" => print_task(&store.cancel(parse_id(args)?, clock.now())?)?,
        "retry" => print_task(&store.retry(parse_id(args)?, clock.now())?)?,
        "bind" => {
            let (id, workspace) = parse_bind(args)?;
            print_task(&store.bind(id, workspace, clock.now())?)?;
        }
        "remove" => {
            let id = parse_id(args)?;
            store.remove(id)?;
            println!("{}", json!({"removed": id}));
        }
        "run" => {
            let id = parse_id(args)?;
            let _execution = store.execution_lock()?;
            store.recover(clock.now())?;
            let task = execute(&store, id, true, host, &clock)?;
            print_task(&task)?;
        }
        other => bail!("unknown task command: {other}\n{HELP}"),
    }
    Ok(())
}

fn current_workspace() -> Result<PathBuf> {
    std::env::current_dir()?
        .canonicalize()
        .context("resolve current workspace")
}

fn parse_bind(args: &[String]) -> Result<(u64, PathBuf)> {
    ensure!(
        args.len() == 2 || args.len() == 3,
        "usage: task bind ID [directory]"
    );
    let id = args[1]
        .parse::<u64>()
        .context("task ID must be a positive integer")?;
    ensure!(id > 0, "task ID must be a positive integer");
    let directory = args
        .get(2)
        .map(PathBuf::from)
        .unwrap_or(std::env::current_dir()?);
    let workspace = directory
        .canonicalize()
        .with_context(|| format!("resolve workspace {}", directory.display()))?;
    ensure!(workspace.is_dir(), "workspace must be a directory");
    Ok((id, workspace))
}

fn parse_id(args: &[String]) -> Result<u64> {
    ensure!(args.len() == 2, "usage: task {} ID", args[0]);
    let id = args[1]
        .parse::<u64>()
        .context("task ID must be a positive integer")?;
    ensure!(id > 0, "task ID must be a positive integer");
    Ok(id)
}

fn parse_create(args: &[String]) -> Result<(String, u64, Option<u64>)> {
    let mut delay = None;
    let mut interval = None;
    let mut index = 1;
    if args[0] == "schedule" {
        while index < args.len() {
            match args[index].as_str() {
                "--after" | "--every" => {
                    let slot = if args[index] == "--after" {
                        &mut delay
                    } else {
                        &mut interval
                    };
                    ensure!(slot.is_none(), "duplicate schedule option: {}", args[index]);
                    *slot = Some(duration(
                        args.get(index + 1)
                            .context("schedule option needs a duration")?,
                    )?);
                    index += 2;
                }
                "--" => {
                    index += 1;
                    break;
                }
                flag if flag.starts_with('-') => bail!("unknown schedule option: {flag}"),
                _ => break,
            }
        }
        ensure!(
            delay.is_some() || interval.is_some(),
            "schedule needs --after and/or --every"
        );
    }
    ensure!(index < args.len(), "task prompt is required");
    Ok((
        args[index..].join(" "),
        delay.or(interval).unwrap_or(0),
        interval,
    ))
}

fn print_task(task: &Task) -> Result<()> {
    // JSON escapes terminal controls in model output and approval arguments.
    println!("{}", serde_json::to_string_pretty(&task.summary())?);
    Ok(())
}

fn confirm(desc: &str) -> Result<bool> {
    println!("Approval required: {}", crate::tui::approval_text(desc));
    print!("Execute this action? [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

/// All execution entry points hold the same lock, including ordinary chat and -c.
fn execute(
    store: &FileStore,
    id: u64,
    interactive: bool,
    host: &dyn Host,
    clock: &dyn Clock,
) -> Result<Task> {
    let mut task = store.get(id)?;
    let workspace = match validate_workspace(&task) {
        Ok(workspace) => workspace,
        Err(error) => {
            // Stop scheduled retries before any model or tool can run in a bad workspace.
            if task.status == Status::Scheduled && !task.action_in_flight {
                task.status = Status::Failed;
                task.error = Some(format!("{error:#}"));
                store.save(&mut task, clock.now())?;
            }
            return Err(error);
        }
    };
    let llm = crate::backend()?;
    let registry = Registry::new(host.tools(&workspace));
    let skills = crate::adapters::skills::load(host.bundled_skills());
    host.reset_tools();
    let mut backend_guard = None;
    let mut prepare = || {
        backend_guard = Some(BackendServeGuard::start(host)?);
        Ok(())
    };
    let mut decide = confirm;
    let approval: runner::Approval<'_> =
        if interactive && io::stdin().is_terminal() && io::stdout().is_terminal() {
            Some(&mut decide)
        } else {
            None
        };
    runner::run(
        runner::Persistence::new(store, clock),
        id,
        llm.as_ref(),
        &registry,
        skills,
        approval,
        &mut prepare,
    )
}

fn validate_workspace(task: &Task) -> Result<PathBuf> {
    let workspace = task.workspace.as_ref().with_context(|| {
        format!(
            "task {} has no workspace; run `usix-code task bind {} [directory]` before execution",
            task.id, task.id
        )
    })?;
    ensure!(
        workspace.is_absolute(),
        "task workspace is not absolute; bind it again"
    );
    let canonical = workspace
        .canonicalize()
        .with_context(|| format!("task workspace is unavailable: {}", workspace.display()))?;
    ensure!(
        canonical == *workspace,
        "task workspace no longer resolves to its bound canonical path; inspect it and bind again"
    );
    ensure!(canonical.is_dir(), "task workspace is not a directory");
    Ok(canonical)
}

pub fn worker(args: &[String], host: &dyn Host) -> Result<()> {
    if args == ["--help"] || args == ["-h"] {
        println!("{HELP}");
        return Ok(());
    }
    ensure!(
        args.is_empty() || args == ["--once"],
        "usage: usix-code worker [--once]"
    );
    let once = !args.is_empty();
    let store = FileStore::default_location()?;
    let clock = SystemClock;
    let _worker = store.worker_lock()?;
    loop {
        match store.execution_lock() {
            Ok(_execution) => {
                store.recover(clock.now())?;
                // A snapshot prevents tasks created during a run from growing this batch.
                let due: Vec<u64> = store
                    .list()?
                    .iter()
                    .filter(|t| {
                        t.status == Status::Scheduled
                            && t.next_run_at.is_some_and(|at| at <= clock.now())
                    })
                    .map(|t| t.id)
                    .collect();
                for id in due {
                    // A user may cancel a queued task while earlier work runs.
                    if !store
                        .list()?
                        .iter()
                        .any(|t| t.id == id && t.status == Status::Scheduled)
                    {
                        continue;
                    }
                    match execute(&store, id, false, host, &clock) {
                        Ok(task) => {
                            print_task(&task)?;
                            notify(&task, host);
                        }
                        Err(error) => {
                            eprintln!("{}", json!({"task": id, "error": format!("{error:#}")}));
                            if let Ok(task) = store.get(id) {
                                notify(&task, host);
                            }
                        }
                    }
                }
            }
            Err(error) if !once && is_busy(&error) => {}
            Err(error) => return Err(error),
        }
        if once {
            return Ok(());
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}

fn is_busy(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<io::Error>()
            .is_some_and(|e| e.kind() == io::ErrorKind::WouldBlock)
    })
}

fn notify(task: &Task, host: &dyn Host) {
    let content = if task.status == Status::AwaitingApproval {
        format!(
            "Task {} needs approval. Run: usix-code task run {}",
            task.id, task.id
        )
    } else {
        format!(
            "Task {}: {:?}. View: usix-code task show {}",
            task.id, task.status, task.id
        )
    };
    host.notify(&content);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn schedule_options_are_unambiguous() {
        assert_eq!(
            parse_create(&args(&["add", "check", "battery"])).unwrap(),
            ("check battery".into(), 0, None)
        );
        assert_eq!(
            parse_create(&args(&["schedule", "--every", "1h", "check battery"])).unwrap(),
            ("check battery".into(), 3600, Some(3600))
        );
        assert_eq!(
            parse_create(&args(&[
                "schedule", "--after", "10m", "--every", "1h", "check"
            ]))
            .unwrap(),
            ("check".into(), 600, Some(3600))
        );
        for parts in [
            &["schedule", "check"][..],
            &["schedule", "--at", "9", "check"],
            &["schedule", "--after"],
            &["schedule", "--after", "1h"],
            &["schedule", "--after", "1h", "--after", "2h", "check"],
        ] {
            assert!(parse_create(&args(parts)).is_err());
        }
    }
}
