from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone

import requests


DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


@dataclass
class Summary:
    user_id: int
    completed: int = 0
    missed: int = 0


def usage() -> None:
    print(f"usage: {sys.argv[0]} <todos-url>", file=sys.stderr)
    raise SystemExit(1)


def parse_date_only(value: str) -> datetime:
    if not DATE_ONLY_RE.fullmatch(value):
        raise ValueError(
            f'parsing time "{value}" as "2006-01-02": cannot parse "{value}" as "2006"'
        )

    year_text, month_text, day_text = value.split("-")
    year = int(year_text)
    month = int(month_text)
    day = int(day_text)

    try:
        return datetime(year, month, day, tzinfo=timezone.utc)
    except ValueError as error:
        if "day is out of range" in str(error):
            raise ValueError(f'parsing time "{value}": day out of range') from None
        raise


def local_start_of_today() -> datetime:
    now = datetime.now().astimezone()
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def main() -> None:
    if len(sys.argv) != 2:
        usage()

    response = requests.get(sys.argv[1], timeout=10)
    if response.status_code < 200 or response.status_code >= 300:
        status_text = f" {response.reason}" if response.reason else ""
        print(f"bad status: {response.status_code}{status_text}", file=sys.stderr)
        raise SystemExit(1)

    todos = response.json()
    today = local_start_of_today()
    by_user: dict[int, Summary] = {}

    for todo in todos:
        user_id = todo["userId"]
        summary = by_user.get(user_id)
        if summary is None:
            summary = Summary(user_id=user_id)
            by_user[user_id] = summary

        if todo["completed"]:
            summary.completed += 1
        elif parse_date_only(todo["dueDate"]) < today:
            summary.missed += 1

    rows = sorted(by_user.values(), key=lambda item: (-item.completed, -item.missed, item.user_id))

    print("USER  COMPLETED  MISSED")
    for summary in rows:
        print(f"{str(summary.user_id):<5} {str(summary.completed):<10} {summary.missed}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)

