# usix-termux

[English](README.md) · **한국어**

안드로이드 [Termux](https://termux.dev)용 로컬 LLM 폰 에이전트. [usix](https://github.com/)의
설계 — **function-calling 도구 + ApprovalClass 권한 게이팅 + 헥사고날 ports/adapters 코어** —
를 폰 규모로 축약해, 로컬 LLM(**llama.cpp** 기본 / ollama 선택)이 `termux-api` 도구를
호출하게 한다.

수치·부작용은 도구가 담당하고, LLM은 자연어 해석과 도구 선택에만 쓴다. 문자 발송·전화
걸기 같은 **변경 작업은 실행 전 사람 승인**을 거친다.

답변은 토큰 단위로, 한 줄씩 스트리밍된다.

## 데모

<!-- 폰에서 녹화해 GIF 삽입: ![demo](docs/demo.gif) -->

```text
> 최근 문자 요약하고 엄마한테 7시까지 간다고 답장해줘
Thinking… (2s)
새 문자 3건 — 엄마: "밥 먹었어?", 은행 OTP, 택배 6시 도착.
엄마(010-…)에게 초안: "7시까지 갈게 — 사랑해"
approval needed: sms_send {"number":"010-…","text":"7시까지 갈게 — 사랑해"}  [y/N] y
발송 완료.
```

## 빠른 시작

```bash
pkg install rust git
git clone https://github.com/yanghoeg/usix-termux && cd usix-termux
cargo build --release && ./target/release/usix-termux setup
```

`setup` 한 번으로 백엔드 설치·모델 다운로드·서버 기동·예시 스킬 심기까지 끝난다.
폰 도구엔 여전히 **Termux:API 앱**(F-Droid)이 필요하다 — [전제](#전제) 참고.

## 특징

- 🧠 **로컬 LLM**, 클라우드 없음 — llama.cpp(`llama-server`, OpenAI 호환) 또는 ollama
- 🔧 **함수 호출** — 모델이 `termux-api`로 실제 폰 도구를 호출
- 🔒 **승인 게이트** — 읽기 도구는 자동 실행, 변경 도구는 먼저 `y/N` 확인
- 📱 **폰 규모 TUI** — 인라인 입력 박스, `Thinking…` 타이머, 스트리밍 마크다운
- 🧩 **헥사고날 코어** — 도메인을 건드리지 않고 LLM 백엔드 교체·도구 추가

## 구조

```
main.rs            DI: 백엔드 선택 + 서브커맨드
bootstrap.rs       setup/doctor — 백엔드 설치·서버 기동·모델 준비
ports.rs           계약: Llm / Tool / ApprovalClass
adapters/
  llama.rs         llama-server OpenAI /v1/chat/completions (스트리밍, 기본)
  ollama.rs        로컬 ollama /api/chat (ureq 동기 HTTP, TLS 없음)
  termux.rs        termux-* 명령 실행 (timeout 가드)
domain/
  registry.rs      도구 등록 + tools 스키마
  agent.rs         function-calling 루프 + 승인 게이트
  skills.rs        마크다운 스킬 로더 (~/.usix/skills/*.md → 시스템 프롬프트)
tools/
  read.rs          sms_list, call_log, battery   (ReadOnly, 자동)
  comms.rs         sms_send, call                (Mutating, 승인 필요)
tui.rs             인라인 ratatui 입력 박스 + 일반 stdout 스트리밍 대화록
  editor.rs        UTF-8 라인 에디터 (멀티라인·히스토리·단어 편집)
  markdown.rs      마크다운 → 스타일 라인 (heading·코드블록·리스트·inline)
skills/
  sms_reply.md     예시 스킬 (최근 문자 요약 + 답장 작성)
```

## 전제

- **Termux** + Rust 툴체인: `pkg install rust`
- **백엔드** (택 1):
  - **llama.cpp** (기본): `pkg install llama-cpp llama-cpp-backend-opencl` + GGUF 모델
    하나. tool-calling 안정성을 위해 Qwen2.5-3B-Instruct Q5_K_M 권장.
    Adreno GPU는 반드시 `llama-gpu` 런처(네이티브 Qualcomm OpenCL, `-ngl 99`)로 서버를
    띄운다 — Vulkan/clvk 경로는 garbage 토큰이 나온다.
  - **ollama**: ollama 설치 후 `USIX_BACKEND=ollama`.
- **termux-api** (폰 도구용):
  - `pkg install termux-api` (CLI 패키지), **그리고**
  - 별도의 **Termux:API 앱**을 [F-Droid](https://f-droid.org/packages/com.termux.api/)에서
    설치해 한 번 실행하고 SMS/전화/배터리 권한을 부여.
  - 앱이 없으면 CLI가 깔려 있어도 `termux-*` 도구가 응답하지 않는다 —
    `usix-termux doctor`가 둘 다 점검한다.

> 루팅 안 된 안드로이드에서는 배터리·SMS에 대한 `sysfs`/`dumpsys` 우회가 없다.
> Termux:API 앱이 유일한 경로다.

## 설치

```bash
git clone <repo-url> usix-termux
cd usix-termux
cargo build --release
./target/release/usix-termux setup    # 백엔드 설치 + 서버 기동 (llama.cpp, GPU)
./target/release/usix-termux doctor   # 전제조건 점검
```

`setup`은 백엔드를 설치하고 서버를 백그라운드로 띄우며(런처 종료에도 생존), ollama면
모델까지 받는다. `doctor`는 백엔드별 체크리스트를 출력한다.

## 사용법

```bash
usix-termux            # 대화형 TUI
usix-termux setup      # 백엔드 설치 + 서버 기동 (+ollama면 모델 다운로드)
usix-termux doctor     # 전제조건 점검
usix-termux -c "..."   # 한 번 질문 (비대화형; 변경 도구는 자동 거부)
```

### 환경변수

| 변수           | 기본값                                             | 의미                                     |
| -------------- | -------------------------------------------------- | ---------------------------------------- |
| `USIX_BACKEND` | `llama`                                            | `llama` (llama.cpp) 또는 `ollama`        |
| `USIX_MODEL`   | `~/models/qwen2.5-3b-instruct-q5_k_m.gguf` (llama) | GGUF 경로(llama) 또는 모델 태그(ollama)  |
|                | `qwen2.5:1.5b-instruct-q5_K_M` (ollama)            |                                          |

```bash
# 더 작고 빠른 GGUF
USIX_MODEL=~/models/qwen2.5-1.5b-instruct-q5_k_m.gguf usix-termux
# ollama 백엔드
USIX_BACKEND=ollama USIX_MODEL=qwen2.5:1.5b usix-termux
```

### TUI 단축키

| 키                  | 동작                          |
| ------------------- | ----------------------------- |
| `Enter`             | 제출                          |
| `Ctrl+J`            | 개행 (멀티라인 입력)          |
| `↑` / `↓`           | 히스토리                      |
| `! <명령>`          | 로컬 셸 명령 실행             |
| `exit` / `quit`     | 세션 종료                     |
| `Esc` / `Ctrl+D`    | 세션 종료 (빈 입력일 때)      |
| `Ctrl+A` / `Ctrl+E` | 줄 처음 / 끝                  |
| `Ctrl+W` / `Ctrl+U` | 단어 삭제 / 줄 처음까지 삭제  |
| `Alt+←` / `Alt+→`   | 단어 단위 이동                |

### 예시

```
> 배터리 얼마나 남았어?
Thinking… (2s)
현재 62%, 충전 중입니다.

> 010-1234-5678로 "10분 늦어" 문자 보내줘
approval needed: sms_send {"number":"010-1234-5678","text":"10분 늦어"}  [y/N] y
010-1234-5678로 발송 완료.
```

## 도구

| 도구       | 등급     | 승인      |
| ---------- | -------- | --------- |
| `sms_list` | ReadOnly | 자동      |
| `call_log` | ReadOnly | 자동      |
| `battery`  | ReadOnly | 자동      |
| `sms_send` | Mutating | `y/N`     |
| `call`     | Mutating | `y/N`     |

## 스킬

스킬은 `~/.usix/skills/*.md`에 두는 **마크다운 절차**로, 모델에게 기존 도구를 엮는 법을
알려준다 — **재빌드가 필요 없다.** 각 파일은 작은 frontmatter(`name`, `description`)와
단계별 본문으로 되어 있고, 이 본문이 시스템 프롬프트에 덧붙는다. 소형 로컬 모델 컨텍스트
보호를 위해 **한 번에 최대 8개**만 활성화된다.

`setup`이 예시 하나 **`sms_reply`** — "최근 문자 요약하고 답장 도와줘" — 를 심는다.
`sms_list`로 읽어 요약하고, 원하면 문자 초안을 잡아 `sms_send`로 보낸다. `sms_send`는
발송 전 여전히 `y/N` 승인을 거친다. 폴더에 `.md`를 하나 더 떨구면 스킬이 늘어난다.

```
> 최근 문자 요약하고 엄마한테 7시까지 간다고 답장해줘
(sms_list 조회·요약) … 010-…에게 초안: "7시까지 갈게, 사랑해"
approval needed: sms_send {"number":"010-…","text":"7시까지 갈게, 사랑해"}  [y/N] y
발송 완료.
```

## 상태

v0 — 백엔드 2종(llama.cpp 기본 / ollama), 읽기 도구 3종 + 변경 도구 2종(승인 게이트),
스트리밍 마크다운 TUI. 라이선스 MIT.
