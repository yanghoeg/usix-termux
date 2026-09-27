// usix-code — composition root for a fully local harness.
mod adapters;
mod bootstrap;
mod domain;
mod ports;
mod tasks;
mod tools;
mod tui;

use adapters::llama::LlamaCpp;
use adapters::ollama::Ollama;
use domain::agent::{Agent, Turn};
use domain::registry::Registry;
use ports::{Backend, Host, Llm};

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let host = adapters::host::current()?;
    let host = host.as_ref();

    match args.first().map(String::as_str) {
        Some("setup") => bootstrap::setup(host)?,
        Some("doctor") => bootstrap::doctor(host)?,
        Some("pair") => host.pair(args.get(1).map(String::as_str))?,
        Some("task") => tasks::command(&args[1..], host)?,
        Some("worker") => tasks::worker(&args[1..], host)?,
        Some("-c") => one_shot(&args[1..].join(" "), host)?,
        Some("chat") | None => {
            let store = tasks::store::Store::default_location()?;
            let _execution = store.execution_lock()?;
            let _serve = bootstrap::BackendServeGuard::start(host)?;
            let llm = backend()?;
            let registry = Registry::new(host.tools());
            let agent = Agent::new(
                llm.as_ref(),
                &registry,
                adapters::skills::load(host.bundled_skills()),
            );
            tui::run(agent, model_label())?;
        }
        Some("-h") | Some("--help") => print_help(),
        Some("-V") | Some("--version") => println!("usix-code {}", env!("CARGO_PKG_VERSION")),
        Some(other) => {
            eprintln!("unknown command: {other}\n");
            print_help();
        }
    }
    Ok(())
}

// LLM 백엔드 선택 — 기본 llama.cpp, USIX_BACKEND=ollama 로 전환.
fn backend() -> anyhow::Result<Box<dyn Llm>> {
    if bootstrap::backend()? == Backend::Ollama {
        Ok(Box::new(Ollama::new(bootstrap::ollama_model())))
    } else {
        Ok(Box::new(LlamaCpp::new()))
    }
}

// 현재 백엔드/모델을 짧게 라벨링 — TUI 하단·배너 표기용.
fn model_label() -> String {
    if std::env::var("USIX_BACKEND").as_deref() == Ok("ollama") {
        bootstrap::ollama_model()
    } else {
        let path = bootstrap::llama_model_path();
        std::path::Path::new(&path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "qwen".into())
    }
}

// 대화형 없이 한 번 질문 — 변경 도구는 안전하게 자동 거부.
fn one_shot(q: &str, host: &dyn Host) -> anyhow::Result<()> {
    let store = tasks::store::Store::default_location()?;
    let _execution = store.execution_lock()?;
    let _serve = bootstrap::BackendServeGuard::start(host)?;
    let llm = backend()?;
    let registry = Registry::new(host.tools());
    let mut agent = Agent::new(
        llm.as_ref(),
        &registry,
        adapters::skills::load(host.bundled_skills()),
    );
    agent.submit(q);
    let mut sink = |_: &str| {};
    match agent.advance(&mut sink)? {
        Turn::Answer(a) => {
            println!("{a}");
        }
        Turn::NeedApproval { desc } => {
            eprintln!("[skipped] mutating actions are only approved in interactive TUI: {desc}");
            agent.approve(false)?;
            // Do not ask the model again after denial: it may report a skipped action as done.
        }
    }
    Ok(())
}

fn print_help() {
    println!(
        "usix-code — fully local coding and automation harness\n\n\
         Usage:\n  \
         usix-code            interactive TUI\n  \
         usix-code setup      prepare local backend + model + skills\n  \
         usix-code doctor     check prerequisites\n  \
         usix-code pair [tok] pair the optional Android companion (Termux)\n  \
         usix-code -c \"query\"  one-shot query (non-interactive)\n\n\
         usix-code task --help  durable tasks and schedules\n  \
         usix-code worker       process due tasks; pause for approvals\n\n\
         Environment:\n  \
         USIX_BACKEND  llama (default) | ollama\n  \
         USIX_MODEL    llama=GGUF path (default ~/models/Qwen3.5-2B-Q5_K_M.gguf)\n                \
         ollama=model tag (default qwen2.5:1.5b-instruct-q5_K_M)"
    );
}
