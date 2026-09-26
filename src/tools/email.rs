use super::bridge::post;
use super::ui::{expect_ok, valid_pkg};
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

const THUNDERBIRD: &str = "net.thunderbird.android";

fn package(args: &Value) -> Result<&str> {
    match args.get("package") {
        None => Ok(THUNDERBIRD),
        Some(Value::String(pkg)) if valid_pkg(pkg) => Ok(pkg),
        _ => Err(anyhow!("package 는 메일 앱 패키지명이어야 함")),
    }
}

fn compose_request(args: &Value) -> Result<Value> {
    let pkg = package(args)?;
    let to = args
        .get("to")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| anyhow!("to 에 받는 사람 이메일 주소 하나가 필요함"))?;
    let field = |key: &str| -> Result<&str> {
        match args.get(key) {
            None => Ok(""),
            Some(Value::String(value)) => Ok(value),
            _ => Err(anyhow!("{key} 는 문자열이어야 함")),
        }
    };
    Ok(json!({ "package": pkg, "to": to, "subject": field("subject")?, "body": field("body")? }))
}

pub struct EmailOpen;
impl Tool for EmailOpen {
    fn name(&self) -> &str {
        "email_open"
    }
    fn description(&self) -> &str {
        "알림 없이 메일 앱을 연다. 기본은 Thunderbird. ui_dump(package=net.thunderbird.android)로 메일 목록을 읽고, 메일을 눌러 본문·답장을 확인한다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {
            "package": { "type": "string", "description": "메일 앱 패키지명. 생략하면 net.thunderbird.android" }
        } })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let pkg = package(args)?;
        let body = post("/email/open", json!({ "package": pkg }))?;
        expect_ok(
            &body,
            format!(
                "메일 앱 실행 요청됨. ui_dump(package={pkg})로 현재 계정과 메일 화면을 확인하라."
            ),
            "메일 앱 실행 실패",
        )
    }
}

pub struct EmailCompose;
impl Tool for EmailCompose {
    fn name(&self) -> &str {
        "email_compose"
    }
    fn description(&self) -> &str {
        "Thunderbird에 받는 사람·제목·본문을 채운 새 메일 작성 화면을 연다. 아직 발송되지 않는다. 기존 메일 답장은 email_open으로 원문을 열고 답장 버튼을 사용한다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {
            "to": { "type": "string", "description": "받는 사람 이메일 주소 하나" },
            "subject": { "type": "string", "description": "메일 제목" },
            "body": { "type": "string", "description": "메일 본문" },
            "package": { "type": "string", "description": "메일 앱 패키지명. 생략하면 net.thunderbird.android" }
        }, "required": ["to"] })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let request = compose_request(args)?;
        let pkg = request["package"].as_str().unwrap().to_owned();
        let body = post("/email/compose", request)?;
        expect_ok(&body, format!("메일 작성 화면 실행 요청됨. 아직 발송되지 않았다. ui_dump(package={pkg})로 발신 계정·수신자·본문을 확인하라. 사용자가 발송을 요청한 경우에만 보내기 버튼을 누르고 결과를 확인하라."), "메일 작성 화면 실행 실패")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_preserves_mail_content_and_defaults_to_thunderbird() {
        let args = json!({"to":"person+work@example.com", "subject":"회의 & 일정", "body":"안녕하세요\n&bcc=other@example.com"});
        let request = compose_request(&args).unwrap();
        assert_eq!(request["package"], THUNDERBIRD);
        for key in ["to", "subject", "body"] {
            assert_eq!(request[key], args[key]);
        }
        assert_eq!(
            compose_request(&json!({"to":"a@example.com", "package":"com.fsck.k9"})).unwrap()
                ["package"],
            "com.fsck.k9"
        );
    }

    #[test]
    fn malformed_compose_requests_are_rejected_before_network() {
        for args in [
            json!({}),
            json!({"to":4}),
            json!({"to":" "}),
            json!({"to":"a@example.com", "body":false}),
            json!({"to":"a@example.com", "subject":null}),
            json!({"to":"a@example.com", "package":""}),
        ] {
            assert!(EmailCompose.run(&args).is_err());
        }
        assert!(EmailOpen.run(&json!({"package":null})).is_err());
    }

    #[test]
    fn draft_and_app_open_use_existing_mutating_approval() {
        assert!(matches!(EmailOpen.approval(), ApprovalClass::Mutating));
        assert!(matches!(EmailCompose.approval(), ApprovalClass::Mutating));
    }
}
