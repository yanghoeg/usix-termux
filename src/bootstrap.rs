//! Setup/doctor application services. Platform operations go through the Host port.
use crate::adapters::{
    host::{has_cmd, state_dir},
    runtime::{self, OwnedServer},
    skills,
};
use crate::ports::{Backend, Host};
use anyhow::{bail, ensure, Context, Result};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::Duration;

const DEFAULT_GGUF: &str = "Qwen3.5-2B-Q5_K_M.gguf";
const MODEL_URL: &str =
    "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q5_K_M.gguf";
pub const DEFAULT_OLLAMA_MODEL: &str = "qwen2.5:1.5b-instruct-q5_K_M";
const OLLAMA_HOST: &str = "127.0.0.1:11434";

pub fn backend() -> Result<Backend> {
    match std::env::var("USIX_BACKEND").as_deref().unwrap_or("llama") {
        "llama" => Ok(Backend::Llama),
        "ollama" => Ok(Backend::Ollama),
        other => bail!("unknown USIX_BACKEND `{other}`; use llama or ollama"),
    }
}

pub fn ollama_model() -> String {
    std::env::var("USIX_MODEL").unwrap_or_else(|_| DEFAULT_OLLAMA_MODEL.into())
}

pub fn llama_model_path() -> String {
    std::env::var("USIX_MODEL").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/models/{DEFAULT_GGUF}")
    })
}

fn probe(url: &str) -> bool {
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(2))
        .timeout_read(Duration::from_secs(5))
        .build()
        .get(url)
        .call()
        .is_ok()
}

fn server_up(backend: Backend) -> bool {
    match backend {
        Backend::Ollama => probe(&format!("http://{OLLAMA_HOST}/api/version")),
        Backend::Llama => probe(&format!(
            "http://127.0.0.1:{}/health",
            crate::adapters::LLAMA_PORT
        )),
    }
}

fn ollama_command() -> Command {
    let mut command = Command::new("ollama");
    command
        .env("OLLAMA_HOST", OLLAMA_HOST)
        .env("OLLAMA_NO_CLOUD", "1");
    command
}

fn has_model(model: &str) -> Result<bool> {
    let out = ollama_command().arg("list").output()?;
    ensure!(out.status.success(), "ollama list failed");
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .any(|line| line.split_whitespace().next() == Some(model)))
}

fn valid_gguf(path: &Path) -> bool {
    let mut magic = [0_u8; 4];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok()
        && magic == *b"GGUF"
}

fn ensure_llama_model() -> Result<()> {
    let path = PathBuf::from(llama_model_path());
    if path.exists() {
        ensure!(valid_gguf(&path), "not a GGUF model: {}", path.display());
        println!("model already present: {}", path.display());
        return Ok(());
    }
    ensure!(
        std::env::var_os("USIX_MODEL").is_none(),
        "model file not found: {}; set USIX_MODEL to an existing GGUF file",
        path.display()
    );
    ensure!(has_cmd("curl"), "curl is required to download the default model, or set USIX_MODEL to an existing GGUF file");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let partial = path.with_extension(format!("gguf.{}.part", std::process::id()));
    println!(
        "downloading {DEFAULT_GGUF} (about 1.44 GB) → {}",
        path.display()
    );
    let result = (|| -> Result<()> {
        let status = Command::new("curl")
            .args([
                "--fail",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--retry",
                "2",
                "--output",
            ])
            .arg(&partial)
            .arg(MODEL_URL)
            .status()
            .context("download model with curl")?;
        ensure!(
            status.success() && valid_gguf(&partial),
            "model download failed; rerun setup to retry"
        );
        std::fs::rename(&partial, &path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(partial);
    }
    result
}

fn log_path(backend: Backend) -> PathBuf {
    state_dir()
        .join("logs")
        .join(format!("{}.log", backend.name()))
}

/// None means the server was already running and belongs to somebody else.
fn ensure_backend_serve(host: &dyn Host) -> Result<Option<Child>> {
    let backend = backend()?;
    if server_up(backend) {
        return Ok(None);
    }
    let mut spec = host.backend_launch(backend);
    let attempts = match backend {
        Backend::Ollama => {
            spec.args.push("serve".into());
            spec.env.extend([
                ("OLLAMA_HOST".into(), OLLAMA_HOST.into()),
                ("OLLAMA_NO_CLOUD".into(), "1".into()),
            ]);
            40
        }
        Backend::Llama => {
            let model = llama_model_path();
            ensure!(valid_gguf(Path::new(&model)), "model file missing or invalid: {model}; run `usix-code setup` or set USIX_MODEL to a GGUF file");
            spec.args.extend([
                "-m".into(),
                model,
                "--host".into(),
                "127.0.0.1".into(),
                "--port".into(),
                crate::adapters::LLAMA_PORT.to_string(),
                "-c".into(),
                "8192".into(),
                "--parallel".into(),
                "1".into(),
                "--jinja".into(),
            ]);
            240
        }
    };
    let log = log_path(backend);
    println!(
        "starting {} on this device (log: {})",
        backend.name(),
        log.display()
    );
    let mut owned = OwnedServer(Some(runtime::spawn(spec, &log)?));
    for _ in 0..attempts {
        if let Some(status) = owned.0.as_mut().unwrap().try_wait()? {
            bail!(
                "{} exited ({status}); see {}",
                backend.name(),
                log.display()
            );
        }
        if server_up(backend) {
            return Ok(owned.0.take());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    bail!("could not confirm server startup; see {}", log.display())
}

pub struct BackendServeGuard {
    _owned: OwnedServer,
}

impl BackendServeGuard {
    pub fn start(host: &dyn Host) -> Result<Self> {
        Ok(Self {
            _owned: OwnedServer(ensure_backend_serve(host)?),
        })
    }
}

pub fn setup(host: &dyn Host) -> Result<()> {
    let backend = backend()?;
    println!("usix-code — fully local harness · {}", host.name());
    // Validate custom paths before installing a backend or downloading anything.
    if backend == Backend::Llama && std::env::var_os("USIX_MODEL").is_some() {
        ensure_llama_model()?;
    }
    host.ensure_backend(backend)?;
    if backend == Backend::Llama {
        ensure_llama_model()?;
    }
    let mut owned = OwnedServer(ensure_backend_serve(host)?);
    if backend == Backend::Ollama {
        let model = ollama_model();
        if !has_model(&model)? {
            println!("downloading model: {model}");
            ensure!(
                ollama_command().args(["pull", &model]).status()?.success(),
                "model download failed: {model}"
            );
        }
    }
    skills::seed(host.bundled_skills())?;
    // Setup deliberately leaves its server running. Chat/worker own theirs only for the session.
    drop(owned.0.take());
    println!("Ready — run `usix-code` in your project directory.");
    Ok(())
}

pub fn doctor(host: &dyn Host) -> Result<()> {
    let backend = backend()?;
    let mark = |ok| if ok { "✅" } else { "❌" };
    println!(
        "usix-code — fully local harness · {} · {}",
        host.name(),
        std::env::consts::ARCH
    );
    let program = host.backend_launch(backend).program;
    println!(
        "{} backend: {}",
        mark(program.is_file() || has_cmd(&program.to_string_lossy())),
        program.display()
    );
    println!(
        "{} local {} server",
        mark(server_up(backend)),
        backend.name()
    );
    match backend {
        Backend::Llama => println!(
            "{} model: {}",
            mark(valid_gguf(Path::new(&llama_model_path()))),
            llama_model_path()
        ),
        Backend::Ollama => println!(
            "{} model: {}",
            mark(has_model(&ollama_model()).unwrap_or(false)),
            ollama_model()
        ),
    }
    for cmd in ["bash", "timeout"] {
        println!("{} {cmd}", mark(has_cmd(cmd)));
    }
    println!("Backend log: {}", log_path(backend).display());
    host.doctor()
}
