// TOOLS — 셸/파일. usix `usix-tools`(bash/file_ops)를 폰 규모로 축약.
// shell·write_file 은 Mutating(승인), read_file·list_dir 은 ReadOnly(자동).
use crate::ports::{ApprovalClass, Tool};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::process::Command;

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("필수 인자 누락: {key}"))
}

// 긴 명령이 hang 하지 않도록 상한(초). termux.rs 처럼 `timeout` 바이너리로 감싼다.
const SHELL_TIMEOUT_SECS: &str = "120";
// 모델 컨텍스트 보호 — 셸 출력이 길면 자른다.
const MAX_OUTPUT: usize = 8000;
// 승인과 무관한 방어선 — 회복 불가 파괴 명령은 승인해도 실행하지 않는다. 소문자 비교.
const BLOCKED: &[&str] = &[
    ":(){:|:&};:",
    ":(){ :|:& };:",
    "rm -rf /",
    "rm -fr /",
    "rm -rf ~",
    "rm -fr ~",
    "rm -rf $home",
    "mkfs.",
    "wipefs",
    "of=/dev/",
    "> /dev/",
];

fn truncate(s: &str) -> String {
    if s.chars().count() <= MAX_OUTPUT {
        return s.trim_end().to_string();
    }
    let head: String = s.chars().take(MAX_OUTPUT).collect();
    format!("{head}\n…(출력 잘림)")
}

pub struct Shell;
impl Tool for Shell {
    fn name(&self) -> &str {
        "shell"
    }
    fn description(&self) -> &str {
        "bash 셸 명령을 실행하고 stdout·stderr·종료코드를 돌려준다. 파일·git·pkg 등 폰의 셸 작업 전반에 쓴다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "실행할 bash 명령" },
                "cwd": { "type": "string", "description": "작업 디렉토리 (생략 시 현재)" }
            },
            "required": ["command"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let cmd = required_str(args, "command")?;
        let low = cmd.to_lowercase();
        if let Some(p) = BLOCKED.iter().find(|p| low.contains(**p)) {
            return Err(anyhow!("차단됨: 파괴적 명령 '{p}' 은 실행하지 않는다."));
        }
        let mut c = Command::new("timeout");
        c.arg(SHELL_TIMEOUT_SECS).arg("bash").arg("-c").arg(cmd);
        if let Some(d) = args.get("cwd").and_then(|v| v.as_str()) {
            c.current_dir(d);
        }
        let out = c.output().map_err(|e| anyhow!("셸 실행 실패: {e}"))?;
        let code = out.status.code().unwrap_or(-1);
        if code == 124 {
            return Err(anyhow!("셸 시간 초과 (>{SHELL_TIMEOUT_SECS}s)"));
        }
        let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
        let se = String::from_utf8_lossy(&out.stderr);
        if !se.trim().is_empty() {
            if !s.is_empty() && !s.ends_with('\n') {
                s.push('\n');
            }
            s.push_str(&se);
        }
        let s = truncate(&s);
        Ok(if s.trim().is_empty() {
            format!("(exit {code})")
        } else if code != 0 {
            format!("(exit {code})\n{s}")
        } else {
            s
        })
    }
}

const MAX_READ_LINES: usize = 1500;

fn render_lines(c: &str, offset: usize, limit: usize) -> String {
    let lines: Vec<&str> = c.lines().collect();
    let total = lines.len();
    let start = offset.min(total);
    let end = start.saturating_add(limit).min(total);
    let body = lines[start..end].join("\n");
    if start > 0 || end < total {
        format!(
            "[{}-{}/{} 줄 — offset/limit 으로 더 읽기]\n{body}",
            start + 1,
            end,
            total
        )
    } else {
        body
    }
}

pub struct ReadFile;
impl Tool for ReadFile {
    fn name(&self) -> &str {
        "read_file"
    }
    fn description(&self) -> &str {
        "텍스트 파일 내용을 읽는다. 큰 파일은 offset·limit(줄 단위)으로 나눠 읽는다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "파일 경로" },
                "offset": { "type": "integer", "description": "시작 줄(0부터)" },
                "limit": { "type": "integer", "description": "읽을 줄 수 (기본/최대 1500)" }
            },
            "required": ["path"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let path = required_str(args, "path")?;
        let offset = args.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(MAX_READ_LINES)
            .min(MAX_READ_LINES);
        let content = std::fs::read_to_string(path).map_err(|e| anyhow!("{path} 읽기 실패: {e}"))?;
        Ok(render_lines(&content, offset, limit))
    }
}

pub struct WriteFile;
impl Tool for WriteFile {
    fn name(&self) -> &str {
        "write_file"
    }
    fn description(&self) -> &str {
        "텍스트 파일을 쓴다(있으면 덮어씀). 상위 폴더가 없으면 만든다."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "파일 경로" },
                "content": { "type": "string", "description": "기록할 내용" }
            },
            "required": ["path", "content"]
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::Mutating
    }
    fn run(&self, args: &Value) -> Result<String> {
        let path = required_str(args, "path")?;
        let content = required_str(args, "content")?;
        if let Some(parent) = std::path::Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).ok();
            }
        }
        std::fs::write(path, content).map_err(|e| anyhow!("{path} 쓰기 실패: {e}"))?;
        Ok(format!("{} 바이트 기록 → {path}", content.len()))
    }
}

pub struct ListDir;
impl Tool for ListDir {
    fn name(&self) -> &str {
        "list_dir"
    }
    fn description(&self) -> &str {
        "디렉토리 내용을 나열한다(폴더는 끝에 /)."
    }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "디렉토리 경로 (기본 현재)" }
            }
        })
    }
    fn approval(&self) -> ApprovalClass {
        ApprovalClass::ReadOnly
    }
    fn run(&self, args: &Value) -> Result<String> {
        let path = args.get("path").and_then(|v| v.as_str()).unwrap_or(".");
        let mut entries: Vec<String> = Vec::new();
        for e in std::fs::read_dir(path).map_err(|e| anyhow!("{path} 나열 실패: {e}"))? {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            entries.push(if is_dir { format!("{name}/") } else { name });
        }
        entries.sort();
        Ok(if entries.is_empty() {
            "(빈 디렉토리)".into()
        } else {
            entries.join("\n")
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_blocks_destructive() {
        for bad in [":(){:|:&};:", "rm -rf /", "sudo rm -fr ~"] {
            let r = Shell.run(&json!({ "command": bad }));
            assert!(r.is_err(), "파괴 명령이 통과됨: {bad}");
        }
    }

    #[test]
    fn shell_runs_echo() {
        let out = Shell.run(&json!({ "command": "echo hi_shell" })).unwrap();
        assert!(out.contains("hi_shell"), "echo 출력 누락: {out}");
    }

    #[test]
    fn read_partial_shows_header() {
        let body = "a\nb\nc\nd\ne";
        let r = render_lines(body, 1, 2);
        assert!(r.starts_with("[2-3/5 줄"), "부분 읽기 헤더 누락: {r}");
        assert!(r.contains("b\nc"), "본문 범위 오류: {r}");
    }

    #[test]
    fn write_then_read_roundtrip() {
        let dir = std::env::temp_dir().join(format!("usix_shell_test_{}", std::process::id()));
        let path = dir.join("nested").join("f.txt");
        let p = path.to_string_lossy().to_string();
        WriteFile.run(&json!({ "path": p, "content": "hello\nworld" })).unwrap();
        let out = ReadFile.run(&json!({ "path": p })).unwrap();
        assert_eq!(out, "hello\nworld");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
