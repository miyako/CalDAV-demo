// Smoke — headless acceptance run.
//
// tool4d --dataless --skip-onstartup --startup-method Smoke --project=...
//   --user-param '{"url":"http://127.0.0.1:PORT/dav/","report":"/tmp/smoke.json"}'
//
// It drives the very same form class the window uses, so a green run means the
// demo works, not just the CLI. The signal is `PASS` on stdout plus
// "success": true in the report -- tool4d exits 0 even when an ASSERT fails,
// so the exit code alone proves nothing.
ON ERR CALL("Demo_Error"; ek local)

var $checks : Collection
var $failures : Collection
var $file : 4D.File
var $userParam; $path : Text
var $params; $state : Object
var $demo : cs.DemoForm
var $i : Integer
var $url; $detail : Text

$checks:=New collection
$failures:=New collection

// Step markers: the highest number printed is the last statement that ran.
LOG EVENT(Into system standard outputs; "smoke 01 read user param")
If (Get database parameter(User param value; $userParam)#0)
	$userParam:=""
End if
If (Length($userParam)=0)
	$userParam:="{}"
End if
$params:=JSON Parse($userParam)

LOG EVENT(Into system standard outputs; "smoke 02 construct form class")
$demo:=cs.DemoForm.new()
If (Value type($params.url)=Is text)
	$demo.url:=$params.url
End if
If (Value type($params.username)=Is text)
	$demo.username:=$params.username
End if
If (Value type($params.password)=Is text)
	$demo.password:=$params.password
End if
$demo.loopback:=True

// --- 1. the component itself ------------------------------------------------
LOG EVENT(Into system standard outputs; "smoke 03 component version")
$demo.checkComponent()
$checks.push(New object("name"; "component version"; "ok"; (Position("0.1.2"; $demo.versionText)>0); "detail"; $demo.versionText))

// --- 2. discovery -----------------------------------------------------------
LOG EVENT(Into system standard outputs; "smoke 04 discover")
$demo.discoverDemo()
var $hasTask : Boolean
$hasTask:=False
For ($i; 1; $demo.calendars.length)
	If (Position("VTODO"; String($demo.calendars[$i-1].componentsText))>0)
		$hasTask:=True
	End if
End for
$detail:="calendars="+String($demo.calendars.length)+" home="+$demo.homeURL
$checks.push(New object("name"; "discover"; "ok"; ($demo.calendars.length>=3); "detail"; $detail))
$checks.push(New object("name"; "discover component sets"; "ok"; $hasTask; "detail"; "a VTODO-only collection was reported"))

// --- 3. query ---------------------------------------------------------------
LOG EVENT(Into system standard outputs; "smoke 05 query")
$demo.queryDemo()
var $hasSeries : Boolean
$hasSeries:=False
For ($i; 1; $demo.resources.length)
	If (Position("RRULE:FREQ=DAILY"; String($demo.resources[$i-1].icalendar))>0)
		$hasSeries:=True
	End if
End for
$detail:="resources="+String($demo.resources.length)+" window="+$demo.startText+".."+$demo.endText
$checks.push(New object("name"; "query"; "ok"; ($demo.resources.length>=2); "detail"; $detail))
$checks.push(New object("name"; "query keeps recurrence"; "ok"; $hasSeries; "detail"; "a resource still carries RRULE and its exception"))

// --- 4. offline build and inspect ------------------------------------------
LOG EVENT(Into system standard outputs; "smoke 06 build/inspect")
$demo.buildDemo()
$demo.inspectDemo()
$detail:="icalendar "+String(Length($demo.icalendarText))+" chars, inspect "+String(Length($demo.inspectText))+" chars"
$checks.push(New object("name"; "build then inspect"; "ok"; (Position("DTSTART"; $demo.inspectText)>0) && (Position("SUMMARY"; $demo.inspectText)>0); "detail"; $detail))

// A document the parser must refuse: the demo has to report it, not crash.
$demo.icalendarText:="this is not an iCalendar document"
$demo.inspectDemo()
$checks.push(New object("name"; "inspect rejects an empty calendar"; "ok"; (Position("refused"; $demo.inspectText)>0); "detail"; $demo.statusText))
$demo.discoverDemo()

// --- 5. create, select, update, delete -------------------------------------
LOG EVENT(Into system standard outputs; "smoke 07 create")
// Clear the selection target first: a stale value would make the next two
// checks pass against a resource this run never created.
$demo.targetURL:=""
$demo.targetETag:=""
$demo.createDemo()
$url:=$demo.targetURL
$checks.push(New object("name"; "create"; "ok"; (Position("Created"; $demo.statusText)=1); "detail"; $demo.statusText))

var $created : Object
$created:=Null
For ($i; 1; $demo.resources.length)
	If (String($demo.resources[$i-1].url)=$url)
		$created:=$demo.resources[$i-1]
	End if
End for
$checks.push(New object("name"; "create is queryable"; "ok"; (Value type($created)=Is object); "detail"; "found the new resource in the next query"))
If (Value type($created)=Is object)
	$demo.selectedResource:=$created
	$demo.showResource()
End if

LOG EVENT(Into system standard outputs; "smoke 08 update")
var $oldETag : Text
$oldETag:=$demo.targetETag
// The demo edits the summary; an unchanged summary is a no-op, not a write.
$demo.summary:="Updated by the smoke test"
$demo.updateDemo()
$checks.push(New object("name"; "update rotates the ETag"; "ok"; (Position("Updated"; $demo.statusText)=1) && ($demo.targetETag#$oldETag); "detail"; $demo.statusText))

LOG EVENT(Into system standard outputs; "smoke 09 delete")
$demo.deleteDemo()
$checks.push(New object("name"; "delete"; "ok"; (Position("Deleted"; $demo.statusText)=1); "detail"; $demo.statusText))

// --- 6. the failure mode that matters --------------------------------------
LOG EVENT(Into system standard outputs; "smoke 10 conflict")
$demo.conflictDemo()
$checks.push(New object("name"; "stale ETag is refused"; "ok"; (Position("412 conflict"; $demo.statusText)=1); "detail"; $demo.statusText))

// --- 7. a closed door is reported, not swallowed ---------------------------
LOG EVENT(Into system standard outputs; "smoke 11 plain http refused")
$demo.loopback:=False
$demo.discoverDemo()
$checks.push(New object("name"; "plain http without the opt-in"; "ok"; (Position("Discovery failed"; $demo.statusText)=1); "detail"; $demo.statusText))
$demo.loopback:=True

// --- report ----------------------------------------------------------------
For ($i; 1; $checks.length)
	If (Not($checks[$i-1].ok))
		$failures.push(String($checks[$i-1].name)+": "+String($checks[$i-1].detail))
	End if
End for

$state:=New object("success"; ($failures.length=0); "finished"; True; "checks"; $checks; "failures"; $failures; "url"; $demo.url; "logEntries"; $demo.log.length)

If (Value type($params.report)=Is text)
	$path:=$params.report
	If (Length($path)>0)
		LOG EVENT(Into system standard outputs; "smoke 12 write report "+$path)
		// The path comes from a JSON parameter, so it is POSIX on macOS.
		$file:=File($path; fk posix path)
		If ($file.exists)
			$file.delete()
		End if
		$file.create()
		$file.setText(JSON Stringify($state; *))
	End if
End if

If ($failures.length=0)
	LOG EVENT(Into system standard outputs; "PASS CalDAV demo smoke — "+String($checks.length)+" checks")
Else
	LOG EVENT(Into system standard outputs; "FAIL CalDAV demo smoke — "+String($failures.length)+" of "+String($checks.length)+" checks")
	LOG EVENT(Into system standard outputs; $failures.join(" | "))
End if

ASSERT($failures.length=0; $failures.join(" | "))
QUIT 4D
