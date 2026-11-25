#!/usr/bin/env python3
"""Protocol-level self test: the published CalDAV CLI against the mock server.

Runs the component's own bundled CLI (``Components/CalDAV.4dbase/Resources/bin``)
against ``scripts/mock_caldav.py`` and checks every operation the demo uses.
This is the fastest way to prove the mock speaks correct CalDAV; the 4D host
check (``scripts/smoke.sh``) then proves the component facade on top of it.

    python3 scripts/selftest_mock.py            # auto-locate the CLI
    python3 scripts/selftest_mock.py --cli PATH # explicit executable
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PASS, FAIL = [], []


def cli_default() -> Path | None:
    base = ROOT / "Components" / "CalDAV.4dbase" / "Resources" / "bin"
    candidates = []
    if sys.platform == "darwin":
        candidates.append(base / "macOS" / "caldav")
    elif sys.platform == "win32":
        candidates.append(base / "Windows" / "caldav.exe")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class MockServer:
    def __init__(self, log_path: Path) -> None:
        self.port = free_port()
        self.log_path = log_path
        self.proc: subprocess.Popen | None = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/dav/"

    def __enter__(self) -> "MockServer":
        self.proc = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "scripts" / "mock_caldav.py"),
                "--port",
                str(self.port),
                "--log",
                str(self.log_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return self
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("mock server did not start")

    def __exit__(self, *exc) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Cli:
    def __init__(self, executable: Path) -> None:
        self.executable = executable

    def call(self, payload: dict) -> tuple[int, dict | None, str]:
        raw = json.dumps(payload).encode()
        proc = subprocess.run(
            [str(self.executable), "request"],
            input=raw,
            capture_output=True,
            timeout=60,
        )
        stream = proc.stdout if proc.returncode == 0 else proc.stderr
        try:
            decoded = json.loads(stream.decode() or "{}")
        except json.JSONDecodeError:
            decoded = None
        return proc.returncode, decoded, stream.decode(errors="replace")

    def version(self) -> tuple[int, dict | None, str]:
        # `version` is a CLI flag, not a request operation: the 4D class runs
        # `caldav --version` and does not go through the JSON request envelope.
        proc = subprocess.run([str(self.executable), "--version"], capture_output=True, timeout=30)
        try:
            decoded = json.loads(proc.stdout.decode() or "{}")
        except json.JSONDecodeError:
            decoded = None
        return proc.returncode, decoded, proc.stdout.decode(errors="replace")


def check(name: str, ok: bool, detail: str = "") -> None:
    (PASS if ok else FAIL).append(name)
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


def utc(offset_days: int, hour: int = 0) -> str:
    day = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=offset_days)
    return day.replace(hour=hour, minute=0, second=0, microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def event_payload(summary: str, start: str) -> dict:
    return {
        "summary": summary,
        "start": start,
        "end": start,  # replaced below by the caller when a duration is wanted
        "allDay": False,
        "timezone": "UTC",
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cli", default=os.environ.get("CALDAV_CLI"))
    parser.add_argument("--keep-mock-log", action="store_true")
    args = parser.parse_args(argv)

    executable = Path(args.cli) if args.cli else cli_default()
    if not executable or not executable.is_file():
        print("no CalDAV CLI found; stage Components/CalDAV.4dbase first (scripts/fetch_component.sh)")
        return 2

    log_path = ROOT / ".local" / "selftest-mock.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if log_path.exists():
        log_path.unlink()

    cli = Cli(executable)
    with MockServer(log_path) as server:
        print(f"mock {server.url}  cli {executable}")
        base = {
            "protocol": 1,
            "url": server.url,
            "username": "demo",
            "password": "demo",
            "allowInsecureLoopback": True,
        }

        # 1. version
        code, body, raw = cli.version()
        check("version", code == 0 and body and body["version"] == "0.1.2", raw)

        # 2. discover
        code, body, raw = cli.call({"operation": "discover", **base})
        data = (body or {}).get("data") or {}
        calendars = {item["name"]: item for item in data.get("calendars") or []}
        check(
            "discover finds three collections",
            code == 0 and set(calendars) == {"Work", "Personal", "Reminders"},
            raw,
        )
        check(
            "discover reports supported components",
            calendars.get("Reminders", {}).get("components") == ["VTODO"],
            raw,
        )

        # 3. query: the daily series starts outside the window but must be returned
        code, body, raw = cli.call(
            {
                "operation": "query",
                **base,
                "url": calendars["Work"]["url"],
                "start": utc(0),
                "end": utc(7),
            }
        )
        resources = (body or {}).get("data", {}).get("resources") or []
        by_name = {item["url"].rsplit("/", 1)[-1]: item for item in resources}
        check("query returns the work resources", code == 0 and set(by_name) == {"standup.ics", "review.ics"}, raw)
        standup = by_name.get("standup.ics") or {}
        check(
            "query keeps unexpanded series plus its exception",
            standup.get("eventCount") == 2
            and any(event["rrule"] for event in standup.get("events", []))
            and any(event["recurrenceId"] for event in standup.get("events", [])),
            raw,
        )
        check(
            "query reports the declared timezone",
            any(event["timezone"] == "Asia/Tokyo" for event in standup.get("events", [])),
            raw,
        )

        # 4. query on a VTODO-only collection returns no resources
        code, body, raw = cli.call(
            {
                "operation": "query",
                **base,
                "url": calendars["Reminders"]["url"],
                "start": utc(0),
                "end": utc(7),
            }
        )
        check(
            "query on a task collection is empty, not an error",
            code == 0 and (body["data"]["resources"] == []),
            raw,
        )

        # 5. get: raw bytes preserved for properties the parser does not model
        code, body, raw = cli.call({"operation": "get", **base, "url": by_name["review.ics"]["url"]})
        review = (body or {}).get("data") or {}
        check(
            "get returns the whole resource",
            code == 0
            and review.get("eventCount") == 1
            and "X-DEMO-NOTE:opaque extension property" in review.get("icalendar", "")
            and "BEGIN:VALARM" in review.get("icalendar", ""),
            raw,
        )
        review_etag = review.get("etag", "")
        check("get returns a strong etag", review_etag.startswith('"') and review_etag.endswith('"'), review_etag)

        # 6. build + inspect (offline; no server)
        target = by_name["review.ics"]["url"]
        code, body, raw = cli.call(
            {
                "protocol": 1,
                "operation": "build",
                "event": {
                    "summary": "Demo created event",
                    "start": utc(3, 9),
                    "end": utc(3, 10),
                    "allDay": False,
                    "timezone": "UTC",
                    "location": "Loopback",
                    "description": "Written by scripts/selftest_mock.py",
                },
            }
        )
        built = (body or {}).get("data") or {}
        check(
            "build produces a single-event calendar",
            code == 0 and built.get("eventCount") == 1 and "BEGIN:VCALENDAR" in built.get("icalendar", ""),
            raw,
        )
        code, body, raw = cli.call({"protocol": 1, "operation": "inspect", "icalendar": built.get("icalendar", "")})
        check(
            "inspect round-trips its own build",
            code == 0 and body["data"]["events"][0]["summary"] == "Demo created event",
            raw,
        )

        # 7. create
        created_url = calendars["Work"]["url"] + "demo-created.ics"
        code, body, raw = cli.call(
            {"operation": "create", **base, "url": created_url, "icalendar": built["icalendar"]}
        )
        created = (body or {}).get("data") or {}
        check(
            "create returns the assigned etag",
            code == 0 and created.get("etag", "").startswith('"'),
            raw,
        )

        # 8. create twice with If-None-Match:* -> conflict
        code, body, raw = cli.call(
            {"operation": "create", **base, "url": created_url, "icalendar": built["icalendar"]}
        )
        check(
            "create on an existing resource is a conflict",
            code == 1 and (body or {}).get("error", {}).get("code") == "conflict",
            raw,
        )

        # 9. update with the current etag
        updated_calendar = built["icalendar"].replace("Demo created event", "Demo updated event")
        code, body, raw = cli.call(
            {
                "operation": "update",
                **base,
                "url": created_url,
                "icalendar": updated_calendar,
                "etag": created["etag"],
            }
        )
        updated = (body or {}).get("data") or {}
        check(
            "update replaces the resource and rotates the etag",
            code == 0 and updated.get("etag") not in ("", created["etag"]),
            raw,
        )

        # 10. update with a stale etag -> 412 conflict, the showcase for chokepoint demos
        code, body, raw = cli.call(
            {
                "operation": "update",
                **base,
                "url": created_url,
                "icalendar": updated_calendar,
                "etag": created["etag"],
            }
        )
        error = (body or {}).get("error") or {}
        check(
            "stale etag is rejected as conflict/412",
            code == 1 and error.get("code") == "conflict" and error.get("status") == 412,
            raw,
        )

        # 11. delete with the fresh etag
        code, body, raw = cli.call(
            {"operation": "delete", **base, "url": created_url, "etag": updated["etag"]}
        )
        check("delete succeeds with If-Match", code == 0 and (body or {}).get("data", {}).get("deleted") is True, raw)

        # 12. delete again -> not_found
        code, body, raw = cli.call(
            {"operation": "delete", **base, "url": created_url, "etag": updated["etag"]}
        )
        check(
            "delete twice is not_found",
            code == 1 and (body or {}).get("error", {}).get("code") == "not_found",
            raw,
        )

        # 13. http without the loopback opt-in is refused before any I/O
        plain = dict(base)
        plain.pop("allowInsecureLoopback")
        code, body, raw = cli.call({"operation": "discover", **plain})
        check(
            "plain http is refused without allowInsecureLoopback",
            code == 2 and (body or {}).get("error", {}).get("code") == "invalid_request",
            raw,
        )

    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("failed: " + ", ".join(FAIL))
        print(f"mock request log: {log_path}")
        return 1
    if not args.keep_mock_log and log_path.exists():
        log_path.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
