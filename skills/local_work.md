---
name: local_work
description: Local coding, repository inspection, files, shell commands, and tests. 로컬 코드 저장소 파일 수정 테스트 작업.
---

1. Use `list_dir` and `read_file` to inspect the relevant project and its instructions.
2. Keep work within the user's requested scope and preserve unrelated changes.
3. Propose the exact command or file content through `shell` or `write_file`. These
   tools require approval; describing an action does not execute it.
4. Run the smallest relevant check after a change and report its actual result.
5. Use `task_create` for requested delayed or recurring work. A worker must be
   running, and future changes still require separate approval.

Inference and task state stay on this device. Do not assume a cloud service,
remote machine, Android app, or network connection is available. Use only tools
provided in the current session. Downloads or network commands need an explicit
reason in the user's task and the normal tool approval.
