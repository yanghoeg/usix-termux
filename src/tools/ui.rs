// TOOLS — 폰 UI 컨트롤(실험적). 온디바이스 adb(무선 디버깅, 루트 불필요)로 화면을 읽고 앱을 연다.
// USIX_UI 가 설정됐을 때만 등록된다(tools/mod.rs). 읽기(ui_dump)는 자동, 앱 실행(app_open)은 승인.
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::process::Command;

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("필수 인자 누락: {key}"))
}

// uiautomator dump 는 수 초 걸릴 수 있어 termux 기본(8s)보다 넉넉히.
const ADB_TIMEOUT_SECS: &str = "12";
// 화면 요소가 많으면 소형 모델 컨텍스트 보호를 위해 상한을 둔다.
const MAX_NODES: usize = 80;

/// `timeout <N> adb shell <args>` — termux.rs::run 과 동일한 timeout 가드 패턴.
/// 기기 미연결이면 무선 디버깅 페어링을 안내한다.
fn adb_shell(args: &[&str]) -> Result<String> {
    let out = Command::new("timeout")
        .arg(ADB_TIMEOUT_SECS)
        .arg("adb")
        .arg("shell")
        .args(args)
        .output()
        .map_err(|e| anyhow!("adb 실행 실패 (android-tools 설치됨?): {e}"))?;
    if out.status.code() == Some(124) {
        return Err(anyhow!("adb 무응답 (>{ADB_TIMEOUT_SECS}s)"));
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let low = stderr.to_lowercase();
    if low.contains("no devices") || low.contains("device offline") || low.contains("not found") {
        return Err(anyhow!(
            "adb 기기 미연결 — 개발자 옵션 > 무선 디버깅으로 페어링 후 `adb connect localhost:PORT`. `usix-termux doctor` 로 점검."
        ));
    }
    if !out.status.success() {
        return Err(anyhow!("adb 오류: {}", stderr.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn attr<'a>(node: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("{key}=\"");
    let start = node.find(&pat)? + pat.len();
    let rest = &node[start..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

/// `[x1,y1][x2,y2]` → 중심 (cx,cy).
fn center(bounds: &str) -> Option<(i64, i64)> {
    let nums: Vec<i64> = bounds
        .split(|c: char| !c.is_ascii_digit() && c != '-')
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse().ok())
        .collect();
    if nums.len() != 4 {
        return None;
    }
    Some(((nums[0] + nums[2]) / 2, (nums[1] + nums[3]) / 2))
}

/// uiautomator XML → 텍스트/클릭가능 요소의 (라벨, 중심x, 중심y). XML 의존성 없이 손으로 스캔.
pub fn parse_uiautomator(xml: &str) -> Vec<(String, i64, i64)> {
    let mut out = Vec::new();
    for chunk in xml.split("<node ").skip(1) {
        let node = chunk.split('>').next().unwrap_or(chunk);
        let text = attr(node, "text").map(unescape).unwrap_or_default();
        let desc = attr(node, "content-desc").map(unescape).unwrap_or_default();
        // `long-clickable="true"` 오탐 방지 위해 앞 공백 포함 검사.
        let clickable = node.contains(" clickable=\"true\"");
        let label = if !text.is_empty() {
            text
        } else if !desc.is_empty() {
            desc
        } else {
            String::new()
        };
        if label.is_empty() && !clickable {
            continue;
        }
        let Some((cx, cy)) = attr(node, "bounds").and_then(center) else {
            continue;
        };
        let label = if label.is_empty() {
            "(빈 버튼)".to_string()
        } else {
            label
        };
        out.push((label, cx, cy));
    }
    out
}

pub struct Screen;
impl Tool for Screen {
    fn name(&self) -> &str {
        "ui_dump"
    }
    fn description(&self) -> &str {
        "현재 폰 화면에 보이는 텍스트·버튼과 위치(x,y)를 읽는다. 화면 내용을 파악할 때 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({ "type": "object", "properties": {} })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, _args: &Value) -> Result<String> {
        // dump 는 파일로 쓰므로(stdout 은 안내문) 버리고 cat 으로 XML 을 회수. 고정 문자열 = 안전.
        let xml = adb_shell(&[
            "uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1; cat /sdcard/window_dump.xml",
        ])?;
        let nodes = parse_uiautomator(&xml);
        if nodes.is_empty() {
            return Ok("(화면에서 읽을 요소 없음)".into());
        }
        let lines: Vec<String> = nodes
            .iter()
            .take(MAX_NODES)
            .map(|(t, x, y)| format!("\"{t}\" @ ({x},{y})"))
            .collect();
        let mut s = lines.join("\n");
        if nodes.len() > MAX_NODES {
            s.push_str(&format!("\n…(+{} 개 더)", nodes.len() - MAX_NODES));
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
        // adb shell 은 인자를 기기 셸이 재파싱 → 패키지명을 문자집합으로 제한해 인젝션 차단.
        if package.is_empty()
            || !package
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_')
        {
            return Err(anyhow!("잘못된 패키지명: {package}"));
        }
        adb_shell(&[
            "monkey",
            "-p",
            package,
            "-c",
            "android.intent.category.LAUNCHER",
            "1",
        ])?;
        Ok(format!("앱 실행 → {package}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nodes_with_centers_and_entities() {
        let xml = r#"<?xml version='1.0'?><hierarchy>
        <node index="0" text="밥 &amp; 국" bounds="[0,100][200,300]" clickable="false"/>
        <node index="1" text="" content-desc="전송" bounds="[400,800][600,900]" clickable="true"/>
        <node index="2" text="" content-desc="" bounds="[0,0][10,10]" long-clickable="true"/>
        </hierarchy>"#;
        let nodes = parse_uiautomator(xml);
        assert_eq!(nodes.len(), 2, "빈 라벨+비클릭 노드는 제외돼야 함: {nodes:?}");
        assert_eq!(nodes[0], ("밥 & 국".to_string(), 100, 200));
        assert_eq!(nodes[1], ("전송".to_string(), 500, 850));
    }

    #[test]
    fn app_open_rejects_injection() {
        let r = AppOpen.run(&json!({ "package": "com.x; rm -rf /" }));
        assert!(r.is_err(), "인젝션 패키지명이 통과됨");
    }
}
