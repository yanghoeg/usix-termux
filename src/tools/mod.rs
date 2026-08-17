pub mod comms;
pub mod read;

use crate::ports::Tool;

/// v0 도구 세트 — 읽기(ReadOnly) + 변경(Mutating, 승인 필요).
pub fn default_tools() -> Vec<Box<dyn Tool>> {
    vec![
        Box::new(read::SmsList),
        Box::new(read::CallLog),
        Box::new(read::Battery),
        Box::new(comms::SmsSend),
        Box::new(comms::Call),
    ]
}
