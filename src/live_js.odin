#+build js
package agentic_design

import "base:runtime"
import "core:strings"

// The browser editor's WebSocket to a cloud document's room (cloud_live.odin): the page opens
// it (web/edit/editor.js, live*) with the site's session cookie, and calls editor_live_event
// with what happens on it.

foreign import page "editor"

@(default_calling_convention = "contextless")
foreign page {
	page_live_open :: proc(url: string) ---
	page_live_send :: proc(text: string) ---
	page_live_close :: proc() ---
	page_live_state :: proc(json: string) ---
	page_live_http :: proc(req: int, method, path, body: string) ---
}

// A request to the site's API with the page's session; the answer comes back as
// editor_live_http.
live_http :: proc(req: int, method, path, body: string) {
	page_live_http(req, method, path, body)
}

@(export)
editor_live_http :: proc "contextless" (req: int, status: int, data: [^]u8, data_len: int) {
	context = js_context()
	live_event(.Http, string(data[:data_len]) if data != nil else "", status, req)
	if data != nil do free(data)
}

live_host_state :: proc(json: string) {
	page_live_state(json)
}

live_allocator :: proc() -> runtime.Allocator {
	return editor_context.allocator
}

// A path on the page's own site: the page makes it wss://.
live_room_url :: proc(doc_id: string) -> (url, bearer: string) {
	return strings.concatenate({"/api/docs/", doc_id, "/room"}, context.temp_allocator), ""
}

live_transport_open :: proc(url, bearer: string) -> bool {
	page_live_open(url)
	return true
}

live_transport_send :: proc(text: string) {
	page_live_send(text)
}

live_transport_close :: proc() {
	page_live_close()
}

// kind 0: open, 1: a message (`data`), 2: closed (`code`, the reason in `data`). `data`
// comes from editor_alloc and is freed here.
@(export)
editor_live_event :: proc "contextless" (kind: int, data: [^]u8, data_len: int, code: int) {
	context = js_context()
	text := string(data[:data_len]) if data != nil else ""
	live_event(Live_Event(kind), text, code)
	if data != nil do free(data)
}

// Opens the cloud document the page loaded (its files handed over at `path`) live.
@(export)
editor_live_open :: proc "contextless" (doc_id: [^]u8, doc_len: int, path: [^]u8, path_len: int, name: [^]u8, name_len: int) {
	context = js_context()
	live_open(string(doc_id[:doc_len]), string(path[:path_len]), string(name[:name_len]))
	free(doc_id)
	free(path)
	free(name)
}
