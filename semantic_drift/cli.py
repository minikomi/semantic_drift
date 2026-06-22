from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from semantic_drift.conformance import (
    check_project,
    check_project_with_running_api,
    fake_api,
    log_step,
)
from semantic_drift.prompt import RewritePromptArgs, render_rewrite_prompt


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "conform":
        return conform(args, api_already_running=False)
    if args.command == "submit":
        return conform(args, api_already_running=True)
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
    submit_parser = subparsers.add_parser(
        "submit",
        help="run one generated project's run.sh and submit stdout to the running oracle",
    )
    submit_parser.add_argument("project_dir", type=Path, help="generated project directory")
    submit_parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="repository root, defaults to current working directory",
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
        help="Codex sandbox mode used only with --use-sandbox",
    )
    rewrite_parser.add_argument(
        "--use-sandbox",
        action="store_true",
        help=(
            "run child Codex inside a sandbox; by default rewrite bypasses "
            "sandboxing so conformance can use localhost and normal caches"
        ),
    )

    return parser


def add_rewrite_prompt_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source-language", required=True)
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--target-dir", required=True, type=Path)
    parser.add_argument(
        "--check-command",
        default="python3 scripts/verify_project.py",
        help="verification command inserted into the translation prompt",
    )
    parser.add_argument(
        "--prompt-variant",
        choices=["original", "neutral", "neutral-guided"],
        default="original",
        help="prompt condition to render or run",
    )
    parser.add_argument(
        "--agent-workspace",
        type=Path,
        default=None,
        help="working directory exposed to the child agent",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="repository root, defaults to current working directory",
    )


def conform(args: argparse.Namespace, *, api_already_running: bool) -> int:
    repo_root = args.repo_root.resolve()
    project_dir = resolve_project_dir(repo_root, args.project_dir)

    log_step(f"repo root: {repo_root}")
    if api_already_running:
        result = check_project_with_running_api(repo_root, project_dir)
    else:
        result = check_project(repo_root, project_dir)

    if result.command.returncode != 0:
        print(f"FAIL: {result.failure}", file=sys.stderr)
        print(result.command.stderr.decode(errors="replace"), file=sys.stderr, end="")
        return 1

    if not result.passed:
        print(f"FAIL: {result.failure}", file=sys.stderr)
        print("--- stdout ---", file=sys.stderr)
        print(result.command.stdout.decode(errors="replace"), file=sys.stderr, end="")
        if result.command.stderr:
            print("--- stderr ---", file=sys.stderr)
            print(result.command.stderr.decode(errors="replace"), file=sys.stderr, end="")
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
    agent_workspace = (
        args.agent_workspace.absolute() if args.agent_workspace is not None else repo_root
    )
    prompt_text = render_rewrite_prompt(rewrite_prompt_args(args))
    command = [
        codex_bin,
        "exec",
        "--cd",
        str(agent_workspace),
        "--skip-git-repo-check",
        "-",
    ]
    if args.use_sandbox:
        command[2:2] = ["--sandbox", args.sandbox]
    else:
        command[2:2] = ["--dangerously-bypass-approvals-and-sandbox"]
    if args.model is not None:
        command[2:2] = ["--model", args.model]

    child_env = sanitized_agent_environment(repo_root, agent_workspace)
    with fake_api(repo_root):
        return subprocess.run(
            command,
            cwd=agent_workspace,
            env=child_env,
            input=prompt_text,
            text=True,
        ).returncode


def sanitized_agent_environment(repo_root: Path, agent_workspace: Path) -> dict[str, str]:
    repo_text = str(repo_root)
    environment: dict[str, str] = {}

    for key, value in os.environ.items():
        label = key.lower().replace("_", "-")
        if "semantic-drift" in label or repo_text in value:
            continue
        environment[key] = value

    path_parts = [
        part
        for part in os.environ.get("PATH", "").split(os.pathsep)
        if part and repo_text not in part
    ]
    environment["PATH"] = os.pathsep.join(path_parts)
    environment["PWD"] = str(agent_workspace)
    environment.pop("OLDPWD", None)
    environment.pop("VIRTUAL_ENV", None)
    environment.pop("PYTHONPATH", None)
    return environment


def rewrite_prompt_args(args: argparse.Namespace) -> RewritePromptArgs:
    repo_root = args.repo_root.resolve()
    return RewritePromptArgs(
        repo_root=repo_root,
        source_language=args.source_language,
        target_language=args.target_language,
        source_dir=resolve_project_parent(repo_root, args.source_dir),
        target_dir=resolve_project_parent(repo_root, args.target_dir),
        check_command=args.check_command,
        prompt_variant=args.prompt_variant,
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
