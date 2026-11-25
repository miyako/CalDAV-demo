# DemoForm

The form class behind the `Main` form. It owns every value the window shows and
performs every CalDAV call, so the same class can be driven headlessly by
`Smoke.4dm` without a window.

`Main/form.4DForm` declares `"formClass": "DemoForm"`, which instantiates the
class and binds its properties to the form objects of the same name.
`Main/method.4dm` receives the form events and dispatches to `onLoad()`;
`Main/ObjectMethods/*.4dm` are one-line dispatchers to the functions below.
A form class does **not** receive events by itself.

## Connection properties

| Property | Purpose |
| --- | --- |
| `url` | Server URL, default `http://127.0.0.1:8787/dav/` |
| `username` / `password` | Basic auth sent with every request |
| `loopback` | Adds `allowInsecureLoopback` to each request; required for plain `http://` |
| `versionText` | Result of `version()`, or an explanation when the component is absent |
| `principalURL` / `homeURL` | Populated by `discoverDemo()` |
| `calendars` / `selectedCalendar` / `selectionText` | Discovered collections and the chosen one |
| `startText` / `endText` | Query window, whole-second RFC 3339 UTC |

## Result properties

`statusText` is the one-line outcome of the last operation and is what the smoke
test asserts on. `resultText` holds the multi-line detail of a mutation,
`icalendarText` / `inspectText` hold the Offline page, and `requestText` /
`responseText` hold the redacted request and raw CLI streams of the last call.

## Operations

| Function | Effect |
| --- | --- |
| `onLoad()` | Seeds the header, then checks the component and discovers |
| `checkComponent()` | `version()`; reports a missing component instead of failing |
| `discoverDemo()` | `discover()`; fills `calendars` and reports each component set |
| `selectCalendar()` | Records the selected collection and clears the mutation target |
| `queryDemo($silent)` | `query()` for the current window; `$silent` refreshes the list without overwriting `statusText` |
| `getResource()` | `get()` on the selected resource |
| `buildDemo()` | `build()` of the form's event fields into `icalendarText` |
| `inspectDemo()` | `inspect()` of `icalendarText` |
| `loadResourceText()` | Copies the selected resource's raw iCalendar into the editor |
| `createDemo()` | `build()` + `create()`, then refreshes and re-selects the new resource |
| `updateDemo()` | Re-reads the resource for a current ETag, edits the summary, `update()` |
| `deleteDemo()` | Re-reads for an ETag, then `delete()` with it |
| `conflictDemo()` | Creates a scratch resource, rotates its ETag, replays the stale one, cleans up |

## Helpers

`utcStamp($days; $hour; $minute)` produces the whole-second RFC 3339 stamp the
CLI requires (it does not accept fractional seconds or an offset other than `Z`).
`connectionRequest()` and `eventRequest()` build the shared request fragments;
`invoke($operation; $request)` sets the operation, times the call, records it and
returns the component result unchanged. `describe($result)` turns a component
result into one line, `redactedRequest()` hides the password before the log page
displays a request.

Every function that talks to the component handles two states explicitly: the
component is absent (`hasComponent()` / `missingComponent()`), and the component
returned `ok:false` with an `error.code`.
