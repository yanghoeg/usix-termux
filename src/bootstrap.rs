// BOOTSTRAP — 백엔드(llama.cpp 기본 / ollama) 설치·서버 기동·모델 준비 CLI.
use crate::tools::bridge;
use anyhow::{anyhow, Result};
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::process::{Command, Stdio};
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

/// 로컬 헬스 프로브 — 짧은 타임아웃(연결 2s·읽기 5s). 서버가 반쯤 죽어 연결만 받으면 doctor 가 굳는다.
fn probe(url: &str) -> bool {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(2))
        .timeout_read(Duration::from_secs(5))
        .build()
        .get(url)
        .call()
        .is_ok()
}

fn server_up() -> bool {
    probe("http://127.0.0.1:11434/api/version")
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

/// 로드할 GGUF 경로 — 기본 Qwen3.5-2B Q5_K_M, `USIX_MODEL` 로 다른 경로 지정 가능.
/// (4B 는 램 ~2.7GB 라 카톡 등 무거운 앱을 포그라운드로 올리면 LMK 가 죽인다. 2B ~1.4GB 로 공존.)
pub(crate) fn llama_model_path() -> String {
    std::env::var("USIX_MODEL").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/models/Qwen3.5-2B-Q5_K_M.gguf")
    })
}

/// GGUF 모델 보장 — 기본 경로가 비어 있으면 `llama-model-get hammer` 로 받는다.
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
    probe(&format!(
        "http://127.0.0.1:{}/health",
        crate::adapters::LLAMA_PORT
    ))
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
            "model file not found: {model}\n  get it with `llama-model-get hammer` or set the path via USIX_MODEL."
        ));
    }
    let gpu = has_cmd("llama-gpu");
    let port = crate::adapters::LLAMA_PORT;
    println!(
        "starting llama-server ({}) — {model}",
        if gpu { "GPU/OpenCL" } else { "CPU" }
    );
    // --parallel 1: 슬롯 1개만. 기본값 4는 KV 캐시를 4배(4×8192=32768토큰) 잡아
    // 메모리 압박으로 lmkd 가 X11 서버를 OOM 킬 하던 원인이었다. 1인용 비서엔 1슬롯이면 충분.
    // -c 8192: 문자/알림 여러 건이 한 툴결과로 들어와도 4096 을 넘겨 400(exceeds context)
    // 나던 걸 막는다. 2B 는 KV 캐시가 작아 1슬롯이면 이 컨텍스트도 감당된다.
    // --jinja: GGUF 내장 챗 템플릿 사용(Hammer 등 도구모델이 도구호출을 제대로 내려면 필요).
    // 모델 경로를 shell 문자열에 넣지 않고 argv 로 전달한다. 경로에 따옴표가 있어도
    // shell 문맥 탈출이나 명령 주입이 일어나지 않는다.
    let log_path = std::env::var_os("PREFIX")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/usix"))
        .join("var/log/llama.log");
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| anyhow!("로그 디렉토리 생성 실패 ({}): {e}", parent.display()))?;
    }
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| anyhow!("llama 로그 열기 실패 ({}): {e}", log_path.display()))?;
    let log_err = log.try_clone()?;
    let port = port.to_string();
    let mut launch = Command::new("setsid");
    launch.arg("nohup");
    if gpu {
        launch.arg("llama-gpu").env("LLAMA_GPU_BIN", "llama-server");
    } else {
        launch.arg("llama-server");
    }
    let mut child = launch
        .args([
            "-m",
            &model,
            "--host",
            "127.0.0.1",
            "--port",
            &port,
            "-c",
            "8192",
            "--parallel",
            "1",
            "--jinja",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|e| anyhow!("llama-server 시작 실패: {e}"))?;
    // 3B GPU 첫 로드는 수십 초 걸릴 수 있어 넉넉히 대기(≤120s).
    for _ in 0..240 {
        if llama_up() {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(anyhow!(
        "could not confirm llama-server startup (log: {})",
        log_path.display()
    ))
}

/// 대화형/one-shot 실행이 직접 기동한 backend만 수명 종료 시 정리한다.
pub struct BackendServeGuard {
    started: bool,
}

impl BackendServeGuard {
    pub fn start() -> Result<Self> {
        Ok(Self {
            started: ensure_backend_serve()?,
        })
    }
}

impl Drop for BackendServeGuard {
    fn drop(&mut self) {
        if self.started {
            stop_backend_serve();
        }
    }
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
const MAIL_SKILL: &str = include_str!("../skills/mail.md");

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

/// 예시 스킬을 심는다. 알림 브리지 도구도 기본 등록이라 kakao_read 도 항상 심는다.
fn seed_skills() {
    seed_skill("sms_reply.md", SMS_REPLY_SKILL);
    seed_skill("kakao_read.md", KAKAO_READ_SKILL);
    seed_skill("mail.md", MAIL_SKILL);
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
                println!("   → 앱에서 '토큰 복사' 를 누른 뒤 `usix-termux pair` 를 실행하세요.");
            }
        }
        // 구형 앱: 무인증 — 같은 폰의 다른 앱도 브리지를 부를 수 있다.
        _ => println!("⚠️  구버전 companion(토큰 검사 없음) — 앱을 최신 릴리스로 올리세요."),
    }
    health
}

/// pair — 앱이 발급한 브리지 토큰을 ~/.usix/companion_token 에 저장한다.
/// 인자 > 클립보드(termux-clipboard-get) > 표준입력 순으로 토큰을 찾는다. 1회만 하면 된다.
pub fn pair(arg: Option<&str>) -> Result<()> {
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
        None => println!("· 브리지 무응답 — 앱을 실행한 뒤 `usix-termux doctor` 로 확인하세요."),
    }
    Ok(())
}

/// doctor — prerequisite checks (per backend).
pub fn doctor() -> Result<()> {
    let mark = |b: bool| if b { "✅" } else { "❌" };
    if backend() == "ollama" {
        let model = ollama_model();
        println!("{} ollama installed", mark(has_cmd("ollama")));
        println!("{} ollama server running", mark(server_up()));
        println!(
            "{} model `{model}`",
            mark(has_model(&model).unwrap_or(false))
        );
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
    println!(
        "{} termux-api (binary)",
        mark(has_cmd("termux-battery-status"))
    );
    println!(
        "{} Termux:API app (bridge responds)",
        mark(termux_bridge_ok())
    );
    let ui = std::env::var("USIX_UI").is_ok();
    let notif = std::env::var("USIX_COMPANION").is_ok();
    if ui || notif {
        let health = doctor_companion(&mark);
        let acc = health
            .as_ref()
            .and_then(|h| h.get("accessibility").and_then(|v| v.as_bool()))
            .unwrap_or(false);
        println!("{} 접근성(화면 제어) 연결됨", mark(acc));
        if !acc {
            println!("   → companion 앱에서 '접근성(화면 제어)' 권한을 켜세요.");
        }
        let listener = health
            .as_ref()
            .and_then(|h| h.get("listener").and_then(|v| v.as_bool()))
            .unwrap_or(false);
        println!("{} 알림 접근(리스너) 연결됨", mark(listener));
        if !listener {
            println!("   → companion 앱에서 '알림 접근' 권한을 켜세요.");
        }
    }
    Ok(())
}
