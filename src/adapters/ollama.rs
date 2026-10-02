// ADAPTER — 로컬 ollama /api/chat (function-calling). 동기 HTTP(ureq), TLS 없음.
use crate::domain::context::Budget;
use crate::ports::Llm;
use anyhow::{anyhow, ensure, Result};
use serde_json::{json, Value};

pub struct Ollama {
    url: String,
    model: String,
    budget: Budget,
    base: String,
}

impl Ollama {
    pub fn new(model: impl Into<String>, budget: Budget, port: u16) -> Self {
        Self {
            url: format!("http://127.0.0.1:{port}/api/chat"),
            model: model.into(),
            budget,
            base: format!("http://127.0.0.1:{port}"),
        }
    }
}

impl Llm for Ollama {
    fn budget(&self) -> Budget {
        self.budget
    }
    fn chat(&self, messages: &[Value], tools: &[Value]) -> Result<Value> {
        ensure_local_model(&super::http_agent(), &self.base, &self.model)?;
        let body = json!({
            "model": self.model,
            "messages": messages,
            "tools": tools,
            "stream": false,
            // tool 선택 결정성 ↑ (소형 모델의 무작위 오선택 완화)
            "options": { "temperature": 0, "num_ctx": self.budget.context_tokens,
                "num_predict": self.budget.output_tokens },
            "think": false,
            "truncate": false,
        });
        let resp: Value = super::http_agent()
            .post(&self.url)
            .send_json(body)
            .map_err(|e| anyhow!("ollama 요청 실패 (USIX_BACKEND=ollama usix-code setup): {e}"))?
            .into_json()
            .map_err(|e| anyhow!("ollama 응답 파싱 실패: {e}"))?;
        resp.get("message")
            .cloned()
            .ok_or_else(|| anyhow!("응답에 message 필드 없음: {resp}"))
    }
}

pub fn validate_model_name(model: &str) -> Result<()> {
    let name = model.to_ascii_lowercase();
    ensure!(
        !model.is_empty()
            && !model.chars().any(char::is_whitespace)
            && !name.contains("://")
            && !name.ends_with(":cloud")
            && !name.ends_with("-cloud"),
        "only downloaded local Ollama model tags are allowed"
    );
    Ok(())
}

fn validate_local_metadata(metadata: &Value) -> Result<()> {
    for key in ["remote_host", "remote_model"] {
        ensure!(
            metadata
                .get(key)
                .is_none_or(|value| value.as_str() == Some("")),
            "remote Ollama models are disabled; select a downloaded local GGUF model"
        );
    }
    ensure!(
        metadata["details"]["format"].as_str() == Some("gguf")
            && metadata["model_info"].is_object(),
        "cannot verify local GGUF model metadata; inference was not sent"
    );
    Ok(())
}

pub fn ensure_local_model(agent: &ureq::Agent, base: &str, model: &str) -> Result<()> {
    validate_model_name(model)?;
    let metadata: Value = agent
        .post(&format!("{base}/api/show"))
        .send_json(json!({"model":model}))
        .map_err(|e| anyhow!("cannot verify downloaded local Ollama model `{model}`: {e}"))?
        .into_json()?;
    validate_local_metadata(&metadata)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_cloud_aliases_and_unverifiable_models() {
        for name in ["qwen:cloud", "model-cloud", "https://remote/model", ""] {
            assert!(validate_model_name(name).is_err(), "{name}");
        }
        let local =
            json!({"details":{"format":"gguf"},"model_info":{"general.architecture":"qwen"}});
        validate_local_metadata(&local).unwrap();
        for key in ["remote_host", "remote_model"] {
            let mut alias = local.clone();
            alias[key] = "hidden-remote-alias".into();
            assert!(validate_local_metadata(&alias).is_err());
        }
        assert!(validate_local_metadata(&json!({})).is_err());
    }
}
