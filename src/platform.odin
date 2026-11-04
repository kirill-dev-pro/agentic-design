package agentic_design

import "core:c"

// Input state the interface polls each frame (key_pressed, mouse_pressed, pf.wheel, ...),
// filled by the host between frames: GLFW's callbacks on the desktop (platform_glfw.odin),
// the page's events in a browser.

Cursor :: enum {
	Default,
	IBeam,
	Crosshair,
	Hand,
	Resize_All,
	Resize_H,
}

MAX_KEYS :: 400
#assert(MAX_KEYS > KEY_LAST)
MAX_BUTTONS :: 8

Platform :: struct {
	using host:     Platform_Host, // the window and what else the host keeps (platform_glfw.odin)
	quiet:          bool, // test instance: no focus, no system dialogs
	no_focus:       bool, // opened without taking the keyboard (tests, agents)
	synthetic:      bool, // mouse position injected through the API (tests)
	synthetic_pos:  [2]f32,
	synthetic_keys: [dynamic]c.int, // keys held for one frame by the API
	polling:        bool, // inside glfwPollEvents (where a live resize runs)
	key_down:       [MAX_KEYS]bool,
	key_pressed:    [MAX_KEYS]bool, // went down this frame
	key_repeated:   [MAX_KEYS]bool, // went down or auto-repeated this frame
	chars:          [dynamic]rune,
	dropped:        [dynamic]string, // files dropped on the window since last frame
	open_requests:  [dynamic]string, // documents the system asked to open (open_events_darwin.odin)
	button_down:    [MAX_BUTTONS]bool,
	button_pressed: [MAX_BUTTONS]bool,
	mouse:          [2]f32,
	mouse_prev:     [2]f32,
	wheel:          [2]f32, // mouse wheel notches
	scroll:         [2]f32, // trackpad two-finger scroll, in points
	magnify:        f32, // pinch, relative scale change
	smart:          bool, // two-finger double tap
	cursor:         Cursor,
	first_frame:    bool,
	refresh:        f64, // the display's frames per second (frames are never drawn faster)
	pointer_moved:  bool, // macOS reported the pointer moving over the window, or entering or leaving it
}

pf: Platform

// Whether anything came in since the last frame: a key, a click, the pointer moving,
// scrolling, a gesture, typing or a dropped file (or a button still held).
platform_had_input :: proc() -> bool {
	// the pointer is read every frame wherever it is (over other apps too); only the moves
	// macOS sends to this window count
	if pf.pointer_moved || (pf.synthetic && pf.mouse != pf.mouse_prev) do return true
	if pf.wheel != {} || pf.scroll != {} || pf.magnify != 0 || pf.smart do return true
	if len(pf.chars) > 0 || len(pf.dropped) > 0 do return true
	for b in pf.button_down do if b do return true
	for b in pf.button_pressed do if b do return true
	for k in pf.key_repeated do if k do return true
	return false
}

key_down :: proc(key: c.int) -> bool {
	return pf.key_down[key]
}

key_pressed :: proc(key: c.int) -> bool {
	return pf.key_pressed[key]
}

// Pressed or auto-repeated this frame.
key_hit :: proc(key: c.int) -> bool {
	return pf.key_repeated[key]
}

mouse_down :: proc(button: c.int) -> bool {
	return pf.button_down[button]
}

mouse_pressed :: proc(button: c.int) -> bool {
	return pf.button_pressed[button]
}

mouse_delta :: proc() -> [2]f32 {
	return (pf.mouse - pf.mouse_prev) / ui_scale() // in the window's interface units
}

mod_cmd :: proc() -> bool {
	return key_down(KEY_LEFT_SUPER) || key_down(KEY_RIGHT_SUPER) || key_down(KEY_LEFT_CONTROL) || key_down(KEY_RIGHT_CONTROL)
}

mod_shift :: proc() -> bool {
	return key_down(KEY_LEFT_SHIFT) || key_down(KEY_RIGHT_SHIFT)
}
