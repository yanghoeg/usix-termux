// ADAPTER — 로컬 llama.cpp llama-server 의 OpenAI 호환 /v1/chat/completions.
// jinja 템플릿이 기본 켜져 있어(Qwen2.5) tools 배열을 넣으면 tool_calls 로 돌려준다.
// 동기 HTTP(ureq), TLS 없음. 모델 로드는 서버 기동 시 결정되므로 여기선 model 필드 불필요.
use crate::ports::Llm;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::io::BufRead;

pub struct LlamaCpp {
    url: String,
}

impl LlamaCpp {
    pub fn new() -> Self {
        Self {
            url: format!("http://127.0.0.1:{}/v1/chat/completions", super::LLAMA_PORT),
        }
    }
}

impl Llm for LlamaCpp {
    fn chat(&self, messages: &[Value], tools: &[Value]) -> Result<Value> {
        let mut body = json!({
            "messages": messages,
            "stream": false,
            "temperature": 0,
            // Qwen3 계열 사고(thinking) 모드 끔 — 켜지면 reasoning_content 로 새고 content 가 비어
            // 빈 응답이 나간다. 이 kwarg 를 안 쓰는 템플릿(hammer·qwen2.5)에선 무시된다.
            "chat_template_kwargs": { "enable_thinking": false },
        });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
            body["tool_choice"] = json!("auto");
        }
        let resp: Value = super::http_agent()
            .post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow!("llama-server 요청 실패 (서버 실행 중? usix-termux setup): {e}"))?
            .into_json()
            .map_err(|e| anyhow!("llama-server 응답 파싱 실패: {e}"))?;
        // OpenAI 스키마: choices[0].message (tool_calls 는 function.arguments 가 JSON 문자열).
        let msg = resp
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .cloned()
            .ok_or_else(|| anyhow!("응답에 choices[0].message 없음: {resp}"))?;
        Ok(apply_codeblock_fallback(msg))
    }

    /// SSE 스트리밍 — `data: {chunk}` 줄마다 delta.content 를 sink 로 흘리고,
    /// tool_calls 는 index 별로 이름·인자 조각을 이어붙여 최종 메시지로 조립한다.
    fn chat_stream(
        &self,
        messages: &[Value],
        tools: &[Value],
        sink: &mut dyn FnMut(&str),
    ) -> Result<Value> {
        let mut body = json!({
            "messages": messages,
            "stream": true,
            "temperature": 0,
            "chat_template_kwargs": { "enable_thinking": false },
        });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
            body["tool_choice"] = json!("auto");
        }
        let resp = super::http_agent()
            .post(&self.url)
            .send_json(body)
            .map_err(|e| {
                anyhow!("llama-server 요청 실패 (서버 실행 중? usix-termux setup): {e}")
            })?;
        let reader = std::io::BufReader::new(resp.into_reader());

        let mut content = String::new();
        let mut sunk = 0usize; // content 중 sink 로 이미 흘린 바이트 수.
        // index → (id, name, arguments 조각 누적).
        let mut calls: Vec<(String, String, String)> = Vec::new();

        for line in reader.lines() {
            let line = line?;
            let data = match line.strip_prefix("data: ") {
                Some(d) => d.trim(),
                None => continue,
            };
            if data == "[DONE]" {
                break;
            }
            let chunk: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let delta = &chunk["choices"][0]["delta"];
            if let Some(c) = delta.get("content").and_then(|v| v.as_str()) {
                if !c.is_empty() {
                    content.push_str(c);
                    // Hammer 등은 tool_calls 대신 ``` 코드블록을 content 로 뱉는다. 그런
                    // 도구호출 원문이 화면에 흘러나가지 않게, 코드블록/배열로 보이면
                    // 확정될 때까지 sink 를 보류한다(끝에서 도구호출이 아니면 마저 흘림).
                    if !looks_like_tool_prefix(&content) {
                        sink(&content[sunk..]);
                        sunk = content.len();
                    }
                }
            }
            if let Some(arr) = delta.get("tool_calls").and_then(|v| v.as_array()) {
                for tc in arr {
                    let idx = tc.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                    while calls.len() <= idx {
                        calls.push((String::new(), String::new(), String::new()));
                    }
                    if let Some(id) = tc.get("id").and_then(|v| v.as_str()) {
                        if !id.is_empty() {
                            calls[idx].0 = id.to_string();
                        }
                    }
                    let func = &tc["function"];
                    if let Some(n) = func.get("name").and_then(|v| v.as_str()) {
                        if !n.is_empty() {
                            calls[idx].1 = n.to_string();
                        }
                    }
                    if let Some(a) = func.get("arguments").and_then(|v| v.as_str()) {
                        calls[idx].2.push_str(a);
                    }
                }
            }
        }

        if !calls.is_empty() {
            let arr: Vec<Value> = calls
                .into_iter()
                .map(|(id, name, args)| {
                    json!({
                        "id": id,
                        "type": "function",
                        "function": { "name": name, "arguments": args },
                    })
                })
                .collect();
            return Ok(json!({ "role": "assistant", "content": content, "tool_calls": arr }));
        }
        // 네이티브 tool_calls 가 없으면 Hammer식 ``` 코드블록 폴백을 시도.
        match extract_tool_protocol(&content) {
            Some(cb) if !cb.is_empty() => {
                Ok(json!({ "role": "assistant", "content": "", "tool_calls": cb }))
            }
            // 배열이지만 실제 호출이 없음(예: "[]") — 프로토콜 잡음이라 답변에서 숨긴다.
            Some(_) => Ok(json!({ "role": "assistant", "content": "" })),
            // 도구호출이 아니었으면(평범한 답변), 보류했던 버퍼를 마저 흘린다.
            None => {
                if sunk < content.len() {
                    sink(&content[sunk..]);
                }
                Ok(json!({ "role": "assistant", "content": content }))
            }
        }
    }
}

/// 스트리밍 중 content 접두가 도구호출 코드블록(``` 또는 JSON 배열)으로 보이는지.
/// 아직 판단이 안 서면(빈 문자열/펜스 조각) true 를 돌려 sink 를 보류시킨다.
fn looks_like_tool_prefix(s: &str) -> bool {
    let t = s.trim_start();
    if t.is_empty() {
        return true;
    }
    t.starts_with('[') || t.starts_with("```") || "```".starts_with(t)
}

/// 비스트리밍 응답에도 같은 폴백을 적용한다. tool_calls 가 이미 있으면 그대로 둔다.
fn apply_codeblock_fallback(mut msg: Value) -> Value {
    let has_calls = msg
        .get("tool_calls")
        .and_then(|v| v.as_array())
        .is_some_and(|a| !a.is_empty());
    if has_calls {
        return msg;
    }
    let content = msg
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    match extract_tool_protocol(&content) {
        Some(cb) if !cb.is_empty() => {
            msg["content"] = json!("");
            msg["tool_calls"] = json!(cb);
        }
        // 배열이지만 호출 없음("[]" 등) → 프로토콜 잡음 숨김.
        Some(_) => {
            msg["content"] = json!("");
        }
        None => {}
    }
    msg
}

/// Hammer 등 일부 3B 모델은 --jinja 로도 tool_calls 를 안 내보내고, 대신 ``` 로 감싼
/// JSON(또는 파이썬 dict) 배열을 content 로 뱉는다. content 가 그런 "도구 프로토콜"이면
/// 파싱한 tool_calls 를 Some 으로(빈 배열 "[]" 이면 Some(vec![])) 돌려주고, 평범한
/// 답변이면 None 을 돌려준다. Some(빈) 은 호출은 없지만 프로토콜 잡음이므로 답변에서 숨긴다.
/// 원소는 {name,arguments} 또는 {function:{name,arguments}} 두 형태를 지원한다.
/// id 는 비워 둔다 — agent 의 ensure_call_ids 가 턴 기준 유일 id 로 채운다.
fn extract_tool_protocol(content: &str) -> Option<Vec<Value>> {
    let inner = strip_code_fence(content);
    let trimmed = inner.trim();
    if !trimmed.starts_with('[') {
        return None;
    }
    // 우선 JSON 으로, 실패하면 파이썬 dict(작은따옴표)로. 소형 모델이 닫는 괄호(]/})를
    // 빠뜨리고 끝내는 경우가 잦아, 원문이 실패하면 괄호를 보정한 판본으로도 시도한다.
    let balanced = close_brackets(trimmed);
    let parsed = serde_json::from_str::<Value>(trimmed)
        .or_else(|_| serde_json::from_str::<Value>(&pyish_to_json(trimmed)))
        .or_else(|_| serde_json::from_str::<Value>(&balanced))
        .or_else(|_| serde_json::from_str::<Value>(&pyish_to_json(&balanced)));
    let Ok(Value::Array(items)) = parsed else {
        return None; // 배열처럼 보였으나 파싱 실패 → 원문 보존(프로즈로 취급).
    };
    let mut out = Vec::new();
    for item in &items {
        let func = item.get("function").unwrap_or(item);
        let Some(name) = func.get("name").and_then(|v| v.as_str()) else {
            continue;
        };
        let args = func.get("arguments").cloned().unwrap_or_else(|| json!({}));
        // OpenAI 스키마는 arguments 를 JSON 문자열로 요구한다.
        let args_str = match args {
            Value::String(s) => s,
            other => other.to_string(),
        };
        out.push(json!({
            "id": "",
            "type": "function",
            "function": { "name": name, "arguments": args_str },
        }));
    }
    Some(out)
}

/// 테스트·간편 호출용 얇은 래퍼 — 프로토콜이 아니거나 호출이 없으면 빈 Vec.
#[cfg(test)]
fn parse_codeblock_tool_calls(content: &str) -> Vec<Value> {
    extract_tool_protocol(content).unwrap_or_default()
}

/// ``` 로 감싼 블록이면 펜스(와 언어 태그 줄)를 벗겨 안쪽만 돌려준다. 아니면 트림만.
fn strip_code_fence(content: &str) -> String {
    let mut t = content.trim();
    if let Some(r) = t.strip_prefix("```") {
        t = match r.find('\n') {
            Some(i) => &r[i + 1..],
            None => r,
        };
    }
    t = t.trim();
    if let Some(r) = t.strip_suffix("```") {
        t = r.trim();
    }
    t.to_string()
}

/// 파이썬 repr → JSON 근사 변환. 관측된 형태(키·문자열 값이 작은따옴표)를 위한 최소 처리라,
/// 값 안에 작은따옴표가 들어 있으면 깨질 수 있다 — JSON 파싱이 먼저 실패했을 때만 쓰는 폴백.
fn pyish_to_json(s: &str) -> String {
    s.replace('\'', "\"")
}

/// 괄호 짝을 관용적으로 복구한다. 소형 모델은 닫는 괄호를 아예 빠뜨리거나(끝에서 누락),
/// 객체를 닫기 전에 `]` 를 먼저 찍는(위치 오류) 식으로 자주 깨진 배열을 낸다. 문자열 밖에서
/// 스택을 추적해 `]` 앞의 열린 객체는 먼저 닫고, 짝 안 맞는 닫힘은 버리고, 끝에 남은 건 채운다.
fn close_brackets(s: &str) -> String {
    let mut stack: Vec<char> = Vec::new();
    let mut in_str: Option<char> = None;
    let mut prev = '\0';
    let mut out = String::with_capacity(s.len() + 4);
    for ch in s.chars() {
        if let Some(q) = in_str {
            out.push(ch);
            if ch == q && prev != '\\' {
                in_str = None;
            }
        } else {
            match ch {
                '"' | '\'' => {
                    in_str = Some(ch);
                    out.push(ch);
                }
                '{' | '[' => {
                    stack.push(ch);
                    out.push(ch);
                }
                '}' if stack.last() == Some(&'{') => {
                    stack.pop();
                    out.push(ch);
                }
                ']' => {
                    // 배열을 닫기 전에 아직 열린 객체가 있으면 먼저 닫아 준다.
                    while stack.last() == Some(&'{') {
                        stack.pop();
                        out.push('}');
                    }
                    if stack.last() == Some(&'[') {
                        stack.pop();
                        out.push(ch);
                    }
                    // 짝이 없으면(스트레이) 버린다.
                }
                '}' => {} // 짝 없는 닫힘 → 버림.
                _ => out.push(ch),
            }
        }
        prev = ch;
    }
    while let Some(open) = stack.pop() {
        out.push(if open == '{' { '}' } else { ']' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_json_codeblock_flat_shape() {
        let c = "```\n[{\"name\": \"sms_send\", \"arguments\": {\"number\": \"01099998888\", \"text\": \"안녕 고생많어\"}}]\n```";
        let calls = parse_codeblock_tool_calls(c);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["function"]["name"], "sms_send");
        let args: Value =
            serde_json::from_str(calls[0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(args["number"], "01099998888");
        assert_eq!(args["text"], "안녕 고생많어");
    }

    #[test]
    fn parses_pydict_codeblock_nested_shape() {
        let c = "```\n[{'type': 'function', 'function': {'name': 'contacts', 'arguments': {'name': '부인'}}}]\n```";
        let calls = parse_codeblock_tool_calls(c);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["function"]["name"], "contacts");
        let args: Value =
            serde_json::from_str(calls[0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(args["name"], "부인");
    }

    #[test]
    fn recovers_truncated_missing_closers() {
        // 모델이 배열 닫는 `]` 를 빠뜨리고 끝낸 관측 사례.
        let c = "```\n[{'type': 'function', 'function': {'name': 'contacts', 'arguments': {'name': '부인'}}}\n```";
        let calls = parse_codeblock_tool_calls(c);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["function"]["name"], "contacts");
        let args: Value =
            serde_json::from_str(calls[0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(args["name"], "부인");
    }

    #[test]
    fn recovers_misplaced_array_close() {
        // 관측 사례: 바깥 객체를 닫기 전 `]` 를 먼저 찍어 `}}]` 로 끝난 출력.
        let c = "```\n[{'type': 'function', 'function': {'name': 'sms_send', 'arguments': {'number': '01056715088', 'text': '고생많아 고마워 사랑해'}}]\n```";
        let calls = parse_codeblock_tool_calls(c);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["function"]["name"], "sms_send");
        let args: Value =
            serde_json::from_str(calls[0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(args["number"], "01056715088");
        assert_eq!(args["text"], "고생많아 고마워 사랑해");
    }

    #[test]
    fn plain_prose_is_not_a_tool_call() {
        assert!(parse_codeblock_tool_calls("배터리는 82% 입니다.").is_empty());
        assert!(parse_codeblock_tool_calls("```\nprint('hi')\n```").is_empty());
    }

    #[test]
    fn prefix_guard_holds_until_decided() {
        assert!(looks_like_tool_prefix(""));
        assert!(looks_like_tool_prefix("`"));
        assert!(looks_like_tool_prefix("``"));
        assert!(looks_like_tool_prefix("```"));
        assert!(looks_like_tool_prefix("[{"));
        assert!(!looks_like_tool_prefix("배터리는"));
        assert!(!looks_like_tool_prefix("`code`"));
    }
}
