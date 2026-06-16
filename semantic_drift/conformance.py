from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request


REFERENCE_DATETIME = "2026-06-16 12:00:00"
API_ADDR = "127.0.0.1:8899"
API_ROOT = f"http://{API_ADDR}"
TODOS_URL = f"{API_ROOT}/todos"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class ConformanceResult:
    command: CommandResult
    expected: str

    @property
    def passed(self) -> bool:
        return self.command.returncode == 0 and self.command.stdout == self.expected


def log_step(message: str) -> None:
    print(f"[semantic-drift] {message}", flush=True)


def require_faketime() -> str:
    log_step("checking for faketime")
    faketime = shutil.which("faketime")
    if faketime is None:
        raise RuntimeError(
            "faketime is required for deterministic conformance tests. "
            "Install libfaketime/faketime and rerun pytest."
        )
    log_step(f"using faketime at {faketime}")
    return faketime


@contextmanager
def fake_api(repo_root: Path):
    log_step(f"starting fake API on http://{API_ADDR}")
    process = subprocess.Popen(
        ["go", "run", "./fake_api"],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_health()
        log_step("fake API is healthy")
        yield
    finally:
        log_step("stopping fake API")
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            log_step("fake API did not stop cleanly; killing it")
            process.kill()
            process.wait(timeout=5)
        log_step("fake API stopped")


def wait_for_health(timeout: float = 10.0) -> None:
    log_step("waiting for /health")
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None

    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{API_ROOT}/health", timeout=0.25) as response:
                if response.status == 200:
                    return
        except OSError as exc:
            last_error = exc
            time.sleep(0.1)

    detail = f": {last_error}" if last_error else ""
    raise RuntimeError(f"fake API did not become healthy{detail}")


def run_with_frozen_time(
    repo_root: Path,
    project_dir: Path,
    url: str = TODOS_URL,
) -> CommandResult:
    faketime = require_faketime()
    run_script = project_dir / "run.sh"
    if not run_script.is_file():
        raise RuntimeError(f"project is missing run script: {run_script}")

    log_step(f"running project under frozen time {REFERENCE_DATETIME}")
    log_step(f"project: {project_dir}")
    log_step(f"script: {run_script}")
    log_step(f"url: {url}")
    completed = subprocess.run(
        [
            faketime,
            REFERENCE_DATETIME,
            str(run_script),
            url,
        ],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
    )
    log_step(f"project exited with code {completed.returncode}")
    return CommandResult(
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )


def check_project(
    repo_root: Path,
    project_dir: Path,
    url: str = TODOS_URL,
) -> ConformanceResult:
    log_step("loading expected output")
    expected = (repo_root / "seed/expected.txt").read_text()

    with fake_api(repo_root):
        command = run_with_frozen_time(repo_root, project_dir, url)

    return ConformanceResult(command=command, expected=expected)
