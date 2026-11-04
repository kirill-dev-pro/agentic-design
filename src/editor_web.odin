#+build js
package agentic_design

import "base:runtime"
import "core:strings"
import "engine"
import nvg "nanovg"

// The editor in a web page (web/edit/): the entry the page's script runs. The page hands the
// engine the document's files (editor_file), asks for the editor to start on one of them
// (editor_open) and then calls step once per animation frame, after the events it queued
// (platform_js.odin). `step` is the loop of app_main (app.odin) turned inside out.

foreign import page "editor"

@(default_calling_convention = "contextless")
foreign page {
	// the editor cannot start (no WebGPU, the document is not readable)
	page_error :: proc(message: string) ---
	// the editor is running: the page hides its loading state
	page_ready :: proc() ---
}

@(private = "file")
web: struct {
	path:    string, // the document to open, once the page has asked
	gpu:     bool, // the renderer is ready (or failed)
	started: bool,
	failed:  bool,
}

main :: proc() {
	editor_context = context
	engine.gpu_create_async(platform_gpu_surface(), proc(vg: ^nvg.Context) {
		web.gpu = true
		if vg == nil {
			web.failed = true
			page_error("This browser has no WebGPU, which the editor needs.")
			return
		}
		pf.vg = vg
	})
}

// The page's frame (requestAnimationFrame).
@(export)
step :: proc(dt: f64) -> bool {
	free_all(context.temp_allocator)
	if web.failed do return false
	if !web.started {
		if pf.vg == nil || web.path == "" || pf.size.x <= 0 || pf.size.y <= 0 do return true
		web.started = true
		if !app_start(web.path) {
			page_error("The editor could not start.")
			web.failed = true
			return false
		}
		if len(app.tabs) == 0 {
			page_error("That is not a .pen document.")
			web.failed = true
			return false
		}
		page_ready()
	}
	engine.font_atlas_trim(app.vg)
	platform_poll()
	app_frame()
	return !platform_should_close()
}

// ---------------------------------------------------------------- called by the page

// A file for the engine to read: the document, its images, fonts and libraries. `path` and
// `data` (both from editor_alloc) are the engine's from now on.
@(export)
editor_file :: proc "contextless" (path: [^]u8, path_len: int, data: [^]u8, data_len: int) {
	context = js_context()
	engine.files_add(string(path[:path_len]), data[:data_len])
	free(path)
}

// Starts the editor on a document whose files have been handed over (editor_file), or once
// it runs opens it in a new tab.
@(export)
editor_open :: proc "contextless" (path: [^]u8, path_len: int) {
	context = js_context()
	p := string(path[:path_len])
	if web.started {
		if !open_in_tab(p) do set_status("Could not read %s as a .pen document", p)
	} else {
		web.path = strings.clone(p)
	}
	free(path)
}

// Writes the open document, if there is one that has changes, to the page (page_fs_write):
// what the page's Download .pen button asks before it saves the file.
@(export)
editor_save :: proc "contextless" () -> bool {
	context = js_context()
	if !web.started || app.tab < 0 do return false
	return save_document(app.file_path)
}
