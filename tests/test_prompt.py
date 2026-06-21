from pathlib import Path

from semantic_drift.cli import sanitized_agent_environment
from semantic_drift.prompt import RewritePromptArgs, render_rewrite_prompt


ROOT = Path(__file__).resolve().parents[1]


def test_rendered_prompt_does_not_expose_experiment_labels_or_repo_path():
    rendered = render_rewrite_prompt(
        RewritePromptArgs(
            repo_root=ROOT,
            source_language="Go",
            target_language="TypeScript",
            source_dir=Path("/tmp/work.123/input"),
            target_dir=Path("/tmp/work.123/output"),
            check_command="python3 /tmp/work.123/verify.py",
            prompt_variant="neutral",
        )
    )

    lowered = rendered.lower()
    assert "semantic drift" not in lowered
    assert "semantic_drift" not in lowered
    assert "neutral title" not in lowered
    assert "neutral-title" not in lowered
    assert str(ROOT) not in rendered


def test_original_prompt_is_retained_as_a_distinct_condition():
    rendered = render_rewrite_prompt(
        RewritePromptArgs(
            repo_root=ROOT,
            source_language="Go",
            target_language="TypeScript",
            source_dir=Path("/tmp/work.123/input"),
            target_dir=Path("/tmp/work.123/output"),
            check_command="python3 /tmp/work.123/verify.py",
            prompt_variant="original",
        )
    )

    assert rendered.startswith("# Semantic Drift Rewrite Task")
    assert "Use idiomatic, mainstream ecosystem libraries" in rendered
    assert str(ROOT) in rendered


def test_child_environment_does_not_expose_repo(monkeypatch):
    monkeypatch.setenv("PATH", f"{ROOT}/.venv/bin:/usr/bin:/bin")
    monkeypatch.setenv("VIRTUAL_ENV", str(ROOT / ".venv"))
    monkeypatch.setenv("SEMANTIC_DRIFT_ADDR", "127.0.0.1:8899")

    environment = sanitized_agent_environment(ROOT, Path("/tmp/work.123"))

    assert environment["PATH"] == "/usr/bin:/bin"
    assert environment["PWD"] == "/tmp/work.123"
    assert "VIRTUAL_ENV" not in environment
    assert "SEMANTIC_DRIFT_ADDR" not in environment
    assert all(str(ROOT) not in value for value in environment.values())
