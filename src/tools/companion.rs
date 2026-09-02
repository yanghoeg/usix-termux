// TOOLS — usix-companion(안드로이드 알림 브리지) 연동.
// 컴패니언 앱의 NotificationListenerService 가 127.0.0.1:8760 에 작은 HTTP 브리지를 열고,
// 여기서 다른 앱(카톡·라인 등)의 알림을 읽거나 인라인 답장을 쏜다. USIX_COMPANION 설정 시에만 등록.
// HTTP·토큰·타임아웃은 bridge.rs 공용.
use super::bridge;
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

pub struct NotifList;
impl Tool for NotifList {
    fn name(&self) -> &str {
        "notif_list"
    }
    fn description(&self) -> &str {
        "카카오톡·라인 등 다른 앱의 최근 알림(제목·내용·답장 가능 여부·key)을 조회한다. '카톡 뭐 왔어' 같은 요청에 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "package": { "type": "string", "description": "앱 패키지로 거르기 (예: com.kakao.talk, 생략 시 전체)" }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let body = bridge::get("/notifications")?;
        let Some(pkg) = args.get("package").and_then(|v| v.as_str()) else {
            return Ok(body.to_string());
        };
        let Value::Array(items) = body else {
            return Ok(body.to_string());
        };
        let hits: Vec<Value> = items
            .into_iter()
            .filter(|n| n.get("pkg").and_then(|v| v.as_str()) == Some(pkg))
            .collect();
        Ok(serde_json::to_string(&hits)?)
    }
}

pub struct NotifReply;
impl Tool for NotifReply {
    fn name(&self) -> &str {
        "notif_reply"
    }
    fn description(&self) -> &str {
        "notif_list 로 조회한 알림에 인라인 답장을 보낸다. key 는 notif_list 결과의 key 값을 그대로 쓴다(지어내지 말 것). 카톡 등 답장 가능한 알림에만 된다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "key": { "type": "string", "description": "notif_list 결과의 알림 key" },
                "text": { "type": "string", "description": "보낼 답장 내용" }
            },
            "required": ["key", "text"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let key = args
            .get("key")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("필수 인자 누락: key"))?;
        let text = args
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("필수 인자 누락: text"))?;
        let body = bridge::post("/reply", json!({ "key": key, "text": text }))?;
        if body.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok("답장 전송됨".into())
        } else {
            Err(anyhow!(
                "답장 실패: {}",
                body.get("error").and_then(|v| v.as_str()).unwrap_or("알 수 없음")
            ))
        }
    }
}
