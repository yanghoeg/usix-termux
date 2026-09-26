use super::store::{now, Status, Store, Task};
use crate::domain::agent::{Agent, Turn};
use crate::domain::registry::Registry;
use crate::ports::Llm;
use anyhow::{ensure, Result};

pub type Approval<'a> = Option<&'a mut dyn FnMut(&str) -> Result<bool>>;

/// The caller holds the execution lock. No approval decision is stored for reuse.
pub fn run(
    store: &Store,
    id: u64,
    llm: &dyn Llm,
    registry: &Registry,
    mut approval: Approval<'_>,
    prepare: &mut dyn FnMut() -> Result<()>,
) -> Result<Task> {
    let mut task = store.get(id)?;
    ensure!(
        matches!(
            task.status,
            Status::Scheduled | Status::AwaitingApproval | Status::Interrupted | Status::Failed
        ),
        "task is {:?}; retry a finished task explicitly",
        task.status
    );
    ensure!(!task.action_in_flight,
        "an approved action may have executed; inspect the phone, then use `task retry {id}` if starting over is appropriate");
    crate::tools::ui::clear_cache();
    let mut agent = match task.checkpoint.clone() {
        Some(state) => Agent::restore(llm, registry, state)?,
        None => {
            let mut agent = Agent::new(llm, registry);
            agent.submit(&task.prompt);
            agent
        }
    };
    task.status = Status::Running;
    task.error = None;
    task.approval = None;
    task.checkpoint = Some(agent.checkpoint());
    store.save(&mut task)?;

    let result = (|| -> Result<()> {
        prepare()?;
        loop {
            let turn = agent.advance_step(&mut |_| {})?;
            task.checkpoint = Some(agent.checkpoint());
            match turn {
                None => store.save(&mut task)?,
                Some(Turn::Answer(answer)) => {
                    task.finish(answer, now())?;
                    store.save(&mut task)?;
                    return Ok(());
                }
                Some(Turn::NeedApproval { desc }) => {
                    task.status = Status::AwaitingApproval;
                    task.approval = Some(desc.clone());
                    store.save(&mut task)?;
                    let Some(decide) = approval.as_mut() else {
                        return Ok(());
                    };
                    if !decide(&desc)? {
                        agent.approve(false)?;
                        task.status = Status::Cancelled;
                        task.next_run_at = None;
                        task.approval = None;
                        task.checkpoint = None;
                        store.save(&mut task)?;
                        return Ok(());
                    }
                    // Save before executing. A crash after this point requires inspection,
                    // because the phone action and the local checkpoint cannot be atomic.
                    task.status = Status::Running;
                    task.action_in_flight = true;
                    store.save(&mut task)?;
                    agent.approve(true)?;
                    task.action_in_flight = false;
                    task.approval = None;
                    task.checkpoint = Some(agent.checkpoint());
                    store.save(&mut task)?;
                }
            }
        }
    })();
    if let Err(error) = result {
        // On a save failure retain the on-disk in-flight marker. In particular,
        // never overwrite a cancellation that changed the record's revision.
        task.status = if task.action_in_flight {
            Status::Interrupted
        } else {
            Status::Failed
        };
        task.error = Some(format!("{error:#}"));
        task.checkpoint = Some(agent.checkpoint());
        let _ = store.save(&mut task);
        return Err(error);
    }
    Ok(task)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::{ApprovalClass, Tool};
    use crate::tasks::store::tests::Fixture;
    use anyhow::{anyhow, bail};
    use serde_json::{json, Value};
    use std::collections::VecDeque;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    };

    struct Scripted {
        replies: Mutex<VecDeque<Value>>,
        requests: Mutex<Vec<Vec<Value>>>,
    }

    impl Scripted {
        fn new(replies: Vec<Value>) -> Self {
            Self {
                replies: Mutex::new(replies.into()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl Llm for Scripted {
        fn chat(&self, messages: &[Value], _: &[Value]) -> Result<Value> {
            self.requests.lock().unwrap().push(messages.to_vec());
            self.replies
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| anyhow!("model unavailable"))
        }
    }

    struct Counter {
        name: &'static str,
        class: ApprovalClass,
        count: Arc<AtomicUsize>,
        crash: bool,
    }

    impl Tool for Counter {
        fn name(&self) -> &str {
            self.name
        }
        fn description(&self) -> &str {
            "test phone tool"
        }
        fn parameters(&self) -> Value {
            json!({"type": "object"})
        }
        fn approval(&self) -> ApprovalClass {
            self.class
        }
        fn requires_fresh_screen(&self) -> bool {
            self.name == "ui_action"
        }
        fn run(&self, _: &Value) -> Result<String> {
            self.count.fetch_add(1, Ordering::SeqCst);
            assert!(!self.crash, "simulated crash after phone side effect");
            Ok(format!("{} result", self.name))
        }
    }

    fn call(names: &[&str]) -> Value {
        json!({"role": "assistant", "tool_calls": names.iter().map(|name| json!({
            "type": "function", "function": {"name": name, "arguments": {"text": "exact user text"}}
        })).collect::<Vec<_>>()})
    }

    fn answer() -> Value {
        json!({"role": "assistant", "content": "Finished from actual tool results"})
    }

    fn registry(crash: bool) -> (Registry, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let reads = Arc::new(AtomicUsize::new(0));
        let writes = Arc::new(AtomicUsize::new(0));
        (
            Registry::new(vec![
                Box::new(Counter {
                    name: "read_phone",
                    class: ApprovalClass::ReadOnly,
                    count: reads.clone(),
                    crash: false,
                }),
                Box::new(Counter {
                    name: "send",
                    class: ApprovalClass::Mutating,
                    count: writes.clone(),
                    crash,
                }),
            ]),
            reads,
            writes,
        )
    }

    #[test]
    fn background_task_pauses_and_resumes_exact_checkpoint_after_reopen() {
        let fixture = Fixture::new();
        let store = &fixture.store;
        let _execution = store.execution_lock().unwrap();
        let task = store.create("read then send", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![call(&["read_phone"]), call(&["send"]), answer()]);
        let (registry, reads, writes) = registry(false);
        let paused = run(store, task.id, &llm, &registry, None, &mut || Ok(())).unwrap();
        assert_eq!(paused.status, Status::AwaitingApproval);
        assert_eq!(reads.load(Ordering::SeqCst), 1);
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        // Serialize/reload, rather than reuse the in-memory agent.
        assert!(store.get(task.id).unwrap().checkpoint.is_some());
        let mut approvals = Vec::new();
        let completed = run(
            store,
            task.id,
            &llm,
            &registry,
            Some(&mut |desc| {
                approvals.push(desc.to_owned());
                Ok(true)
            }),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(completed.status, Status::Completed);
        assert_eq!(reads.load(Ordering::SeqCst), 1);
        assert_eq!(writes.load(Ordering::SeqCst), 1);
        assert_eq!(approvals.len(), 1);
        assert!(approvals[0].contains("exact user text"));
        let requests = llm.requests.lock().unwrap();
        assert!(requests
            .last()
            .unwrap()
            .iter()
            .any(|m| m["role"] == "tool" && m["content"] == "read_phone result"));
        assert!(completed.checkpoint.is_none());
    }

    #[test]
    fn declining_approval_cancels_siblings_without_model_recall() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture.store.create("send twice", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![call(&["send", "send"]), answer()]);
        let (registry, _, writes) = registry(false);
        let cancelled = run(
            &fixture.store,
            task.id,
            &llm,
            &registry,
            Some(&mut |_| Ok(false)),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(cancelled.status, Status::Cancelled);
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        assert_eq!(llm.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn approval_is_per_action_and_never_carries_into_repeated_runs() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture
            .store
            .create("send twice", 0, Some(60), 100)
            .unwrap();
        let llm = Scripted::new(vec![call(&["send", "send"]), answer(), call(&["send"])]);
        let (registry, _, writes) = registry(false);
        let mut approvals = 0;
        let completed = run(
            &fixture.store,
            task.id,
            &llm,
            &registry,
            Some(&mut |_| {
                approvals += 1;
                Ok(true)
            }),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(approvals, 2);
        assert_eq!(completed.status, Status::Scheduled);
        assert!(completed.next_run_at.unwrap() >= completed.last_finished_at.unwrap() + 60);
        let paused = run(&fixture.store, task.id, &llm, &registry, None, &mut || {
            Ok(())
        })
        .unwrap();
        assert_eq!(paused.status, Status::AwaitingApproval);
        assert_eq!(writes.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn crash_after_side_effect_cannot_replay_approved_action() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture.store.create("send", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![call(&["send"])]);
        let (registry, _, writes) = registry(true);
        let crash = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run(
                &fixture.store,
                task.id,
                &llm,
                &registry,
                Some(&mut |_| Ok(true)),
                &mut || Ok(()),
            )
            .unwrap();
        }));
        assert!(crash.is_err());
        assert!(fixture.store.get(task.id).unwrap().action_in_flight);
        fixture.store.recover().unwrap();
        assert_eq!(
            fixture.store.get(task.id).unwrap().status,
            Status::Interrupted
        );
        assert!(run(
            &fixture.store,
            task.id,
            &llm,
            &registry,
            Some(&mut |_| Ok(true)),
            &mut || Ok(())
        )
        .is_err());
        assert_eq!(writes.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn model_failure_retains_successful_reads_for_resume() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture.store.create("read", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![call(&["read_phone"])]);
        let (registry, reads, _) = registry(false);
        assert!(
            run(&fixture.store, task.id, &llm, &registry, None, &mut || Ok(
                ()
            ))
            .is_err()
        );
        assert_eq!(fixture.store.get(task.id).unwrap().status, Status::Failed);
        let resumed = run(
            &fixture.store,
            task.id,
            &Scripted::new(vec![answer()]),
            &registry,
            None,
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(resumed.status, Status::Completed);
        assert_eq!(reads.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn cancellation_during_approval_wins_before_side_effect() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture.store.create("send", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![call(&["send"])]);
        let (registry, _, writes) = registry(false);
        let result = run(
            &fixture.store,
            task.id,
            &llm,
            &registry,
            Some(&mut |_| {
                fixture.store.cancel(task.id)?;
                Ok(true)
            }),
            &mut || Ok(()),
        );
        assert!(result.is_err());
        assert_eq!(
            fixture.store.get(task.id).unwrap().status,
            Status::Cancelled
        );
        assert_eq!(writes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn unavailable_backend_and_step_exhaustion_are_failures() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let task = fixture.store.create("read", 0, None, 100).unwrap();
        let llm = Scripted::new(vec![answer()]);
        let (registry, _, _) = registry(false);
        assert!(run(
            &fixture.store,
            task.id,
            &llm,
            &registry,
            None,
            &mut || bail!("backend unavailable")
        )
        .is_err());
        assert_eq!(fixture.store.get(task.id).unwrap().status, Status::Failed);
        assert_eq!(llm.requests.lock().unwrap().len(), 0);
        let llm = Scripted::new((0..20).map(|_| call(&["read_phone"])).collect());
        assert!(
            run(&fixture.store, task.id, &llm, &registry, None, &mut || Ok(
                ()
            ))
            .is_err()
        );
        let saved = fixture.store.get(task.id).unwrap();
        assert_eq!(saved.status, Status::Failed);
        assert!(saved.error.unwrap().contains("step limit"));
    }

    #[test]
    fn invalid_model_responses_do_not_poison_a_resumable_checkpoint() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let (registry, reads, writes) = registry(false);
        let too_many = call(&["read_phone"; 33]);
        for replies in [
            vec![too_many],
            vec![json!({"role": "assistant", "content": ""}), call(&["send"])],
            vec![
                json!({"role": "assistant", "content": " "}),
                json!({"role": "assistant", "content": ""}),
            ],
        ] {
            let task = fixture.store.create("check", 0, None, 100).unwrap();
            assert!(run(
                &fixture.store,
                task.id,
                &Scripted::new(replies),
                &registry,
                None,
                &mut || Ok(())
            )
            .is_err());
            let llm = Scripted::new(vec![answer()]);
            let resumed = run(&fixture.store, task.id, &llm, &registry, None, &mut || {
                Ok(())
            })
            .unwrap();
            assert_eq!(resumed.status, Status::Completed);
            let requests = llm.requests.lock().unwrap();
            assert!(requests[0].iter().all(|m| m.get("tool_calls").is_none()));
        }
        assert_eq!(reads.load(Ordering::SeqCst), 0);
        assert_eq!(writes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn resumed_screen_actions_are_replanned_before_new_approval() {
        let fixture = Fixture::new();
        let _execution = fixture.store.execution_lock().unwrap();
        let reads = Arc::new(AtomicUsize::new(0));
        let taps = Arc::new(AtomicUsize::new(0));
        let sends = Arc::new(AtomicUsize::new(0));
        let registry = Registry::new(vec![
            Box::new(Counter {
                name: "ui_dump",
                class: ApprovalClass::ReadOnly,
                count: reads.clone(),
                crash: false,
            }),
            Box::new(Counter {
                name: "ui_action",
                class: ApprovalClass::Mutating,
                count: taps.clone(),
                crash: false,
            }),
            Box::new(Counter {
                name: "send",
                class: ApprovalClass::Mutating,
                count: sends.clone(),
                crash: false,
            }),
        ]);
        let task = fixture
            .store
            .create("use the phone screen", 0, None, 100)
            .unwrap();
        let first = Scripted::new(vec![call(&["ui_action", "send"])]);
        let paused = run(
            &fixture.store,
            task.id,
            &first,
            &registry,
            None,
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(paused.status, Status::AwaitingApproval);
        let resumed = Scripted::new(vec![call(&["ui_action"]), answer()]);
        let mut approvals = 0;
        let completed = run(
            &fixture.store,
            task.id,
            &resumed,
            &registry,
            Some(&mut |_| {
                assert_eq!(reads.load(Ordering::SeqCst), 1);
                approvals += 1;
                Ok(true)
            }),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(completed.status, Status::Completed);
        assert_eq!(approvals, 1);
        assert_eq!(taps.load(Ordering::SeqCst), 1);
        assert_eq!(sends.load(Ordering::SeqCst), 0);
        let requests = resumed.requests.lock().unwrap();
        assert_eq!(
            requests[0]
                .iter()
                .filter(|m| m["role"] == "tool"
                    && m["content"]
                        .as_str()
                        .is_some_and(|s| s.starts_with("Not executed.")))
                .count(),
            2
        );
    }
}
