// PORTS — I/O 없는 도메인 계약. usix의 도구/권한 경계를 폰 규모로 축약.
use anyhow::Result;
use serde_json::Value;

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
    /// 모델이 채운 인자로 실행하고 사람이 읽을 결과 문자열을 돌려준다.
    fn run(&self, args: &Value) -> Result<String>;
}

/// usix ApprovalClass 축약 — 읽기는 자동, 변경은 사람 승인.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ApprovalClass {
    ReadOnly,
    Mutating,
}
