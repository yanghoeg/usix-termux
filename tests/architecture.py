"""Enforce the source boundary of the in-process hexagonal core."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CORE = sorted((ROOT / "src/domain").glob("*.rs")) + [
    ROOT / "src/ports.rs", ROOT / "src/tasks/runner.rs"
]
FORBIDDEN = re.compile(
    r"\bstd::(?:fs|env|process|thread|time|net|io)\b"
    r"|\bcrate::(?:adapters|tools|bootstrap|tui)\b"
    r"|\b(?:ureq|libc|crossterm|ratatui)::"
    r"|\b(?:println|eprintln|print|eprint)!"
)

failures = []
for path in CORE:
    production = path.read_text().split("#[cfg(test)]", 1)[0]
    for number, line in enumerate(production.splitlines(), 1):
        code = line.split("//", 1)[0]
        if match := FORBIDDEN.search(code):
            failures.append(f"{path.relative_to(ROOT)}:{number}: {match.group(0)}")
if failures:
    raise SystemExit("Core must use ports for I/O:\n" + "\n".join(failures))
print(f"Architecture boundary passed for {len(CORE)} core files.")
