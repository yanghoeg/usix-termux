use crate::domain::tasks::{Status, Task};
use crate::ports::TaskStore;
use anyhow::{anyhow, bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

const MAX_TASKS: usize = 256;
const MAX_DATABASE_BYTES: u64 = 32 * 1024 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

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
pub struct FileStore {
    root: PathBuf,
}

impl FileStore {
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
            .context("another task or interactive session is using the local harness")
    }

    pub fn worker_lock(&self) -> Result<FileLock> {
        self.lock("worker.lock", false)
            .context("a task worker is already running")
    }

    fn read(&self) -> Result<Database> {
        let file = match private_file().read(true).open(self.root.join("state.json")) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Database::default())
            }
            Err(error) => return Err(error.into()),
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
            .find(|task| task.id == id)
            .ok_or_else(|| anyhow!("task {id} not found"))
    }

    pub fn create(
        &self,
        prompt: &str,
        workspace: PathBuf,
        delay: u64,
        interval: Option<u64>,
        at: u64,
    ) -> Result<Task> {
        self.update(|db| {
            ensure!(
                db.tasks.len() < MAX_TASKS,
                "task limit reached; remove finished tasks first"
            );
            let task = Task::new(db.next_id, prompt, workspace, delay, interval, at)?;
            db.next_id = db.next_id.checked_add(1).context("task id overflow")?;
            db.tasks.push(task.clone());
            Ok(task)
        })
    }

    /// The execution lock must be held while saving a running task.
    pub fn save(&self, task: &mut Task, at: u64) -> Result<()> {
        let updated = self.update(|db| {
            let saved = db
                .tasks
                .iter_mut()
                .find(|saved| saved.id == task.id)
                .context("task disappeared")?;
            ensure!(
                saved.revision == task.revision,
                "task changed while running; reload it before continuing"
            );
            *saved = task.clone();
            saved.updated_at = at;
            saved.revision += 1;
            Ok(saved.clone())
        })?;
        *task = updated;
        Ok(())
    }

    /// Called only with the execution lock held, so no live execution is recovered.
    pub fn recover(&self, at: u64) -> Result<()> {
        if !self
            .list()?
            .iter()
            .any(|task| task.status == Status::Running)
        {
            return Ok(());
        }
        self.update(|db| {
            for task in &mut db.tasks {
                if task.status == Status::Running {
                    task.status = Status::Interrupted;
                    task.error = Some(if task.action_in_flight {
                        "An approved action may have executed. Inspect the affected state before retrying; it will not be replayed automatically."
                    } else {
                        "Execution was interrupted. Run this task to resume its saved checkpoint."
                    }.into());
                    task.updated_at = at;
                    task.revision += 1;
                }
            }
            Ok(())
        })
    }

    pub fn cancel(&self, id: u64, at: u64) -> Result<Task> {
        self.update(|db| {
            let task = db
                .tasks
                .iter_mut()
                .find(|task| task.id == id)
                .context("task not found")?;
            ensure!(
                task.status != Status::Running,
                "task is running; stop its runner before cancelling"
            );
            task.status = Status::Cancelled;
            task.next_run_at = None;
            task.checkpoint = None;
            task.approval = None;
            task.updated_at = at;
            task.revision += 1;
            Ok(task.clone())
        })
    }

    pub fn retry(&self, id: u64, at: u64) -> Result<Task> {
        let _execution = self.execution_lock()?;
        self.recover(at)?;
        self.update(|db| {
            let task = db
                .tasks
                .iter_mut()
                .find(|task| task.id == id)
                .context("task not found")?;
            ensure!(
                matches!(
                    task.status,
                    Status::Failed | Status::Interrupted | Status::Cancelled | Status::Completed
                ),
                "only stopped tasks can be retried"
            );
            task.status = Status::Scheduled;
            task.next_run_at = Some(at);
            task.checkpoint = None;
            task.approval = None;
            task.action_in_flight = false;
            task.error = None;
            task.updated_at = at;
            task.revision += 1;
            Ok(task.clone())
        })
    }

    pub fn bind(&self, id: u64, workspace: PathBuf, at: u64) -> Result<Task> {
        ensure!(workspace.is_absolute(), "task workspace must be absolute");
        let _execution = self.execution_lock()?;
        self.recover(at)?;
        self.update(|db| {
            let task = db
                .tasks
                .iter_mut()
                .find(|task| task.id == id)
                .context("task not found")?;
            ensure!(
                !matches!(task.status, Status::Running | Status::AwaitingApproval),
                "stop or cancel the task before binding its workspace"
            );
            ensure!(!task.action_in_flight,
                "an approved action may have executed; inspect the affected state, then use `task retry {id}` before binding if starting over is appropriate");
            ensure!(task.checkpoint.is_none(),
                "task has a saved checkpoint; use `task retry {id}` to discard it before binding a workspace");
            task.workspace = Some(workspace);
            task.approval = None;
            task.error = None;
            task.updated_at = at;
            task.revision += 1;
            Ok(task.clone())
        })
    }

    pub fn remove(&self, id: u64) -> Result<()> {
        self.update(|db| {
            let task = db
                .tasks
                .iter()
                .find(|task| task.id == id)
                .context("task not found")?;
            if !matches!(
                task.status,
                Status::Completed | Status::Cancelled | Status::Failed | Status::Interrupted
            ) {
                bail!("cancel the task before removing it");
            }
            db.tasks.retain(|task| task.id != id);
            Ok(())
        })
    }
}

impl TaskStore for FileStore {
    fn get(&self, id: u64) -> Result<Task> {
        FileStore::get(self, id)
    }

    fn save(&self, task: &mut Task, at: u64) -> Result<()> {
        FileStore::save(self, task, at)
    }
}

fn private_file() -> OpenOptions {
    let mut options = OpenOptions::new();
    options
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    options
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::domain::tasks::MAX_SECONDS;
    use std::os::unix::fs::{symlink, PermissionsExt};

    pub struct Fixture {
        pub store: FileStore,
        pub workspace: PathBuf,
    }

    impl Fixture {
        pub fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "usix-tasks-test-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let workspace = root.join("workspace");
            let store = FileStore::open(root).unwrap();
            fs::create_dir_all(&workspace).unwrap();
            Self { store, workspace }
        }

        pub fn create(&self, prompt: &str, delay: u64, interval: Option<u64>, at: u64) -> Task {
            self.store
                .create(prompt, self.workspace.clone(), delay, interval, at)
                .unwrap()
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
        let first = fixture.create("check battery", 30, Some(60), 100);
        let reopened = FileStore::open(&fixture.store.root).unwrap();
        let loaded = reopened.get(first.id).unwrap();
        assert_eq!(loaded.next_run_at, Some(130));
        assert_eq!(loaded.interval_secs, Some(60));
        assert_eq!(loaded.prompt, "check battery");
        assert_eq!(loaded.workspace, Some(fixture.workspace.clone()));
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
                let workspace = fixture.workspace.clone();
                scope.spawn(move || {
                    for _ in 0..5 {
                        store
                            .create("check", workspace.clone(), 0, None, 100)
                            .unwrap();
                    }
                });
            }
        });
        let mut ids: Vec<_> = fixture
            .store
            .list()
            .unwrap()
            .iter()
            .map(|task| task.id)
            .collect();
        ids.sort_unstable();
        assert_eq!(ids, (1..=40).collect::<Vec<_>>());
    }

    #[test]
    fn execution_and_worker_locks_release_without_stale_pid_files() {
        let fixture = Fixture::new();
        let execution = fixture.store.execution_lock().unwrap();
        assert!(fixture.store.execution_lock().is_err());
        fixture.create("check", 0, None, 100);
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
        assert!(fixture
            .store
            .create("check", fixture.workspace.clone(), 0, None, 100)
            .is_err());
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
        let mut task = fixture.create("check", 60, Some(60), 100);
        task.finish("battery 50%".into(), 10000).unwrap();
        fixture.store.save(&mut task, 10001).unwrap();
        assert_eq!(task.next_run_at, Some(10060));
        assert_eq!(task.completed_runs, 1);
        assert_eq!(task.status, Status::Scheduled);
        assert_eq!(task.updated_at, 10001);
        let cancelled = fixture.store.cancel(task.id, 10002).unwrap();
        assert_eq!(cancelled.next_run_at, None);
        assert_eq!(cancelled.status, Status::Cancelled);
        assert!(fixture.store.save(&mut task, 10003).is_err());
        fixture.store.remove(task.id).unwrap();
        assert!(fixture.store.list().unwrap().is_empty());
    }

    #[test]
    fn binding_requires_safe_checkpoint_free_state() {
        let fixture = Fixture::new();
        let task = fixture.create("check", 0, None, 100);
        let rebound = fixture
            .store
            .bind(task.id, fixture.workspace.clone(), 101)
            .unwrap();
        assert_eq!(rebound.updated_at, 101);
        assert_eq!(rebound.workspace, Some(fixture.workspace.clone()));
    }

    #[test]
    fn create_still_rejects_invalid_schedule_values() {
        let fixture = Fixture::new();
        assert!(fixture
            .store
            .create(" ", fixture.workspace.clone(), 0, None, 100)
            .is_err());
        assert!(fixture
            .store
            .create("check", fixture.workspace.clone(), 0, Some(59), 100)
            .is_err());
        assert!(fixture
            .store
            .create(
                "check",
                fixture.workspace.clone(),
                MAX_SECONDS + 1,
                None,
                100
            )
            .is_err());
        assert!(fixture
            .store
            .create("check", fixture.workspace.clone(), 1, None, u64::MAX)
            .is_err());
    }
}
