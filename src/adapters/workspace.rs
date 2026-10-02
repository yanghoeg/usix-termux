//! Bind local paths explicitly; task execution never changes process-wide cwd.
use crate::ports::{ApprovalClass, Tool};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub fn tools(tools: Vec<Box<dyn Tool>>, workspace: &Path) -> Vec<Box<dyn Tool>> {
    tools
        .into_iter()
        .map(|tool| {
            Box::new(Bound {
                tool,
                workspace: workspace.to_owned(),
            }) as Box<dyn Tool>
        })
        .collect()
}

struct Bound {
    tool: Box<dyn Tool>,
    workspace: PathBuf,
}

impl Bound {
    fn arguments(&self, args: &Value) -> Value {
        let mut args = args.clone();
        let key = match self.name() {
            "read_file" | "write_file" | "list_dir" => "path",
            "shell" => "cwd",
            _ => return args,
        };
        let supplied = args.get(key).and_then(Value::as_str);
        if supplied.is_none() && matches!(self.name(), "read_file" | "write_file") {
            return args;
        }
        // Invalid explicit values stay invalid; defaults apply only when absent.
        if args.get(key).is_some() && supplied.is_none() {
            return args;
        }
        let path = supplied.map_or_else(|| self.workspace.clone(), |p| self.workspace.join(p));
        if let Some(object) = args.as_object_mut() {
            object.insert(key.into(), json!(path));
        }
        args
    }
}

impl Tool for Bound {
    fn name(&self) -> &str {
        self.tool.name()
    }
    fn description(&self) -> &str {
        self.tool.description()
    }
    fn parameters(&self) -> Value {
        self.tool.parameters()
    }
    fn approval(&self) -> ApprovalClass {
        self.tool.approval()
    }
    fn approval_arguments(&self, args: &Value) -> Value {
        self.arguments(args)
    }
    fn requires_fresh_screen(&self) -> bool {
        self.tool.requires_fresh_screen()
    }
    fn run(&self, args: &Value) -> Result<String> {
        if matches!(
            self.name(),
            "read_file" | "write_file" | "list_dir" | "shell"
        ) {
            ensure!(args.is_object(), "tool arguments must be an object");
            let key = if self.name() == "shell" {
                "cwd"
            } else {
                "path"
            };
            if let Some(value) = args.get(key) {
                ensure!(value.is_string(), "{key} must be a string");
            }
        }
        self.tool.run(&self.arguments(args))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::shell::{ListDir, ReadFile, Shell, WriteFile};

    #[test]
    fn invalid_optional_paths_cannot_fall_back_to_process_cwd() {
        let list = Bound {
            tool: Box::new(ListDir),
            workspace: std::env::current_dir().unwrap(),
        };
        for args in [Value::Null, json!({"path":null}), json!({"path":42})] {
            assert!(list.run(&args).is_err());
        }
        let shell = Bound {
            tool: Box::new(Shell),
            workspace: std::env::current_dir().unwrap(),
        };
        assert!(shell
            .run(&json!({"command":"printf invalid", "cwd":null}))
            .is_err());
    }

    #[test]
    fn binds_relative_paths_and_default_shell_directory() {
        let file = Bound {
            tool: Box::new(ReadFile),
            workspace: PathBuf::from("/project/a"),
        };
        assert_eq!(
            file.arguments(&json!({"path":"README.md"}))["path"],
            "/project/a/README.md"
        );
        assert_eq!(
            file.arguments(&json!({"path":"/project/b/file"}))["path"],
            "/project/b/file"
        );
        let shell = Bound {
            tool: Box::new(Shell),
            workspace: PathBuf::from("/project/a"),
        };
        assert_eq!(
            shell.arguments(&json!({"command":"pwd"}))["cwd"],
            "/project/a"
        );
        assert_eq!(
            shell.arguments(&json!({"command":"pwd","cwd":"src"}))["cwd"],
            "/project/a/src"
        );
    }

    #[test]
    fn reads_and_writes_creation_workspace_without_changing_process_cwd() {
        let root = std::env::temp_dir().join(format!("usix-workspace-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let original = std::env::current_dir().unwrap();
        let tools = tools(
            vec![Box::new(ReadFile), Box::new(WriteFile), Box::new(Shell)],
            &root,
        );
        tools[1]
            .run(&json!({"path":"test.txt","content":"bound workspace"}))
            .unwrap();
        assert_eq!(
            tools[0].run(&json!({"path":"test.txt"})).unwrap(),
            "bound workspace"
        );
        assert_eq!(
            tools[2].run(&json!({"command":"cat test.txt"})).unwrap(),
            "bound workspace"
        );
        assert_eq!(std::env::current_dir().unwrap(), original);
        std::fs::remove_dir_all(root).unwrap();
    }
}
