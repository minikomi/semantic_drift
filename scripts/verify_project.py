from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import urllib.request


SERVICE_ROOT = "http://127.0.0.1:8899"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <project-directory>", file=sys.stderr)
        return 2

    project_dir = Path(sys.argv[1])
    completed = subprocess.run(
        [str(project_dir / "run.sh"), f"{SERVICE_ROOT}/todos"],
        cwd=project_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
    )
    if completed.returncode != 0:
        sys.stderr.buffer.write(completed.stderr)
        return completed.returncode

    request = urllib.request.Request(
        f"{SERVICE_ROOT}/conform",
        data=completed.stdout,
        headers={"Content-Type": "text/plain"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        result = json.load(response)

    print(json.dumps(result))
    return 0 if result.get("passed") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
