use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Cli {
    root: PathBuf,
}

impl Cli {
    fn new() -> Self {
        Self {
            root: std::env::temp_dir().join(format!(
                "usix-task-cli-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            )),
        }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_usix-termux"))
            .args(args)
            .env("USIX_TASKS_DIR", &self.root)
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

impl Drop for Cli {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn manage_tasks_across_processes_without_loading_a_model() {
    let cli = Cli::new();
    assert!(cli.json(&["task", "list"]).as_array().unwrap().is_empty());
    let created = cli.json(&[
        "task",
        "schedule",
        "--after",
        "1h",
        "--every",
        "1d",
        "check battery",
    ]);
    assert_eq!(created["id"], 1);
    assert_eq!(created["interval_secs"], 86400);
    assert_eq!(
        created["next_run_at"].as_u64().unwrap() - created["created_at"].as_u64().unwrap(),
        3600
    );
    assert!(cli.run(&["worker", "--once"]).status.success());
    assert_eq!(cli.json(&["task", "show", "1"])["status"], "scheduled");
    assert_eq!(cli.json(&["task", "cancel", "1"])["status"], "cancelled");
    assert_eq!(cli.json(&["task", "retry", "1"])["status"], "scheduled");
    assert!(!cli.run(&["task", "remove", "1"]).status.success());
    cli.json(&["task", "cancel", "1"]);
    assert_eq!(cli.json(&["task", "remove", "1"])["removed"], 1);
    assert!(cli.json(&["task", "list"]).as_array().unwrap().is_empty());
}

#[test]
fn bad_schedule_arguments_fail_without_queuing_work() {
    let cli = Cli::new();
    for args in [
        &["task", "schedule", "--every", "1s", "check"][..],
        &["task", "schedule", "--after", "0", "check"],
        &[
            "task", "schedule", "--after", "1h", "--after", "2h", "check",
        ],
        &["task", "schedule", "--at", "09:00", "check"],
        &["task", "add"],
        &["task", "show", "../1"],
        &["worker", "--unknown"],
    ] {
        assert!(!cli.run(args).status.success(), "{args:?}");
    }
    assert!(cli.json(&["task", "list"]).as_array().unwrap().is_empty());
}

#[test]
fn another_process_cannot_start_a_second_worker() {
    let cli = Cli::new();
    cli.json(&["task", "list"]);
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(cli.root.join("worker.lock"))
        .unwrap();
    // SAFETY: lock owns this descriptor throughout the child process invocation.
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let blocked = cli.run(&["worker", "--once"]);
    assert!(!blocked.status.success());
    assert!(String::from_utf8_lossy(&blocked.stderr).contains("worker is already running"));
    drop(lock);
    assert!(cli.run(&["worker", "--once"]).status.success());
}
