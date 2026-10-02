use crate::domain::agent::AgentState;
use anyhow::{anyhow, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

pub const MAX_SECONDS: u64 = 365 * 24 * 60 * 60;

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
    /// Canonical absolute directory in which this task was created.
    #[serde(default)]
    pub workspace: Option<PathBuf>,
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
    pub fn new(
        id: u64,
        prompt: &str,
        workspace: PathBuf,
        delay: u64,
        interval: Option<u64>,
        at: u64,
    ) -> Result<Self> {
        ensure!(
            !prompt.trim().is_empty() && prompt.len() <= 8192,
            "prompt must contain 1–8192 bytes"
        );
        ensure!(delay <= MAX_SECONDS, "delay cannot exceed one year");
        ensure!(workspace.is_absolute(), "task workspace must be absolute");
        if let Some(seconds) = interval {
            ensure!(
                (60..=MAX_SECONDS).contains(&seconds),
                "repeat interval must be between 60 seconds and one year"
            );
        }
        let next_run_at = at
            .checked_add(delay)
            .context("schedule timestamp overflow")?;
        Ok(Self {
            id,
            revision: 0,
            prompt: prompt.to_owned(),
            workspace: Some(workspace),
            created_at: at,
            updated_at: at,
            next_run_at: Some(next_run_at),
            interval_secs: interval,
            status: Status::Scheduled,
            completed_runs: 0,
            checkpoint: None,
            action_in_flight: false,
            approval: None,
            last_result: None,
            last_finished_at: None,
            error: None,
        })
    }

    pub fn summary(&self) -> Value {
        json!({
            "id": self.id, "prompt": self.prompt, "workspace": self.workspace,
            "status": self.status, "created_at": self.created_at, "updated_at": self.updated_at,
            "next_run_at": self.next_run_at, "interval_secs": self.interval_secs,
            "completed_runs": self.completed_runs, "approval": self.approval,
            "action_in_flight": self.action_in_flight, "last_result": self.last_result,
            "last_finished_at": self.last_finished_at, "error": self.error,
        })
    }

    pub fn finish(&mut self, answer: String, finished_at: u64) -> Result<()> {
        self.next_run_at = self
            .interval_secs
            .map(|seconds| {
                finished_at
                    .checked_add(seconds)
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

pub fn duration(text: &str) -> Result<u64> {
    let (number, multiplier) = match text.as_bytes().last() {
        Some(b's') => (&text[..text.len() - 1], 1),
        Some(b'm') => (&text[..text.len() - 1], 60),
        Some(b'h') => (&text[..text.len() - 1], 3600),
        Some(b'd') => (&text[..text.len() - 1], 86400),
        _ => (text, 1),
    };
    ensure!(
        !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit()),
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
mod tests {
    use super::*;

    #[test]
    fn validates_schedule_bounds_and_durations() {
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
        assert!(Task::new(1, " ", "/tmp".into(), 0, None, 100).is_err());
        assert!(Task::new(1, "check", "/tmp".into(), 0, Some(59), 100).is_err());
        assert!(Task::new(1, "check", "/tmp".into(), MAX_SECONDS + 1, None, 100).is_err());
        assert!(Task::new(1, "check", "/tmp".into(), 1, None, u64::MAX).is_err());
    }

    #[test]
    fn legacy_task_without_workspace_deserializes_unbound() {
        let task = Task::new(1, "check", "/tmp".into(), 0, None, 100).unwrap();
        let mut value = serde_json::to_value(task).unwrap();
        value.as_object_mut().unwrap().remove("workspace");
        let loaded: Task = serde_json::from_value(value).unwrap();
        assert!(loaded.workspace.is_none());
    }
}
