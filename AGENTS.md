# Agent guide for CalDAV-demo

This repository is a 4D **host** project: it consumes the `miyako/CalDAV`
component as a pinned dependency and demonstrates it. Read the shared 4D skills
first — they are a git submodule:

* `.agents/AGENTS.md` — how the skill set is organised, and which skill covers
  which artifact (`4dproject`, `4dform`, `4dmethod`, `4dclass`, `4dstartup`,
  `4dtools`, `4dmodernise`, …).
* `.agents/skills/<name>/SKILL.md` — the specific rules for an artifact you are
  about to edit.

`.agents` is pinned by `.gitmodules` (branch `dist`); keep it at the recorded
commit when you are reproducing the results in `NOTES.md`.

## Non-negotiables in this project

1. **The component is a dependency.** Do not copy component code here, and do not
   edit files inside `Components/CalDAV.4dbase` — that folder is a fetched
   artifact and is git-ignored. Reproduce it with `scripts/fetch_component.sh`,
   which reads the tag from `Project/Sources/dependencies.json`.
2. **Validate before claiming.** Form JSON must pass
   `tools/4dform/boon .agents/schemas/4dform/formsSchema.json Project/Sources/Forms/Main/form.4DForm`, layout
   must pass `form_layout_calc.py` for every page, and behaviour must pass
   `scripts/smoke.sh`. `cs.CalDAV is unknown` from `tool4d-lsp-stdio validate` is
   the documented class-store limitation, not a regression (see `NOTES.md`).
3. **Keep the demo evergreen.** The mock generates its calendar relative to
   today and the form computes its query window from `Current date`; never
   reintroduce a fixed date.
4. **Form state lives in the form class.** `Project/Sources/Classes/DemoForm.4dm`
   owns everything the form shows. `method.4dm` dispatches events and the
   `ObjectMethods/` files are one-line dispatchers — keep them that way, and keep
   the smoke test driving the same class rather than a parallel code path.
5. **Show the failure, do not swallow it.** Every CLI call ends in a status line
   plus a Protocol log entry with the redacted request and raw streams. A missing
   component, a refused plain-HTTP URL and a 412 conflict are demonstrated
   states, not exceptions.

## Local commands

```sh
scripts/fetch_component.sh              # stage Components/CalDAV.4dbase (pinned tag)
scripts/smoke.sh                        # mock + tool4d + 17 checks
scripts/smoke.sh --tool4d PATH
python3 scripts/mock_caldav.py --port 8787
python3 scripts/selftest_mock.py --cli Components/CalDAV.4dbase/Resources/bin/macOS/caldav
```

`scripts/smoke.sh` exits non-zero on any red check because it parses the report
`Smoke.4dm` writes -- not because of `tool4d`'s exit code, which is `0` even for a
failed `ASSERT`.
