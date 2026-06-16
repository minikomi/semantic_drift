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

    @property
    def source_project_dir(self) -> Path:
        return project_dir(self.source_dir)

    @property
    def target_project_dir(self) -> Path:
        return project_dir(self.target_dir)


def render_rewrite_prompt(args: RewritePromptArgs) -> str:
    template_path = args.repo_root / "prompts" / "rewrite.md"
    template = Template(template_path.read_text())
    return template.substitute(
        REPO_ROOT=str(args.repo_root),
        SOURCE_LANGUAGE=args.source_language,
        TARGET_LANGUAGE=args.target_language,
        SOURCE_DIR=str(args.source_dir),
        SOURCE_PROJECT_DIR=str(args.source_project_dir),
        TARGET_DIR=str(args.target_dir),
        TARGET_PROJECT_DIR=str(args.target_project_dir),
    )


def project_dir(step_or_project_dir: Path) -> Path:
    if step_or_project_dir.name == "project":
        return step_or_project_dir
    return step_or_project_dir / "project"
