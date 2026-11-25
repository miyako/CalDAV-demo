#!/usr/bin/env python3
"""Loopback CalDAV server for the CalDAV-demo 4D project.

The demo calls the ``miyako/CalDAV`` component, whose bundled Go CLI talks
WebDAV/CalDAV over HTTPS.  HTTPS needs credentials and a real account, so the
demo ships this mock instead: a plain-HTTP server on 127.0.0.1 only, which the
CLI accepts when the request carries ``allowInsecureLoopback: true``.

Supported surface (exactly what the CLI uses, nothing more):

    PROPFIND  /dav/                 Depth 0  current-user-principal
    PROPFIND  /principals/demo/     Depth 0  calendar-home-set
    PROPFIND  /dav/home/            Depth 1  resourcetype/displayname/... per child
    REPORT    /dav/home/<cal>/      Depth 1  calendar-query + time-range
    GET       /dav/home/<cal>/x.ics          body + ETag
    PUT       /dav/home/<cal>/x.ics          If-None-Match / If-Match
    DELETE    /dav/home/<cal>/x.ics          If-Match

State is in memory and is regenerated relative to "today" on every start, so
the demo stays evergreen: the daily standup series always covers the default
query window and the all-day birthday is always "tomorrow".

Standard library only.  Start it with:

    python3 scripts/mock_caldav.py --port 8787 --log .local/mock.log
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.etree import ElementTree as ET
from zoneinfo import ZoneInfo

DAV = "DAV:"
CALDAV = "urn:ietf:params:xml:ns:caldav"
ET.register_namespace("d", DAV)
ET.register_namespace("c", CALDAV)

# Paths used by the CLI.  The home collection is discovered through
# calendar-home-set, never guessed, but the mock keeps them stable.
START_PATH = "/dav/"
PRINCIPAL_PATH = "/principals/demo/"
HOME_PATH = "/dav/home/"
TOKYO = ZoneInfo("Asia/Tokyo")

VTIMEZONE_TOKYO = "\r\n".join(
    [
        "BEGIN:VTIMEZONE",
        "TZID:Asia/Tokyo",
        "X-LIC-LOCATION:Asia/Tokyo",
        "BEGIN:STANDARD",
        "DTSTART:19511001T000000",
        "TZOFFSETFROM:+0900",
        "TZOFFSETTO:+0900",
        "TZNAME:JST",
        "END:STANDARD",
        "END:VTIMEZONE",
    ]
)


def ical(*lines: str) -> str:
    """Return a CRLF-terminated iCalendar object with the shared envelope."""
    body = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//miyako//CalDAV-demo mock//EN",
        "CALSCALE:GREGORIAN",
    ]
    body.extend(lines)
    body.append("END:VCALENDAR")
    return "\r\n".join(body) + "\r\n"


def utc(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def stamp() -> str:
    return utc(dt.datetime.now(dt.timezone.utc))


class Resource:
    """One iCalendar object in a collection, with a stable-looking ETag."""

    def __init__(self, data: str) -> None:
        self.data = data
        self.etag = self._etag(data)

    @staticmethod
    def _etag(data: str) -> str:
        # A strong validator: quoted, no spaces, changes with the bytes.
        return '"' + hashlib.sha256(data.encode("utf-8")).hexdigest()[:32] + '"'

    def replace(self, data: str) -> None:
        self.data = data
        self.etag = self._etag(data)


class Collection:
    def __init__(self, name: str, description: str, components: list[str]) -> None:
        self.name = name
        self.description = description
        self.components = components
        self.resources: dict[str, Resource] = {}

    @property
    def path(self) -> str:
        return HOME_PATH + self.name.lower() + "/"


def build_state(today: dt.date) -> dict[str, Collection]:
    """Create the three demo calendars with dates relative to ``today``."""

    work = Collection("Work", "Meetings and release chores", ["VEVENT"])
    personal = Collection("Personal", "All-day entries only", ["VEVENT"])
    reminders = Collection("Reminders", "Task-only collection, no VEVENT resources", ["VTODO"])

    # A daily series: the master starts a week ago, so the default window
    # (today .. today+7) only intersects later instances.  The CLI must still
    # return the whole resource, including its exception.
    first = today - dt.timedelta(days=7)
    master_start = dt.datetime(first.year, first.month, first.day, 10, 0, tzinfo=TOKYO)
    exception_day = today + dt.timedelta(days=1)
    exception_start = dt.datetime(
        exception_day.year, exception_day.month, exception_day.day, 11, 30, tzinfo=TOKYO
    )
    standup = ical(
        VTIMEZONE_TOKYO,
        "BEGIN:VEVENT",
        "UID:standup-" + str(uuid.uuid5(uuid.NAMESPACE_DNS, first.isoformat())),
        "DTSTAMP:" + stamp(),
        "DTSTART;TZID=Asia/Tokyo:" + master_start.strftime("%Y%m%dT%H%M%S"),
        "DTEND;TZID=Asia/Tokyo:" + (master_start + dt.timedelta(minutes=15)).strftime("%Y%m%dT%H%M%S"),
        "RRULE:FREQ=DAILY;COUNT=20",
        "SUMMARY:Daily standup",
        "LOCATION:Room 4D",
        "DESCRIPTION:Recurring series served raw by the mock. The component does not expand it.",
        "END:VEVENT",
        "BEGIN:VEVENT",
        # An edited instance of the series.  Same UID, RECURRENCE-ID ties it back.
        "UID:standup-" + str(uuid.uuid5(uuid.NAMESPACE_DNS, first.isoformat())),
        "DTSTAMP:" + stamp(),
        "RECURRENCE-ID;TZID=Asia/Tokyo:" + exception_start.strftime("%Y%m%dT%H%M%S"),
        "DTSTART;TZID=Asia/Tokyo:" + exception_start.strftime("%Y%m%dT%H%M%S"),
        "DTEND;TZID=Asia/Tokyo:" + (exception_start + dt.timedelta(minutes=30)).strftime("%Y%m%dT%H%M%S"),
        "SUMMARY:Daily standup (moved)",
        "END:VEVENT",
    )
    work.resources["standup.ics"] = Resource(standup)

    review_day = today + dt.timedelta(days=2)
    review_start = dt.datetime(review_day.year, review_day.month, review_day.day, 14, 0, tzinfo=dt.timezone.utc)
    review = ical(
        "BEGIN:VEVENT",
        "UID:review-" + str(uuid.uuid5(uuid.NAMESPACE_DNS, review_day.isoformat())),
        "DTSTAMP:" + stamp(),
        "DTSTART:" + utc(review_start),
        "DTEND:" + utc(review_start + dt.timedelta(hours=1, minutes=30)),
        "SUMMARY:Release review",
        "LOCATION:https://meet.example.test/review",
        "DESCRIPTION:Round-trip check: unknown properties below must survive GET.",
        "ATTENDEE;CN=Demo;ROLE=REQ-PARTICIPANT:mailto:demo@example.test",
        "CATEGORIES:release,demo",
        "X-DEMO-NOTE:opaque extension property",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "TRIGGER:-PT15M",
        "DESCRIPTION:Reminder",
        "END:VALARM",
        "END:VEVENT",
    )
    work.resources["review.ics"] = Resource(review)

    holiday_day = today + dt.timedelta(days=1)
    birthday = ical(
        "BEGIN:VEVENT",
        "UID:birthday-" + str(uuid.uuid5(uuid.NAMESPACE_DNS, holiday_day.isoformat())),
        "DTSTAMP:" + stamp(),
        "DTSTART;VALUE=DATE:" + holiday_day.strftime("%Y%m%d"),
        "DTEND;VALUE=DATE:" + (holiday_day + dt.timedelta(days=1)).strftime("%Y%m%d"),
        "SUMMARY:Public holiday",
        "TRANSP:TRANSPARENT",
        "END:VEVENT",
    )
    personal.resources["holiday.ics"] = Resource(birthday)

    return {"work": work, "personal": personal, "reminders": reminders}


# --------------------------------------------------------------------------
# iCalendar helpers (only what the time-range filter needs)
# --------------------------------------------------------------------------


def unfold(raw: str) -> list[str]:
    out: list[str] = []
    for line in raw.replace("\r\n", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        elif line:
            out.append(line)
    return out


def parse_dt(value: str, params: str) -> tuple[dt.datetime, bool] | None:
    """Return (instant, all_day) for a DTSTART/DTEND/RECURRENCE-ID value."""
    tzid = re.search(r'TZID="?([^";:]+)', params)
    for fmt in ("%Y%m%dT%H%M%SZ", "%Y%m%dT%H%M%S", "%Y%m%d"):
        try:
            parsed = dt.datetime.strptime(value, fmt)
        except ValueError:
            continue
        if fmt == "%Y%m%d":
            return parsed.replace(tzinfo=dt.timezone.utc), True
        if fmt.endswith("Z"):
            return parsed.replace(tzinfo=dt.timezone.utc), False
        zone = ZoneInfo(tzid.group(1)) if tzid else dt.timezone.utc
        return parsed.replace(tzinfo=zone), False
    return None


class Vevent:
    def __init__(self, lines: list[str]) -> None:
        self.props: dict[str, tuple[str, str]] = {}
        for line in lines:
            name, _, rest = line.partition(":")
            key, _, params = name.partition(";")
            self.props.setdefault(key.upper(), (rest, params))

    def text(self, name: str) -> str:
        return self.props.get(name, ("", ""))[0]

    def params(self, name: str) -> str:
        return self.props.get(name, ("", ""))[1]

    def instant(self, name: str) -> tuple[dt.datetime, bool] | None:
        if name not in self.props:
            return None
        value, params = self.props[name]
        return parse_dt(value, params)


def parse_events(raw: str) -> list[Vevent]:
    events: list[Vevent] = []
    current: list[str] | None = None
    for line in unfold(raw):
        upper = line.upper()
        if upper == "BEGIN:VEVENT":
            current = []
        elif upper == "END:VEVENT" and current is not None:
            events.append(Vevent(current))
            current = None
        elif current is not None:
            current.append(line)
    return events


def occurences(event: Vevent, limit: int = 400) -> list[tuple[dt.datetime, dt.datetime]]:
    """Expand DAILY/WEEKLY/MONTHLY/YEARLY series at the same clock time.

    This is deliberately shallow: enough to prove that a series master whose
    DTSTART lies outside the window is still returned by the server.  The
    component itself never expands recurrence rules.
    """
    start = event.instant("DTSTART")
    if start is None:
        return []
    begin, all_day = start
    end = event.instant("DTEND")
    duration = (end[0] - begin) if end else (dt.timedelta(days=1) if all_day else dt.timedelta(0))
    rule = event.text("RRULE")
    if not rule:
        return [(begin, begin + duration)]

    parts = {}
    for piece in rule.split(";"):
        key, _, value = piece.partition("=")
        parts[key.upper()] = value
    freq = parts.get("FREQ", "").upper()
    interval = max(1, int(parts.get("INTERVAL", "1") or 1))
    count = int(parts.get("COUNT", "0") or 0)
    until = None
    if parts.get("UNTIL"):
        parsed = parse_dt(parts["UNTIL"], "")
        until = parsed[0] if parsed else None

    out: list[tuple[dt.datetime, dt.datetime]] = []
    cursor = begin
    produced = 0
    while produced < limit:
        if until is not None and cursor > until:
            break
        if count and produced >= count:
            break
        out.append((cursor, cursor + duration))
        produced += 1
        if freq == "DAILY":
            cursor += dt.timedelta(days=interval)
        elif freq == "WEEKLY":
            cursor += dt.timedelta(weeks=interval)
        elif freq == "MONTHLY":
            month = cursor.month - 1 + interval
            cursor = cursor.replace(
                year=cursor.year + month // 12, month=month % 12 + 1, day=min(cursor.day, 28)
            )
        elif freq == "YEARLY":
            cursor = cursor.replace(year=cursor.year + interval)
        else:
            break
    return out


def in_range(raw: str, start: dt.datetime, end: dt.datetime) -> bool:
    """True when any instance in the resource overlaps [start, end)."""
    events = parse_events(raw)
    masters = {e.text("RECURRENCE-ID"): e for e in events if e.text("RECURRENCE-ID")}
    for event in events:
        if event.text("RECURRENCE-ID"):
            continue
        for begin, finish in occurences(event):
            if begin < end and finish > start:
                return True
    # An exception-only resource (master outside the fetched window) still
    # counts: real servers return the whole resource, and so does this one.
    for event in masters.values():
        span = event.instant("DTSTART")
        if span is None:
            continue
        begin = span[0]
        end_value = event.instant("DTEND")
        finish = end_value[0] if end_value else begin
        if begin < end and finish > start:
            return True
    return False


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------


class Mock:
    def __init__(self, require_auth: bool, log_path: str | None) -> None:
        self.lock = threading.Lock()
        self.require_auth = require_auth
        self.log_path = log_path
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self.today = dt.date.today()
            self.collections = build_state(self.today)

    def log(self, line: str) -> None:
        stamp_text = dt.datetime.now().strftime("%H:%M:%S")
        print(f"{stamp_text} {line}", flush=True)
        if self.log_path:
            try:
                with open(self.log_path, "a", encoding="utf-8") as handle:
                    handle.write(f"{stamp_text} {line}\n")
            except OSError:
                pass

    def collection_for(self, path: str) -> Collection | None:
        for collection in self.collections.values():
            if collection.path == path:
                return collection
        return None

    def resolve(self, path: str) -> tuple[Collection | None, str | None]:
        """Split a resource path into (collection, resource name)."""
        for collection in self.collections.values():
            if path.startswith(collection.path):
                name = path[len(collection.path) :]
                if name and "/" not in name:
                    return collection, name
        return None, None


def multistatus(responses: list[ET.Element]) -> bytes:
    root = ET.Element(f"{{{DAV}}}multistatus")
    for response in responses:
        root.append(response)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def prop_response(href: str, props: list[ET.Element]) -> ET.Element:
    response = ET.Element(f"{{{DAV}}}response")
    ET.SubElement(response, f"{{{DAV}}}href").text = href
    stat = ET.SubElement(response, f"{{{DAV}}}propstat")
    prop = ET.SubElement(stat, f"{{{DAV}}}prop")
    for item in props:
        prop.append(item)
    ET.SubElement(stat, f"{{{DAV}}}status").text = "HTTP/1.1 200 OK"
    return response


class Handler(BaseHTTPRequestHandler):
    server_version = "CalDAV-demo-mock/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def mock(self) -> Mock:
        return self.server.mock  # type: ignore[attr-defined]

    # -- plumbing ---------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - stdlib hook
        # Each verb logs its own outcome; the stdlib access log would duplicate it.
        pass

    def reply(self, status: int, body: bytes = b"", headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def authorised(self) -> bool:
        if not self.mock.require_auth:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = __import__("base64").b64decode(header[6:]).decode("utf-8")
        except Exception:  # noqa: BLE001 - any malformed header is a rejection
            return False
        return ":" in decoded and decoded.split(":", 1)[0] != ""

    def guarded(self, method: str, path: str) -> bool:
        if not self.authorised():
            self.reply(401, b"", {"WWW-Authenticate": 'Basic realm="mock"'})
            self.mock.log(f"{method} {path} -> 401")
            return False
        return True

    # -- verbs ------------------------------------------------------------

    def do_PROPFIND(self) -> None:  # noqa: N802 - stdlib naming
        path = self.path
        if not self.guarded("PROPFIND", path):
            return
        self.body()  # the requested prop set is fixed by the CLI; ignore it
        if path == START_PATH:
            principal = ET.Element(f"{{{DAV}}}current-user-principal")
            ET.SubElement(principal, f"{{{DAV}}}href").text = PRINCIPAL_PATH
            self.reply(
                207,
                multistatus([prop_response(path, [principal])]),
                {"Content-Type": "application/xml; charset=utf-8"},
            )
            self.mock.log(f"PROPFIND {path} -> 207 current-user-principal")
            return
        if path == PRINCIPAL_PATH:
            home = ET.Element(f"{{{CALDAV}}}calendar-home-set")
            ET.SubElement(home, f"{{{DAV}}}href").text = HOME_PATH
            self.reply(
                207,
                multistatus([prop_response(path, [home])]),
                {"Content-Type": "application/xml; charset=utf-8"},
            )
            self.mock.log(f"PROPFIND {path} -> 207 calendar-home-set")
            return
        if path == HOME_PATH:
            # Depth 1: the home itself plus every child collection.  The home
            # response must still carry a resourcetype, or the CLI rejects the
            # whole multistatus as invalid.
            responses = [prop_response(HOME_PATH, [ET.Element(f"{{{DAV}}}resourcetype")])]
            for collection in self.mock.collections.values():
                responses.append(calendar_response(collection))
            self.reply(
                207,
                multistatus(responses),
                {"Content-Type": "application/xml; charset=utf-8"},
            )
            self.mock.log(f"PROPFIND {path} -> 207 {len(responses)} responses")
            return
        self.reply(404)

    def do_REPORT(self) -> None:
        path = self.path
        if not self.guarded("REPORT", path):
            return
        request = self.body().decode("utf-8", "replace")
        self.mock.log(f"REPORT {path} time-range {time_range_note(request)}")
        collection = self.mock.collection_for(path)
        if collection is None:
            self.reply(404)
            return
        start, end = time_range(request)
        responses = []
        for name, resource in collection.resources.items():
            if not in_range(resource.data, start, end):
                continue
            response = ET.Element(f"{{{DAV}}}response")
            ET.SubElement(response, f"{{{DAV}}}href").text = collection.path + name
            stat = ET.SubElement(response, f"{{{DAV}}}propstat")
            prop = ET.SubElement(stat, f"{{{DAV}}}prop")
            ET.SubElement(prop, f"{{{DAV}}}getetag").text = resource.etag
            ET.SubElement(prop, f"{{{CALDAV}}}calendar-data").text = resource.data
            ET.SubElement(stat, f"{{{DAV}}}status").text = "HTTP/1.1 200 OK"
            responses.append(response)
        self.reply(
            207,
            multistatus(responses),
            {"Content-Type": "application/xml; charset=utf-8"},
        )
        self.mock.log(f"REPORT {path} -> 207 {len(responses)} resources")

    def do_GET(self) -> None:
        path = self.path
        if not self.guarded("GET", path):
            return
        collection, name = self.mock.resolve(path)
        if collection is None or name is None or name not in collection.resources:
            self.reply(404)
            return
        resource = collection.resources[name]
        self.reply(
            200,
            resource.data.encode("utf-8"),
            {
                "Content-Type": "text/calendar; charset=utf-8",
                "ETag": resource.etag,
            },
        )

    def do_PUT(self) -> None:
        path = self.path
        if not self.guarded("PUT", path):
            return
        payload = self.body()
        text = payload.decode("utf-8", "replace")
        collection, name = self.mock.resolve(path)
        if collection is None or name is None:
            self.reply(409)
            return
        if "BEGIN:VCALENDAR" not in text.upper():
            self.reply(400)
            return
        if "VEVENT" not in text.upper() and "VTODO" not in text.upper():
            self.reply(400)
            return
        with self.mock.lock:
            existing = collection.resources.get(name)
            if_match = self.headers.get("If-Match")
            if_none_match = self.headers.get("If-None-Match")
            if if_none_match == "*" and existing is not None:
                self.mock.log(f"PUT {path} -> 412 stale precondition (exists)")
                self.reply(412)
                return
            if if_match is not None:
                if existing is None:
                    self.reply(404)
                    return
                if if_match != existing.etag:
                    self.mock.log(f"PUT {path} -> 412 etag mismatch")
                    self.reply(412)
                    return
            if existing is None:
                collection.resources[name] = Resource(text)
                status = 201
            else:
                existing.replace(text)
                status = 204
            etag = collection.resources[name].etag
        self.reply(status, b"", {"ETag": etag})
        self.mock.log(f"PUT {path} -> {status} etag={etag}")

    def do_DELETE(self) -> None:
        path = self.path
        if not self.guarded("DELETE", path):
            return
        collection, name = self.mock.resolve(path)
        if collection is None or name is None:
            self.reply(404)
            return
        with self.mock.lock:
            existing = collection.resources.get(name)
            if existing is None:
                self.reply(404)
                return
            if_match = self.headers.get("If-Match")
            if if_match is not None and if_match != existing.etag:
                self.mock.log(f"DELETE {path} -> 412 etag mismatch")
                self.reply(412)
                return
            del collection.resources[name]
        self.reply(204)
        self.mock.log(f"DELETE {path} -> 204")

    def do_OPTIONS(self) -> None:  # some clients probe first
        self.reply(200, b"", {"DAV": "1, 2, calendar-access", "Allow": "PROPFIND, REPORT, GET, PUT, DELETE"})


def calendar_response(collection: Collection) -> ET.Element:
    response = ET.Element(f"{{{DAV}}}response")
    ET.SubElement(response, f"{{{DAV}}}href").text = collection.path
    stat = ET.SubElement(response, f"{{{DAV}}}propstat")
    prop = ET.SubElement(stat, f"{{{DAV}}}prop")
    resourcetype = ET.SubElement(prop, f"{{{DAV}}}resourcetype")
    if collection.components:
        ET.SubElement(resourcetype, f"{{{DAV}}}collection")
        ET.SubElement(resourcetype, f"{{{CALDAV}}}calendar")
    else:
        ET.SubElement(resourcetype, f"{{{DAV}}}collection")
    ET.SubElement(prop, f"{{{DAV}}}displayname").text = collection.name
    ET.SubElement(prop, f"{{{CALDAV}}}calendar-description").text = collection.description
    supported = ET.SubElement(prop, f"{{{CALDAV}}}supported-calendar-component-set")
    for name in collection.components:
        ET.SubElement(supported, f"{{{CALDAV}}}comp", {"name": name})
    ET.SubElement(stat, f"{{{DAV}}}status").text = "HTTP/1.1 200 OK"
    return response


def time_range(request: str) -> tuple[dt.datetime, dt.datetime]:
    start = re.search(r'start="([0-9T]+Z)"', request)
    end = re.search(r'end="([0-9T]+Z)"', request)
    begin = dt.datetime.strptime(start.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)
    finish = dt.datetime.strptime(end.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)
    return begin, finish


def time_range_note(request: str) -> str:
    match = re.search(r'start="([0-9T]+Z)" end="([0-9T]+Z)"', request)
    return f"{match.group(1)} .. {match.group(2)}" if match else "(none)"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8787, help="TCP port on 127.0.0.1 (default 8787)")
    parser.add_argument("--log", default=None, help="also append request lines to this file")
    parser.add_argument(
        "--require-auth",
        action="store_true",
        help="reject requests without a Basic Authorization header",
    )
    parser.add_argument(
        "--state",
        action="store_true",
        help="print the generated state as JSON and exit",
    )
    args = parser.parse_args(argv)

    mock = Mock(args.require_auth, args.log)
    if args.state:
        payload = {
            name: {
                "path": collection.path,
                "components": collection.components,
                "resources": sorted(collection.resources),
            }
            for name, collection in mock.collections.items()
        }
        print(json.dumps(payload, indent=2))
        return 0

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.mock = mock  # type: ignore[attr-defined]
    base = f"http://127.0.0.1:{args.port}"
    mock.log("CalDAV demo mock listening")
    print(
        "\n".join(
            [
                f"start URL   {base}{START_PATH}",
                f"principal   {base}{PRINCIPAL_PATH}",
                f"home        {base}{HOME_PATH}",
                "calendars   " + ", ".join(f"{c.name} ({c.path})" for c in mock.collections.values()),
                "state reset on restart; Ctrl+C to stop",
            ]
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
