#+build linux, windows
package agentic_design

import "core:time"

// What the macOS-only files (*_darwin.odin) give the shared code, on Linux and Windows,
// where it is the same on both: mostly "nothing to do". The rest is per system in
// desktop_linux.odin and desktop_windows.odin.

// activity_darwin.odin: no App Nap to hold off, only the time of the last request.
agent_activity: struct {
	last: time.Tick,
}
agent_activity_touch :: proc() {agent_activity.last = time.tick_now()}
agent_activity_tick :: proc() {}

// app_menu_darwin.odin: no application menu; What's New is opened from Settings.
app_menu_install :: proc() {}
app_menu_click_whats_new :: proc() -> bool {return false}

// open_events_darwin.odin: documents arrive as arguments (fs_args), never as events.
install_open_handler :: proc() {}
handle_open_requests :: proc() {}

// gestures_darwin.odin: GLFW's scroll events are all there is (pinch zoom is Ctrl+wheel).
gestures_install :: proc() {}
gestures_collect :: proc() {}

// A quiet (test) window opens behind the others on a Mac; elsewhere it opens unfocused.
platform_order_back :: proc() {}

// clipboard_darwin.odin: GLFW's clipboard holds text only, so a copy as PNG or HTML puts
// its text version there; pasting images and files is not supported yet.
clipboard_set :: proc(data: []u8, uti: string, text := "") {
	if text != "" do platform_clipboard_set(text)
}
clipboard_image_png :: proc(allocator := context.allocator) -> []u8 {return nil}
clipboard_file_path :: proc() -> string {return ""}
