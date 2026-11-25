// Start — the project entry point. Called with no parameter by On Startup and
// by the "CalDAV demo" menu item; called with a parameter by itself, through
// CALL WORKER, so the window lives in the application process.
#DECLARE($params : Object)

var $title : Text
var $window : Integer
var $i : Integer
var $left; $top; $right; $bottom : Integer
$title:="CalDAV demo"

If (Count parameters=0)

	// Already open? Bring it to the front instead of opening a duplicate.
	ARRAY LONGINT($windows; 0)
	WINDOW LIST($windows)
	For ($i; 1; Size of array($windows))
		$window:=$windows{$i}
		If (Window process($window)=1) && (Get window title($window)=$title)
			GET WINDOW RECT($left; $top; $right; $bottom; $window)
			CALL FORM($window; Formula(SET WINDOW RECT($left; $top; $right; $bottom; $window)))
			return 
		End if 
	End for 

	CALL WORKER(1; Current method name; {})

Else 

	SET MENU BAR(1)
	$window:=Open form window("Main"; Plain form window; Horizontally centered; Vertically centered)
	SET WINDOW TITLE($title; $window)
	DIALOG("Main"; $params; *)

End if 
