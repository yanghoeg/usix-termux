// TOOLS — 폰 UI 컨트롤(실험적). usix-companion 앱의 접근성 서비스를 통해 루트·adb 없이 화면을 읽고
// 탭·입력한다. 8760 브리지의 /screen·/tap·/type·/back·/open 을 친다. 기본 등록된다.
// 읽기(ui_dump)는 자동, 나머지(탭·입력·앱 실행)는 화면이 바뀌므로 승인 대상.
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

const COMPANION_PORT: u16 = 8760;
// 화면 요소가 많으면 소형 모델 컨텍스트 보호를 위해 상한을 둔다.
const MAX_NODES: usize = 80;

fn url(path: &str) -> String {
    format!("http://127.0.0.1:{COMPANION_PORT}{path}")
}

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("필수 인자 누락: {key}"))
}

/// 브리지 무응답(앱 미설치/미실행) → 원인 안내. 503 은 접근성 권한 꺼짐으로 따로 처리.
fn bridge_err(e: ureq::Error) -> anyhow::Error {
    match e {
        ureq::Error::Status(503, _) => anyhow!(
            "접근성 서비스 꺼짐 — usix-companion 앱에서 '접근성(화면 제어)' 권한을 켜라."
        ),
        other => anyhow!(
            "companion 브리지 무응답 — usix-companion 앱을 설치·실행했는지 확인하라. ({other})"
        ),
    }
}

fn bridge_get(path: &str) -> Result<Value> {
    let resp = ureq::get(&url(path)).call().map_err(bridge_err)?;
    resp.into_json().map_err(|e| anyhow!("응답 파싱 실패: {e}"))
}

fn bridge_post(path: &str, body: Value) -> Result<Value> {
    let resp = ureq::post(&url(path)).send_json(body).map_err(bridge_err)?;
    resp.into_json().map_err(|e| anyhow!("응답 파싱 실패: {e}"))
}

/// {ok:bool} 응답을 성공 메시지 또는 에러로 변환.
fn expect_ok(body: &Value, on_ok: String, on_fail: &str) -> Result<String> {
    if body.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        Ok(on_ok)
    } else {
        let err = body.get("error").and_then(|v| v.as_str()).unwrap_or(on_fail);
        Err(anyhow!("{err}"))
    }
}

pub struct Screen;
impl Tool for Screen {
    fn name(&self) -> &str {
        "ui_dump"
    }
    fn description(&self) -> &str {
        "현재 폰 화면에 보이는 텍스트·버튼과 위치(x,y)를 읽는다. 화면 내용을 파악하거나 누를 위치를 찾을 때 쓴다. 특정 앱을 읽으려면 package 를 준다(멀티윈도에서 정확)."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "package": { "type": "string", "description": "읽을 앱 패키지명 (예: com.kakao.talk). 생략 시 최상위 앱 창." }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let path = match args.get("package").and_then(|v| v.as_str()) {
            Some(pkg) if !pkg.is_empty() => {
                if !pkg.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_') {
                    return Err(anyhow!("잘못된 패키지명: {pkg}"));
                }
                format!("/screen?package={pkg}")
            }
            _ => "/screen".to_string(),
        };
        let body = bridge_get(&path)?;
        let Value::Array(items) = body else {
            return Ok("(화면에서 읽을 요소 없음)".into());
        };
        if items.is_empty() {
            return Ok("(화면에서 읽을 요소 없음)".into());
        }
        let lines: Vec<String> = items
            .iter()
            .take(MAX_NODES)
            .map(|n| {
                let t = n.get("text").and_then(|v| v.as_str()).unwrap_or("");
                let x = n.get("x").and_then(|v| v.as_i64()).unwrap_or(0);
                let y = n.get("y").and_then(|v| v.as_i64()).unwrap_or(0);
                let tag = if n.get("editable").and_then(|v| v.as_bool()) == Some(true) {
                    " [입력창]"
                } else {
                    ""
                };
                format!("\"{t}\" @ ({x},{y}){tag}")
            })
            .collect();
        let mut s = lines.join("\n");
        if items.len() > MAX_NODES {
            s.push_str(&format!("\n…(+{} 개 더)", items.len() - MAX_NODES));
        }
        Ok(s)
    }
}

pub struct AppOpen;
impl Tool for AppOpen {
    fn name(&self) -> &str {
        "app_open"
    }
    fn description(&self) -> &str {
        "패키지명으로 앱을 실행한다(예: com.kakao.talk). 화면을 읽기 전에 해당 앱을 연다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "package": { "type": "string", "description": "앱 패키지명 (예: com.kakao.talk)" }
            },
            "required": ["package"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let package = required_str(args, "package")?;
        if package.is_empty()
            || !package
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_')
        {
            return Err(anyhow!("잘못된 패키지명: {package}"));
        }
        let body = bridge_post("/open", json!({ "package": package }))?;
        expect_ok(&body, format!("앱 실행 → {package}"), "실행 실패(런처 인텐트 없음)")
    }
}

pub struct UiTap;
impl Tool for UiTap {
    fn name(&self) -> &str {
        "ui_tap"
    }
    fn description(&self) -> &str {
        "화면 좌표 (x,y)를 탭한다. ui_dump 로 얻은 요소 위치를 눌러 버튼·입력창을 조작한다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "x": { "type": "integer", "description": "탭할 x 좌표(px)" },
                "y": { "type": "integer", "description": "탭할 y 좌표(px)" }
            },
            "required": ["x", "y"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let x = args
            .get("x")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow!("x 는 정수여야 함"))?;
        let y = args
            .get("y")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow!("y 는 정수여야 함"))?;
        let body = bridge_post("/tap", json!({ "x": x, "y": y }))?;
        expect_ok(&body, format!("탭 → ({x},{y})"), "탭 실패")
    }
}

pub struct UiType;
impl Tool for UiType {
    fn name(&self) -> &str {
        "ui_type"
    }
    fn description(&self) -> &str {
        "현재 포커스된 입력창에 텍스트를 입력한다(한글 정상). 먼저 ui_tap 으로 입력창을 누른 뒤 사용한다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "입력할 텍스트" }
            },
            "required": ["text"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let text = required_str(args, "text")?;
        if text.is_empty() {
            return Err(anyhow!("빈 텍스트"));
        }
        let body = bridge_post("/type", json!({ "text": text }))?;
        expect_ok(&body, format!("입력 → \"{text}\""), "입력 실패(포커스된 입력창 없음)")
    }
}

pub struct UiBack;
impl Tool for UiBack {
    fn name(&self) -> &str {
        "ui_back"
    }
    fn description(&self) -> &str {
        "뒤로가기(back)를 누른다. 화면을 이전으로 되돌릴 때 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {} })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, _args: &Value) -> Result<String> {
        let body = bridge_post("/back", json!({}))?;
        expect_ok(&body, "뒤로가기".into(), "뒤로가기 실패")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 아래 테스트들은 네트워크 이전(인자 검증) 단계에서 거부되는 경로만 확인한다 — 기기 불필요.

    #[test]
    fn app_open_rejects_injection() {
        let r = AppOpen.run(&json!({ "package": "com.x; rm -rf /" }));
        assert!(r.is_err(), "인젝션 패키지명이 통과됨");
    }

    #[test]
    fn ui_tap_requires_integers() {
        assert!(UiTap.run(&json!({ "x": "5; reboot", "y": 10 })).is_err());
        assert!(UiTap.run(&json!({ "y": 10 })).is_err());
    }

    #[test]
    fn ui_type_rejects_empty() {
        assert!(UiType.run(&json!({ "text": "" })).is_err());
        assert!(UiType.run(&json!({})).is_err());
    }

    #[test]
    fn expect_ok_maps_ok_and_error() {
        assert!(expect_ok(&json!({ "ok": true }), "good".into(), "bad").is_ok());
        let e = expect_ok(&json!({ "ok": false, "error": "boom" }), "good".into(), "bad");
        assert_eq!(e.unwrap_err().to_string(), "boom");
    }
}
