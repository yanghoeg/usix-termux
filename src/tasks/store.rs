use crate::domain::agent::AgentState;
use anyhow::{anyhow, bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_SECONDS: u64 = 365 * 24 * 60 * 60;
const MAX_TASKS: usize = 256;
const MAX_DATABASE_BYTES: u64 = 32 * 1024 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Scheduled,
    Running,
    AwaitingApproval,
    Interrupted,
    Failed,
    Completed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Task {
    pub id: u64,
    pub revision: u64,
    pub prompt: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub next_run_at: Option<u64>,
    pub interval_secs: Option<u64>,
    pub status: Status,
    pub completed_runs: u64,
    pub checkpoint: Option<AgentState>,
    /// Persisted before an approved side effect; cleared only after its result is saved.
    pub action_in_flight: bool,
    pub approval: Option<String>,
    pub last_result: Option<String>,
    pub last_finished_at: Option<u64>,
    pub error: Option<String>,
}

impl Task {
    pub fn summary(&self) -> Value {
        json!({
            "id": self.id, "prompt": self.prompt, "status": self.status,
            "created_at": self.created_at, "updated_at": self.updated_at,
            "next_run_at": self.next_run_at, "interval_secs": self.interval_secs,
            "completed_runs": self.completed_runs, "approval": self.approval,
            "action_in_flight": self.action_in_flight, "last_result": self.last_result,
            "last_finished_at": self.last_finished_at, "error": self.error,
        })
    }

    pub fn finish(&mut self, answer: String, finished_at: u64) -> Result<()> {
        self.next_run_at = self
            .interval_secs
            .map(|s| {
                finished_at
                    .checked_add(s)
                    .ok_or_else(|| anyhow!("schedule timestamp overflow"))
            })
            .transpose()?;
        self.status = if self.next_run_at.is_some() {
            Status::Scheduled
        } else {
            Status::Completed
        };
        self.last_result = Some(answer);
        self.last_finished_at = Some(finished_at);
        self.completed_runs += 1;
        self.checkpoint = None;
        self.approval = None;
        self.error = None;
        self.action_in_flight = false;
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
struct Database {
    version: u32,
    next_id: u64,
    tasks: Vec<Task>,
}

impl Default for Database {
    fn default() -> Self {
        Self {
            version: 1,
            next_id: 1,
            tasks: Vec::new(),
        }
    }
}

/// Closing this file releases the kernel lock, including after process termination.
pub struct FileLock {
    _file: File,
}

#[derive(Clone)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn default_location() -> Result<Self> {
        let root = match std::env::var_os("USIX_TASKS_DIR") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?)
                .join(".usix/tasks"),
        };
        Self::open(root)
    }

    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        ensure!(
            !root.as_os_str().is_empty(),
            "task directory cannot be empty"
        );
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&root)?;
        Ok(Self { root })
    }

    fn lock(&self, name: &str, wait: bool) -> Result<FileLock> {
        let file = private_file()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.root.join(name))?;
        let operation = libc::LOCK_EX | if wait { 0 } else { libc::LOCK_NB };
        // SAFETY: file owns a valid descriptor for the lifetime of this call and guard.
        if unsafe { libc::flock(file.as_raw_fd(), operation) } != 0 {
            return Err(std::io::Error::last_os_error()).context(format!("busy: {name}"));
        }
        Ok(FileLock { _file: file })
    }

    pub fn execution_lock(&self) -> Result<FileLock> {
        self.lock("execution.lock", false)
            .context("another task or interactive session is using the phone")
    }

    pub fn worker_lock(&self) -> Result<FileLock> {
        self.lock("worker.lock", false)
            .context("a task worker is already running")
    }

    fn read(&self) -> Result<Database> {
        let file = match private_file().read(true).open(self.root.join("state.json")) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Database::default()),
            Err(e) => return Err(e.into()),
        };
        let mut bytes = Vec::new();
        file.take(MAX_DATABASE_BYTES + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= MAX_DATABASE_BYTES,
            "task database exceeds size limit"
        );
        let db: Database = serde_json::from_slice(&bytes)
            .context("cannot read task database; original retained")?;
        ensure!(
            db.version == 1,
            "unsupported task database version: {}",
            db.version
        );
        ensure!(
            db.tasks.len() <= MAX_TASKS,
            "task database exceeds task limit"
        );
        Ok(db)
    }

    fn write(&self, db: &Database) -> Result<()> {
        let bytes = serde_json::to_vec(db)?;
        ensure!(
            bytes.len() as u64 <= MAX_DATABASE_BYTES,
            "task database exceeds size limit"
        );
        let temp = self.root.join(format!(
            ".state-{}-{}.tmp",
            std::process::id(),
            TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let result = (|| -> Result<()> {
            let mut file = private_file().write(true).create_new(true).open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temp, self.root.join("state.json"))?;
            File::open(&self.root)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }

    fn update<R>(&self, change: impl FnOnce(&mut Database) -> Result<R>) -> Result<R> {
        let _lock = self.lock("store.lock", true)?;
        let mut db = self.read()?;
        let result = change(&mut db)?;
        self.write(&db)?;
        Ok(result)
    }

    pub fn list(&self) -> Result<Vec<Task>> {
        let _lock = self.lock("store.lock", true)?;
        Ok(self.read()?.tasks)
    }

    pub fn get(&self, id: u64) -> Result<Task> {
        self.list()?
            .into_iter()
            .find(|t| t.id == id)
            .ok_or_else(|| anyhow!("task {id} not found"))
    }

    pub fn create(&self, prompt: &str, delay: u64, interval: Option<u64>, at: u64) -> Result<Task> {
        ensure!(
            !prompt.trim().is_empty() && prompt.len() <= 8192,
            "prompt must contain 1–8192 bytes"
        );
        ensure!(delay <= MAX_SECONDS, "delay cannot exceed one year");
        if let Some(seconds) = interval {
            ensure!(
                (60..=MAX_SECONDS).contains(&seconds),
                "repeat interval must be between 60 seconds and one year"
            );
        }
        let next_run = at
            .checked_add(delay)
            .context("schedule timestamp overflow")?;
        self.update(|db| {
            ensure!(
                db.tasks.len() < MAX_TASKS,
                "task limit reached; remove finished tasks first"
            );
            let task = Task {
                id: db.next_id,
                revision: 0,
                prompt: prompt.to_owned(),
                created_at: at,
                updated_at: at,
                next_run_at: Some(next_run),
                interval_secs: interval,
                status: Status::Scheduled,
                completed_runs: 0,
                checkpoint: None,
                action_in_flight: false,
                approval: None,
                last_result: None,
                last_finished_at: None,
                error: None,
            };
            db.next_id = db.next_id.checked_add(1).context("task id overflow")?;
            db.tasks.push(task.clone());
            Ok(task)
        })
    }

    /// The execution lock must be held while saving a running task.
    pub fn save(&self, task: &mut Task) -> Result<()> {
        let updated = self.update(|db| {
            let saved = db
                .tasks
                .iter_mut()
                .find(|t| t.id == task.id)
                .context("task disappeared")?;
            ensure!(
                saved.revision == task.revision,
                "task changed while running; reload it before continuing"
            );
            *saved = task.clone();
            saved.updated_at = now();
            saved.revision += 1;
            Ok(saved.clone())
        })?;
        *task = updated;
        Ok(())
    }

    /// Called only with the execution lock held, so no live execution is recovered.
    pub fn recover(&self) -> Result<()> {
        if !self.list()?.iter().any(|t| t.status == Status::Running) {
            return Ok(());
        }
        self.update(|db| {
            for task in &mut db.tasks {
                if task.status == Status::Running {
                    task.status = Status::Interrupted;
                    task.error = Some(if task.action_in_flight {
                        "An approved action may have executed. Inspect the phone before retrying; it will not be replayed automatically."
                    } else {
                        "Execution was interrupted. Run this task to resume its saved checkpoint."
                    }.into());
                    task.updated_at = now();
                    task.revision += 1;
                }
            }
            Ok(())
        })
    }

    pub fn cancel(&self, id: u64) -> Result<Task> {
        self.update(|db| {
            let task = db
                .tasks
                .iter_mut()
                .find(|t| t.id == id)
                .context("task not found")?;
            ensure!(
                task.status != Status::Running,
                "task is running; stop its runner before cancelling"
            );
            task.status = Status::Cancelled;
            task.next_run_at = None;
            task.checkpoint = None;
            task.approval = None;
            task.updated_at = now();
            task.revision += 1;
            Ok(task.clone())
        })
    }

    pub fn retry(&self, id: u64) -> Result<Task> {
        let _execution = self.execution_lock()?;
        self.recover()?;
        self.update(|db| {
            let task = db
                .tasks
                .iter_mut()
                .find(|t| t.id == id)
                .context("task not found")?;
            ensure!(
                matches!(
                    task.status,
                    Status::Failed | Status::Interrupted | Status::Cancelled | Status::Completed
                ),
                "only stopped tasks can be retried"
            );
            task.status = Status::Scheduled;
            task.next_run_at = Some(now());
            task.checkpoint = None;
            task.approval = None;
            task.action_in_flight = false;
            task.error = None;
            task.updated_at = now();
            task.revision += 1;
            Ok(task.clone())
        })
    }

    pub fn remove(&self, id: u64) -> Result<()> {
        self.update(|db| {
            let task = db
                .tasks
                .iter()
                .find(|t| t.id == id)
                .context("task not found")?;
            if !matches!(
                task.status,
                Status::Completed | Status::Cancelled | Status::Failed | Status::Interrupted
            ) {
                bail!("cancel the task before removing it");
            }
            db.tasks.retain(|t| t.id != id);
            Ok(())
        })
    }
}

fn private_file() -> OpenOptions {
    let mut options = OpenOptions::new();
    options
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    options
}

pub fn duration(text: &str) -> Result<u64> {
    let (number, multiplier) = match text.as_bytes().last() {
        Some(b's') => (&text[..text.len() - 1], 1),
        Some(b'm') => (&text[..text.len() - 1], 60),
        Some(b'h') => (&text[..text.len() - 1], 3600),
        Some(b'd') => (&text[..text.len() - 1], 86400),
        _ => (text, 1),
    };
    ensure!(
        !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()),
        "use a duration such as 30s, 10m, 1h, or 1d"
    );
    let seconds = number
        .parse::<u64>()?
        .checked_mul(multiplier)
        .context("duration overflow")?;
    ensure!(
        (1..=MAX_SECONDS).contains(&seconds),
        "duration must be between one second and one year"
    );
    Ok(seconds)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    pub struct Fixture {
        pub store: Store,
    }

    impl Fixture {
        pub fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "usix-tasks-test-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            Self {
                store: Store::open(root).unwrap(),
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.store.root);
        }
    }

    #[test]
    fn schedules_survive_reopening_with_private_storage() {
        let fixture = Fixture::new();
        let first = fixture
            .store
            .create("check battery", 30, Some(60), 100)
            .unwrap();
        let reopened = Store::open(&fixture.store.root).unwrap();
        let loaded = reopened.get(first.id).unwrap();
        assert_eq!(loaded.next_run_at, Some(130));
        assert_eq!(loaded.interval_secs, Some(60));
        assert_eq!(loaded.prompt, "check battery");
        assert_eq!(
            fs::metadata(reopened.root.join("state.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&reopened.root).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }

    #[test]
    fn concurrent_creates_keep_all_unique_ids() {
        let fixture = Fixture::new();
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let store = &fixture.store;
                scope.spawn(move || {
                    for _ in 0..5 {
                        store.create("check", 0, None, 100).unwrap();
                    }
                });
            }
        });
        let mut ids: Vec<_> = fixture.store.list().unwrap().iter().map(|t| t.id).collect();
        ids.sort_unstable();
        assert_eq!(ids, (1..=40).collect::<Vec<_>>());
    }

    #[test]
    fn execution_and_worker_locks_release_without_stale_pid_files() {
        let fixture = Fixture::new();
        let execution = fixture.store.execution_lock().unwrap();
        assert!(fixture.store.execution_lock().is_err());
        // Store updates do not block on the phone execution lock.
        fixture.store.create("check", 0, None, 100).unwrap();
        drop(execution);
        assert!(fixture.store.execution_lock().is_ok());
        let worker = fixture.store.worker_lock().unwrap();
        assert!(fixture.store.worker_lock().is_err());
        drop(worker);
        assert!(fixture.store.worker_lock().is_ok());
    }

    #[test]
    fn bad_database_is_preserved_and_symlinks_are_not_followed() {
        let fixture = Fixture::new();
        let state = fixture.store.root.join("state.json");
        fs::write(&state, "broken").unwrap();
        assert!(fixture.store.create("check", 0, None, 100).is_err());
        assert_eq!(fs::read_to_string(&state).unwrap(), "broken");
        fs::remove_file(&state).unwrap();
        let target = fixture.store.root.join("other.json");
        fs::write(&target, serde_json::to_vec(&Database::default()).unwrap()).unwrap();
        symlink(&target, &state).unwrap();
        assert!(fixture.store.list().is_err());
    }

    #[test]
    fn repeat_coalesces_missed_runs_and_cancel_stops_the_schedule() {
        let fixture = Fixture::new();
        let mut task = fixture.store.create("check", 60, Some(60), 100).unwrap();
        task.finish("battery 50%".into(), 10000).unwrap();
        fixture.store.save(&mut task).unwrap();
        assert_eq!(task.next_run_at, Some(10060));
        assert_eq!(task.completed_runs, 1);
        assert_eq!(task.status, Status::Scheduled);
        let cancelled = fixture.store.cancel(task.id).unwrap();
        assert_eq!(cancelled.next_run_at, None);
        assert_eq!(cancelled.status, Status::Cancelled);
        assert!(fixture.store.save(&mut task).is_err());
        fixture.store.remove(task.id).unwrap();
        assert!(fixture.store.list().unwrap().is_empty());
    }

    #[test]
    fn validates_schedule_bounds_and_durations() {
        let fixture = Fixture::new();
        for text in [
            "0",
            "-1",
            "1.5h",
            "",
            "1w",
            "366d",
            "999999999999999999999h",
            "1h\n",
        ] {
            assert!(duration(text).is_err(), "{text:?}");
        }
        assert_eq!(duration("2h").unwrap(), 7200);
        assert_eq!(duration("30").unwrap(), 30);
        assert!(fixture.store.create(" ", 0, None, 100).is_err());
        assert!(fixture.store.create("check", 0, Some(59), 100).is_err());
        assert!(fixture
            .store
            .create("check", MAX_SECONDS + 1, None, 100)
            .is_err());
        assert!(fixture.store.create("check", 1, None, u64::MAX).is_err());
    }
}
