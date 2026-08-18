// usix-termux — 폰 Termux 에이전트 진입점 + DI.
mod adapters;
mod bootstrap;
mod domain;
mod ports;
mod tools;
mod tui;

use adapters::llama::LlamaCpp;
use adapters::ollama::Ollama;
use domain::agent::{Agent, Turn};
use domain::registry::Registry;
use ports::Llm;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match args.first().map(String::as_str) {
        Some("setup") => bootstrap::setup()?,
        Some("doctor") => bootstrap::doctor()?,
        Some("-c") => one_shot(&args[1..].join(" "))?,
        Some("chat") | None => {
            // "시작한 쪽이 정리한다" — 이번 실행이 서버를 띄웠을 때만 나갈 때 내린다.
            let started = bootstrap::ensure_backend_serve()?;
            let llm = backend();
            let registry = Registry::new(tools::default_tools());
            let agent = Agent::new(llm.as_ref(), &registry);
            let res = tui::run(agent, model_label());
            if started {
                bootstrap::stop_backend_serve();
            }
            res?;
        }
        Some("-h") | Some("--help") => print_help(),
        Some(other) => {
            eprintln!("unknown command: {other}\n");
            print_help();
        }
    }
    Ok(())
}

// LLM 백엔드 선택 — 기본 llama.cpp, USIX_BACKEND=ollama 로 전환.
fn backend() -> Box<dyn Llm> {
    if std::env::var("USIX_BACKEND").as_deref() == Ok("ollama") {
        let model =
            std::env::var("USIX_MODEL").unwrap_or_else(|_| "qwen2.5:1.5b-instruct-q5_K_M".into());
        Box::new(Ollama::new(model))
    } else {
        Box::new(LlamaCpp::new())
    }
}

// 현재 백엔드/모델을 짧게 라벨링 — TUI 하단·배너 표기용.
fn model_label() -> String {
    if std::env::var("USIX_BACKEND").as_deref() == Ok("ollama") {
        std::env::var("USIX_MODEL").unwrap_or_else(|_| "qwen2.5:1.5b".into())
    } else {
        std::env::var("USIX_MODEL")
            .ok()
            .and_then(|p| {
                std::path::Path::new(&p)
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
            })
            .unwrap_or_else(|| "qwen2.5-3b".into())
    }
}

// 대화형 없이 한 번 질문 — 변경 도구는 안전하게 자동 거부.
fn one_shot(q: &str) -> anyhow::Result<()> {
    bootstrap::ensure_backend_serve()?;
    let llm = backend();
    let registry = Registry::new(tools::default_tools());
    let mut agent = Agent::new(llm.as_ref(), &registry);
    agent.submit(q);
    let mut sink = |_: &str| {};
    loop {
        match agent.advance(&mut sink)? {
            Turn::Answer(a) => {
                println!("{a}");
                break;
            }
            Turn::NeedApproval { desc } => {
                eprintln!("[skipped] mutating actions are only approved in interactive TUI: {desc}");
                agent.approve(false)?;
            }
        }
    }
    Ok(())
}

fn print_help() {
    println!(
        "usix-termux — phone Termux agent\n\n\
         Usage:\n  \
         usix-termux            interactive TUI\n  \
         usix-termux setup      install backend + start server (+pull model on ollama)\n  \
         usix-termux doctor     check prerequisites\n  \
         usix-termux -c \"query\"  one-shot query (non-interactive)\n\n\
         Environment:\n  \
         USIX_BACKEND  llama (default) | ollama\n  \
         USIX_MODEL    llama=GGUF path (default ~/models/Qwen3.5-4B-Q4_K_M.gguf)\n                \
         ollama=model tag (default qwen2.5:1.5b-instruct-q5_K_M)"
    );
}
