# Notes: chokepoints, failures and findings

Everything below is from building this demo against `miyako/CalDAV` 0.1.2 with
4D 21 R5 (build 100176) on Apple Silicon, `tool4d` for the headless runs. Each
item is either a diagnosis with evidence or a claim I could not confirm.

## Chokepoints

### 1. `Components/` is not where the documentation implies

The skills reference says `<project>/Components/<Name>.4dbase` is "highest
priority; the folder 4D and tool4d load at startup". For a project database that
reads as *inside* the folder that holds the `.4DProject`, and that is wrong:

| Placement | `version()` result |
| --- | --- |
| `Project/Components/CalDAV.4dbase` | `component not loaded` |
| `Project/CalDAV.4dbase` (beside the `.4DProject`) | `component not loaded` |
| `CalDAV.4dbase` at the database folder root (beside `Project/`) | `component 0.1.2 · protocol 1` |

The database folder is the one holding `Project/`, `Resources/` and the data
file — for this repository, the repository root. The component has to be a
sibling of `Project/`, and `scripts/fetch_component.sh` stages it there. The
`.4DZ` archive member layout is not the issue: all three placements contained a
complete `CalDAV.4dbase` with `.4DZ`, `Resources/` and native `Libraries/`.

### 2. The pin key is `version`, not `tag`

`dependencies.json` in this repository pins:

```json
{"version": 2100, "dependencies": {"CalDAV": {"github": "miyako/CalDAV", "version": "0.1.2"}}}
```

Two independently IDE-generated files on the same machine use the same key, with
`"latest"` and `"4d"` as special values instead of a number; 4D 21 R5 also wrote
`userPreferences.miyako/dependencies-lock.json` echoing `"version": "0.1.2"` back
for this project. The skills reference shows `"tag": "0.1.3"` for the same
purpose. An unrecognised key is not reported as an error, which makes the
mistake quiet: the dependency declares itself and then never resolves.

### 3. `tool4d` never fetches — and says so without failing

A headless run of a project with a declared dependency prints, before anything
else:

```
PackageManager No component to fetch dependencies ()
PackageManager Dependency 'CalDAV' cannot be found ()
```

Both lines are benign *when the component is staged under `Components/`*: the run
then reports `component 0.1.2`. They are also emitted when it is not staged, and
then `cs.CalDAV` is `Null` and every call raises `-10716 Object or Collection
Expected`. The lock file is not a reliable signal either: it recorded
`"loaded": false, "found": false` for a run in which the component loaded and
worked. Treat "did the run report a version" as the real check.

### 4. `cs.CalDAV is unknown` is expected, and it hides real errors

`tool4d-lsp-stdio validate` ends with:

```
Sources/Classes/DemoForm.4dm:117:21: error: The class cs.CalDAV is unknown.
Sources/Classes/DemoForm.4dm:160:37: warning: ... execute does not exist on type cs.CalDAV.Calendar. (550.2)
```

This is the documented class-store limitation of compiling a host of a
dependency under `tool4d`; the same code runs interpreted. The consequence for a
project like this one is that syntax validation is only useful for *everything
else*: four genuine errors (below) were reported in the same list and had to be
read apart from the four expected ones. On the first run they were mixed with
`A Boolean argument was expected` (`Not(Null)`) noise caused by calling into an
absent component, which is why the form class now checks `hasComponent()` first.

## Failures I hit, and the fix

| Symptom | Cause | Fix |
| --- | --- | --- |
| `build` → `cli_error invalid_request` | `execute()` takes the CLI's own request shape: `build` wants `{event: {…}}`, `inspect` wants `{icalendar: "…"}` | call the facade helpers (`build($event)`, `inspect($ical)`) or wrap the field yourself |
| query window `2026-11-26T00:00:00T00:00:00Z` | `String($date; ISO date)` returns `2026-11-26T00:00:00`, not `2026-11-26` | `Substring(String($date; ISO date); 1; 10)`, or build the stamp from `String($date; ISO date; $time)` which does produce `2026-11-26T05:44:44` |
| `Time string($t; ISO time)` → `4DRT [58] A ")" was expected.` | `Time string` takes no format argument, and the surplus argument is reported at run time, not at compile time | use `String($t)` (`05:44:44`) or `Substring(String($t; ISO time); 12; 8)` |
| `Test path exists($path)` → `Missing expression` | a POSIX path from JSON is not a platform path | `File($path; fk posix path)` then `$file.exists` |
| syntax error at `This.pad2(Hour of($now))` | a command nested as an argument inside another call | assign to a local first, or avoid the nested form |
| a path check passed locally but named the wrong file | the package is `CalDAV.4dbase` while the CLI basename is lowercase `caldav`/`caldav.exe`; a mixed-case path resolves on APFS and would not on a case-sensitive volume | `os.listdir` (not `ls -l`, which echoes the requested case) to confirm the real names, then use them literally |
| every call raises `-10716` with `Not($result.ok)` | `cs.CalDAV` is `Null`; `.ok` on `Null` fails before `Not` can object | `hasComponent()` guard returning a `component_missing` result |
| "conflict" demo reported that the server *accepted* a stale write | the mock derives ETags from the body, and the first update wrote a byte-identical body | change the body before the second write; a conditional write with unchanged content is a no-op, not an ETag rotation |
| smoke said `create` passed while `create` had failed | the assertion read `targetURL`, which `showResource()` had already set from the previous selection | assert on the operation's own status line, and clear the target before the step |
| smoke's `update`/`delete` acted on the wrong resource | `queryDemo()` re-selects row 1 after every mutation | re-select the URL that was just written (`selectURL`) |
| smoke's `update` produced no new ETag | the demo wrote the summary back unchanged | refuse a no-op edit explicitly instead of PUTing it |

### 5. A failing headless run exits 0

`tool4d` returns `0` for a successful run *and* for a run whose startup method
failed:

```
$ tool4d --startup-method Probe ... ; echo $?
tool4d.4DRT [-10518] Assert failed: deliberate failure (task=-1, taskName=Main task)
0
```

Same for a runtime error (`[58]`, `[-10716]`, `[59]`). `scripts/smoke.sh` therefore
parses the JSON report the method writes and looks at `success`; the exit status
is printed for information only. Any pipeline that gates on `tool4d`'s exit code
is gating on nothing.

## Findings worth carrying to another project

1. **Stage, then pin.** Keep `dependencies.json` pinned for the IDE, and stage
   `Components/` for `tool4d`; the two coexist and the PackageManager warnings
   are noise. `scripts/fetch_component.sh` resolves the exact tag through the
   release API, verifies the archive and rejects escaping members.
2. **Version first, then discover.** Asking `version()` before any DAV traffic
   separates "component missing / stale staging" from "server unreachable" in one
   line of UI or one line of smoke output. It also caught a staging mistake here
   that otherwise looked like a network error.
3. **Report the component set.** `discover()` shows that `Reminders` is VTODO
   only. That single field explains most "why did my event write fail" questions
   before the write happens.
4. **ETags are preconditions.** The useful lesson for a UI is that `update` and
   `delete` should re-read the resource and carry the ETag it *just* saw; the
   demo does that, and then shows the failure it is protecting against by
   replaying an old ETag on purpose.
5. **Loopback is a deliberate opt-in.** Plain `http://` on a literal loopback
   address is refused unless `allowInsecureLoopback` is set. That field is not in
   the component's `Documentation/Classes/Calendar.md`, so a host that only reads
   the docs will believe its local development server is unreachable.
6. **Offline operations are free test surface.** `build`, `inspect` and `version`
   need no server. The Offline page is therefore the cheapest place to prove the
   component is wired correctly, and `inspect` on a deliberately broken document
   proves the error path without any network.
7. **Form classes do not receive events.** `"formClass"` instantiates the class;
   `"method": "method.4dm"` receives the form events, and that method has to
   dispatch to the class. Wiring only the class leaves a form that loads but
   never reacts.
8. **A headless 4D run needs a written verdict.** Since the process exits `0`
   regardless, the startup method has to produce evidence: print one line per
   check and write a report file that a wrapper can parse.
9. **Assert on the result, not on derived state.** Two smoke checks passed here
   while the operation underneath was failing, because they read a value that an
   earlier step had already set. Every assertion now reads the status line the
   operation itself wrote.

## Open questions

* Whether the IDE's Dependency manager resolves this exact pin on a clean
  machine. It was not exercised: `tool4d` has no manager, and the IDE run was not
  part of the acceptance. The staged `Components/` path is what the evidence
  covers.
* Whether `cs.CalDAV` resolves for `tool4d-lsp-stdio` when a component's
  `Resources/en.lproj/syntaxEN.json` is staged differently; the reference notes
  that the compiler never learns the signatures, so this is expected to stay.
