pub mod clock;
pub mod host;
pub mod llama;
pub mod ollama;
pub mod runtime;
pub mod skills;
pub mod task_store;
pub mod termux;
pub mod workspace;

/// llama-server 포트 (llama.cpp 기본값).
pub const LLAMA_PORT: u16 = 8080;

fn port(name: &str, default: u16) -> anyhow::Result<u16> {
    let value = match std::env::var(name) {
        Ok(value) => value
            .parse::<u16>()
            .map_err(|_| anyhow::anyhow!("{name} must be a valid TCP port"))?,
        Err(std::env::VarError::NotPresent) => default,
        Err(error) => return Err(error.into()),
    };
    anyhow::ensure!(value > 0, "{name} must not be zero");
    Ok(value)
}

pub fn llama_port() -> anyhow::Result<u16> {
    port("USIX_LLAMA_PORT", LLAMA_PORT)
}
pub fn ollama_port() -> anyhow::Result<u16> {
    port("USIX_OLLAMA_PORT", 11434)
}

/// LLM 백엔드용 HTTP 에이전트 — 타임아웃 필수. 서버가 연결만 받고 침묵하면 워커 스레드가
/// "Thinking…" 에 영구 블록되므로 상한을 둔다. 읽기 상한은 폰에서 긴 프롬프트 프리필+생성이
/// 수 분 걸릴 수 있어 넉넉히(스트리밍은 토큰 간 간격에 적용).
pub fn http_agent() -> ureq::Agent {
    use std::time::Duration;
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(5))
        .timeout_read(Duration::from_secs(600))
        .timeout_write(Duration::from_secs(30))
        .build()
}
