#+build js
package agentic_design

import "base:runtime"
import nvg "nanovg"

// What the shared interface asks of the desktop-only files (#+build !js), in a browser:
// there is no control socket, updater, onboarding, macOS sheet or agent, so each answer is
// "nothing to do". The desktop files are the real ones.

// server.odin, api.odin: agents' requests and their screenshots
Request :: struct {}
Shot :: struct {
	req: ^Request,
	uid: int,
}
shot: Shot
server_listening: bool
server_port :: proc() -> int {return 0}
server_start :: proc() {}
process_requests :: proc() -> bool {return false}
posix_ignore_sigpipe :: proc() {}
shot_pending :: proc() -> bool {return false}
view_shot_pending :: proc() -> bool {return false}
capture_view :: proc() {}
render_screenshot :: proc() {}
undo_suppressed: bool

// applog.odin
Exit_Signal :: enum i32 {
	None,
}
exit_signal: Exit_Signal
app_log :: proc(format: string, args: ..any) {}
install_exit_handlers :: proc() {}

// memory.odin: the default allocators
big_allocator :: proc "contextless" () -> runtime.Allocator {return editor_context.allocator}
use_big_allocator_for_temp :: proc() {}
memory_trim :: proc() -> uint {return 0}

// activity_darwin.odin, process_desktop.odin: agents
agent_activity_touch :: proc() {}
agent_activity_tick :: proc() {}
background_tick :: proc() {}
agent_tick :: proc() {}
annotate_input :: proc(over_canvas: bool, page: [2]f32) -> bool {return false}
draw_annotations :: proc(vg: ^nvg.Context) {}
agents_stop_all :: proc() {}
agent_history_clear :: proc() {}
agent_user_edit :: proc(path: string) {}
agent_chrome_hit :: proc(p: [2]f32) -> bool {return false}
draw_agent_input :: proc(vg: ^nvg.Context) {}
agent_input_reserve :: proc() -> f32 {return 0}
agent_process_gone :: proc(id: string) -> bool {return false}

// open_events_darwin.odin: documents the system asks to open
handle_open_requests :: proc() {}

// update.odin: updates come with the page
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

// onboarding.odin
Onboarding :: struct {
	open: bool,
	step: int,
}
onboarding: Onboarding
onboarding_start :: proc(step := 0) {}
onboarding_maybe_start :: proc() {}
draw_onboarding :: proc(vg: ^nvg.Context) {}

// whats_new.odin
whats_new: struct {
	open: bool,
}
whats_new_launch :: proc() {}
whats_new_show :: proc() {}
draw_whats_new :: proc(vg: ^nvg.Context) {}

// share_ui.odin: the web has its own Share (web/upload.js)
share_open: bool
share_sheet_open :: proc() {}
share_tick :: proc() {}
draw_share_sheet :: proc(vg: ^nvg.Context) {}

// clipboard_darwin.odin: copy as PNG or HTML (the text goes through platform_clipboard_set)
clipboard_set :: proc(data: []u8, uti: string, text := "") {
	if text != "" do platform_clipboard_set(text)
}

// files_dialogs_darwin.odin, export_dialogs_darwin.odin: the page's pickers and downloads come
// with the editor's host
import_font_dialog :: proc() {}
import_library_dialog :: proc() {}
place_image_dialog :: proc() {}
ask_save_path :: proc(name: string, types: []string) -> (path: string, ok: bool) {return}
ask_folder :: proc() -> (dir: string, ok: bool) {return}
reveal_in_finder :: proc(path: string) {}

// dashboard.odin, files_index.odin: the web editor has no file system to list
draw_dashboard :: proc(vg: ^nvg.Context) {}
dash_field_apply :: proc(key, text: string) -> bool {return false}
dash_cloud_tick :: proc() {}
draw_settings_account :: proc(vg: ^nvg.Context, x, w: f32, y: ^f32) {
	label(vg, x, y^ + 10, "The cloud account is in the Mac app.", TEXT_DIM, 12)
}

// whats_new.odin: settings are kept by the page
settings_test_writes :: proc() -> bool {return false}

// agent_panel.odin: the web editor has no agents
annot_leave_agent_mode :: proc() {}
draw_agent_panel :: proc(vg: ^nvg.Context) {}
draw_mode_switch :: proc(vg: ^nvg.Context, x: f32) -> f32 {return x}
draw_marks_bar :: proc(vg: ^nvg.Context) {}
agent_focus_keys :: proc() {}
