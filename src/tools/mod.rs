pub mod bridge;
pub mod comms;
pub mod companion;
pub mod email;
pub mod read;
pub mod shell;
pub mod tasks;
pub mod ui;

use crate::ports::Tool;

/// Shared local tools; a host adapter may add device-specific capabilities.
pub fn local_tools() -> Vec<Box<dyn Tool>> {
    vec![
        Box::new(shell::Shell),
        Box::new(shell::ReadFile),
        Box::new(shell::WriteFile),
        Box::new(shell::ListDir),
        Box::new(tasks::TaskCreate),
        Box::new(tasks::TaskList),
        Box::new(tasks::TaskCancel),
    ]
}
