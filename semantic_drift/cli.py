from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from semantic_drift.conformance import TODOS_URL, check_project, log_step
from semantic_drift.prompt import RewritePromptArgs, render_rewrite_prompt


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "conform":
        return conform(args)
    if args.command == "prompt":
        return prompt(args)
    if args.command == "rewrite":
        return rewrite(args)

    parser.error("missing command")
    return 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="semantic-drift")
    subparsers = parser.add_subparsers(dest="command")

    conform_parser = subparsers.add_parser(
        "conform",
        help="run one generated project's run.sh and check stdout",
    )
    conform_parser.add_argument("project_dir", type=Path, help="generated project directory")
    conform_parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="repository root, defaults to current working directory",
    )
    conform_parser.add_argument(
        "--url",
        default=TODOS_URL,
        help=f"todos URL passed to the entrance, defaults to {TODOS_URL}",
    )

    prompt_parser = subparsers.add_parser("prompt", help="render reusable LLM prompts")
    prompt_subparsers = prompt_parser.add_subparsers(dest="prompt_command")
    add_rewrite_prompt_args(
        prompt_subparsers.add_parser(
            "rewrite",
            help="render the translation prompt for a source/target pair",
        )
    )

    rewrite_parser = subparsers.add_parser(
        "rewrite",
        help="run a fresh Codex exec instance with the rewrite prompt",
    )
    add_rewrite_prompt_args(rewrite_parser)
    rewrite_parser.add_argument(
        "--codex-bin",
        default="codex",
        help="Codex executable, defaults to codex",
    )
    rewrite_parser.add_argument(
        "--model",
        default=None,
        help="optional Codex model argument",
    )
    rewrite_parser.add_argument(
        "--sandbox",
        default="workspace-write",
        choices=["read-only", "workspace-write", "danger-full-access"],
        help="Codex sandbox mode, defaults to workspace-write",
    )

    return parser


def add_rewrite_prompt_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source-language", required=True)
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--target-dir", required=True, type=Path)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="repository root, defaults to current working directory",
    )


def conform(args: argparse.Namespace) -> int:
    repo_root = args.repo_root.resolve()
    project_dir = resolve_project_dir(repo_root, args.project_dir)

    log_step(f"repo root: {repo_root}")
    result = check_project(repo_root, project_dir, args.url)

    if result.command.returncode != 0:
        print("FAIL: generated project exited non-zero", file=sys.stderr)
        print(result.command.stderr, file=sys.stderr, end="")
        return 1

    if result.command.stdout != result.expected:
        print("FAIL: stdout did not match seed/expected.txt", file=sys.stderr)
        print("--- expected ---", file=sys.stderr)
        print(result.expected, file=sys.stderr, end="")
        print("--- actual ---", file=sys.stderr)
        print(result.command.stdout, file=sys.stderr, end="")
        if result.command.stderr:
            print("--- stderr ---", file=sys.stderr)
            print(result.command.stderr, file=sys.stderr, end="")
        return 1

    log_step("conformance passed")
    return 0


def prompt(args: argparse.Namespace) -> int:
    if args.prompt_command == "rewrite":
        print(render_rewrite_prompt(rewrite_prompt_args(args)), end="")
        return 0

    print("missing prompt command", file=sys.stderr)
    return 2


def rewrite(args: argparse.Namespace) -> int:
    codex_bin = shutil.which(args.codex_bin)
    if codex_bin is None:
        print(f"Codex executable not found: {args.codex_bin}", file=sys.stderr)
        return 127

    repo_root = args.repo_root.resolve()
    prompt_text = render_rewrite_prompt(rewrite_prompt_args(args))
    command = [
        codex_bin,
        "exec",
        "--cd",
        str(repo_root),
        "--sandbox",
        args.sandbox,
        "--skip-git-repo-check",
        "-",
    ]
    if args.model is not None:
        command[2:2] = ["--model", args.model]

    return subprocess.run(command, cwd=repo_root, input=prompt_text, text=True).returncode


def rewrite_prompt_args(args: argparse.Namespace) -> RewritePromptArgs:
    repo_root = args.repo_root.resolve()
    return RewritePromptArgs(
        repo_root=repo_root,
        source_language=args.source_language,
        target_language=args.target_language,
        source_dir=resolve_project_parent(repo_root, args.source_dir),
        target_dir=resolve_project_parent(repo_root, args.target_dir),
    )


def resolve_project_dir(repo_root: Path, project_dir: Path) -> Path:
    if project_dir.is_absolute():
        return project_dir
    return repo_root / project_dir


def resolve_project_parent(repo_root: Path, step_dir: Path) -> Path:
    if step_dir.is_absolute():
        return step_dir
    return repo_root / step_dir


if __name__ == "__main__":
    raise SystemExit(main())
