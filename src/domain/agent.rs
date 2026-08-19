// DOMAIN — step 기반 function-calling 루프.
// usix의 PermissionRequest 처럼, 변경 도구는 실행하지 않고 `NeedApproval` 로 UI에 넘긴다.
// UI가 approve(true/false)로 결정을 돌려주면 이어서 진행한다.
use crate::domain::registry::Registry;
use crate::domain::skills::Skill;
use crate::ports::{ApprovalClass, Llm};
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::VecDeque;

const SYSTEM_PROMPT: &str = "너는 안드로이드 Termux 폰 비서다. \
필요하면 제공된 도구를 호출해 실제 폰 정보를 조회하거나 작업한다. \
문자 발송·전화 걸기 같은 변경 작업은 반드시 도구로만 수행한다. \
전화번호를 모르면 절대 임의로 지어내지 말고 contacts 도구로 이름을 조회해 번호를 찾는다. \
sms_send 의 number 에는 contacts 로 찾은 실제 숫자만 넣는다. \
이름이나 '부인 전화번호' 같은 자리표시자를 number 에 넣지 마라. \
번호를 아직 모르면 sms_send 를 부르지 말고, 그 턴에는 contacts 만 호출해 번호부터 받는다. \
조회해도 없으면 번호를 추측하지 말고 사용자에게 번호를 물어본다. \
사용자가 준 메시지 문구는 그대로 보낸다(이름으로 오해해 문장을 새로 짓지 않는다). \
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
    skills: Vec<Skill>, // 전체 로드분 — submit마다 요청 관련분만 프롬프트에 얹는다.
}

impl<'a> Agent<'a> {
    pub fn new(llm: &'a dyn Llm, registry: &'a Registry) -> Self {
        // 스킬은 로드만 해두고, 프롬프트에는 submit에서 요청 관련분만 얹는다. 무관한
        // 스킬 지침이 끼면 소형 모델이 후속 절차를 놓쳐(빈 응답) 흐름이 깨진다.
        let system = json!({ "role": "system", "content": SYSTEM_PROMPT });
        Self {
            llm,
            registry,
            messages: vec![system],
            tools_schema: registry.schemas(),
            pending: VecDeque::new(),
            awaiting: None,
            steps: 0,
            skills: crate::domain::skills::load(),
        }
    }

    pub fn submit(&mut self, user: &str) {
        // 이번 요청과 관련된 스킬만 골라 system 프롬프트를 재구성한다.
        let relevant = crate::domain::skills::select(&self.skills, user);
        let content = format!("{SYSTEM_PROMPT}{}", crate::domain::skills::guidance(&relevant));
        self.messages[0] = json!({ "role": "system", "content": content });
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
                let id = call_id(&call);
                match self.registry.get(&name) {
                    None => {
                        self.pending.pop_front();
                        self.push_tool_result(&id, format!("알 수 없는 도구: {name}"));
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
                        self.push_tool_result(
                            &id,
                            if result.is_empty() {
                                "(완료)".into()
                            } else {
                                result
                            },
                        );
                    }
                }
            }

            // 2) 무한 루프 차단.
            self.steps += 1;
            if self.steps > MAX_STEPS {
                return Ok(Turn::Answer("(도구 호출이 너무 많아 중단했습니다)".into()));
            }

            // 3) 모델 호출 (최종 답변은 sink 로 스트리밍).
            let mut msg = self
                .llm
                .chat_stream(&self.messages, &self.tools_schema, sink)?;
            // 백엔드가 tool_call id 를 안 주면(ollama 등) 여기서 채운다 — 없으면 취소·결과
            // 응답의 tool_call_id 가 어긋나 대화가 깨진다. assistant 메시지로 저장하기 전에
            // 손봐서 저장본과 pending 이 같은 id 를 갖게 한다.
            ensure_call_ids(&mut msg, self.messages.len());
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
                if content.is_empty() {
                    // Hammer 등 일부 3B 는 도구가 필요 없을 때 답변 대신 빈 도구배열("[]")
                    // 노이즈를 낸다 → content 가 비어 빈 답이 나간다. 도구 없이 한 번 더
                    // 물어 자연어 답을 받는다.
                    return Ok(Turn::Answer(self.answer_without_tools(sink)?));
                }
                return Ok(Turn::Answer(content));
            }
            self.pending.extend(calls);
        }
    }

    /// 방금 저장한 빈 assistant 응답을 걷어내고, 도구 스키마 없이 다시 물어 자연어 답을 받는다.
    fn answer_without_tools(&mut self, sink: &mut dyn FnMut(&str)) -> Result<String> {
        self.messages.pop();
        let msg = self.llm.chat_stream(&self.messages, &[], sink)?;
        let content = msg
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        self.messages.push(msg);
        Ok(content)
    }

    /// 승인 대기 중인 변경 도구를 실행하거나 취소한다.
    pub fn approve(&mut self, yes: bool) -> Result<()> {
        if let Some(call) = self.awaiting.take() {
            let (name, args) = parse_call(&call);
            let id = call_id(&call);
            if yes {
                let result = match self.registry.get(&name) {
                    Some(t) => t.run(&args).unwrap_or_else(|e| format!("도구 오류: {e}")),
                    None => format!("알 수 없는 도구: {name}"),
                };
                self.push_tool_result(&id, if result.is_empty() { "(완료)".into() } else { result });
            } else {
                // 취소 시엔 모델을 다시 부르지 않는다(호출부가 턴을 끝냄) — 소형 모델이 "실행했다"고
                // 거짓 보고하던 문제를 원천 차단. 대신 형제 호출까지 모두 취소 응답으로 채워
                // 대화 일관성(모든 tool_call 엔 tool 응답이 있어야 함)을 지킨다.
                self.push_tool_result(&id, "사용자가 취소함. 실행되지 않음.".into());
                let siblings: Vec<Value> = self.pending.drain(..).collect();
                for c in siblings {
                    self.push_tool_result(&call_id(&c), "사용자가 취소함. 실행되지 않음.".into());
                }
            }
        }
        Ok(())
    }

    fn push_tool_result(&mut self, id: &str, content: String) {
        self.messages
            .push(json!({ "role": "tool", "tool_call_id": id, "content": content }));
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

/// tool_call 의 id — tool 결과 메시지의 `tool_call_id` 로 되짚어 OpenAI 템플릿 짝을 맞춘다.
/// (id 가 없으면 assistant tool_calls 와 tool 응답이 어긋나 취소 후 대화가 깨진다.)
fn call_id(call: &Value) -> String {
    call.get("id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// tool_call 에 빠진/빈 id 를 채운다(ollama 처럼 id 없는 백엔드 대비). turn 은 현 대화 길이라
/// 턴마다 달라져 `call_{turn}_{idx}` 가 대화 전체에서 유일해진다. id 가 이미 있으면 건드리지 않는다.
fn ensure_call_ids(msg: &mut Value, turn: usize) {
    let Some(calls) = msg.get_mut("tool_calls").and_then(|v| v.as_array_mut()) else {
        return;
    };
    for (idx, call) in calls.iter_mut().enumerate() {
        let empty = call
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .is_empty();
        if empty {
            call["id"] = json!(format!("call_{turn}_{idx}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ensure_call_ids;
    use serde_json::json;

    #[test]
    fn fills_missing_ids_keeps_existing() {
        let mut msg = json!({
            "role": "assistant",
            "tool_calls": [
                { "id": "", "function": { "name": "a" } },
                { "id": "keep", "function": { "name": "b" } },
                { "function": { "name": "c" } }
            ]
        });
        ensure_call_ids(&mut msg, 5);
        let calls = msg["tool_calls"].as_array().unwrap();
        assert_eq!(calls[0]["id"], "call_5_0");
        assert_eq!(calls[1]["id"], "keep");
        assert_eq!(calls[2]["id"], "call_5_2");
    }
}
