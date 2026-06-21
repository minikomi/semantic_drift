import json
import re
import sys
import urllib.error
import urllib.request
from datetime import date
from typing import Any, Dict


DATE_ONLY_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")


def usage() -> None:
    print(f"usage: {sys.argv[0]} <todos-url>", file=sys.stderr)
    raise SystemExit(1)


def exit_with_error(err: Any) -> None:
    print(str(err), file=sys.stderr)
    raise SystemExit(1)


def js_json_stringify(value: Any) -> str:
    if value is _UNDEFINED:
        return "undefined"
    return json.dumps(value, separators=(",", ":"))


def js_string(value: Any) -> str:
    if value is _UNDEFINED:
        return "undefined"
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


class _Undefined:
    pass


_UNDEFINED = _Undefined()


def parse_go_date_only_in_local_time(value: Any) -> date:
    text = js_string(value)
    match = DATE_ONLY_RE.match(text)
    if match is None:
        raise ValueError(
            f"parsing time {js_json_stringify(value)} as "
            f"{js_json_stringify('2006-01-02')}: cannot parse date"
        )

    year = int(match.group(1))
    month = int(match.group(2))
    day = int(match.group(3))

    try:
        if 0 <= year <= 99:
            raise ValueError()
        return date(year, month, day)
    except ValueError:
        raise ValueError(f"parsing time {js_json_stringify(value)}: day out of range")


def fetch_json(url: str) -> Any:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status = response.status
            if status < 200 or status >= 300:
                reason = response.reason or ""
                rendered = f"{status} {reason}" if reason else str(status)
                print(f"bad status: {rendered}", file=sys.stderr)
                raise SystemExit(1)
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        reason = err.reason or ""
        rendered = f"{err.code} {reason}" if reason else str(err.code)
        print(f"bad status: {rendered}", file=sys.stderr)
        raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        usage()

    try:
        todos = fetch_json(sys.argv[1])
    except SystemExit:
        raise
    except Exception as err:
        exit_with_error(err)

    today = date.today()
    by_user: Dict[Any, Dict[str, Any]] = {}

    for todo in todos:
        user_id = todo.get("userId", _UNDEFINED)
        if user_id not in by_user:
            by_user[user_id] = {"userId": user_id, "completed": 0, "missed": 0}

        summary = by_user[user_id]
        if todo.get("completed", _UNDEFINED):
            summary["completed"] += 1
        else:
            try:
                due = parse_go_date_only_in_local_time(todo.get("dueDate", _UNDEFINED))
            except Exception as err:
                exit_with_error(err)
            if due < today:
                summary["missed"] += 1

    rows = list(by_user.values())
    rows.sort(key=lambda item: (-item["completed"], -item["missed"], item["userId"]))

    sys.stdout.write("USER  COMPLETED  MISSED\n")
    for summary in rows:
        user = str(summary["userId"]).ljust(5)
        completed = str(summary["completed"]).ljust(10)
        sys.stdout.write(f"{user} {completed} {summary['missed']}\n")


if __name__ == "__main__":
    main()

