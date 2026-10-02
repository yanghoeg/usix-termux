//! Network-free fixtures: only ephemeral loopback HTTP and temporary processes.
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);
const BINARY: &str = env!("CARGO_BIN_EXE_usix-code");

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "usix-runtime-cli-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn command(&self) -> Command {
        let mut command = Command::new(BINARY);
        command
            .env("USIX_TASKS_DIR", self.0.join("tasks"))
            .env_remove("USIX_BACKEND")
            .env_remove("USIX_MODEL")
            .env_remove("USIX_CONTEXT_TOKENS")
            .env_remove("USIX_OUTPUT_TOKENS");
        command
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

type Requests = Arc<Mutex<Vec<(String, Value)>>>;
struct Server {
    port: u16,
    requests: Requests,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Server {
    fn start(
        mut respond: impl FnMut(&str, &Value) -> (&'static str, String) + Send + 'static,
    ) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let requests: Requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let thread = thread::spawn(move || {
            while !stopped.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if let Some((path, body)) = read_request(&stream) {
                            captured.lock().unwrap().push((path.clone(), body.clone()));
                            let (kind, body) = respond(&path, &body);
                            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) => panic!("fixture listener: {error}"),
                }
            }
        });
        Self {
            port,
            requests,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.take().unwrap().join().unwrap();
    }
}

fn read_request(stream: &TcpStream) -> Option<(String, Value)> {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let path = line.split_whitespace().nth(1)?.to_owned();
    let mut length = 0;
    loop {
        line.clear();
        reader.read_line(&mut line).ok()?;
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse().ok()?;
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).ok()?;
    Some((path, serde_json::from_slice(&body).unwrap_or(Value::Null)))
}

#[test]
fn worker_reads_creation_workspace_even_when_launched_elsewhere() {
    let fixture = Fixture::new();
    let a = fixture.0.join("a");
    let b = fixture.0.join("b");
    fs::create_dir_all(&a).unwrap();
    fs::create_dir_all(&b).unwrap();
    fs::write(a.join("README.md"), "CREATION_WORKSPACE").unwrap();
    fs::write(b.join("README.md"), "WRONG_WORKSPACE").unwrap();
    assert!(fixture
        .command()
        .current_dir(&a)
        .args(["task", "add", "Read README.md"])
        .output()
        .unwrap()
        .status
        .success());
    let server = Server::start(|path, body| {
        if path == "/health" {
            return ("application/json", json!({"status":"ok"}).to_string());
        }
        assert_eq!(path, "/v1/chat/completions");
        assert_eq!(body["max_tokens"], 1024);
        let read = body["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["role"] == "tool");
        let delta = match read {
            None => {
                json!({"tool_calls":[{"index":0,"id":"read_1","function":{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}}]})
            }
            Some(message) => {
                assert_eq!(message["content"], "CREATION_WORKSPACE");
                json!({"content":"CREATION_WORKSPACE"})
            }
        };
        (
            "text/event-stream",
            format!(
                "data: {}\n\ndata: [DONE]\n\n",
                json!({"choices":[{"delta":delta}]})
            ),
        )
    });
    let output = fixture
        .command()
        .current_dir(&b)
        .env("USIX_LLAMA_PORT", server.port.to_string())
        .args(["worker", "--once"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = fixture
        .command()
        .args(["task", "show", "1"])
        .output()
        .unwrap();
    let task: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(task["status"], "completed");
    assert_eq!(task["last_result"], "CREATION_WORKSPACE");
    assert_eq!(task["workspace"], json!(a.canonicalize().unwrap()));
}

#[test]
fn remote_ollama_alias_never_receives_conversation_data() {
    let fixture = Fixture::new();
    let server = Server::start(|path, _| {
        ("application/json",match path {
        "/api/version" => json!({"version":"0.18.0"}),
        "/api/show" => json!({"details":{"format":"gguf"},"model_info":{},"remote_model":"hidden-cloud","remote_host":"https://remote.example"}),
        _ => panic!("inference must not be called: {path}"),
    }.to_string())
    });
    let output = fixture
        .command()
        .env("USIX_BACKEND", "ollama")
        .env("USIX_MODEL", "innocent-alias")
        .env("USIX_OLLAMA_PORT", server.port.to_string())
        .args(["-c", "PRIVATE_PROMPT_123"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("remote Ollama models are disabled"));
    let requests = server.requests.lock().unwrap();
    assert!(requests.iter().all(
        |(path, body)| path != "/api/chat" && !body.to_string().contains("PRIVATE_PROMPT_123")
    ));
}

#[test]
fn verified_local_ollama_receives_explicit_context_and_output_limits() {
    let fixture = Fixture::new();
    let server = Server::start(|path, body| {
        ("application/json",match path {
        "/api/version" => json!({"version":"0.18.0"}),
        "/api/show" => json!({"details":{"format":"gguf"},"model_info":{"general.architecture":"qwen"}}),
        "/api/chat" => { assert_eq!(body["options"]["num_ctx"],8192); assert_eq!(body["options"]["num_predict"],1024); json!({"message":{"role":"assistant","content":"local answer"}}) },
        _ => panic!("unexpected endpoint: {path}"),
    }.to_string())
    });
    let output = fixture
        .command()
        .env("USIX_BACKEND", "ollama")
        .env("USIX_MODEL", "local:latest")
        .env("USIX_OLLAMA_PORT", server.port.to_string())
        .args(["-c", "hello"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "local answer"
    );
}

fn wait_for_file(path: &std::path::Path) -> u32 {
    let end = Instant::now() + Duration::from_secs(5);
    while Instant::now() < end {
        if let Ok(text) = fs::read_to_string(path) {
            if let Ok(pid) = text.trim().parse() {
                return pid;
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("process fixture did not start: {}", path.display());
}
fn running(pid: u32) -> bool {
    // A terminated descendant may briefly remain a zombie until its reaper runs.
    let state = fs::read_to_string(format!("/proc/{pid}/stat")).ok();
    state.is_some_and(|s| {
        s.rsplit_once(") ")
            .is_some_and(|(_, tail)| !tail.starts_with('Z'))
    })
}
fn assert_stopped(pid: u32) {
    let end = Instant::now() + Duration::from_secs(5);
    while running(pid) && Instant::now() < end {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !running(pid),
        "owned process {pid} survived its lifetime pipe"
    );
}

fn supervisor(fixture: &Fixture) -> Child {
    let mut child = Command::new(BINARY)
        .arg("__supervise-backend")
        .stdin(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let spec = json!({"program":"bash","args":["-c","echo $$ > \"$1\"; sleep 60 & echo $! > \"$2\"; wait","fixture",fixture.0.join("leader"),fixture.0.join("descendant")],"env":[]});
    writeln!(child.stdin.as_mut().unwrap(), "{spec}").unwrap();
    child
}

#[test]
fn lifetime_pipe_stops_owned_wrapper_and_descendants_only() {
    let fixture = Fixture::new();
    let mut unrelated = Command::new("sleep").arg("60").spawn().unwrap();
    let mut child = supervisor(&fixture);
    let leader = wait_for_file(&fixture.0.join("leader"));
    let descendant = wait_for_file(&fixture.0.join("descendant"));
    drop(child.stdin.take());
    assert!(child.wait().unwrap().success());
    assert_stopped(leader);
    assert_stopped(descendant);
    assert!(unrelated.try_wait().unwrap().is_none());
    unrelated.kill().unwrap();
    unrelated.wait().unwrap();
}

#[test]
fn owner_signals_and_sigkill_close_pipe_and_stop_backend() {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGKILL] {
        let fixture = Fixture::new();
        let spec = json!({"program":"bash","args":["-c","echo $$ > \"$1\"; sleep 60 & echo $! > \"$2\"; wait","fixture",fixture.0.join("leader"),fixture.0.join("descendant")],"env":[]});
        let mut owner = Command::new("python3").args(["-c", "import subprocess,sys,time; p=subprocess.Popen([sys.argv[1],'__supervise-backend'],stdin=subprocess.PIPE); p.stdin.write((sys.argv[2]+'\\n').encode()); p.stdin.flush(); time.sleep(60)", BINARY, &spec.to_string()])
            .stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let leader = wait_for_file(&fixture.0.join("leader"));
        let descendant = wait_for_file(&fixture.0.join("descendant"));
        // SAFETY: owner is a process created and retained by this test.
        unsafe {
            libc::kill(owner.id() as libc::pid_t, signal);
        }
        owner.wait().unwrap();
        assert_stopped(leader);
        assert_stopped(descendant);
    }
}
