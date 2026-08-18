// BOOTSTRAP — 백엔드(llama.cpp 기본 / ollama) 설치·서버 기동·모델 준비 CLI.
use anyhow::{anyhow, Result};
use std::process::Command;
use std::time::Duration;

/// 백엔드 선택 — 기본 llama.cpp, `USIX_BACKEND=ollama` 로 전환.
fn backend() -> String {
    std::env::var("USIX_BACKEND").unwrap_or_else(|_| "llama".into())
}

fn has_cmd(c: &str) -> bool {
    Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {c}"))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn server_up() -> bool {
    ureq::get("http://127.0.0.1:11434/api/version")
        .call()
        .is_ok()
}

/// ollama 바이너리 보장 — 없으면 termux 패키지 설치. 목록이 오래되면 갱신 후 재시도.
pub fn ensure_ollama() -> Result<()> {
    if has_cmd("ollama") {
        return Ok(());
    }
    println!("ollama not installed → pkg install ollama");
    if Command::new("pkg")
        .args(["install", "-y", "ollama"])
        .status()?
        .success()
    {
        return Ok(());
    }
    // 오래된 apt 목록 대비 1회 갱신 후 재시도
    let _ = Command::new("apt").arg("update").status();
    if Command::new("pkg")
        .args(["install", "-y", "ollama"])
        .status()?
        .success()
    {
        Ok(())
    } else {
        Err(anyhow!("ollama install failed"))
    }
}

/// serve 데몬 보장 — 내려가 있으면 백그라운드로 기동(런처 종료에도 생존).
/// 반환값: 이번 호출이 서버를 새로 띄웠으면 true(=우리가 소유), 이미 떠 있었으면 false.
pub fn ensure_serve() -> Result<bool> {
    if server_up() {
        return Ok(false);
    }
    println!("starting ollama server...");
    Command::new("sh")
        .arg("-c")
        .arg("setsid nohup ollama serve </dev/null >\"$PREFIX/var/log/ollama.log\" 2>&1 &")
        .status()?;
    for _ in 0..40 {
        if server_up() {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    Err(anyhow!(
        "could not confirm server startup (log: $PREFIX/var/log/ollama.log)"
    ))
}

fn has_model(model: &str) -> Result<bool> {
    let out = Command::new("ollama").arg("list").output()?;
    let s = String::from_utf8_lossy(&out.stdout);
    Ok(s.lines()
        .any(|l| l.split_whitespace().next() == Some(model)))
}

/// 모델 다운로드 — 진행률을 그대로 보여준다.
pub fn pull(model: &str) -> Result<()> {
    ensure_serve()?;
    println!("downloading model: {model}");
    if Command::new("ollama")
        .args(["pull", model])
        .status()?
        .success()
    {
        Ok(())
    } else {
        Err(anyhow!("model download failed: {model}"))
    }
}

fn ollama_model() -> String {
    std::env::var("USIX_MODEL").unwrap_or_else(|_| "qwen2.5:1.5b-instruct-q5_K_M".into())
}

// ── llama.cpp ──

/// 로드할 GGUF 경로 — 기본 Qwen3.5-4B Q4_K_M, `USIX_MODEL` 로 다른 경로 지정 가능.
fn llama_model_path() -> String {
    std::env::var("USIX_MODEL").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/models/Qwen3.5-4B-Q4_K_M.gguf")
    })
}

/// GGUF 모델 보장 — 기본 경로가 비어 있으면 `llama-model-get 3b` 로 받는다.
/// (USIX_MODEL 로 커스텀 경로를 지정했으면 크기를 알 수 없어 자동 다운로드하지 않는다.)
pub fn ensure_llama_model() -> Result<()> {
    let path = llama_model_path();
    if std::path::Path::new(&path).exists() {
        println!("model already present: {path}");
        return Ok(());
    }
    if std::env::var("USIX_MODEL").is_ok() {
        // 커스텀 경로인데 없음 — ensure_llama_serve 가 친절히 안내하며 실패한다.
        return Ok(());
    }
    if !has_cmd("llama-model-get") {
        return Err(anyhow!(
            "llama-model-get not found — reinstall llama-cpp or fetch the GGUF manually."
        ));
    }
    println!("downloading model (Hammer2.1-3b Q4 GGUF) via llama-model-get...");
    if Command::new("llama-model-get")
        .arg("hammer")
        .status()?
        .success()
    {
        Ok(())
    } else {
        Err(anyhow!("model download failed (llama-model-get hammer)"))
    }
}

fn llama_up() -> bool {
    ureq::get(&format!(
        "http://127.0.0.1:{}/health",
        crate::adapters::LLAMA_PORT
    ))
    .call()
    .is_ok()
}

/// llama-server 바이너리 보장 — 없으면 termux 패키지(OpenCL 백엔드 포함) 설치.
pub fn ensure_llama() -> Result<()> {
    if has_cmd("llama-server") {
        return Ok(());
    }
    println!("llama.cpp not installed → pkg install llama-cpp llama-cpp-backend-opencl");
    if Command::new("pkg")
        .args(["install", "-y", "llama-cpp", "llama-cpp-backend-opencl"])
        .status()?
        .success()
    {
        Ok(())
    } else {
        Err(anyhow!("llama.cpp install failed"))
    }
}

/// llama-server 데몬 보장 — 내려가 있으면 백그라운드로 기동(런처 종료에도 생존).
/// GPU: `llama-gpu` 런처가 네이티브 Qualcomm OpenCL 강제 + 전 레이어 오프로드(-ngl 99).
/// (Adreno 의 Vulkan/clvk 경로는 garbage 토큰 → 반드시 이 우회를 쓴다.) 없으면 CPU 폴백.
pub fn ensure_llama_serve() -> Result<bool> {
    if llama_up() {
        return Ok(false);
    }
    let model = llama_model_path();
    if !std::path::Path::new(&model).exists() {
        return Err(anyhow!(
            "model file not found: {model}\n  get it with `llama-model-get 3b` or set the path via USIX_MODEL."
        ));
    }
    let gpu = has_cmd("llama-gpu");
    let port = crate::adapters::LLAMA_PORT;
    println!(
        "starting llama-server ({}) — {model}",
        if gpu { "GPU/OpenCL" } else { "CPU" }
    );
    // --parallel 1: 슬롯 1개만. 기본값 4는 KV 캐시를 4배(4×4096=16384토큰) 잡아
    // 메모리 압박으로 lmkd 가 X11 서버를 OOM 킬 하던 원인이었다. 1인용 비서엔 1슬롯이면 충분.
    // --jinja: GGUF 내장 챗 템플릿 사용(Hammer 등 도구모델이 도구호출을 제대로 내려면 필요).
    let launch = if gpu {
        // env: nohup 뒤에서 `VAR=..` 는 명령 이름으로 오해되므로 env 로 넘긴다.
        format!("env LLAMA_GPU_BIN=llama-server llama-gpu -m '{model}' --host 127.0.0.1 --port {port} -c 4096 --parallel 1 --jinja")
    } else {
        format!("llama-server -m '{model}' --host 127.0.0.1 --port {port} -c 4096 --parallel 1 --jinja")
    };
    Command::new("sh")
        .arg("-c")
        .arg(format!(
            "setsid nohup {launch} </dev/null >\"$PREFIX/var/log/llama.log\" 2>&1 &"
        ))
        .status()?;
    // 3B GPU 첫 로드는 수십 초 걸릴 수 있어 넉넉히 대기(≤120s).
    for _ in 0..240 {
        if llama_up() {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    Err(anyhow!(
        "could not confirm llama-server startup (log: $PREFIX/var/log/llama.log)"
    ))
}

/// serve 데몬 종료 — "시작한 쪽이 정리한다" 원칙에 따라 우리가 띄운 서버만 내린다.
pub fn stop_backend_serve() {
    let pat = if backend() == "ollama" {
        "ollama serve".to_string()
    } else {
        format!("llama-server .*--port {}", crate::adapters::LLAMA_PORT)
    };
    let _ = Command::new("pkill").args(["-f", &pat]).status();
}

/// 대화 시작 전 자동 호출 — 현재 백엔드 서버가 내려가 있으면 기동한다.
/// (ollama 는 이미 설치돼 있다고 보고 serve 만; llama 는 서버만 띄운다.)
/// 반환값: 이번 호출이 서버를 새로 띄웠으면 true.
pub fn ensure_backend_serve() -> Result<bool> {
    if backend() == "ollama" {
        ensure_serve()
    } else {
        ensure_llama_serve()
    }
}

/// setup — 백엔드별 설치 → 서버 → 모델까지 한 번에 준비.
pub fn setup() -> Result<()> {
    if backend() == "ollama" {
        let model = ollama_model();
        ensure_ollama()?;
        ensure_serve()?;
        if has_model(&model)? {
            println!("model already present: {model}");
        } else {
            pull(&model)?;
        }
    } else {
        ensure_llama()?;
        ensure_llama_model()?;
        ensure_llama_serve()?;
    }
    seed_skills();
    println!("Ready — run `usix-termux` to start chatting.");
    Ok(())
}

// 예시 스킬을 바이너리에 담아 배포 — 재빌드 없이 마크다운으로 능력을 늘리는 진입점.
const SMS_REPLY_SKILL: &str = include_str!("../skills/sms_reply.md");
const KAKAO_READ_SKILL: &str = include_str!("../skills/kakao_read.md");
const KAKAO_NOTIFY_SKILL: &str = include_str!("../skills/kakao_notify.md");

/// 스킬 하나를 ~/.usix/skills/ 에 심는다(없을 때만).
fn seed_skill(name: &str, body: &str) {
    let dir = crate::domain::skills::skills_dir();
    let f = dir.join(name);
    if f.exists() {
        return;
    }
    if std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&f, body).is_ok() {
        println!("seeded example skill → {}", f.display());
    }
}

/// 예시 스킬을 심는다. UI 도구는 기본 등록이라 kakao_read 도 항상 심는다.
/// 알림 스킬만 USIX_COMPANION 설정 시(해당 도구가 있을 때) 심는다.
fn seed_skills() {
    seed_skill("sms_reply.md", SMS_REPLY_SKILL);
    seed_skill("kakao_read.md", KAKAO_READ_SKILL);
    if std::env::var("USIX_COMPANION").is_ok() {
        seed_skill("kakao_notify.md", KAKAO_NOTIFY_SKILL);
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

/// 컴패니언 브리지 점검 — 127.0.0.1:8760/health 가 응답하면 앱이 살아 있는 것.
fn companion_bridge_ok() -> bool {
    ureq::get("http://127.0.0.1:8760/health").call().is_ok()
}

/// /health 의 accessibility 플래그 — 접근성 서비스가 연결돼 화면 제어가 가능한지.
fn companion_accessibility_ok() -> bool {
    ureq::get("http://127.0.0.1:8760/health")
        .call()
        .ok()
        .and_then(|r| r.into_json::<serde_json::Value>().ok())
        .and_then(|v| v.get("accessibility").and_then(|a| a.as_bool()))
        .unwrap_or(false)
}

/// doctor — prerequisite checks (per backend).
pub fn doctor() -> Result<()> {
    let mark = |b: bool| if b { "✅" } else { "❌" };
    if backend() == "ollama" {
        let model = ollama_model();
        println!("{} ollama installed", mark(has_cmd("ollama")));
        println!("{} ollama server running", mark(server_up()));
        println!("{} model `{model}`", mark(has_model(&model).unwrap_or(false)));
    } else {
        let model = llama_model_path();
        println!("{} llama.cpp (llama-server)", mark(has_cmd("llama-server")));
        println!("{} llama-gpu launcher (OpenCL)", mark(has_cmd("llama-gpu")));
        println!(
            "{} model file {model}",
            mark(std::path::Path::new(&model).exists())
        );
        println!("{} llama-server running", mark(llama_up()));
    }
    println!("{} termux-api (binary)", mark(has_cmd("termux-battery-status")));
    println!("{} Termux:API app (bridge responds)", mark(termux_bridge_ok()));
    {
        let bridge = companion_bridge_ok();
        let acc = bridge && companion_accessibility_ok();
        println!("{} usix-companion 브리지 (127.0.0.1:8760)", mark(bridge));
        println!("{} 접근성(화면 제어) 연결됨", mark(acc));
        if !acc {
            println!("   → companion 앱에서 '접근성(화면 제어)' 권한을 켜세요.");
        }
    }
    if std::env::var("USIX_COMPANION").is_ok() {
        let ok = companion_bridge_ok();
        println!("{} usix-companion 알림 브리지 (127.0.0.1:8760)", mark(ok));
        if !ok {
            println!("   → companion/ 앱 설치 후 실행하고 '알림 접근' 권한을 켜세요.");
        }
    }
    Ok(())
}
