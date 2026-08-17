// TOOLS — 변경(Mutating). 실행 전 사람 승인 게이트를 거친다.
use crate::adapters::termux;
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("필수 인자 누락: {key}"))
}

pub struct SmsSend;
impl Tool for SmsSend {
    fn name(&self) -> &str {
        "sms_send"
    }
    fn description(&self) -> &str {
        "지정한 번호로 문자 메시지를 보낸다"
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "number": { "type": "string", "description": "수신 전화번호" },
                "text": { "type": "string", "description": "보낼 내용" }
            },
            "required": ["number", "text"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let number = required_str(args, "number")?;
        let text = required_str(args, "text")?;
        termux::run("termux-sms-send", &["-n", number, text])?;
        Ok(format!("문자 발송 완료 → {number}"))
    }
}

pub struct Call;
impl Tool for Call {
    fn name(&self) -> &str {
        "call"
    }
    fn description(&self) -> &str {
        "지정한 전화번호로 실제 전화를 건다. 사용자가 명시적으로 전화를 걸어달라고 할 때만 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "number": { "type": "string", "description": "발신 전화번호" }
            },
            "required": ["number"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let number = required_str(args, "number")?;
        termux::run("termux-telephony-call", &[number])?;
        Ok(format!("전화 발신 → {number}"))
    }
}
