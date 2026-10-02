use super::{has_cmd, install, LOCAL_SKILL};
use crate::ports::{Backend, BundledSkill, Host, LaunchSpec, Tool};
use crate::tools::{bridge, comms, companion, email, read, ui};
use anyhow::{anyhow, Result};
use std::process::{Command, Stdio};

pub struct Termux;

impl Host for Termux {
    fn name(&self) -> &'static str {
        "Android Termux"
    }

    fn tools(&self, workspace: &std::path::Path) -> Vec<Box<dyn Tool>> {
        let mut tools = crate::tools::local_tools(workspace);
        let phone: Vec<Box<dyn Tool>> = vec![
            Box::new(read::SmsList),
            Box::new(read::CallLog),
            Box::new(read::Battery),
            Box::new(read::Contacts),
            Box::new(comms::SmsSend),
            Box::new(comms::Call),
            Box::new(comms::Reminder),
            Box::new(ui::Screen),
            Box::new(ui::AppOpen),
            Box::new(ui::UiTap),
            Box::new(ui::UiTapText),
            Box::new(ui::UiType),
            Box::new(ui::UiBack),
            Box::new(ui::UiScroll),
            Box::new(email::EmailOpen),
            Box::new(email::EmailCompose),
            Box::new(companion::NotifList),
            Box::new(companion::NotifReply),
        ];
        tools.extend(phone);
        crate::adapters::workspace::tools(tools, workspace)
    }

    fn bundled_skills(&self) -> &'static [BundledSkill] {
        &[
            LOCAL_SKILL,
            BundledSkill {
                filename: "sms_reply.md",
                text: include_str!("../../../skills/sms_reply.md"),
                legacy: None,
            },
            BundledSkill {
                filename: "kakao_read.md",
                text: include_str!("../../../skills/kakao_read.md"),
                legacy: Some(include_str!("../../../skills/legacy/kakao_read.md")),
            },
            BundledSkill {
                filename: "mail.md",
                text: include_str!("../../../skills/mail.md"),
                legacy: None,
            },
        ]
    }

    fn ensure_backend(&self, backend: Backend) -> Result<()> {
        if has_cmd(match backend {
            Backend::Llama => "llama-server",
            Backend::Ollama => "ollama",
        }) {
            return Ok(());
        }
        install(include_str!("../../../scripts/backends/termux.sh"), backend)
    }

    fn backend_launch(&self, backend: Backend) -> LaunchSpec {
        match backend {
            Backend::Llama if has_cmd("llama-gpu") => {
                let mut spec = LaunchSpec::new("llama-gpu");
                spec.env
                    .push(("LLAMA_GPU_BIN".into(), "llama-server".into()));
                spec
            }
            Backend::Llama => LaunchSpec::new("llama-server"),
            Backend::Ollama => LaunchSpec::new("ollama"),
        }
    }

    fn doctor(&self) -> Result<()> {
        let mark = |b| if b { "✅" } else { "❌" };
        println!("Optional phone tools:");
        println!(
            "{} termux-api (binary)",
            mark(has_cmd("termux-battery-status"))
        );
        println!(
            "{} Termux:API app (bridge responds)",
            mark(termux_bridge_ok())
        );
        if bridge::token_path().is_file()
            || std::env::var_os("USIX_UI").is_some()
            || std::env::var_os("USIX_COMPANION").is_some()
        {
            if let Some(h) = doctor_companion(&mark) {
                println!(
                    "{} companion accessibility",
                    mark(h["accessibility"].as_bool() == Some(true))
                );
                println!(
                    "{} companion notifications",
                    mark(h["listener"].as_bool() == Some(true))
                );
            }
        } else {
            println!("Optional companion: use `usix-code pair` after installing the Android app.");
        }
        Ok(())
    }

    fn pair(&self, token: Option<&str>) -> Result<()> {
        pair_companion(token)
    }

    fn notify(&self, content: &str) {
        eprintln!("{content}");
        let _ = Command::new("timeout")
            .args([
                "8",
                "termux-notification",
                "--title",
                "usix-code task",
                "--content",
                content,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    fn reset_tools(&self) {
        ui::clear_cache();
    }
}

/// termux-api 브리지 생존 점검 — 바이너리 존재만으론 부족하다. 실제 termux-* 를 짧게
/// 찔러 Termux:API 앱(APK)이 응답하는지 본다(무응답이면 timeout 124 → false).
fn termux_bridge_ok() -> bool {
    Command::new("timeout")
        .args(["5", "termux-battery-status"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// 컴패니언 /health — 응답하면 앱이 살아 있는 것. 토큰을 실어 보내므로 `paired` 로 페어링 여부,
/// `accessibility` 로 접근성 연결 여부까지 한 번에 본다(bridge.rs 타임아웃 적용).
fn companion_health() -> Option<serde_json::Value> {
    bridge::get("/health").ok()
}

/// doctor 의 컴패니언 공통 항목 — 브리지·토큰 페어링 상태를 한 번 찍고 health JSON 을 돌려준다.
fn doctor_companion(mark: &dyn Fn(bool) -> &'static str) -> Option<serde_json::Value> {
    let health = companion_health();
    println!(
        "{} usix-companion 브리지 (127.0.0.1:{})",
        mark(health.is_some()),
        bridge::PORT
    );
    let Some(h) = &health else {
        println!("   → usix-companion 앱을 설치·실행하고 필요한 권한을 켜세요.");
        return None;
    };
    match h.get("auth").and_then(|v| v.as_bool()) {
        // 신형 앱: 토큰 검사가 켜져 있다 → 페어링 상태를 그대로 보고.
        Some(true) => {
            let paired = h.get("paired").and_then(|v| v.as_bool()) == Some(true);
            println!(
                "{} 토큰 페어링 ({})",
                mark(paired),
                bridge::token_path().display()
            );
            if !paired {
                println!("   → 앱에서 '토큰 복사' 를 누른 뒤 `usix-code pair` 를 실행하세요.");
            }
        }
        // 구형 앱: 무인증 — 같은 폰의 다른 앱도 브리지를 부를 수 있다.
        _ => println!("⚠️  구버전 companion(토큰 검사 없음) — 앱을 최신 릴리스로 올리세요."),
    }
    health
}

/// pair — 앱이 발급한 브리지 토큰을 ~/.usix/companion_token 에 저장한다.
/// 인자 > 클립보드(termux-clipboard-get) > 표준입력 순으로 토큰을 찾는다. 1회만 하면 된다.
fn pair_companion(arg: Option<&str>) -> Result<()> {
    let mut token = arg.map(str::trim).map(String::from);
    if token.is_none() {
        // 앱의 '토큰 복사' 버튼 → 클립보드. Termux:API 없거나 빈 클립보드면 아래 프롬프트로.
        let clip = Command::new("timeout")
            .args(["5", "termux-clipboard-get"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| bridge::valid_token(s));
        if clip.is_some() {
            println!("클립보드에서 토큰을 읽었습니다.");
        }
        token = clip;
    }
    if token.is_none() {
        print!("companion 앱의 토큰을 붙여넣으세요: ");
        use std::io::Write;
        std::io::stdout().flush()?;
        let mut line = String::new();
        std::io::stdin().read_line(&mut line)?;
        token = Some(line.trim().to_string());
    }
    let token = token.unwrap_or_default();
    if !bridge::valid_token(&token) {
        return Err(anyhow!(
            "토큰 형식이 아닙니다(영숫자·-·_ 16~128자). 앱 화면의 '토큰 복사' 를 다시 누르세요."
        ));
    }
    let path = bridge::save_token(&token)?;
    println!("✅ 저장 → {}", path.display());
    // 저장 직후 서버와 대조 — 여기서 ❌ 면 앱 쪽 토큰이 바뀐 것.
    match companion_health() {
        Some(h) if h.get("paired").and_then(|v| v.as_bool()) == Some(true) => {
            println!("✅ 브리지가 토큰을 승인했습니다.")
        }
        Some(h) if h.get("auth").and_then(|v| v.as_bool()) == Some(true) => {
            println!("❌ 브리지가 토큰을 거부했습니다 — 앱 화면의 토큰과 다시 대조하세요.")
        }
        Some(_) => println!("⚠️  구버전 companion(토큰 검사 없음) — 앱을 최신 릴리스로 올리세요."),
        None => println!("· 브리지 무응답 — 앱을 실행한 뒤 `usix-code doctor` 로 확인하세요."),
    }
    Ok(())
}
