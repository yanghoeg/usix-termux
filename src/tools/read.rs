// TOOLS — 읽기 전용(ReadOnly). 승인 없이 자동 실행.
use crate::adapters::termux;
use crate::ports::{ApprovalClass, Tool};
use anyhow::Result;
use serde_json::{json, Value};

pub struct SmsList;
impl Tool for SmsList {
    fn name(&self) -> &str {
        "sms_list"
    }
    fn description(&self) -> &str {
        "최근 수신 문자 메시지를 조회한다"
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "limit": { "type": "integer", "description": "가져올 개수 (기본 10)" }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let limit = args.get("limit").and_then(|v| v.as_i64()).unwrap_or(10);
        termux::run("termux-sms-list", &["-l", &limit.to_string()])
    }
}

pub struct CallLog;
impl Tool for CallLog {
    fn name(&self) -> &str {
        "call_log"
    }
    fn description(&self) -> &str {
        "최근 통화 기록을 조회한다"
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "limit": { "type": "integer", "description": "가져올 개수 (기본 10)" }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let limit = args.get("limit").and_then(|v| v.as_i64()).unwrap_or(10);
        termux::run("termux-call-log", &["-l", &limit.to_string()])
    }
}

pub struct Battery;
impl Tool for Battery {
    fn name(&self) -> &str {
        "battery"
    }
    fn description(&self) -> &str {
        "배터리 퍼센트(잔량)·온도·충전 상태를 조회한다. 배터리 관련 질문은 이 도구를 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {} })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, _args: &Value) -> Result<String> {
        termux::run("termux-battery-status", &[])
    }
}
