"""Exercise installer boundaries without downloading packages or loading a model."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
STUB = '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["SMOKE_LOG"], "a") as out:
    out.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if os.environ.get("SMOKE_FAIL") == name:
    sys.exit(7)
if name == "git" and sys.argv[1] == "clone":
    pathlib.Path(sys.argv[-1], ".git").mkdir(parents=True)
'''


class InstallSmoke(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="usix install ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        self.env = {"PATH": str(self.bin), "HOME": str(self.root / "home"),
                    "SMOKE_LOG": str(self.log)}
        for cmd in ["cargo", "rustc", "cc", "git", "cmake", "make", "c++", "pkg"]:
            self.stub(cmd, f"#!{sys.executable}\n{STUB}")
        self.stub("uname", '#!/bin/sh\nprintf "%s\\n" "${SMOKE_OS:-Linux}"\n')
        for cmd in ["dirname", "mkdir"]:
            (self.bin / cmd).symlink_to(shutil.which(cmd))

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_script(self, script="install.sh", *args):
        return subprocess.run(["/bin/sh", str(REPO / script), *map(str, args)],
                              env=self.env, text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_linux_installs_the_locked_native_package(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [["cargo", "install", "--locked", "--path", str(REPO),
                                           "--root", str(self.root / "home/.local")]])

    def test_termux_and_custom_paths_preserve_spaces(self):
        self.env.update(TERMUX_VERSION="test", PREFIX=str(self.root / "termux prefix"))
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.commands()[-1][-1], self.env["PREFIX"])
        target = self.root / "custom prefix"
        self.assertEqual(self.run_script("install.sh", "--prefix", target).returncode, 0)
        self.assertEqual(self.commands()[-1][-1], str(target))

    def test_unsupported_host_and_bad_options_do_not_build(self):
        self.env["SMOKE_OS"] = "Darwin"
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertNotEqual(self.run_script("install.sh", "--prefix").returncode, 0)
        self.assertNotEqual(self.run_script("install.sh", "--unknown").returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_missing_toolchain_and_failed_build_do_not_report_success(self):
        (self.bin / "rustc").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing rustc", result.stderr)
        self.stub("rustc", f"#!{sys.executable}\n{STUB}")
        self.env["SMOKE_FAIL"] = "cargo"
        result = self.run_script()
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("Installed:", result.stdout)

    def test_linux_backend_builds_pinned_source_in_user_directory(self):
        root = self.root / "backend cache"
        result = self.run_script("scripts/backends/linux.sh", "llama", root)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual([c[0] for c in commands], ["git", "cmake", "cmake"])
        self.assertIn("v0.5.0", commands[0])
        self.assertEqual(commands[0][-1], str(root / "llama.cpp-v0.5.0"))
        self.assertIn("-DBUILD_SHARED_LIBS=OFF", commands[1])
        self.assertIn("llama-server", commands[2])
        self.assertEqual(commands[2][-2:], ["--parallel", "2"])
        self.assertEqual(self.run_script("scripts/backends/linux.sh", "llama", root).returncode, 0)
        self.assertEqual(sum(c[0] == "git" for c in self.commands()), 1)

    def test_backend_failures_propagate(self):
        self.env["SMOKE_FAIL"] = "cmake"
        self.assertEqual(self.run_script("scripts/backends/linux.sh", "llama", self.root / "cache").returncode, 7)
        self.env["SMOKE_FAIL"] = "pkg"
        self.assertEqual(self.run_script("scripts/backends/termux.sh", "llama").returncode, 7)

    def test_termux_uses_native_packages_without_requiring_gpu(self):
        for backend in ["llama", "ollama"]:
            self.assertEqual(self.run_script("scripts/backends/termux.sh", backend).returncode, 0)
        self.assertEqual(self.commands(), [["pkg", "install", "-y", "llama-cpp"],
                                           ["pkg", "install", "-y", "ollama"]])


if __name__ == "__main__":
    unittest.main()
