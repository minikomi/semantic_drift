from pathlib import Path

import pytest

from semantic_drift.conformance import (
    check_project,
    fake_api,
    log_step,
    request_conformance,
)


ROOT = Path(__file__).resolve().parents[1]


def test_first_go_iteration_matches_expected_output():
    project_dir = ROOT / "runs/latest/01-go/project"

    try:
        result = check_project(ROOT, project_dir)
    except RuntimeError as exc:
        pytest.fail(str(exc))

    log_step("checking oracle result")
    assert result.passed, result.failure or result.command.stderr.decode(errors="replace")
    log_step("conformance passed")


def test_oracle_rejects_incorrect_submitted_output():
    with fake_api(ROOT):
        result = request_conformance(b"wrong output\n")

    assert not result.passed
    assert result.failure == "submitted output did not match expected output"
