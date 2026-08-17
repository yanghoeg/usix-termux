// ADAPTER — termux-api 명령 실행 헬퍼.
use anyhow::{anyhow, Result};
use std::process::Command;

// Termux:API 브리지가 무응답이면 termux-* 가 무한 hang → `timeout` 으로 상한을 둔다.
const TIMEOUT_SECS: &str = "8";

/// termux-* 바이너리를 실행하고 stdout(trim)을 돌려준다.
pub fn run(cmd: &str, args: &[&str]) -> Result<String> {
    let out = Command::new("timeout")
        .arg(TIMEOUT_SECS)
        .arg(cmd)
        .args(args)
        .output()
        .map_err(|e| anyhow!("{cmd} failed to run (termux-api installed?): {e}"))?;
    if out.status.code() == Some(124) {
        return Err(anyhow!(
            "{cmd} no response (>{TIMEOUT_SECS}s) — check the Termux:API app is installed, running, and permitted."
        ));
    }
    if !out.status.success() {
        return Err(anyhow!(
            "{cmd} error: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}
