pub mod comms;
pub mod read;
pub mod shell;

use crate::ports::Tool;

/// v0 도구 세트 — 읽기(ReadOnly) + 변경(Mutating, 승인 필요).
pub fn default_tools() -> Vec<Box<dyn Tool>> {
    vec![
        Box::new(read::SmsList),
        Box::new(read::CallLog),
        Box::new(read::Battery),
        Box::new(read::Contacts),
        Box::new(comms::SmsSend),
        Box::new(comms::Call),
        Box::new(comms::Reminder),
        Box::new(shell::Shell),
        Box::new(shell::ReadFile),
        Box::new(shell::WriteFile),
        Box::new(shell::ListDir),
    ]
}
