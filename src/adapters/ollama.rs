// ADAPTER — 로컬 ollama /api/chat (function-calling). 동기 HTTP(ureq), TLS 없음.
use crate::ports::Llm;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

pub struct Ollama {
    url: String,
    model: String,
}

impl Ollama {
    pub fn new(model: impl Into<String>) -> Self {
        Self {
            url: "http://127.0.0.1:11434/api/chat".into(),
            model: model.into(),
        }
    }
}

impl Llm for Ollama {
    fn chat(&self, messages: &[Value], tools: &[Value]) -> Result<Value> {
        let body = json!({
            "model": self.model,
            "messages": messages,
            "tools": tools,
            "stream": false,
            // tool 선택 결정성 ↑ (소형 모델의 무작위 오선택 완화)
            "options": { "temperature": 0 },
        });
        let resp: Value = super::http_agent()
            .post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow!("ollama 요청 실패 (서버 실행 중? ollama-serve start): {e}"))?
            .into_json()
            .map_err(|e| anyhow!("ollama 응답 파싱 실패: {e}"))?;
        resp.get("message")
            .cloned()
            .ok_or_else(|| anyhow!("응답에 message 필드 없음: {resp}"))
    }
}
