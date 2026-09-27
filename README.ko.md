# usix-code

[English](README.md) · **한국어**

노트북·데스크톱·Android Termux에서 실행하는 **완전 로컬 코딩·자동화 하네스**입니다.
모델 추론, 도구 실행, 승인, 작업 저장을 모두 사용자의 기기에서 처리합니다.
헥사고날 구조로 코어와 외부 환경을 분리하고 운영체제와 모델 엔진을 어댑터로 연결합니다.

기본 엔진은 **llama.cpp**이며 로컬 **Ollama**도 지원합니다. 클라우드 추론으로 자동
전환하지 않고 API 키도 필요하지 않습니다. 최초 설치와 모델 다운로드에는 인터넷이
필요하지만 준비된 로컬 환경에서는 오프라인으로 실행할 수 있습니다. 사용자가 요청하고
승인한 셸 명령이나 문자 발송 등의 도구 작업은 네트워크를 사용할 수 있습니다.

## x64 Linux 설치

최신 안정 버전 [Rust](https://rustup.rs)와 C/C++ 빌드 도구가 필요합니다.
Debian/Ubuntu에서는 다음 패키지를 설치한 뒤 하네스를 빌드합니다.

```sh
sudo apt update
sudo apt install build-essential cmake git curl
git clone https://github.com/yanghoeg/usix-code.git
cd usix-code
sh install.sh
export PATH="$HOME/.local/bin:$PATH"
usix-code setup
usix-code doctor
usix-code
```

설치 위치는 `~/.local/bin`입니다. PATH 설정을 셸 설정 파일에도 추가하세요.
`setup`은 PATH의 `llama-server`를 사용하거나 `~/.usix/backends`에 llama.cpp
**v0.5.0**을 CPU용으로 빌드합니다. Git, CMake, Make, C++ 컴파일러가 필요하며
기본 빌드 작업 수는 2개입니다. `CMAKE_BUILD_PARALLEL_LEVEL`로 조절할 수 있습니다.
GPU와 시스템 서비스는 필수가 아닙니다. GPU를 쓰려면 해당 GPU용 `llama-server`를
PATH에 두거나 로컬 서버를 먼저 실행하세요.

## Android Termux 설치

[Termux](https://termux.dev) 안에서 직접 빌드합니다.

```sh
pkg update
pkg install rust clang make git curl bash coreutils
git clone https://github.com/yanghoeg/usix-code.git
cd usix-code
sh install.sh
usix-code setup
usix-code doctor
usix-code
```

설치 위치는 `$PREFIX/bin`입니다. `setup`은 필요한 경우 `pkg`로 `llama-cpp`를
설치합니다. Termux:API와 컴패니언 앱은 폰 도구를 쓸 때만 필요합니다.
[Android 도구 안내](docs/termux.md)에서 권한과 연결 방법을 확인할 수 있습니다.

두 환경에서 같은 Rust 패키지와 명령을 사용합니다.
`sh install.sh --prefix /원하는/경로`로 설치 위치를 바꿀 수 있고,
`cargo install --locked --path .`도 지원합니다. 각 환경에서 네이티브 빌드해야 하므로
x64 Linux 실행 파일을 ARM Android에 그대로 복사해서 사용할 수는 없습니다.

## 모델과 실행

`setup`은 모델이 없으면 [Qwen3.5-2B Q5_K_M](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/main/Qwen3.5-2B-Q5_K_M.gguf)을
`~/models/Qwen3.5-2B-Q5_K_M.gguf`에 다운로드합니다. 크기는 약 1.44 GB입니다.
다운로드가 완료된 뒤 모델 파일로 옮깁니다. 더 큰 모델을 사용하려면 메모리 용량에
맞는 로컬 GGUF를 지정하세요.

```sh
export USIX_MODEL="$HOME/models/my-local-model.gguf"
usix-code setup
cd /path/to/project
usix-code
```

직접 지정한 GGUF는 이미 존재해야 하며 대화와 도구 호출을 지원해야 합니다.
품질과 메모리 사용량은 선택한 모델에 따라 달라집니다.
기본 2B 모델은 두 환경에서 시작하기 위한 작은 모델입니다.

Ollama는 다음처럼 선택합니다. Linux에서는 [공식 설치 안내](https://docs.ollama.com/linux)에
따라 먼저 설치해야 하며, Termux에서는 `setup`이 패키지를 설치할 수 있습니다.

```sh
export USIX_BACKEND=ollama
export USIX_MODEL=qwen2.5:1.5b-instruct-q5_K_M
usix-code setup
usix-code
```

하네스가 시작하는 Ollama에는 `OLLAMA_NO_CLOUD=1`을 설정합니다. 직접 관리하는
서버에서도 클라우드 기능을 끄고 다운로드한 로컬 모델을 사용하세요.
추론 연결은 llama.cpp의 `127.0.0.1:8080` 또는 Ollama의 `127.0.0.1:11434`를 사용하며
HTTP 리다이렉트는 따르지 않습니다. 로그는 `~/.usix/logs`에 저장합니다.
`setup`이 준비한 서버는 계속 실행됩니다. 대화나 워커가 직접 시작한 서버는 종료할 때
정리하며 기존 서버는 유지합니다. 자동 시작 서비스는 설치하지 않습니다.

## 공통 도구와 승인

| 도구 | 승인 |
| --- | --- |
| `read_file`, `list_dir`, `task_list` | 자동 실행 |
| `shell`, `write_file`, `task_create`, `task_cancel` | 사람 승인 필요 |

```sh
usix-code -c "README.md를 읽고 프로젝트를 요약해줘"
usix-code task --help
usix-code worker --once
```

`-c` 모드에서는 변경 작업을 거부합니다. 백그라운드 작업은 승인이 필요하면 멈추며
`usix-code task run ID`로 확인하고 이어서 진행할 수 있습니다.
도구는 현재 OS 계정 권한으로 실행됩니다. 승인 절차가 파일 접근을 격리하는 샌드박스는
아닙니다. [작업·예약·복구 안내](docs/tasks.md).

스킬은 `~/.usix/skills`의 Markdown 파일입니다. 로컬 코딩 스킬은 두 환경에 제공하고
문자·메일·카카오톡 스킬은 Termux 어댑터가 추가합니다. 사용자가 수정한 스킬은 보존합니다.
일반 대화 기록은 세션 안에서 유지되고 저장한 작업은 종료 후에도 남습니다.

## 헥사고날 구조

코어는 운영체제를 판별하거나 패키지 명령을 실행하지 않습니다.

- `domain/`: 에이전트, 승인 흐름, 도구 레지스트리, 스킬 해석·선택
- `ports.rs`: 모델의 `Llm`, 작업의 `Tool`, 실행 환경의 `Host` 계약
- `adapters/host/`: Linux·Termux별 설치, 도구, 기본 스킬, 진단, 알림
- `adapters/skills.rs`, `adapters/runtime.rs`: 파일과 프로세스 입출력
- `bootstrap.rs`: 선택한 호스트를 이용한 설치 준비와 서버 수명 관리
- `main.rs`: 환경에 맞는 어댑터를 선택하고 주입하는 진입점

다른 환경은 `Host` 구현과 필요한 입출력 어댑터를 추가해 연결합니다.
에이전트와 작업 실행기의 변경 없이 확장하는 구조이며 현재 지원 대상은 Linux와
Android Termux입니다. 다른 운영체제의 실행까지 검증했다는 뜻은 아닙니다.

## 이름 변경과 검증

기존 `usix-termux` 패키지·실행 파일 이름은 `usix-code`로 바뀝니다.
`~/.usix`의 스킬, 작업, 컴패니언 토큰 경로는 유지합니다. 셸 별칭과 워커 실행 명령을
바꾸세요. 새 설치가 예전 실행 파일을 자동으로 삭제하지는 않습니다.

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
python3 tests/install_smoke.py
```

CI는 Linux 테스트와 Android ARM64 컴파일 검사를 수행합니다.
Termux 기기에서의 모델 실행과 폰 도구 검증은 별도로 필요합니다. MIT 라이선스입니다.
