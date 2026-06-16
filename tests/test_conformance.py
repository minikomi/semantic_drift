from pathlib import Path

import pytest

from semantic_drift.conformance import (
    check_project,
    log_step,
)


ROOT = Path(__file__).resolve().parents[1]


def test_first_go_iteration_matches_expected_output():
    project_dir = ROOT / "runs/latest/01-go/project"

    try:
        result = check_project(ROOT, project_dir)
    except RuntimeError as exc:
        pytest.fail(str(exc))

    log_step("checking exit code")
    assert result.command.returncode == 0, result.command.stderr
    log_step("comparing stdout with seed/expected.txt")
    assert result.command.stdout == result.expected
    log_step("conformance passed")
