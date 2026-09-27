// PORTS — contracts implemented by external adapters.
use anyhow::Result;
use serde_json::Value;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Llama,
    Ollama,
}

impl Backend {
    pub fn name(self) -> &'static str {
        match self {
            Self::Llama => "llama",
            Self::Ollama => "ollama",
        }
    }
}

pub struct LaunchSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl LaunchSpec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            env: Vec::new(),
        }
    }
}

pub struct BundledSkill {
    pub filename: &'static str,
    pub text: &'static str,
    pub legacy: Option<&'static str>,
}

/// Host services are injected at the application boundary. The agent never detects an OS.
pub trait Host: Send + Sync {
    fn name(&self) -> &'static str;
    fn tools(&self) -> Vec<Box<dyn Tool>>;
    fn bundled_skills(&self) -> &'static [BundledSkill];
    fn ensure_backend(&self, backend: Backend) -> Result<()>;
    fn backend_launch(&self, backend: Backend) -> LaunchSpec;
    fn doctor(&self) -> Result<()>;
    fn pair(&self, _token: Option<&str>) -> Result<()> {
        anyhow::bail!("companion pairing is unavailable on {}", self.name())
    }
    fn notify(&self, content: &str) {
        eprintln!("{content}");
    }
    fn reset_tools(&self) {}
}

/// LLM 게이트웨이 계약 (ollama 등 구현체가 채움).
/// Send + Sync: TUI가 모델 호출(블로킹)을 워커 스레드로 돌려 경과 시간을 표시한다.
pub trait Llm: Send + Sync {
    /// messages + tools 스키마를 보내고 assistant 메시지(content 또는 tool_calls)를 받는다.
    fn chat(&self, messages: &[Value], tools: &[Value]) -> Result<Value>;

    /// content 델타를 `sink` 로 흘리며 최종 assistant 메시지를 조립해 돌려준다.
    /// 기본 구현은 비스트리밍 `chat` 폴백(증분 출력 없음) — 스트리밍 미지원 백엔드용.
    fn chat_stream(
        &self,
        messages: &[Value],
        tools: &[Value],
        _sink: &mut dyn FnMut(&str),
    ) -> Result<Value> {
        self.chat(messages, tools)
    }
}

/// function-calling 도구 하나의 계약.
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    /// 파라미터 JSON schema (function-calling).
    fn parameters(&self) -> Value;
    /// 실행 전 승인 등급.
    fn approval(&self) -> ApprovalClass;
    /// Screen-dependent calls must be planned again after a task leaves the process.
    fn requires_fresh_screen(&self) -> bool {
        false
    }
    /// 모델이 채운 인자로 실행하고 사람이 읽을 결과 문자열을 돌려준다.
    fn run(&self, args: &Value) -> Result<String>;
}

/// usix ApprovalClass 축약 — 읽기는 자동, 변경은 사람 승인.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ApprovalClass {
    ReadOnly,
    Mutating,
}
