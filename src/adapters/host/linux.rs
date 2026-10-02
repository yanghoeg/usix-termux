use super::{has_cmd, install, state_dir, LOCAL_SKILL};
use crate::ports::{Backend, BundledSkill, Host, LaunchSpec, Tool};
use anyhow::Result;
use std::path::PathBuf;

pub struct Linux;

fn managed_llama() -> PathBuf {
    state_dir().join("backends/llama.cpp-v0.5.0/build/bin/llama-server")
}

impl Host for Linux {
    fn name(&self) -> &'static str {
        "Linux"
    }

    fn tools(&self, workspace: &std::path::Path) -> Vec<Box<dyn Tool>> {
        crate::adapters::workspace::tools(crate::tools::local_tools(workspace), workspace)
    }

    fn bundled_skills(&self) -> &'static [BundledSkill] {
        &[LOCAL_SKILL]
    }

    fn ensure_backend(&self, backend: Backend) -> Result<()> {
        if has_cmd(match backend {
            Backend::Llama => "llama-server",
            Backend::Ollama => "ollama",
        }) || (backend == Backend::Llama && managed_llama().is_file())
        {
            return Ok(());
        }
        install(include_str!("../../../scripts/backends/linux.sh"), backend)
    }

    fn backend_launch(&self, backend: Backend) -> LaunchSpec {
        match backend {
            Backend::Llama if !has_cmd("llama-server") => LaunchSpec::new(managed_llama()),
            Backend::Llama => LaunchSpec::new("llama-server"),
            Backend::Ollama => LaunchSpec::new("ollama"),
        }
    }

    fn doctor(&self) -> Result<()> {
        println!("Local file, shell, and task tools enabled.");
        Ok(())
    }

    fn notify(&self, content: &str) {
        eprintln!("{content}");
    }
}
