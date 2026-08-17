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

pub struct Contacts;
impl Tool for Contacts {
    fn name(&self) -> &str {
        "contacts"
    }
    fn description(&self) -> &str {
        "저장된 연락처(이름↔전화번호)를 조회한다. 이름으로 문자·전화할 때 번호를 찾는 데 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "name": { "type": "string", "description": "이름 일부로 거를 검색어 (생략 시 전체)" }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let raw = termux::run("termux-contact-list", &[])?;
        let Some(query) = args.get("name").and_then(|v| v.as_str()) else {
            return Ok(raw);
        };
        let query = query.to_lowercase();
        // 연락처가 많으면 소형 모델 컨텍스트를 아끼려 이름으로 걸러 준다.
        let Ok(Value::Array(all)) = serde_json::from_str::<Value>(&raw) else {
            return Ok(raw);
        };
        let hits: Vec<Value> = all
            .into_iter()
            .filter(|c| {
                c.get("name")
                    .and_then(|v| v.as_str())
                    .is_some_and(|n| n.to_lowercase().contains(&query))
            })
            .collect();
        Ok(serde_json::to_string(&hits)?)
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
