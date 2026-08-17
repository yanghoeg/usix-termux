pub mod comms;
pub mod read;
pub mod shell;
pub mod ui;

use crate::ports::Tool;

/// v0 도구 세트 — 읽기(ReadOnly) + 변경(Mutating, 승인 필요).
pub fn default_tools() -> Vec<Box<dyn Tool>> {
    let mut tools: Vec<Box<dyn Tool>> = vec![
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
    ];
    // 폰 UI 컨트롤(실험적) — 무선 디버깅 adb 필요. USIX_UI 설정 시에만 붙여 기본 스키마를 가볍게.
    if std::env::var("USIX_UI").is_ok() {
        tools.push(Box::new(ui::Screen));
        tools.push(Box::new(ui::AppOpen));
    }
    tools
}
