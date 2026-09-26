// TOOLS — usix-companion 브리지(127.0.0.1:8760) 공용 클라이언트.
// 안드로이드는 모든 앱이 같은 loopback 을 공유하므로 포트만으론 호출자를 가릴 수 없다.
// → 앱이 발급한 토큰(~/.usix/companion_token)을 Bearer 헤더로 보내고, 서버가 대조한다.
// 페어링은 `usix-termux pair` 1회. 모든 요청에 연결·읽기 타임아웃을 둬 브리지가 멎어도 에이전트가 안 굳는다.
use anyhow::{anyhow, Result};
use serde_json::Value;
use std::path::PathBuf;
use std::time::Duration;

pub const PORT: u16 = 8760;

pub fn url(path: &str) -> String {
    format!("http://127.0.0.1:{PORT}{path}")
}

/// 토큰 파일 경로 — ~/.usix/companion_token (skills.rs 와 같은 홈 규약).
pub fn token_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".usix/companion_token")
}

/// 앱이 발급하는 토큰 형식(hex/base64url 계열, 16~128자). 클립보드 잡음을 걸러낸다.
pub fn valid_token(t: &str) -> bool {
    (16..=128).contains(&t.len())
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn load_token() -> Option<String> {
    let raw = std::fs::read_to_string(token_path()).ok()?;
    let t = raw.trim();
    valid_token(t).then(|| t.to_string())
}

/// 토큰 저장 — 소유자만 읽게(0600).
pub fn save_token(t: &str) -> Result<PathBuf> {
    let path = token_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, format!("{t}\n"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(path)
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(3))
        .timeout_read(Duration::from_secs(20))
        .timeout_write(Duration::from_secs(5))
        .build()
}

fn with_auth(req: ureq::Request) -> ureq::Request {
    match load_token() {
        Some(t) => req.set("Authorization", &format!("Bearer {t}")),
        None => req,
    }
}

/// 브리지 오류 → 모델·사용자에게 원인 안내. 401 은 페어링, 503 은 접근성 권한.
pub fn bridge_err(e: ureq::Error) -> anyhow::Error {
    match e {
        ureq::Error::Status(401, _) => anyhow!(
            "companion 토큰 불일치/없음 — 앱에서 '토큰 복사' 후 `usix-termux pair` 를 실행하라."
        ),
        ureq::Error::Status(503, _) => anyhow!(
            "접근성 서비스 꺼짐 — usix-companion 앱에서 '접근성(화면 제어)' 권한을 켜라."
        ),
        ureq::Error::Status(404, _) => anyhow!(
            "이 기능을 지원하지 않는 companion 버전 — usix-companion 앱도 함께 업데이트하라."
        ),
        other => anyhow!(
            "companion 브리지 무응답 — usix-companion 앱을 설치·실행하고 필요한 권한(알림 접근/접근성)을 켰는지 확인하라. ({other})"
        ),
    }
}

pub fn get(path: &str) -> Result<Value> {
    let resp = with_auth(agent().get(&url(path)))
        .call()
        .map_err(bridge_err)?;
    resp.into_json().map_err(|e| anyhow!("응답 파싱 실패: {e}"))
}

pub fn post(path: &str, body: Value) -> Result<Value> {
    let resp = with_auth(agent().post(&url(path)))
        .send_json(body)
        .map_err(bridge_err)?;
    resp.into_json().map_err(|e| anyhow!("응답 파싱 실패: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_format_gate() {
        assert!(valid_token("0123456789abcdef0123456789abcdef"));
        assert!(valid_token("AbC-_0123456789xyz"));
        assert!(!valid_token("short"));
        assert!(!valid_token("has space 0123456789abcdef"));
        assert!(!valid_token("has;semi0123456789abcdef"));
        assert!(!valid_token(&"a".repeat(129)));
    }
}
