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
    stdout: bytes
    stderr: bytes


@dataclass(frozen=True)
class ConformanceResult:
    command: CommandResult
    passed: bool
    failure: str


@dataclass(frozen=True)
class OracleResult:
    passed: bool
    failure: str


def log_step(message: str) -> None:
    print(f"[semantic-drift] {message}", flush=True)


@contextmanager
def fake_api(repo_root: Path):
    log_step(f"starting fake API on http://{API_ADDR}")
    process = subprocess.Popen(
        [
            "go",
            "run",
            "./fake_api",
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


def request_conformance(stdout: bytes) -> OracleResult:
    log_step("submitting stdout to POST /conform")
    request = urllib.request.Request(
        f"{API_ROOT}/conform",
        data=stdout,
        headers={"Content-Type": "text/plain"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        payload = json.load(response)

    return OracleResult(
        passed=payload["passed"],
        failure=payload.get("failure", ""),
    )


def check_project(
    repo_root: Path,
    project_dir: Path,
) -> ConformanceResult:
    with fake_api(repo_root):
        return check_project_with_running_api(repo_root, project_dir)


def check_project_with_running_api(
    repo_root: Path,
    project_dir: Path,
) -> ConformanceResult:
    run_script = project_dir / "run.sh"
    if not run_script.is_file():
        raise RuntimeError(f"project is missing run script: {run_script}")

    log_step(f"running project: {project_dir}")
    try:
        completed = subprocess.run(
            [str(run_script), f"{API_ROOT}/todos"],
            cwd=repo_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )
    except subprocess.TimeoutExpired as exc:
        command = CommandResult(
            returncode=-1,
            stdout=exc.stdout or b"",
            stderr=exc.stderr or b"",
        )
        return ConformanceResult(command, False, "project timed out")

    command = CommandResult(
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )
    log_step(f"project exited with code {command.returncode}")
    if command.returncode != 0:
        return ConformanceResult(command, False, "project exited non-zero")

    oracle = request_conformance(command.stdout)
    return ConformanceResult(command, oracle.passed, oracle.failure)
