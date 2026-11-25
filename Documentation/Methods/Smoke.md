# Smoke

Headless acceptance for the demo. It drives `DemoForm` — the same class the
window uses — through the whole component surface without a UI, prints one line
per check, and writes a JSON report.

`tool4d` exits `0` even when this method's final `ASSERT` fails, so the exit code
is not evidence: read `success` in the report (or look for `PASS` on stdout).

```sh
scripts/smoke.sh
```

The script stages the component, starts `scripts/mock_caldav.py` on a free
loopback port, runs

```sh
tool4d --dataless --skip-onstartup --startup-method Smoke \
	--project=Project/CalDAV-demo.4DProject --user-param '<json>'
```

and reads the report. The user parameter is an Object:

| Key | Meaning |
| --- | --- |
| `url` | Server URL; the script passes `http://127.0.0.1:<port>/dav/` |
| `username` / `password` | Credentials for the mock (`demo` / `demo`) |
| `report` | POSIX path of the JSON report to write |

Read it with `Get database parameter(User param value; $param)` and check the
return value — `0` means success.

## Checks

| Check | Proves |
| --- | --- |
| `component version` | `version()` returns `0.1.2`; the component is staged and loadable |
| `discover` | three collections and a calendar home URL |
| `discover component sets` | the VTODO-only collection is reported as such |
| `query` / `query keeps recurrence` | the window returns resources and preserves `RRULE` plus its exception |
| `build then inspect` | offline round trip of a generated event |
| `inspect rejects an empty calendar` | the parser refuses a broken document without crashing |
| `create` / `create is queryable` | write, then find the new resource in the next query |
| `update rotates the ETag` | a conditional write with a current ETag changes the resource and its ETag |
| `delete` | a conditional delete with a current ETag removes it |
| `stale ETag is refused` | replaying an old ETag on changed content comes back as `412 conflict` |
| `plain http without the opt-in` | clearing `loopback` turns plain `http://` into `invalid_request` |

Each check is written against the status line the operation itself produced, not
against a value an earlier step had already set. That distinction matters: two
checks passed here once while the operation underneath them was failing.

## Report shape

```json
{
  "success": true,
  "finished": true,
  "checks": [{"name": "discover", "ok": true, "detail": "calendars=3 home=…"}],
  "failures": [],
  "url": "http://127.0.0.1:58698/dav/",
  "logEntries": 9
}
```

`success` is false and `failures` carries `"<name>: <detail>"` lines for every red
check; `logEntries` is the number of Protocol log rows the run produced.
