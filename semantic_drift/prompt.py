from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from string import Template


@dataclass(frozen=True)
class RewritePromptArgs:
    repo_root: Path
    source_language: str
    target_language: str
    source_dir: Path
    target_dir: Path
    check_command: str
    prompt_variant: str = "original"

    @property
    def source_project_dir(self) -> Path:
        return project_dir(self.source_dir)

    @property
    def target_project_dir(self) -> Path:
        return project_dir(self.target_dir)


def render_rewrite_prompt(args: RewritePromptArgs) -> str:
    prompt_files = {
        "original": "rewrite.md",
        "neutral": "rewrite-neutral.md",
        "neutral-guided": "rewrite-neutral-guided.md",
    }
    template_path = args.repo_root / "prompts" / prompt_files[args.prompt_variant]
    template = Template(template_path.read_text())
    return template.substitute(
        SOURCE_LANGUAGE=args.source_language,
        TARGET_LANGUAGE=args.target_language,
        SOURCE_DIR=str(args.source_dir),
        SOURCE_PROJECT_DIR=str(args.source_project_dir),
        TARGET_DIR=str(args.target_dir),
        TARGET_PROJECT_DIR=str(args.target_project_dir),
        CHECK_COMMAND=args.check_command,
        REPO_ROOT=str(args.repo_root),
    )


def project_dir(step_or_project_dir: Path) -> Path:
    if step_or_project_dir.name == "project":
        return step_or_project_dir
    return step_or_project_dir / "project"
