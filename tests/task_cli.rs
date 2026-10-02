use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
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
        self.run_in(args, Path::new(env!("CARGO_MANIFEST_DIR")))
    }

    fn run_in(&self, args: &[&str], directory: &Path) -> Output {
        Command::new(env!("CARGO_BIN_EXE_usix-code"))
            .args(args)
            .current_dir(directory)
            .env("USIX_TASKS_DIR", &self.root)
            .env_remove("USIX_BACKEND")
            .env_remove("USIX_MODEL")
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

#[test]
fn task_workspace_survives_processes_started_from_another_directory() {
    let cli = Cli::new();
    let first = cli.root.join("first workspace");
    let second = cli.root.join("second workspace");
    fs::create_dir_all(&first).unwrap();
    fs::create_dir_all(&second).unwrap();
    let created: Value = serde_json::from_slice(
        &cli.run_in(&["task", "add", "inspect local files"], &first)
            .stdout,
    )
    .unwrap();
    assert_eq!(
        created["workspace"],
        first.canonicalize().unwrap().to_string_lossy().as_ref()
    );
    let shown: Value =
        serde_json::from_slice(&cli.run_in(&["task", "show", "1"], &second).stdout).unwrap();
    assert_eq!(shown["workspace"], created["workspace"]);
}

#[test]
fn legacy_unbound_task_is_rejected_before_backend_selection() {
    let cli = Cli::new();
    let workspace = cli.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    assert!(cli
        .run_in(&["task", "add", "inspect local files"], &workspace)
        .status
        .success());
    let state_path = cli.root.join("state.json");
    let mut state: Value = serde_json::from_slice(&fs::read(&state_path).unwrap()).unwrap();
    state["tasks"][0]
        .as_object_mut()
        .unwrap()
        .remove("workspace");
    fs::write(&state_path, serde_json::to_vec(&state).unwrap()).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_usix-code"))
        .args(["task", "run", "1"])
        .current_dir(&workspace)
        .env("USIX_TASKS_DIR", &cli.root)
        .env("USIX_BACKEND", "invalid-if-reached")
        .output()
        .unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("has no workspace"), "{error}");
    assert!(!error.contains("unknown USIX_BACKEND"), "{error}");

    let rebound = cli.run_in(&["task", "bind", "1", second_arg(&workspace)], &workspace);
    assert!(
        rebound.status.success(),
        "{}",
        String::from_utf8_lossy(&rebound.stderr)
    );
    let rebound: Value = serde_json::from_slice(&rebound.stdout).unwrap();
    assert_eq!(
        rebound["workspace"],
        workspace.canonicalize().unwrap().to_string_lossy().as_ref()
    );
}

fn second_arg(path: &Path) -> &str {
    path.to_str().unwrap()
}

#[test]
fn missing_workspace_pauses_scheduled_work_before_model_startup() {
    let cli = Cli::new();
    let workspace = cli.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    assert!(cli
        .run_in(&["task", "add", "inspect local files"], &workspace)
        .status
        .success());
    fs::remove_dir(&workspace).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_usix-code"))
        .args(["worker", "--once"])
        .env("USIX_TASKS_DIR", &cli.root)
        .env("USIX_BACKEND", "invalid-if-reached")
        .output()
        .unwrap();
    assert!(output.status.success());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("workspace is unavailable"), "{error}");
    assert!(!error.contains("unknown USIX_BACKEND"), "{error}");
    let task = cli.json(&["task", "show", "1"]);
    assert_eq!(task["status"], "failed");
    assert!(task["error"]
        .as_str()
        .unwrap()
        .contains("workspace is unavailable"));
}

#[test]
fn renamed_cli_exposes_local_harness_help() {
    let cli = Cli::new();
    let output = cli.run(&["--help"]);
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout)
        .contains("fully local coding and automation harness"));
    let output = cli.run(&["--version"]);
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("usix-code "));
}

#[test]
fn missing_custom_model_fails_before_backend_installation() {
    let cli = Cli::new();
    let output = Command::new(env!("CARGO_BIN_EXE_usix-code"))
        .arg("setup")
        .env("USIX_BACKEND", "llama")
        .env("USIX_MODEL", cli.root.join("missing.gguf"))
        .env("PATH", "")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("model file not found"));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_pairing_is_rejected_before_reading_clipboard_or_stdin() {
    let output = Cli::new().run(&["pair"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("pairing is unavailable on Linux"));
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
