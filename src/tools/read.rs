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
        // 소형 모델은 컨텍스트가 4096뿐이라, 수백 명짜리 전체 목록을 넣으면 컨텍스트가
        // 넘쳐 다음 요청이 400(exceeds context)으로 깨진다. 이름으로 거르고, 이름이
        // 없거나 매치가 많으면 상한(MAX_HITS)을 두어 항상 작게 돌려준다.
        const MAX_HITS: usize = 20;
        let raw = termux::run("termux-contact-list", &[])?;
        let Ok(Value::Array(all)) = serde_json::from_str::<Value>(&raw) else {
            return Ok(raw);
        };
        let query = args
            .get("name")
            .and_then(|v| v.as_str())
            .map(str::to_lowercase);
        let mut hits: Vec<Value> = all
            .into_iter()
            .filter(|c| match &query {
                None => true,
                Some(q) => c
                    .get("name")
                    .and_then(|v| v.as_str())
                    .is_some_and(|n| n.to_lowercase().contains(q)),
            })
            .collect();
        let total = hits.len();
        hits.truncate(MAX_HITS);
        let mut out = serde_json::to_string(&hits)?;
        if total > MAX_HITS {
            // 잘렸음을 알려 모델이 이름을 더 구체적으로 좁혀 다시 검색하게 한다.
            out.push_str(&format!(
                "\n(총 {total}건 중 {MAX_HITS}건만 표시 — 이름을 더 구체적으로 지정해 다시 검색하세요)"
            ));
        }
        Ok(out)
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
