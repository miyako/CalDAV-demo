# CalDAV-demo

An interactive 4D project that puts the [CalDAV](https://github.com/miyako/CalDAV)
component on screen and lets you press every part of it.

The component is a **dependency, not a fork**: `Project/Sources/dependencies.json`
pins `miyako/CalDAV` at `0.1.2`, and nothing in this repository reimplements the
protocol. The demo is five pages that walk from "is the component here?" to
"why did that write come back as a conflict?", plus a headless smoke test that
drives the same form class without a UI.

```
Start.4dm ──▶ Main form ──▶ DemoForm (form class) ──▶ cs.CalDAV.Calendar ──▶ caldav CLI ──▶ server
                                  │
                                  └──▶ Protocol log page (redacted request + raw streams)
```

## What you can do with it

| Page | What it shows | Press |
| --- | --- | --- |
| **Server** | `version()` first, then `discover()`: principal URL, calendar home, and the collections with their reported component sets | `Discover` |
| **Query** | `query()` with a live time window (UTC today 00:00 … + 7 days), the raw iCalendar of each hit, and `get()` on demand | `Query`, `Get` |
| **Offline** | `build()` from a form, `inspect()` of the result, and `inspect()` of a document you deliberately break | `Build`, `Inspect`, `Load` |
| **Mutate** | `create()` with generated content, `update()` with a conditional ETag, `delete()` with the ETag it just read, and a scripted 412 conflict | `Create`, `Update`, `Delete`, `Conflict` |
| **Protocol log** | Every call: operation, elapsed time, status, the redacted request JSON and the raw CLI stdout/stderr | — |

The last page is the point of the demo. A component that shells out to a CLI is
easy to call and hard to debug; the demo keeps the exact bytes that crossed the
process boundary visible while you use it.

Points worth noticing while clicking:

* **A missing component is a state, not a crash.** With `Components/CalDAV.4dbase`
  absent, `cs.CalDAV` is `Null`. The form says so on the Server page and every
  operation returns a `component_missing` result instead of raising `-10716`.
* **Discovery reports the component set.** `Reminders` is VTODO-only; the demo
  prints that so a VTODO/VTIMEZONE mismatch is visible before an event write.
* **Offline operations never touch the network.** `build`, `inspect` and
  `version` run the CLI with no DAV traffic, which is why the Offline page works
  with the mock server stopped.
* **ETags are preconditions, not identifiers.** `Update` re-reads the resource to
  get a current ETag, changes the summary, and sends it back with `If-Match`.
  `Conflict` keeps an old ETag, changes the body, and gets `412` — reported as
  `conflict`, not as a generic network error.
* **Loopback HTTP is opt-in.** `allowInsecureLoopback` is a pass-through field
  the component documentation does not list; the checkbox on the Server page
  toggles it, and clearing it against `http://` fails with `invalid_request`
  before a socket is opened.

## Run it in the 4D IDE

1. Open `Project/CalDAV-demo.4DProject`.
2. Let the Dependency manager install `CalDAV 0.1.2` (Dependencies panel), or
   stage a copy in `Components/` with `scripts/fetch_component.sh`.
3. Run and press **Discover**. With no CalDAV server configured, start the mock:

```sh
python3 scripts/mock_caldav.py --port 8787
```

The form defaults to `http://127.0.0.1:8787/dav/` with `demo` / `demo`, which is
what the mock expects. Any real CalDAV server works too: clear the loopback
checkbox and use `https://`.

## Run it headless

No licence, no serial, no IDE — [tool4d](https://developer.4d.com/docs/Admin/cli)
is the free headless runtime:

```sh
scripts/smoke.sh                       # stages the component, starts the mock, runs Smoke
scripts/smoke.sh --tool4d /path/to/tool4d
```

The script picks a free port, starts `scripts/mock_caldav.py`, runs the project's
`Smoke` method with `--startup-method Smoke --user-param <json>`, and reads the
JSON report the method writes. A green run looks like:

```
PASS component version — component 0.1.2 · protocol 1
PASS discover — calendars=3 home=http://127.0.0.1:58698/dav/home/
PASS query — resources=2 window=2026-11-26T00:00:00Z..2026-12-03T00:00:00Z
...
17/17 checks passed (tool4d exit 0)
```

`Smoke.4dm` is an ordinary project method; it constructs the same `DemoForm` class
the window uses and calls the same functions, so it is a real exercise of the UI
path rather than a second implementation. It prints `PASS`/`FAIL` per check,
writes a JSON report and `ASSERT`s the failure count.

Note what the exit code is worth: **nothing**. `tool4d` exits `0` even when an
`ASSERT` fails (`4DRT [-10518] Assert failed`) or a runtime error is logged, so
`scripts/smoke.sh` reads the report's `success` flag instead of `$?`.

## The mock server

`scripts/mock_caldav.py` is a stdlib-only CalDAV server (`ThreadingHTTPServer`,
127.0.0.1) with three collections and deliberately interesting data:

* `Work` — two resources: a daily standup with `RRULE:FREQ=DAILY;COUNT=20` and a
  `RECURRENCE-ID` exception, plus a review resource carrying an `X-DEMO-NOTE`
  property and a `VALARM`.
* `Personal` — an all-day holiday (the all-day shape is different: `DATE` values
  and an exclusive end).
* `Reminders` — VTODO-only, so the demo can show a component set that would
  reject a VEVENT.

It implements `PROPFIND`, `REPORT calendar-query`, `GET`, `PUT` (with
`If-None-Match: *` and `If-Match`), `DELETE` and `OPTIONS`, and computes ETags as
the hash of the stored body — so a byte-identical write keeps its ETag and a real
change rotates it. Data is generated relative to *today*, so the demo never goes
stale.

`scripts/selftest_mock.py` exercises the server directly against the staged CLI
(18 checks: discovery, recurrence, `X-` preservation, build/inspect round trip,
create/update/delete, 412 on a stale ETag, refusal of plain HTTP).

## Layout

```
Project/CalDAV-demo.4DProject      binary project descriptor
Project/Sources/dependencies.json  the component pin (version 0.1.2)
Project/Sources/Classes/DemoForm.4dm   all form state and behaviour
Project/Sources/Forms/Main/        form.json + method.4dm + ObjectMethods/
Project/Sources/Methods/           Start, Smoke, Demo_Error
Project/Sources/DatabaseMethods/   onStartup → Start
Components/CalDAV.4dbase           staged release (git-ignored)
scripts/                           mock server, mock selftest, fetch + smoke
tools/                             boon / fourdform / tool4d-lsp-stdio (git-ignored)
.agents/                           miyako/skills, the project's working guide
```

## Validation performed

| Check | Command | Result |
| --- | --- | --- |
| Form schema | `tools/4dform/boon …formsSchema.json … form.4DForm` | ok |
| Layout overlap | `form_layout_calc.py --form … --page 1..5` | none |
| Source syntax | `tools/4dlsp/tool4d-lsp-stdio validate --workspace Project/` | only `cs.CalDAV is unknown` (see NOTES) |
| Mock contract | `scripts/selftest_mock.py --cli Components/…/caldav` | 18 passed |
| End-to-end | `scripts/smoke.sh` | 17/17, tool4d exit 0 |

## Notes, chokepoints and dead ends

See [NOTES.md](NOTES.md) for the things that cost time here: where `Components/`
actually lives, why the dependency declaration is not enough for `tool4d`, why
`String(…; ISO date)` is not `YYYY-MM-DD`, and the `cs.CalDAV is unknown`
diagnostic that is expected rather than broken.

## License

MIT. The CalDAV component is a dependency under its own license; nothing from it
is vendored here.
