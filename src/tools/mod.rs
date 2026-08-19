pub mod comms;
pub mod companion;
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
    // 폰 UI 컨트롤 — companion 앱 접근성 서비스 필요(루트·adb 불필요). 기본 등록.
    tools.push(Box::new(ui::Screen));
    tools.push(Box::new(ui::AppOpen));
    tools.push(Box::new(ui::UiTap));
    tools.push(Box::new(ui::UiType));
    tools.push(Box::new(ui::UiBack));
    // 알림 브리지(컴패니언 앱) — 카톡·라인 알림 읽기/인라인 답장. kakao_read 스킬의 기본 경로라 항상 등록.
    tools.push(Box::new(companion::NotifList));
    tools.push(Box::new(companion::NotifReply));
    tools
}
