//! Owned inference processes are supervised through a private lifetime pipe.
//! EOF cleans up the entire backend group even if the harness is killed or crashes.
use crate::ports::LaunchSpec;
use anyhow::{ensure, Context, Result};
use std::fs::OpenOptions;
use std::io::{BufRead, Read, Write};
use std::os::unix::{fs::OpenOptionsExt, process::CommandExt};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const MAX_LAUNCH_BYTES: usize = 64 * 1024;
static STOP: AtomicBool = AtomicBool::new(false);

pub fn spawn(spec: LaunchSpec, log_path: &Path) -> Result<Child> {
    let payload = serde_json::to_vec(&spec)?;
    ensure!(
        payload.len() < MAX_LAUNCH_BYTES,
        "backend launch specification is too large"
    );
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("__supervise-backend")
        .stdin(Stdio::piped())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    // SAFETY: only async-signal-safe operations run between fork and exec.
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
    let mut owned = OwnedServer(Some(command.spawn().context("start backend supervisor")?));
    let control = owned
        .0
        .as_mut()
        .unwrap()
        .stdin
        .as_mut()
        .context("supervisor lifetime pipe")?;
    control.write_all(&payload)?;
    control.write_all(b"\n")?;
    Ok(owned.0.take().unwrap())
}

extern "C" fn stop_signal(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

/// Internal executable entry point; has no network listener or persistent state.
pub fn supervise() -> Result<()> {
    let mut specification = String::new();
    std::io::stdin()
        .lock()
        .take(MAX_LAUNCH_BYTES as u64)
        .read_line(&mut specification)?;
    ensure!(
        specification.ends_with('\n'),
        "incomplete backend launch specification"
    );
    let spec: LaunchSpec = serde_json::from_str(&specification)?;
    // SAFETY: the handler only stores a lock-free atomic flag.
    unsafe {
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = stop_signal as *const () as usize;
            libc::sigemptyset(&mut action.sa_mask);
            ensure!(
                libc::sigaction(signal, &action, std::ptr::null_mut()) == 0,
                "cannot install supervisor shutdown handler"
            );
        }
    }
    let mut command = Command::new(&spec.program);
    command
        .args(spec.args)
        .envs(spec.env)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    // The model and any GPU wrapper descendants share their own process group.
    // SAFETY: only async-signal-safe operations run before exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
                if libc::signal(signal, libc::SIG_DFL) == libc::SIG_ERR {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut backend = command.spawn().context("start inference backend")?;
    let outcome = (|| -> Result<()> {
        loop {
            if STOP.load(Ordering::Relaxed) {
                return Ok(());
            }
            if let Some(status) = backend.try_wait()? {
                ensure!(status.success(), "inference backend exited: {status}");
                return Ok(());
            }
            let mut descriptor = libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN | libc::POLLHUP,
                revents: 0,
            };
            // SAFETY: descriptor points to one initialized pollfd for this call.
            let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error.into());
                }
            } else if ready > 0 && descriptor.revents != 0 {
                // EOF (including SIGKILL of the owner), or unexpected control data.
                return Ok(());
            }
        }
    })();
    stop_group(&mut backend);
    outcome
}

fn stop_group(child: &mut Child) {
    let group = -(child.id() as libc::pid_t);
    // SAFETY: this group was created for the child retained by this supervisor.
    unsafe {
        libc::kill(group, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        if child.try_wait().ok().flatten().is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    // Also reap wrapper descendants that ignored TERM or outlived the group leader.
    unsafe {
        libc::kill(group, libc::SIGKILL);
    }
    let _ = child.wait();
}

/// Never stop a process discovered by name or port. Closing our private pipe
/// asks only our supervisor to stop its backend and descendants.
pub struct OwnedServer(pub Option<Child>);

impl Drop for OwnedServer {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            drop(child.stdin.take());
            let _ = child.wait();
        }
    }
}
