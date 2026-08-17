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
        });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
            body["tool_choice"] = json!("auto");
        }
        let resp: Value = ureq::post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow!("llama-server 요청 실패 (서버 실행 중? usix-termux setup): {e}"))?
            .into_json()
            .map_err(|e| anyhow!("llama-server 응답 파싱 실패: {e}"))?;
        // OpenAI 스키마: choices[0].message (tool_calls 는 function.arguments 가 JSON 문자열).
        resp.get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .cloned()
            .ok_or_else(|| anyhow!("응답에 choices[0].message 없음: {resp}"))
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
        });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
            body["tool_choice"] = json!("auto");
        }
        let resp = ureq::post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow!("llama-server 요청 실패 (서버 실행 중? usix-termux setup): {e}"))?;
        let reader = std::io::BufReader::new(resp.into_reader());

        let mut content = String::new();
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
                    sink(c);
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

        let mut msg = json!({ "role": "assistant", "content": content });
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
            msg["tool_calls"] = json!(arr);
        }
        Ok(msg)
    }
}
