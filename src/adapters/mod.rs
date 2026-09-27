pub mod host;
pub mod llama;
pub mod ollama;
pub mod runtime;
pub mod skills;
pub mod termux;

/// llama-server 포트 (llama.cpp 기본값).
pub const LLAMA_PORT: u16 = 8080;

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
