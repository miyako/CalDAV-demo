// Main form method — all state lives in the form class (formClass: DemoForm).
// A form class does not receive events by itself: this method is the bridge.
Case of 
	: (FORM Event code=On Load)
		// Form is the DemoForm instance; the constructor already seeded defaults.
		Form.onLoad()
End case 
