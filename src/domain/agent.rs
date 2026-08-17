// DOMAIN — step 기반 function-calling 루프.
// usix의 PermissionRequest 처럼, 변경 도구는 실행하지 않고 `NeedApproval` 로 UI에 넘긴다.
// UI가 approve(true/false)로 결정을 돌려주면 이어서 진행한다.
use crate::domain::registry::Registry;
use crate::ports::{ApprovalClass, Llm};
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::VecDeque;

const SYSTEM_PROMPT: &str = "너는 안드로이드 Termux 폰 비서다. \
필요하면 제공된 도구를 호출해 실제 폰 정보를 조회하거나 작업한다. \
문자 발송·전화 걸기 같은 변경 작업은 반드시 도구로만 수행한다. \
도구 결과를 바탕으로 한국어로 간결하게 답한다.";

// 도구 호출 폭주 방지 (모델이 무한 호출하는 경우 차단).
const MAX_STEPS: usize = 16;

pub enum Turn {
    /// 최종 자연어 답변.
    Answer(String),
    /// 변경 도구 실행 대기 — UI가 사람 승인을 받아 approve()를 호출해야 한다.
    NeedApproval { desc: String },
}

pub struct Agent<'a> {
    llm: &'a dyn Llm,
    registry: &'a Registry,
    messages: Vec<Value>,
    tools_schema: Vec<Value>,
    pending: VecDeque<Value>, // 아직 실행 안 한 tool_calls
    awaiting: Option<Value>,  // 승인 대기 중인 변경 호출
    steps: usize,
}

impl<'a> Agent<'a> {
    pub fn new(llm: &'a dyn Llm, registry: &'a Registry) -> Self {
        // 기본 지침 + ~/.usix/skills/*.md 절차형 스킬(있으면 덧붙임).
        let content = format!(
            "{SYSTEM_PROMPT}{}",
            crate::domain::skills::guidance(&crate::domain::skills::load())
        );
        let system = json!({ "role": "system", "content": content });
        Self {
            llm,
            registry,
            messages: vec![system],
            tools_schema: registry.schemas(),
            pending: VecDeque::new(),
            awaiting: None,
            steps: 0,
        }
    }

    pub fn submit(&mut self, user: &str) {
        self.messages
            .push(json!({ "role": "user", "content": user }));
        self.steps = 0;
    }

    /// Answer 또는 NeedApproval 이 나올 때까지 진행. 최종 답변 content 는 `sink` 로
    /// 토큰 단위 스트리밍된다(도구 호출 턴은 content 가 없어 sink 미호출).
    pub fn advance(&mut self, sink: &mut dyn FnMut(&str)) -> Result<Turn> {
        loop {
            // 1) 대기 중인 도구 호출을 먼저 소진.
            while let Some(call) = self.pending.front().cloned() {
                let (name, args) = parse_call(&call);
                match self.registry.get(&name) {
                    None => {
                        self.pending.pop_front();
                        self.push_tool_result(format!("알 수 없는 도구: {name}"));
                    }
                    Some(t) if t.approval() == ApprovalClass::Mutating => {
                        // 승인 대기로 넘기고 UI에 알림.
                        self.pending.pop_front();
                        self.awaiting = Some(call);
                        return Ok(Turn::NeedApproval {
                            desc: format!("{name} {args}"),
                        });
                    }
                    Some(t) => {
                        let result = t.run(&args).unwrap_or_else(|e| format!("도구 오류: {e}"));
                        self.pending.pop_front();
                        self.push_tool_result(if result.is_empty() {
                            "(완료)".into()
                        } else {
                            result
                        });
                    }
                }
            }

            // 2) 무한 루프 차단.
            self.steps += 1;
            if self.steps > MAX_STEPS {
                return Ok(Turn::Answer("(도구 호출이 너무 많아 중단했습니다)".into()));
            }

            // 3) 모델 호출 (최종 답변은 sink 로 스트리밍).
            let msg = self
                .llm
                .chat_stream(&self.messages, &self.tools_schema, sink)?;
            self.messages.push(msg.clone());

            let calls = msg
                .get("tool_calls")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();

            if calls.is_empty() {
                let content = msg
                    .get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                return Ok(Turn::Answer(content));
            }
            self.pending.extend(calls);
        }
    }

    /// 승인 대기 중인 변경 도구를 실행하거나 취소한다.
    pub fn approve(&mut self, yes: bool) -> Result<()> {
        if let Some(call) = self.awaiting.take() {
            let (name, args) = parse_call(&call);
            let result = if yes {
                match self.registry.get(&name) {
                    Some(t) => t.run(&args).unwrap_or_else(|e| format!("도구 오류: {e}")),
                    None => format!("알 수 없는 도구: {name}"),
                }
            } else {
                "사용자가 취소함".into()
            };
            self.push_tool_result(if result.is_empty() {
                "(완료)".into()
            } else {
                result
            });
        }
        Ok(())
    }

    fn push_tool_result(&mut self, content: String) {
        self.messages
            .push(json!({ "role": "tool", "content": content }));
    }
}

/// tool_call → (이름, 인자). ollama는 arguments를 객체로 주지만 문자열 구현도 처리.
fn parse_call(call: &Value) -> (String, Value) {
    let func = &call["function"];
    let name = func
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let args = match func.get("arguments") {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or_else(|_| json!({})),
        Some(v) => v.clone(),
        None => json!({}),
    };
    (name, args)
}
