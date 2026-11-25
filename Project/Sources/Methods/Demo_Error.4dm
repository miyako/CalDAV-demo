// Demo_Error — error handler for headless runs ($1=2 is the runtime error).
// Printing the failure is the difference between "exited 1 with no output" and
// a diagnosable run.
If ($1=2)
	LOG EVENT(Into system standard outputs; "failed in "+Error method+" ("+String(Error code)+"): "+Error description)
End if 
