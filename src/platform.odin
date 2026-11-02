package agentic_design


import "core:c"
import "core:os"
import "core:strings"
import "vendor:glfw"
import "engine"

// Window and input on top of GLFW. Events arrive through callbacks between
// two PollEvents calls; this module turns them into per-frame state that the
// rest of the app polls (key_pressed, mouse_pressed, pf.wheel, ...).

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
	window:         glfw.WindowHandle,
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
	cursors:        [Cursor]glfw.CursorHandle,
	cursor:         Cursor,
	first_frame:    bool,
	refresh:        f64, // the display's frames per second (frames are never drawn faster)
	pointer_moved:  bool, // macOS reported the pointer moving over the window, or entering or leaving it
}

pf: Platform

platform_init :: proc(width, height: int, title: cstring) -> bool {
	install_open_handler() // before glfwInit: a launch's files arrive while it finishes launching
	if !glfw.Init() do return false
	when engine.RENDERER == "gl" {
		glfw.WindowHint_int(glfw.CONTEXT_VERSION_MAJOR, 3)
		glfw.WindowHint_int(glfw.CONTEXT_VERSION_MINOR, 2)
		glfw.WindowHint_int(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint_bool(glfw.OPENGL_FORWARD_COMPAT, true)
		// NanoVG antialiases its own edges, and draws with the stencil buffer alone: no
		// multisampling (4× would hold 4 colour and 4 depth-stencil values per pixel) and
		// no depth buffer, which together took some 200 MB of video memory on a Retina
		// window
		glfw.WindowHint_int(glfw.SAMPLES, 0)
		glfw.WindowHint_int(glfw.DEPTH_BITS, 0)
		glfw.WindowHint_int(glfw.STENCIL_BITS, 8)
	} else {
		glfw.WindowHint_int(glfw.CLIENT_API, glfw.NO_API) // WebGPU draws into a Metal layer
	}
	glfw.WindowHint_bool(glfw.RESIZABLE, true)
	glfw.WindowHint_bool(glfw.COCOA_RETINA_FRAMEBUFFER, true)
	// AGENTIC_QUIET: open behind other windows without taking focus (tests);
	// AGENTIC_NO_FOCUS: open in front but leave the keyboard focus where it is (agents).
	quiet := os.get_env("AGENTIC_QUIET", context.temp_allocator) != ""
	pf.quiet = quiet
	no_focus := quiet || os.get_env("AGENTIC_NO_FOCUS", context.temp_allocator) != ""
	pf.no_focus = no_focus
	glfw.WindowHint_bool(glfw.FOCUSED, !no_focus)
	glfw.WindowHint_bool(glfw.FOCUS_ON_SHOW, !no_focus)
	pf.window = glfw.CreateWindow(c.int(width), c.int(height), title, nil, nil)
	if pf.window == nil {
		glfw.Terminate()
		return false
	}
	if quiet do platform_order_back()
	when engine.RENDERER == "gl" {
		glfw.MakeContextCurrent(pf.window)
		glfw.SwapInterval(1)
	}
	pf.refresh = 60
	// (no monitor while the displays sleep: GetVideoMode(nil) would crash)
	if monitor := glfw.GetPrimaryMonitor(); monitor != nil {
		if mode := glfw.GetVideoMode(monitor); mode != nil && mode.refresh_rate > 0 do pf.refresh = f64(mode.refresh_rate)
	}
	glfw.SetKeyCallback(pf.window, key_callback)
	glfw.SetCharCallback(pf.window, char_callback)
	glfw.SetDropCallback(pf.window, drop_callback)
	glfw.SetMouseButtonCallback(pf.window, mouse_button_callback)
	glfw.SetScrollCallback(pf.window, scroll_callback)
	glfw.SetCursorPosCallback(pf.window, proc "c" (window: glfw.WindowHandle, x, y: f64) {pf.pointer_moved = true})
	glfw.SetCursorEnterCallback(pf.window, proc "c" (window: glfw.WindowHandle, entered: c.int) {pf.pointer_moved = true})
	// live resize: draw at every size step instead of letting macOS stretch the last frame
	glfw.SetFramebufferSizeCallback(pf.window, framebuffer_size_callback)
	glfw.SetWindowRefreshCallback(pf.window, window_refresh_callback)
	gestures_install()

	shapes := [Cursor]c.int {
		.Default    = glfw.ARROW_CURSOR,
		.IBeam      = glfw.IBEAM_CURSOR,
		.Crosshair  = glfw.CROSSHAIR_CURSOR,
		.Hand       = glfw.POINTING_HAND_CURSOR,
		.Resize_All = glfw.RESIZE_ALL_CURSOR,
		.Resize_H   = glfw.RESIZE_EW_CURSOR,
	}
	for shape, cur in shapes do pf.cursors[cur] = glfw.CreateStandardCursor(shape)
	pf.first_frame = true
	return true
}

platform_shutdown :: proc() {
	glfw.DestroyWindow(pf.window)
	glfw.Terminate()
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = app_context()
	live_redraw()
}

window_refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = app_context()
	live_redraw()
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	if key < 0 || int(key) >= MAX_KEYS do return
	switch action {
	case glfw.PRESS:
		pf.key_down[key] = true
		pf.key_pressed[key] = true
		pf.key_repeated[key] = true
	case glfw.REPEAT:
		pf.key_repeated[key] = true
	case glfw.RELEASE:
		pf.key_down[key] = false
	}
}

char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = app_context()
	append(&pf.chars, codepoint)
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
	if button < 0 || int(button) >= MAX_BUTTONS do return
	if action == glfw.PRESS {
		pf.button_down[button] = true
		pf.button_pressed[button] = true
	} else if action == glfw.RELEASE {
		pf.button_down[button] = false
	}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	pf.wheel += {f32(xoffset), f32(yoffset)}
}

// Clears the per-frame state and pumps the event queue; with `wait` > 0 it first sleeps
// until an event arrives or `wait` seconds pass (the app idling, see idle_wait).
platform_poll :: proc(wait: f64 = 0) {
	pf.key_pressed = {}
	pf.key_repeated = {}
	pf.button_pressed = {}
	pf.wheel = {}
	pf.scroll = {}
	pf.magnify = 0
	pf.smart = false
	clear(&pf.chars)
	for k in pf.synthetic_keys do pf.key_down[k] = false
	clear(&pf.synthetic_keys)
	pf.mouse_prev = pf.mouse
	pf.pointer_moved = false
	pf.polling = true
	if wait > 0 do glfw.WaitEventsTimeout(wait)
	else do glfw.PollEvents()
	pf.polling = false
	gestures_collect()
	x, y := glfw.GetCursorPos(pf.window)
	pf.mouse = {f32(x), f32(y)}
	if pf.synthetic do pf.mouse = pf.synthetic_pos
	if pf.first_frame {
		pf.mouse_prev = pf.mouse
		pf.first_frame = false
	}
}

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

// Wakes the main loop from WaitEventsTimeout (safe from any thread).
platform_wake :: proc() {
	glfw.PostEmptyEvent()
}

platform_should_close :: proc() -> bool {
	return bool(glfw.WindowShouldClose(pf.window))
}

platform_swap :: proc() {
	when engine.RENDERER == "gl" do glfw.SwapBuffers(pf.window)
	else do engine.gpu_present()
}

platform_window_size :: proc() -> [2]f32 {
	w, h := glfw.GetWindowSize(pf.window)
	return {f32(w), f32(h)}
}

platform_framebuffer_size :: proc() -> [2]i32 {
	w, h := glfw.GetFramebufferSize(pf.window)
	return {i32(w), i32(h)}
}

platform_set_title :: proc(title: cstring) {
	glfw.SetWindowTitle(pf.window, title)
}

platform_set_cursor :: proc(cur: Cursor) {
	if cur == pf.cursor do return
	pf.cursor = cur
	glfw.SetCursor(pf.window, pf.cursors[cur])
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
	return pf.mouse - pf.mouse_prev
}

mod_cmd :: proc() -> bool {
	return key_down(KEY_LEFT_SUPER) || key_down(KEY_RIGHT_SUPER) || key_down(KEY_LEFT_CONTROL) || key_down(KEY_RIGHT_CONTROL)
}

mod_shift :: proc() -> bool {
	return key_down(KEY_LEFT_SHIFT) || key_down(KEY_RIGHT_SHIFT)
}

// What the renderer needs from the window: the GL context is current (GL), or the
// window's content view has a CAMetalLayer to draw into (WebGPU).
platform_gpu_surface :: proc() -> engine.Gpu_Surface {
	when engine.RENDERER == "gl" do return {set_proc_address = glfw.gl_set_proc_address}
	else do return {metal_layer = platform_metal_layer(pf.window)}
}

// Seconds on GLFW's clock (the frame pacing and the agents' cursors read it).
platform_time :: proc() -> f64 {
	return glfw.GetTime()
}

// The system clipboard as text.
platform_clipboard_set :: proc(text: string) {
	glfw.SetClipboardString(pf.window, strings.clone_to_cstring(text, context.temp_allocator))
}

platform_clipboard_get :: proc() -> string {
	return string(glfw.GetClipboardString(pf.window))
}

platform_set_window_pos :: proc(x, y: int) {
	glfw.SetWindowPos(pf.window, i32(x), i32(y))
}

// Asks the main loop to end (as the window's close button does).
platform_request_close :: proc() {
	glfw.SetWindowShouldClose(pf.window, true)
}

// Files dropped on the window land where the pointer is (files_ui.odin, handle_drops).
drop_callback :: proc "c" (window: glfw.WindowHandle, count: c.int, paths: [^]cstring) {
	context = app_context()
	for i in 0 ..< int(count) do append(&pf.dropped, strings.clone(string(paths[i])))
}

// keys.odin's numbers are GLFW's: checked at compile time on the desktop build
#assert(KEY_0 == glfw.KEY_0)
#assert(KEY_1 == glfw.KEY_1)
#assert(KEY_2 == glfw.KEY_2)
#assert(KEY_A == glfw.KEY_A)
#assert(KEY_APOSTROPHE == glfw.KEY_APOSTROPHE)
#assert(KEY_B == glfw.KEY_B)
#assert(KEY_BACKSPACE == glfw.KEY_BACKSPACE)
#assert(KEY_C == glfw.KEY_C)
#assert(KEY_COMMA == glfw.KEY_COMMA)
#assert(KEY_D == glfw.KEY_D)
#assert(KEY_DELETE == glfw.KEY_DELETE)
#assert(KEY_DOWN == glfw.KEY_DOWN)
#assert(KEY_E == glfw.KEY_E)
#assert(KEY_END == glfw.KEY_END)
#assert(KEY_ENTER == glfw.KEY_ENTER)
#assert(KEY_EQUAL == glfw.KEY_EQUAL)
#assert(KEY_ESCAPE == glfw.KEY_ESCAPE)
#assert(KEY_F == glfw.KEY_F)
#assert(KEY_G == glfw.KEY_G)
#assert(KEY_H == glfw.KEY_H)
#assert(KEY_HOME == glfw.KEY_HOME)
#assert(KEY_K == glfw.KEY_K)
#assert(KEY_KP_ENTER == glfw.KEY_KP_ENTER)
#assert(KEY_LEFT == glfw.KEY_LEFT)
#assert(KEY_LEFT_ALT == glfw.KEY_LEFT_ALT)
#assert(KEY_LEFT_BRACKET == glfw.KEY_LEFT_BRACKET)
#assert(KEY_LEFT_CONTROL == glfw.KEY_LEFT_CONTROL)
#assert(KEY_LEFT_SHIFT == glfw.KEY_LEFT_SHIFT)
#assert(KEY_LEFT_SUPER == glfw.KEY_LEFT_SUPER)
#assert(KEY_MINUS == glfw.KEY_MINUS)
#assert(KEY_N == glfw.KEY_N)
#assert(KEY_O == glfw.KEY_O)
#assert(KEY_P == glfw.KEY_P)
#assert(KEY_R == glfw.KEY_R)
#assert(KEY_RIGHT == glfw.KEY_RIGHT)
#assert(KEY_RIGHT_ALT == glfw.KEY_RIGHT_ALT)
#assert(KEY_RIGHT_BRACKET == glfw.KEY_RIGHT_BRACKET)
#assert(KEY_RIGHT_CONTROL == glfw.KEY_RIGHT_CONTROL)
#assert(KEY_RIGHT_SHIFT == glfw.KEY_RIGHT_SHIFT)
#assert(KEY_RIGHT_SUPER == glfw.KEY_RIGHT_SUPER)
#assert(KEY_S == glfw.KEY_S)
#assert(KEY_SLASH == glfw.KEY_SLASH)
#assert(KEY_SPACE == glfw.KEY_SPACE)
#assert(KEY_T == glfw.KEY_T)
#assert(KEY_TAB == glfw.KEY_TAB)
#assert(KEY_UP == glfw.KEY_UP)
#assert(KEY_V == glfw.KEY_V)
#assert(KEY_W == glfw.KEY_W)
#assert(KEY_X == glfw.KEY_X)
#assert(KEY_Z == glfw.KEY_Z)
#assert(MOUSE_BUTTON_LEFT == glfw.MOUSE_BUTTON_LEFT)
#assert(MOUSE_BUTTON_MIDDLE == glfw.MOUSE_BUTTON_MIDDLE)
#assert(MOUSE_BUTTON_RIGHT == glfw.MOUSE_BUTTON_RIGHT)
#assert(KEY_LAST == glfw.KEY_LAST)
#assert(MOD_SHIFT == glfw.MOD_SHIFT)
#assert(MOD_CONTROL == glfw.MOD_CONTROL)
#assert(MOD_ALT == glfw.MOD_ALT)
#assert(MOD_SUPER == glfw.MOD_SUPER)
