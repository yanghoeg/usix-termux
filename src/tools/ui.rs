// TOOLS — 폰 UI 컨트롤(실험적). usix-companion 앱의 접근성 서비스를 통해 루트·adb 없이 화면을 읽고
// 탭·입력한다. 8760 브리지의 /screen·/tap·/type·/back·/open 을 친다. 기본 등록된다.
//
// 소형 모델이 생좌표(x,y)를 못 맞추므로, 모델에겐 좌표를 숨기고 "번호(index) 또는 텍스트"로만
// 조작하게 한다. ui_dump 가 화면 요소에 번호를 매겨 캐시에 저장하고, ui_tap 은 그 번호를,
// ui_tap_text 는 보이는 텍스트를 받는다. 탭·입력·뒤로 뒤엔 화면을 자동 재읽기(re-dump)해 결과로
// 돌려준다 → 모델이 "쏘고 잊는" 대신 즉시 최신 화면을 보고 다음 수를 정한다(행동 후 검증).
// HTTP·토큰·타임아웃은 bridge.rs 공용.
use super::bridge::{get as bridge_get, post as bridge_post};
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

// 화면 요소가 많으면 소형 모델 컨텍스트 보호를 위해 상한을 둔다.
const MAX_NODES: usize = 80;

/// 화면 요소 하나 — 모델엔 text 만 보이고, 좌표는 탭할 때 내부에서만 쓴다.
struct Elem {
    text: String,
    x: i64,
    y: i64,
    editable: bool,
}

/// 마지막 ui_dump 결과(번호→요소). ui_tap 이 번호로 좌표를 되짚는다. 단일 워커 스레드가
/// advance() 를 순차 실행하므로 경합은 없지만, 안전을 위해 Mutex 로 감싼다.
fn last() -> &'static Mutex<Vec<Elem>> {
    static LAST: OnceLock<Mutex<Vec<Elem>>> = OnceLock::new();
    LAST.get_or_init(|| Mutex::new(Vec::new()))
}

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("필수 인자 누락: {key}"))
}

/// {ok:bool} 응답을 성공 메시지 또는 에러로 변환.
pub(super) fn expect_ok(body: &Value, on_ok: String, on_fail: &str) -> Result<String> {
    if body.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        Ok(on_ok)
    } else {
        let err = body
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or(on_fail);
        Err(anyhow!("{err}"))
    }
}

/// 패키지명 인젝션 가드 — /screen·/open 은 브리지가 그대로 쓰므로 charset 을 제한한다.
pub(super) fn valid_pkg(pkg: &str) -> bool {
    pkg.contains('.')
        && pkg.split('.').all(|part| {
            !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

fn optional_package(args: &Value) -> Result<Option<&str>> {
    match args.get("package") {
        None => Ok(None),
        Some(Value::String(pkg)) if valid_pkg(pkg) => Ok(Some(pkg)),
        _ => Err(anyhow!("package 는 앱 패키지명이어야 함")),
    }
}

/// /screen JSON 배열 → Elem 벡터. (순수: 기기 불필요, 테스트 가능)
fn parse_elems(body: &Value) -> Vec<Elem> {
    let Some(arr) = body.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .map(|n| Elem {
            text: n
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            x: n.get("x").and_then(|v| v.as_i64()).unwrap_or(0),
            y: n.get("y").and_then(|v| v.as_i64()).unwrap_or(0),
            editable: n.get("editable").and_then(|v| v.as_bool()).unwrap_or(false),
        })
        .collect()
}

/// 요소에 번호를 매겨 모델용 목록으로. 좌표는 넣지 않는다. (순수: 테스트 가능)
fn number_elems(elems: &[Elem]) -> String {
    elems
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let tag = if e.editable { " [입력창]" } else { "" };
            format!("[{i}] \"{}\"{tag}", e.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// text 에 q(대소문자 무시)가 포함된 첫 요소의 인덱스. (순수: 테스트 가능)
fn find_text(elems: &[Elem], q: &str) -> Option<usize> {
    let ql = q.to_lowercase();
    elems
        .iter()
        .position(|e| e.text.to_lowercase().contains(&ql))
}

/// /screen 을 읽어 캐시에 저장하고 번호 매긴 목록을 돌려준다. ui_dump 와 모든 자동검증 꼬리가 공유.
/// pkg 가 있으면 그 앱 창을, 없으면 최상위 앱 창을 읽는다.
fn dump_and_cache(pkg: Option<&str>) -> Result<String> {
    let path = match pkg {
        Some(p) if !p.is_empty() => format!("/screen?package={p}"),
        _ => "/screen".to_string(),
    };
    let body = bridge_get(&path)?;
    let all = parse_elems(&body);
    if all.is_empty() {
        *last().lock().unwrap() = Vec::new();
        return Ok("(화면에서 읽을 요소 없음)".into());
    }
    let total = all.len();
    let shown: Vec<Elem> = all.into_iter().take(MAX_NODES).collect();
    let mut s = number_elems(&shown);
    if total > MAX_NODES {
        s.push_str(&format!("\n…(+{} 개 더)", total - MAX_NODES));
    }
    *last().lock().unwrap() = shown;
    Ok(s)
}

pub struct Screen;
impl Tool for Screen {
    fn name(&self) -> &str {
        "ui_dump"
    }
    fn description(&self) -> &str {
        "현재 폰 화면의 요소를 번호와 함께 읽는다(예: [3] \"메시지 입력\"). 누를 요소의 번호를 ui_tap 에 준다. 특정 앱을 읽으려면 package 를 준다(멀티윈도에서 정확)."
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
        match args.get("package").and_then(|v| v.as_str()) {
            Some(pkg) if !pkg.is_empty() => {
                if !valid_pkg(pkg) {
                    return Err(anyhow!("잘못된 패키지명: {pkg}"));
                }
                dump_and_cache(Some(pkg))
            }
            _ => dump_and_cache(None),
        }
    }
}

pub struct AppOpen;
impl Tool for AppOpen {
    fn name(&self) -> &str {
        "app_open"
    }
    fn description(&self) -> &str {
        "패키지명으로 앱을 실행한다(예: com.kakao.talk). 실행 후 ui_dump 로 화면을 읽어라."
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
        if !valid_pkg(package) {
            return Err(anyhow!("잘못된 패키지명: {package}"));
        }
        // 앱 콜드스타트 타이밍이 불안정해 즉시 재덤프는 빈 화면 위험 → 힌트만 주고 모델이 ui_dump 하게.
        let body = bridge_post("/open", json!({ "package": package }))?;
        expect_ok(
            &body,
            format!("앱 실행 → {package}. ui_dump 로 화면을 읽어라."),
            "실행 실패(런처 인텐트 없음)",
        )
    }
}

pub struct UiTap;
impl Tool for UiTap {
    fn name(&self) -> &str {
        "ui_tap"
    }
    fn description(&self) -> &str {
        "ui_dump 로 얻은 요소 번호(index)를 눌러 버튼·입력창을 조작한다. 누른 뒤의 화면을 함께 돌려준다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "index": { "type": "integer", "description": "ui_dump 목록의 요소 번호(예: [3] 이면 3)" }
            },
            "required": ["index"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let index = args
            .get("index")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow!("index 는 정수여야 함(ui_dump 의 번호)"))?;
        // 캐시에서 번호→좌표. 네트워크 전에 락을 풀어 I/O 동안 잠그지 않는다.
        let (x, y) = {
            let guard = last().lock().unwrap();
            if guard.is_empty() {
                return Err(anyhow!("먼저 ui_dump 로 화면을 읽어 번호를 확인하라."));
            }
            let i = usize::try_from(index).map_err(|_| anyhow!("잘못된 index: {index}"))?;
            let e = guard.get(i).ok_or_else(|| {
                anyhow!(
                    "번호 범위 밖: {index} (0..{}). ui_dump 를 다시 읽어라.",
                    guard.len() - 1
                )
            })?;
            (e.x, e.y)
        };
        let body = bridge_post("/tap", json!({ "x": x, "y": y }))?;
        expect_ok(&body, String::new(), "탭 실패")?;
        let screen = dump_and_cache(None)?;
        Ok(format!("탭함(#{index}). 현재 화면:\n{screen}"))
    }
}

pub struct UiTapText;
impl Tool for UiTapText {
    fn name(&self) -> &str {
        "ui_tap_text"
    }
    fn description(&self) -> &str {
        "화면에서 그 텍스트가 보이는 요소를 눌러(예: 이름·버튼 라벨). 번호를 몰라도 된다. 누른 뒤의 화면을 함께 돌려준다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "누를 요소에 보이는 텍스트(부분 일치)" }
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
        // fresh 로 읽어 텍스트를 찾는다(캐시 staleness 무관). 탭 후 dump_and_cache 로 다시 갱신.
        let body = bridge_get("/screen")?;
        let elems = parse_elems(&body);
        let idx = find_text(&elems, text).ok_or_else(|| {
            let shown = &elems[..elems.len().min(MAX_NODES)];
            anyhow!(
                "화면에서 \"{text}\" 를 못 찾음. 현재 화면:\n{}",
                number_elems(shown)
            )
        })?;
        let (x, y) = (elems[idx].x, elems[idx].y);
        let tap = bridge_post("/tap", json!({ "x": x, "y": y }))?;
        expect_ok(&tap, String::new(), "탭 실패")?;
        let screen = dump_and_cache(None)?;
        Ok(format!("\"{text}\" 눌렀다(#{idx}). 현재 화면:\n{screen}"))
    }
}

pub struct UiType;
impl Tool for UiType {
    fn name(&self) -> &str {
        "ui_type"
    }
    fn description(&self) -> &str {
        "현재 포커스된 입력창에 텍스트를 입력한다(한글 정상). 먼저 입력창을 눌러 포커스한 뒤 사용한다. 입력 뒤의 화면을 함께 돌려준다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string", "description": "입력할 텍스트" },
                "package": { "type": "string", "description": "이 앱의 포커스된 입력창에만 입력 (예: net.thunderbird.android)" }
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
        let pkg = optional_package(args)?;
        let mut request = json!({ "text": text });
        if let Some(pkg) = pkg {
            request["package"] = json!(pkg);
        }
        let body = bridge_post("/type", request)?;
        expect_ok(&body, String::new(), "입력 실패(포커스된 입력창 없음)")?;
        let screen = dump_and_cache(pkg)?;
        Ok(format!("입력함(\"{text}\"). 현재 화면:\n{screen}"))
    }
}

pub struct UiBack;
impl Tool for UiBack {
    fn name(&self) -> &str {
        "ui_back"
    }
    fn description(&self) -> &str {
        "뒤로가기(back)를 누른다. 화면을 이전으로 되돌린 뒤의 화면을 함께 돌려준다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {} })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, _args: &Value) -> Result<String> {
        let body = bridge_post("/back", json!({}))?;
        expect_ok(&body, String::new(), "뒤로가기 실패")?;
        let screen = dump_and_cache(None)?;
        Ok(format!("뒤로가기. 현재 화면:\n{screen}"))
    }
}

pub struct UiScroll;
impl Tool for UiScroll {
    fn name(&self) -> &str {
        "ui_scroll"
    }
    fn description(&self) -> &str {
        "메일 목록·긴 본문·대화 화면을 위(up) 또는 아래(down)로 스크롤하고 새 화면을 읽는다. package를 주면 그 앱에서만 동작한다. 끝에 도달하면 반복하지 않는다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {
            "direction": { "type": "string", "enum": ["down", "up"] },
            "package": { "type": "string", "description": "스크롤할 앱 패키지명 (예: net.thunderbird.android)" }
        }, "required": ["direction"] })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let direction = required_str(args, "direction")?;
        if !matches!(direction, "up" | "down") {
            return Err(anyhow!("direction 은 up 또는 down 이어야 함"));
        }
        let pkg = optional_package(args)?;
        let mut request = json!({ "direction": direction });
        if let Some(pkg) = pkg {
            request["package"] = json!(pkg);
        }
        let body = bridge_post("/scroll", request)?;
        expect_ok(&body, String::new(), "스크롤 실패 또는 끝에 도달함")?;
        let screen = dump_and_cache(pkg)?;
        Ok(format!("스크롤함({direction}). 현재 화면:\n{screen}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scroll_and_typing_reject_bad_scope_before_network() {
        assert!(UiScroll.run(&json!({"direction":"left"})).is_err());
        assert!(UiScroll
            .run(&json!({"direction":"down", "package":null}))
            .is_err());
        assert!(UiType.run(&json!({"text":"reply", "package":""})).is_err());
        assert!(matches!(UiScroll.approval(), ApprovalClass::Mutating));
    }

    fn elem(text: &str, editable: bool) -> Elem {
        Elem {
            text: text.into(),
            x: 0,
            y: 0,
            editable,
        }
    }

    #[test]
    fn number_elems_numbers_and_tags_input() {
        let els = vec![elem("친구", false), elem("메시지 입력", true)];
        assert_eq!(
            number_elems(&els),
            "[0] \"친구\"\n[1] \"메시지 입력\" [입력창]"
        );
    }

    #[test]
    fn find_text_substring_case_insensitive() {
        let els = vec![elem("채팅", false), elem("홍길동 밥 먹었어?", false)];
        assert_eq!(find_text(&els, "밥"), Some(1));
        assert_eq!(find_text(&els, "홍길동"), Some(1));
        assert_eq!(find_text(&els, "없는말"), None);
    }

    #[test]
    fn find_text_ignores_case_for_ascii() {
        let els = vec![elem("Send", false)];
        assert_eq!(find_text(&els, "send"), Some(0));
    }

    #[test]
    fn parse_elems_reads_fields() {
        let body = json!([{ "text": "확인", "x": 10, "y": 20, "editable": true }]);
        let els = parse_elems(&body);
        assert_eq!(els.len(), 1);
        assert_eq!(els[0].text, "확인");
        assert_eq!((els[0].x, els[0].y), (10, 20));
        assert!(els[0].editable);
    }

    // 아래 도구 테스트들은 네트워크 이전(인자·캐시 검증) 단계에서 거부되는 경로만 확인한다 — 기기 불필요.

    #[test]
    fn app_open_rejects_injection() {
        let r = AppOpen.run(&json!({ "package": "com.x; rm -rf /" }));
        assert!(r.is_err(), "인젝션 패키지명이 통과됨");
    }

    #[test]
    fn ui_tap_requires_index() {
        // 문자열 index 는 거부.
        assert!(UiTap.run(&json!({ "index": "3; reboot" })).is_err());
        assert!(UiTap.run(&json!({})).is_err());
        // 캐시가 비어 있으면(덤프 전) 정수 index 도 명확히 거부한다 — 네트워크 이전.
        let e = UiTap.run(&json!({ "index": 0 })).unwrap_err().to_string();
        assert!(e.contains("ui_dump"), "덤프 안내 메시지가 아님: {e}");
    }

    #[test]
    fn ui_type_rejects_empty() {
        assert!(UiType.run(&json!({ "text": "" })).is_err());
        assert!(UiType.run(&json!({})).is_err());
    }

    #[test]
    fn expect_ok_maps_ok_and_error() {
        assert!(expect_ok(&json!({ "ok": true }), "good".into(), "bad").is_ok());
        let e = expect_ok(
            &json!({ "ok": false, "error": "boom" }),
            "good".into(),
            "bad",
        );
        assert_eq!(e.unwrap_err().to_string(), "boom");
    }
}
