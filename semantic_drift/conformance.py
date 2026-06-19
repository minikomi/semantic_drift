from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import time
import urllib.request


API_ADDR = "127.0.0.1:8899"
API_ROOT = f"http://{API_ADDR}"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class ConformanceResult:
    command: CommandResult
    passed: bool
    failure: str


def log_step(message: str) -> None:
    print(f"[semantic-drift] {message}", flush=True)


@contextmanager
def fake_api(repo_root: Path, project_dir: Path):
    log_step(f"starting fake API on http://{API_ADDR}")
    process = subprocess.Popen(
        [
            "go",
            "run",
            "./fake_api",
            "--repo-root",
            str(repo_root),
            "--project",
            str(project_dir),
        ],
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
                payload = json.load(response)
                if response.status == 200 and payload.get("conformanceEnabled") is True:
                    return
        except OSError as exc:
            last_error = exc
            time.sleep(0.1)

    detail = f": {last_error}" if last_error else ""
    raise RuntimeError(f"fake API did not become healthy{detail}")


def request_conformance() -> ConformanceResult:
    log_step("requesting POST /conform")
    request = urllib.request.Request(f"{API_ROOT}/conform", method="POST")
    with urllib.request.urlopen(request, timeout=25) as response:
        payload = json.load(response)

    command = CommandResult(
        returncode=payload["exitCode"],
        stdout=payload.get("stdout", ""),
        stderr=payload.get("stderr", ""),
    )
    log_step(f"project exited with code {command.returncode}")
    return ConformanceResult(
        command=command,
        passed=payload["passed"],
        failure=payload.get("failure", ""),
    )


def check_project(
    repo_root: Path,
    project_dir: Path,
) -> ConformanceResult:
    with fake_api(repo_root, project_dir):
        return request_conformance()
