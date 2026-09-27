//! Local process lifecycle shared by the Linux and Termux host adapters.
use crate::ports::LaunchSpec;
use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};

pub fn spawn(spec: LaunchSpec, log_path: &Path) -> Result<Child> {
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    let mut command = Command::new(&spec.program);
    command
        .args(spec.args)
        .envs(spec.env)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    // SAFETY: only async-signal-safe libc operations run between fork and exec.
    // A private session keeps setup's server alive after the launching terminal closes.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::signal(libc::SIGHUP, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn().with_context(|| {
        format!(
            "start {} (run `usix-code setup` first)",
            spec.program.display()
        )
    })
}

/// Retain the Child handle: never stop a process discovered by name or port.
pub struct OwnedServer(pub Option<Child>);

impl Drop for OwnedServer {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_stops_only_its_child() {
        let log = std::env::temp_dir().join(format!("usix-runtime-{}.log", std::process::id()));
        let mut spec = LaunchSpec::new("sleep");
        spec.args.push("60".into());
        let mut unrelated = Command::new("sleep").arg("60").spawn().unwrap();
        let owned = spawn(spec, &log).unwrap();
        let pid = owned.id();
        drop(OwnedServer(Some(owned)));
        // SAFETY: signal 0 checks existence without sending a signal.
        assert_eq!(unsafe { libc::kill(pid as libc::pid_t, 0) }, -1);
        assert!(unrelated.try_wait().unwrap().is_none());
        unrelated.kill().unwrap();
        unrelated.wait().unwrap();
        let _ = std::fs::remove_file(log);
    }
}
