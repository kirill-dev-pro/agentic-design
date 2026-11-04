#+build js
package agentic_design

import "base:runtime"
import "core:strings"
import "core:time"
import "engine"
import nvg "nanovg"

// The browser host of the interface: the page's canvas is the window. The page sends
// pointer, wheel, key and text events (the exports at the end of this file); they are
// queued and applied by platform_poll at the start of a frame, as GLFW's callbacks are
// between two PollEvents calls on the desktop. Key numbers are GLFW's (keys.odin,
// web/edit/keys.js). The page asks for each frame (requestAnimationFrame).

Platform_Host :: struct {
	vg:         ^nvg.Context, // created by the page's entry before app_start
	size:       [2]f32, // the canvas in CSS pixels
	dpr:        f32,
	started:    time.Tick,
	clipboard:  string, // the last text the page passed in (paste) or the app copied
	title:      string,
	close_asked: bool,
}

foreign import page "editor"

@(default_calling_convention = "contextless")
foreign page {
	page_set_cursor :: proc(cursor: i32) ---
	page_set_title :: proc(title: string) ---
	page_clipboard_write :: proc(text: string) ---
}

@(private = "file")
Event :: struct {
	kind:  enum u8 {Key_Down, Key_Up, Key_Repeat, Button_Down, Button_Up, Move, Wheel, Scroll, Magnify, Char},
	code:  i32,
	pos:   [2]f32,
}

@(private = "file")
queue: [dynamic]Event

platform_init :: proc(width, height: int, title: cstring) -> bool {
	pf.started = time.tick_now()
	pf.refresh = 60
	pf.first_frame = true
	return true
}

platform_shutdown :: proc() {}

platform_poll :: proc(wait: f64 = 0) {
	pf.key_pressed = {}
	pf.key_repeated = {}
	pf.button_pressed = {}
	pf.wheel = {}
	pf.scroll = {}
	pf.magnify = 0
	pf.smart = false
	clear(&pf.chars)
	pf.mouse_prev = pf.mouse
	pf.pointer_moved = false
	for e in queue {
		switch e.kind {
		case .Key_Down:
			if e.code >= 0 && int(e.code) < MAX_KEYS {
				pf.key_down[e.code] = true
				pf.key_pressed[e.code] = true
				pf.key_repeated[e.code] = true
			}
		case .Key_Repeat:
			if e.code >= 0 && int(e.code) < MAX_KEYS do pf.key_repeated[e.code] = true
		case .Key_Up:
			if e.code >= 0 && int(e.code) < MAX_KEYS do pf.key_down[e.code] = false
		case .Button_Down:
			if e.code >= 0 && int(e.code) < MAX_BUTTONS {
				pf.button_down[e.code] = true
				pf.button_pressed[e.code] = true
			}
			pf.mouse = e.pos
		case .Button_Up:
			if e.code >= 0 && int(e.code) < MAX_BUTTONS do pf.button_down[e.code] = false
			pf.mouse = e.pos
		case .Move:
			pf.mouse = e.pos
			pf.pointer_moved = true
		case .Wheel:
			pf.wheel += e.pos
		case .Scroll:
			pf.scroll += e.pos
		case .Magnify:
			pf.magnify += e.pos.x
		case .Char:
			append(&pf.chars, rune(e.code))
		}
	}
	clear(&queue)
	if pf.first_frame {
		pf.mouse_prev = pf.mouse
		pf.first_frame = false
	}
}

platform_wake :: proc() {}

platform_should_close :: proc() -> bool {
	return pf.close_asked
}

platform_swap :: proc() {
	engine.gpu_present()
}

platform_window_size :: proc() -> [2]f32 {
	return pf.size
}

platform_framebuffer_size :: proc() -> [2]i32 {
	return {i32(pf.size.x * pf.dpr + 0.5), i32(pf.size.y * pf.dpr + 0.5)}
}

platform_set_title :: proc(title: cstring) {
	page_set_title(string(title))
}

platform_set_cursor :: proc(cur: Cursor) {
	if cur == pf.cursor do return
	pf.cursor = cur
	page_set_cursor(i32(cur))
}

platform_gpu_surface :: proc() -> engine.Gpu_Surface {
	return {canvas = "#canvas"}
}

platform_gpu_create :: proc() -> ^nvg.Context {
	return pf.vg
}

// The interface's fonts: a browser has no system fonts to read, so Noto Sans, built into the
// engine (what the viewer draws text without a family with), serves as all three.
platform_load_fonts :: proc(vg: ^nvg.Context) {
	for name in ([3]string{"sans", "sans-bold", "ui"}) {
		if inst, ok := engine.varfont_instance(engine.NOTO_SANS, 0, {{"wght", 700 if name == "sans-bold" else 400}}); ok {
			nvg.CreateFontMem(vg, name, inst, true)
		}
	}
}

platform_time :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(pf.started))
}

platform_clipboard_set :: proc(text: string) {
	delete(pf.clipboard)
	pf.clipboard = strings.clone(text)
	page_clipboard_write(text)
}

// The page writes the system clipboard's text in before a paste (viewer_paste below), since
// a page can read the clipboard only in answer to the user's paste.
platform_clipboard_get :: proc() -> string {
	return pf.clipboard
}

platform_set_window_pos :: proc(x, y: int) {}

platform_request_close :: proc() {
	pf.close_asked = true
}

// ---------------------------------------------------------------- called by the page

@(private = "file")
push :: proc "contextless" (e: Event) {
	context = js_context()
	append(&queue, e)
}

js_context :: proc "contextless" () -> runtime.Context {
	return editor_context
}

// set by the entry (editor_web.odin) to the context the app runs in
editor_context: runtime.Context

@(export)
editor_key :: proc "contextless" (key: i32, action: i32) {
	push({kind = .Key_Down if action == 1 else .Key_Repeat if action == 2 else .Key_Up, code = key})
}

@(export)
editor_button :: proc "contextless" (button: i32, down: bool, x, y: f32) {
	push({kind = .Button_Down if down else .Button_Up, code = button, pos = {x, y}})
}

@(export)
editor_move :: proc "contextless" (x, y: f32) {
	push({kind = .Move, pos = {x, y}})
}

// A mouse wheel's notches.
@(export)
editor_wheel :: proc "contextless" (dx, dy: f32) {
	push({kind = .Wheel, pos = {dx, dy}})
}

// A trackpad's scroll, in points.
@(export)
editor_scroll :: proc "contextless" (dx, dy: f32) {
	push({kind = .Scroll, pos = {dx, dy}})
}

// A pinch: the relative change of scale.
@(export)
editor_magnify :: proc "contextless" (delta: f32) {
	push({kind = .Magnify, pos = {delta, 0}})
}

@(export)
editor_char :: proc "contextless" (codepoint: i32) {
	push({kind = .Char, code = codepoint})
}

@(export)
editor_resize :: proc "contextless" (width, height, dpr: f32) {
	pf.size = {width, height}
	pf.dpr = dpr
}

// The clipboard's text before a paste (the page reads it in its paste event).
@(export)
editor_clipboard :: proc "contextless" (ptr: [^]u8, n: int) {
	context = js_context()
	delete(pf.clipboard)
	pf.clipboard = strings.clone(string(ptr[:n]))
	free(ptr)
}

// Memory for the page to write a string or a file into.
@(export)
editor_alloc :: proc "contextless" (n: int) -> rawptr {
	context = js_context()
	return raw_data(make([]u8, max(n, 1)))
}
