#+build linux, windows
package agentic_design

import "core:encoding/json"
import "core:strings"
import nvg "nanovg"

// Updates on Windows and Linux: none yet. The macOS updater (update.odin) swaps a signed
// .app bundle; these builds are updated by downloading the next one. The same names as
// update.odin, so Settings and the socket work unchanged.

Update_Phase :: enum i32 {
	Idle,
	Checking,
	Up_To_Date,
	Downloading,
	Ready,
	Waiting_For_Agents,
	Installing,
	Failed,
}

update: struct {
	version: string,
	error:   string,
}

update_allowed :: proc() -> bool {return false}
update_phase :: proc() -> Update_Phase {return .Idle}
update_tick :: proc() {}
update_check :: proc() {}
update_request_install :: proc() {}
draw_update_button :: proc(vg: ^nvg.Context, right: f32) -> f32 {return 0}

api_update :: proc(b: ^strings.Builder, params: json.Object) -> string {
	return "updates are only built into the macOS app; download the next release"
}
