use crate::ports::{ApprovalClass, Tool};
use crate::tasks::store::{now, Store, MAX_SECONDS};
use anyhow::{Context, Result};
use serde_json::{json, Value};

pub struct TaskCreate;
impl Tool for TaskCreate {
    fn name(&self) -> &str {
        "task_create"
    }
    fn description(&self) -> &str {
        "Queue a multi-step phone task for later. delay_seconds is the first delay (0 means now); optional interval_seconds repeats after each completion. A running `usix-termux worker` is required. Phone-changing actions pause for separate human approval. Use for scheduled work, not simple reminder notifications."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "prompt": {"type": "string", "description": "The complete task to perform at execution time, including the user's constraints", "minLength": 1, "maxLength": 8192},
            "delay_seconds": {"type": "integer", "minimum": 0, "maximum": MAX_SECONDS},
            "interval_seconds": {"type": "integer", "minimum": 60, "maximum": MAX_SECONDS}
        }, "required": ["prompt", "delay_seconds"], "additionalProperties": false})
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let prompt = args["prompt"].as_str().context("prompt is required")?;
        let delay = args["delay_seconds"]
            .as_u64()
            .context("delay_seconds must be a non-negative integer")?;
        let interval = match args.get("interval_seconds") {
            Some(value) => Some(
                value
                    .as_u64()
                    .context("interval_seconds must be a positive integer")?,
            ),
            None => None,
        };
        let task = Store::default_location()?.create(prompt, delay, interval, now())?;
        Ok(json!({"task": task.summary(), "worker_required": true,
            "message": "Task queued; it executes only while `usix-termux worker` is running. Changing phone actions require separate approval."}).to_string())
    }
}

pub struct TaskList;
impl Tool for TaskList {
    fn name(&self) -> &str {
        "task_list"
    }
    fn description(&self) -> &str {
        "List the 20 newest saved tasks and schedules. Use id to inspect one task's full prompt, pending approval, and last result."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}}, "additionalProperties": false})
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let store = Store::default_location()?;
        if let Some(value) = args.get("id") {
            return Ok(store
                .get(value.as_u64().context("id must be a positive integer")?)?
                .summary()
                .to_string());
        }
        let tasks = store.list()?;
        Ok(json!({"total": tasks.len(), "tasks": tasks.iter().rev().take(20).map(|task| json!({
            "id": task.id, "prompt": task.prompt.chars().take(160).collect::<String>(),
            "status": task.status, "next_run_at": task.next_run_at, "interval_secs": task.interval_secs,
        })).collect::<Vec<_>>()}).to_string())
    }
}

pub struct TaskCancel;
impl Tool for TaskCancel {
    fn name(&self) -> &str {
        "task_cancel"
    }
    fn description(&self) -> &str {
        "Cancel a queued task, repeating schedule, or pending approval by its task id."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}}, "required": ["id"], "additionalProperties": false})
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        Ok(Store::default_location()?
            .cancel(
                args["id"]
                    .as_u64()
                    .context("id must be a positive integer")?,
            )?
            .summary()
            .to_string())
    }
}
