from __future__ import annotations

import sys
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any

import requests


@dataclass
class Summary:
    userId: int
    completed: int = 0
    missed: int = 0


def usage() -> None:
    print(f"usage: {sys.argv[0]} <todos-url>", file=sys.stderr)
    raise SystemExit(1)


def fail(message: Any) -> None:
    print(str(message), file=sys.stderr)
    raise SystemExit(1)


def parse_date_only_in_local_time(value: str, today: date) -> date:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        fail(f'parsing time "{value}" as "2006-01-02": cannot parse "{value}" as "2006"')

    if parsed.strftime("%Y-%m-%d") != value:
        fail(f'parsing time "{value}" as "2006-01-02": cannot parse "{value}" as "2006"')

    return parsed


def main() -> None:
    if len(sys.argv) != 2:
        usage()

    url = sys.argv[1]

    try:
        response = requests.get(url, timeout=10)
        if response.status_code < 200 or response.status_code >= 300:
            fail(f"bad status: {response.status_code} {response.reason}")
        todos = response.json()
    except SystemExit:
        raise
    except Exception as error:
        fail(error)

    today = date.today()
    by_user: dict[int, Summary] = {}

    for todo in todos:
        user_id = todo["userId"]
        summary = by_user.get(user_id)
        if summary is None:
            summary = Summary(userId=user_id)
            by_user[user_id] = summary

        if todo["completed"]:
            summary.completed += 1
        else:
            due = parse_date_only_in_local_time(todo["dueDate"], today)
            if due < today:
                summary.missed += 1

    rows = sorted(by_user.values(), key=lambda s: (-s.completed, -s.missed, s.userId))

    print("USER  COMPLETED  MISSED")
    for summary in rows:
        print(f"{str(summary.userId):<5} {str(summary.completed):<10} {summary.missed}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        fail(error)

