// DemoForm — controller for the "Main" form.
//
// One property group per page of the form, so every text object can bind a
// plain expression (Form.something) instead of being poked with OBJECT SET.
// Every remote call goes through invoke(), which times it, redacts the
// password and appends an entry to the protocol log.

property url : Text
property username : Text
property password : Text
property loopback : Boolean

property headerText : Text
property versionText : Text
property principalURL : Text
property homeURL : Text

property calendars : Collection
property selectedCalendar : Object
property selectionText : Text

property startText : Text
property endText : Text
property resources : Collection
property selectedResource : Object
property detailText : Text

property summary : Text
property location : Text
property eventStart : Text
property eventEnd : Text
property allDay : Boolean
property icalendarText : Text
property inspectText : Text

property targetURL : Text
property targetETag : Text
property resultText : Text
property mutateHint : Text

property log : Collection
property selectedLog : Object
property statusText : Text
property lastOperation : Text
property requestText : Text
property responseText : Text

// Hidden state: the form class is instantiated by 4D, so the constructor is
// the only place that can set defaults before the first On Load.
Class constructor()

	This.headerText:="CalDAV component demo — miyako/CalDAV"
	This.versionText:="probing the bundled CLI…"

	This.url:="http://127.0.0.1:8787/dav/"
	This.username:="demo"
	This.password:="demo"
	This.loopback:=True

	This.principalURL:=""
	This.homeURL:=""
	This.calendars:=New collection
	This.resources:=New collection
	This.log:=New collection
	This.selectionText:="No calendar selected yet. Press Discover."

	This.startText:=This.utcStamp(0; 0; 0)
	This.endText:=This.utcStamp(7; 0; 0)

	This.summary:="Written by the CalDAV demo"
	This.location:="Room 4D"
	This.eventStart:=This.utcStamp(3; 9; 0)
	This.eventEnd:=This.utcStamp(3; 10; 0)
	This.allDay:=False
	This.icalendarText:=""

	This.detailText:="Select a resource on the Query page."
	This.inspectText:="Press Inspect to parse an iCalendar document."
	This.resultText:=""
	This.mutateHint:="The mock refuses to overwrite or delete a resource whose ETag changed. That is the whole point of the conflict demo."
	This.statusText:="Ready. Make sure scripts/mock_caldav.py is running, then press Discover."
	This.lastOperation:="—"
	This.requestText:=""
	This.responseText:=""

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

// The UTC calendar date today. Current date is the *local* date, which near
// local midnight differs from the UTC date the fields are labelled with;
// Timestamp is always UTC ("2026-11-26T05:44:44.123Z").
Function utcToday()->$date : Date

	$date:=Date(Substring(Timestamp; 1; 10))

// A whole-second RFC 3339 UTC timestamp relative to the UTC date today, which is
// what the CLI accepts for query bounds and for event start/end.
// String(value; ISO date) renders as 0000-00-00T00:00:00, so the date part is
// cut to 10 characters and the clock is formatted by hand.
Function utcStamp($days : Integer; $hour : Integer; $minute : Integer)->$stamp : Text

	$stamp:=Substring(String(This.utcToday()+$days; ISO date); 1; 10)+"T"+This.pad2($hour)+":"+This.pad2($minute)+":00Z"

Function pad2($value : Integer)->$text : Text

	$text:=String($value)
	If (Length($text)<2)
		$text:="0"+$text
	End if

Function clockText()->$text : Text

	var $now : Time
	$now:=Current time
	// String(time; ISO time) renders as 0000-00-00THH:MM:SS, so take the clock part.
	$text:=Substring(String($now; ISO time); 12; 8)

// A missing component is a normal, reportable state: cs.CalDAV is Null when the
// .4dbase is not staged, and touching its classes then raises -10716.
Function hasComponent()->$ok : Boolean

	$ok:=(Value type(cs.CalDAV)=Is object)

Function missingComponent()->$result : Object

	$result:=New object("ok"; False; "error"; New object("code"; "component_missing"; "message"; "cs.CalDAV is Null: stage CalDAV.4dbase in Components/ beside the Project/ folder (scripts/fetch_component.sh)"); "stdout"; ""; "stderr"; "")

// A resource URL is the collection URL plus a name, so the collection URL must
// end in a slash; a server may report it without one.
Function resourceURL($collection : Text; $prefix : Text)->$url : Text

	$url:=$collection
	If (Substring($url; Length($url); 1)#"/")
		$url:=$url+"/"
	End if
	$url:=$url+$prefix+Replace string(Generate UUID; "-"; "")+".ics"

Function calendarController()->$calendar : cs.CalDAV.Calendar

	var $target : Text
	$target:="macOS-universal"
	If (Is Windows)
		$target:="Windows-x64"
	End if
	// The facade keeps no state: a fresh instance per call is free and avoids
	// carrying a stale configuration between runs.
	$calendar:=cs.CalDAV.Calendar.new($target)

// Base request for every remote operation. allowInsecureLoopback is the
// CLI's opt-in for plain HTTP on a literal loopback address; it is a
// pass-through field that the component documentation does not list.
Function connectionRequest()->$request : Object

	$request:=New object("url"; This.url; "username"; This.username; "password"; This.password)
	If (This.loopback)
		$request.allowInsecureLoopback:=True
	End if

// The subset accepted by build(): no timezone override, no recurrence.
Function eventRequest()->$request : Object

	$request:=New object("summary"; This.summary; "start"; This.eventStart; "end"; This.eventEnd; "allDay"; This.allDay)
	If (This.allDay)
		// All-day events take plain YYYY-MM-DD dates with an exclusive end later
		// than the start; RFC 3339 stamps are refused as invalid_request.
		$request.start:=Substring(This.eventStart; 1; 10)
		$request.end:=Substring(This.eventEnd; 1; 10)
		If ($request.end<=$request.start)
			$request.end:=Substring(String(Date($request.start)+1; ISO date); 1; 10)
		End if
	End if
	If (Length(This.location)>0)
		$request.location:=This.location
	End if

// Dispatch one operation, time it, and log the redacted request plus the raw
// CLI streams. Returns the component result unchanged.
Function invoke($operation : Text; $request : Object)->$result : Object

	var $elapsed; $started : Integer
	$started:=Milliseconds
	If (This.hasComponent())
		$request.operation:=$operation
		$result:=This.calendarController().execute($request)
	Else
		$result:=This.missingComponent()
	End if
	$elapsed:=Milliseconds-$started
	This.record($operation; $request; $result; $elapsed)
	return $result

Function record($operation : Text; $request : Object; $result : Object; $elapsed : Integer)

	var $entry : Object
	var $status : Text
	$status:="ok"
	If (Not($result.ok))
		$status:="fail"
	End if
	$entry:=New object("time"; This.clockText(); "operation"; $operation; "status"; $status; "elapsed"; String($elapsed)+" ms"; "note"; This.note($result); "request"; This.redactedRequest($request); "response"; This.rawResponse($result))
	This.log.unshift($entry)
	While (This.log.length>200)
		This.log.pop()
	End while
	This.selectedLog:=$entry
	This.lastOperation:=$operation+" — "+$status+" — "+String($elapsed)+" ms"
	This.requestText:=$entry.request
	This.responseText:=$entry.response

// Selecting an older log entry shows the request and streams of that call, not
// of the latest one.
Function selectLog()

	If (Value type(This.selectedLog)=Is object)
		This.requestText:=String(This.selectedLog.request)
		This.responseText:=String(This.selectedLog.response)
	End if

Function note($result : Object)->$note : Text

	If ($result.ok)
		$note:="protocol "+String($result.value.protocol)
	Else
		$note:=This.describe($result)
	End if

Function describe($result : Object)->$text : Text

	$text:="unknown error"
	If (Not($result.ok))
		If (Value type($result.error)=Is object)
			$text:=$result.error.code
			If (Value type($result.error.message)=Is text)
				If (Length($result.error.message)>0)
					$text:=$text+" — "+$result.error.message
				End if
			End if
			If (Value type($result.error.details)=Is object)
				If (Value type($result.error.details.status)=Is real)
					$text:=$text+" (HTTP "+String($result.error.details.status)+")"
				End if
			End if
		End if
	End if

Function redactedRequest($request : Object)->$text : Text

	var $copy : Object
	$copy:=OB Copy($request)
	If (Value type($copy.password)=Is text)
		If (Length($copy.password)>0)
			$copy.password:="••••••"
		End if
	End if
	$text:=JSON Stringify($copy; *)

Function rawResponse($result : Object)->$text : Text

	$text:=""
	If (Value type($result.exitCode)=Is real)
		$text:="exit "+String($result.exitCode)+Char(13)
	End if
	If (Value type($result.stdout)=Is text)
		If (Length($result.stdout)>0)
			$text:=$text+"stdout"+Char(13)+$result.stdout+Char(13)
		End if
	End if
	If (Value type($result.stderr)=Is text)
		If (Length($result.stderr)>0)
			$text:=$text+"stderr"+Char(13)+$result.stderr
		End if
	End if

Function joinComponents($components : Collection)->$text : Text

	var $component : Text
	$text:=""
	If (Value type($components)=Is collection)
		For each ($component; $components)
			If (Length($text)>0)
				$text:=$text+", "
			End if
			$text:=$text+$component
		End for each
	End if

// Map a component resource into the flat row the list boxes display.
Function toRow($resource : Object)->$row : Object

	var $first : Object
	var $summary; $start; $end : Text
	$summary:="(no events)"
	$start:=""
	$end:=""
	If ($resource.eventCount>0)
		$first:=$resource.events[0]
		$summary:=String($first.summary)
		If (Length($summary)=0)
			$summary:="(untitled)"
		End if
		$start:=String($first.start)
		$end:=String($first.end)
		// startUTC/endUTC are reported for timed events; DATE values have none.
		If (Length(String($first.startUTC))>0)
			$start:=String($first.startUTC)
		End if
		If (Length(String($first.endUTC))>0)
			$end:=String($first.endUTC)
		End if
		If ($first.allDay)
			$start:=$start+" (all day)"
		End if
	End if
	$row:=New object("summary"; $summary; "start"; $start; "end"; $end; "countText"; String($resource.eventCount); "url"; $resource.url; "etag"; $resource.etag; "icalendar"; $resource.icalendar)

// ---------------------------------------------------------------------------
// Page 1 — server and discovery
// ---------------------------------------------------------------------------

Function onLoad()

	This.checkComponent()
	This.discoverDemo()

Function checkComponent()

	var $result : Object
	If (Not(This.hasComponent()))
		This.versionText:="component not loaded — stage CalDAV.4dbase in Components/ beside Project/"
		return
	End if
	$result:=This.calendarController().version()
	If ($result.ok)
		This.versionText:="component "+String($result.value.version)+" · protocol "+String($result.value.protocol)
	Else
		This.versionText:="component unavailable — "+This.describe($result)
	End if

Function discoverDemo()

	var $request; $result : Object
	var $calendars : Collection
	var $item : Object
	$request:=This.connectionRequest()
	$result:=This.invoke("discover"; $request)
	If ($result.ok)
		$calendars:=New collection
		For each ($item; $result.value.data.calendars)
			$calendars.push(New object("name"; $item.name; "componentsText"; This.joinComponents($item.components); "descriptionText"; $item.description; "url"; $item.url))
		End for each
		This.calendars:=$calendars
		This.principalURL:=String($result.value.data.principalURL)
		This.homeURL:=String($result.value.data.homeURL)
		This.selectedCalendar:=Null
		This.resources:=New collection
		This.selectedResource:=Null
		This.detailText:="Select a resource on the Query page."
		If ($calendars.length>0)
			This.selectedCalendar:=$calendars[0]
			This.selectionText:="Selected "+String(This.selectedCalendar.name)+" — "+String(This.selectedCalendar.url)
		End if
		This.statusText:="Discovered "+String($calendars.length)+" calendar(s) under "+This.homeURL
		This.queryDemo()
	Else
		This.calendars:=New collection
		This.selectedCalendar:=Null
		This.selectionText:="No calendar selected yet. Press Discover."
		This.resources:=New collection
		This.selectedResource:=Null
		This.principalURL:=""
		This.homeURL:=""
		If (String($result.error.code)="component_missing")
			This.statusText:="Discovery failed. "+This.describe($result)
		Else
			This.statusText:="Discovery failed. Is scripts/mock_caldav.py running? "+This.describe($result)
		End if
	End if

Function selectCalendar()

	If (Value type(This.selectedCalendar)=Is object)
		This.selectionText:="Selected "+String(This.selectedCalendar.name)+" — "+String(This.selectedCalendar.url)
		This.statusText:="Calendar: "+String(This.selectedCalendar.name)
		If (Length(This.targetURL)>0)
			// Keep the mutation target consistent with the chosen calendar.
			This.targetURL:=""
			This.targetETag:=""
		End if
	End if

// ---------------------------------------------------------------------------
// Page 2 — query and get
// ---------------------------------------------------------------------------

// $silent refreshes the list after a mutation without stealing the status line
// from the operation that caused the refresh.
Function queryDemo($silent : Boolean)

	var $request; $result : Object
	var $rows : Collection
	var $item : Object
	If (Value type(This.selectedCalendar)#Is object)
		This.statusText:="Select a calendar on the Server page first."
		return
	End if
	$request:=This.connectionRequest()
	$request.url:=This.selectedCalendar.url
	$request.start:=This.startText
	$request.end:=This.endText
	$result:=This.invoke("query"; $request)
	If ($result.ok)
		$rows:=New collection
		For each ($item; $result.value.data.resources)
			$rows.push(This.toRow($item))
		End for each
		This.resources:=$rows
		This.selectedResource:=Null
		This.detailText:="No resource in this window."
		If ($rows.length>0)
			This.selectedResource:=$rows[0]
			This.showResource()
		End if
		If (Not($silent))
			This.statusText:="Query on "+String(This.selectedCalendar.name)+" returned "+String($rows.length)+" resource(s)"
		End if
	Else
		This.resources:=New collection
		This.selectedResource:=Null
		This.detailText:=""
		This.statusText:="Query failed — "+This.describe($result)
	End if

Function selectResource()

	This.showResource()

Function showResource()

	var $resource : Object
	var $text : Text
	If (Value type(This.selectedResource)#Is object)
		This.detailText:="Select a resource in the list."
		return
	End if
	$resource:=This.selectedResource
	$text:="URL"+Char(13)+String($resource.url)+Char(13)+Char(13)
	$text:=$text+"ETag"+Char(13)+String($resource.etag)+Char(13)+Char(13)
	$text:=$text+"events in this resource"+Char(13)+String($resource.countText)+Char(13)+Char(13)
	$text:=$text+"----- raw iCalendar, exactly as served -----"+Char(13)+String($resource.icalendar)
	This.detailText:=$text
	This.targetURL:=String($resource.url)
	This.targetETag:=String($resource.etag)

Function getResource()

	var $request; $result : Object
	If (Value type(This.selectedResource)#Is object)
		This.statusText:="Select a resource in the list first."
		return
	End if
	$request:=This.connectionRequest()
	$request.url:=This.selectedResource.url
	$result:=This.invoke("get"; $request)
	If ($result.ok)
		This.selectedResource:=This.toRow($result.value.data)
		This.showResource()
		This.statusText:="Get returned "+String($result.value.data.eventCount)+" event(s) with ETag "+String($result.value.data.etag)
	Else
		This.statusText:="Get failed — "+This.describe($result)
	End if

// ---------------------------------------------------------------------------
// Page 3 — offline build and inspect
// ---------------------------------------------------------------------------

Function buildDemo()

	var $result : Object
	$result:=This.invoke("build"; New object("event"; This.eventRequest()))
	If ($result.ok)
		This.icalendarText:=String($result.value.data.icalendar)
		This.statusText:="build produced "+String($result.value.data.eventCount)+" event(s); edit the text to break it on purpose"
	Else
		This.statusText:="Build failed — "+This.describe($result)
	End if

Function inspectDemo()

	var $request; $result : Object
	var $text : Text
	var $event : Object
	$request:=New object("icalendar"; This.icalendarText)
	$result:=This.invoke("inspect"; $request)
	If ($result.ok)
		$text:="eventCount "+String($result.value.data.eventCount)+Char(13)+Char(13)
		For each ($event; $result.value.data.events)
			$text:=$text+"UID            "+String($event.uid)+Char(13)
			$text:=$text+"SUMMARY        "+String($event.summary)+Char(13)
			$text:=$text+"DTSTART        "+String($event.start)+Char(13)
			$text:=$text+"DTEND          "+String($event.end)+Char(13)
			$text:=$text+"allDay         "+String($event.allDay)+Char(13)
			$text:=$text+"timezone       "+String($event.timezone)+Char(13)
			$text:=$text+"RRULE          "+String($event.rrule)+Char(13)
			$text:=$text+"RECURRENCE-ID  "+String($event.recurrenceId)+Char(13)
			$text:=$text+Char(13)
		End for each
		This.inspectText:=$text
		This.statusText:="inspect parsed "+String($result.value.data.eventCount)+" event(s) locally — no server involved"
	Else
		This.inspectText:="The CLI refused this document."+Char(13)+Char(13)+This.rawResponse($result)
		This.statusText:="Inspect failed — "+This.describe($result)
	End if

Function loadResourceText()

	If (Value type(This.selectedResource)=Is object)
		This.icalendarText:=String(This.selectedResource.icalendar)
		This.statusText:="Loaded the selected resource into the editable text"
	Else
		This.statusText:="Select a resource on the Query page first."
	End if

// ---------------------------------------------------------------------------
// Page 4 — create, update, delete, conflict
// ---------------------------------------------------------------------------

Function createDemo()

	var $calendar : Object
	var $build; $request; $result : Object
	var $created : Text
	$calendar:=This.selectedCalendar
	If (Value type($calendar)#Is object)
		This.statusText:="Select a calendar on the Server page first."
		return
	End if
	$build:=This.invoke("build"; New object("event"; This.eventRequest()))
	If (Not($build.ok))
		This.statusText:="Build failed — "+This.describe($build)
		return
	End if
	This.icalendarText:=String($build.value.data.icalendar)
	$request:=This.connectionRequest()
	$request.url:=This.resourceURL(String($calendar.url); "demo-")
	$request.icalendar:=String($build.value.data.icalendar)
	$result:=This.invoke("create"; $request)
	If ($result.ok)
		$created:=String($result.value.data.url)
		This.targetURL:=$created
		This.targetETag:=String($result.value.data.etag)
		This.resultText:="created"+Char(13)+This.targetURL+Char(13)+Char(13)+"etag"+Char(13)+This.targetETag
		This.statusText:="Created "+This.targetURL
		This.queryDemo(True)
		This.selectURL($created)
	Else
		This.statusText:="Create failed — "+This.describe($result)
	End if

// queryDemo selects the first row; after a mutation the interesting row is the
// one that was just written, so put the selection back on that URL.
Function selectURL($url : Text)

	var $row : Object
	For each ($row; This.resources)
		If (String($row.url)=$url)
			This.selectedResource:=$row
			This.showResource()
			return
		End if
	End for each

Function updateDemo()

	var $get; $request; $result : Object
	var $ical; $old; $new; $updated : Text
	If (Value type(This.selectedResource)#Is object)
		This.statusText:="Select a resource on the Query page first."
		return
	End if
	// Re-read before writing: a strong precondition needs the current ETag.
	$request:=This.connectionRequest()
	$request.url:=This.selectedResource.url
	$get:=This.invoke("get"; $request)
	If (Not($get.ok))
		This.statusText:="Get failed — "+This.describe($get)
		return
	End if
	$ical:=String($get.value.data.icalendar)
	$old:=String($get.value.data.events[0].summary)
	$new:=This.summary
	If (Length($new)=0)
		$new:="Updated by the demo"
	End if
	If ($new=$old)
		This.statusText:="The summary already reads \""+$old+"\" — edit it before writing."
		return
	End if
	// Replace the first SUMMARY line only: a series keeps its exception text.
	// A text search for the old summary would miss escaped (A\, B) or folded
	// lines and then PUT the body back unchanged.
	$ical:=This.replaceSummary($ical; $new)
	If (Length($ical)=0)
		This.statusText:="No SUMMARY property found in the resource — nothing was written."
		return
	End if
	$request.icalendar:=$ical
	$request.etag:=String($get.value.data.etag)
	$result:=This.invoke("update"; $request)
	If ($result.ok)
		$updated:=String($result.value.data.url)
		This.targetURL:=$updated
		This.resultText:="updated"+Char(13)+$updated+Char(13)+Char(13)+"new etag"+Char(13)+String($result.value.data.etag)
		// Report what happened, not what was expected: a server may keep the ETag.
		If (String($result.value.data.etag)#String($request.etag))
			This.statusText:="Updated "+$updated+" — the ETag rotated"
		Else
			This.statusText:="Updated "+$updated+" — the server kept the same ETag"
		End if
		This.targetETag:=String($result.value.data.etag)
		This.queryDemo(True)
		This.selectURL($updated)
	Else
		This.statusText:="Update failed — "+This.describe($result)
	End if

// Escape a value for an iCalendar TEXT property (RFC 5545 section 3.3.11).
Function escapeText($value : Text)->$text : Text

	$text:=Replace string($value; "\\"; "\\\\")
	$text:=Replace string($text; ";"; "\\;")
	$text:=Replace string($text; ","; "\\,")
	$text:=Replace string($text; Char(13)+Char(10); "\\n")
	$text:=Replace string($text; Char(13); "\\n")
	$text:=Replace string($text; Char(10); "\\n")

// Return $ical with the value of its first SUMMARY property replaced, or "" if
// it has none. Lines are unfolded first so a folded SUMMARY is found whole.
Function replaceSummary($ical : Text; $value : Text)->$out : Text

	var $unfolded : Text
	var $lines : Collection
	var $line : Text
	var $index; $colon : Integer
	var $found : Boolean
	$out:=""
	$unfolded:=Replace string($ical; Char(13)+Char(10)+" "; "")
	$unfolded:=Replace string($unfolded; Char(13)+Char(10)+Char(9); "")
	$unfolded:=Replace string($unfolded; Char(10)+" "; "")
	$lines:=Split string($unfolded; Char(13)+Char(10))
	If ($lines.length<2)
		$lines:=Split string($unfolded; Char(10))
	End if
	$found:=False
	For ($index; 0; $lines.length-1)
		$line:=$lines[$index]
		If (Not($found))
			If ((Position("SUMMARY:"; $line)=1) | (Position("SUMMARY;"; $line)=1))
				$colon:=Position(":"; $line)
				$lines[$index]:=Substring($line; 1; $colon)+This.escapeText($value)
				$found:=True
			End if
		End if
	End for
	If ($found)
		$out:=$lines.join(Char(13)+Char(10))
		If (Substring($out; Length($out)-1; 2)#(Char(13)+Char(10)))
			$out:=$out+Char(13)+Char(10)
		End if
	End if

Function deleteDemo()

	var $get; $request; $result : Object
	If (Value type(This.selectedResource)#Is object)
		This.statusText:="Select a resource on the Query page first."
		return
	End if
	$request:=This.connectionRequest()
	$request.url:=This.selectedResource.url
	$get:=This.invoke("get"; $request)
	If (Not($get.ok))
		This.statusText:="Get failed — "+This.describe($get)
		return
	End if
	$request.etag:=String($get.value.data.etag)
	$result:=This.invoke("delete"; $request)
	If ($result.ok)
		This.resultText:="deleted"+Char(13)+String($request.url)+Char(13)+Char(13)+"with etag"+Char(13)+String($request.etag)
		This.targetURL:=""
		This.targetETag:=""
		This.statusText:="Deleted "+String($request.url)
		This.queryDemo(True)
	Else
		This.statusText:="Delete failed — "+This.describe($result)
	End if

// The showcase for the failure mode that matters: an ETag that is no longer
// current is refused with HTTP 412, and the component reports it as conflict.
Function conflictDemo()

	var $calendar : Object
	var $build; $request; $result : Object
	var $stale; $fresh; $report : Text
	$calendar:=This.selectedCalendar
	If (Value type($calendar)#Is object)
		This.statusText:="Select a calendar on the Server page first."
		return
	End if
	$build:=This.invoke("build"; New object("event"; This.eventRequest()))
	If (Not($build.ok))
		This.statusText:="Build failed — "+This.describe($build)
		return
	End if
	$request:=This.connectionRequest()
	$request.url:=This.resourceURL(String($calendar.url); "conflict-")
	$request.icalendar:=String($build.value.data.icalendar)
	$result:=This.invoke("create"; $request)
	If (Not($result.ok))
		This.statusText:="Create failed — "+This.describe($result)
		return
	End if
	$stale:=String($result.value.data.etag)
	$report:="1. created with etag "+$stale+Char(13)

	// First writer: conditional on the ETag it just received, so it succeeds.
	// The body has to change as well: a byte-identical PUT keeps the same ETag,
	// and then the "stale" value below would still be current.
	$request.etag:=$stale
	$request.icalendar:=Replace string(String($build.value.data.icalendar); "SUMMARY:"; "SUMMARY:First writer "; 1)
	$result:=This.invoke("update"; $request)
	If (Not($result.ok))
		This.resultText:=$report+"first update failed — "+This.describe($result)
		This.statusText:="Conflict demo stopped after the first update."
		return
	End if
	$fresh:=String($result.value.data.etag)
	$report:=$report+"2. updated once, server returned a new etag "+$fresh+Char(13)

	// Second writer: different content, still holding the old ETag — this must be
	// refused. The content has to change, because an identical body keeps the
	// same ETag and the stale precondition would look current.
	$request.etag:=$stale
	$request.icalendar:=Replace string(String($build.value.data.icalendar); "SUMMARY:"; "SUMMARY:Conflicting writer "; 1)
	$result:=This.invoke("update"; $request)
	$report:=$report+"3. replayed the stale etag "+$stale+Char(13)
	If ($result.ok)
		$report:=$report+"   unexpected: the server accepted a stale write"+Char(13)
		This.statusText:="The mock accepted a stale write — that is a bug."
	Else
		$report:=$report+"   refused: "+This.describe($result)+Char(13)
		$report:=$report+"   component ok="+String($result.ok)+Char(13)
		$report:=$report+"   CLI stdout"+Char(13)+String($result.stdout)+Char(13)
		$report:=$report+"   CLI stderr"+Char(13)+String($result.stderr)
		This.statusText:="412 conflict demonstrated — the stale write was refused, not silently applied"
	End if

	// Leave the collection as we found it.
	$request.etag:=$fresh
	$result:=This.invoke("delete"; $request)
	If ($result.ok)
		$report:=$report+Char(13)+"4. cleaned up the scratch resource"
	End if
	This.resultText:=$report
	This.queryDemo(True)
