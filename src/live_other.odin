#+build linux, windows
package agentic_design

import "base:runtime"

// Linux and Windows have no WebSocket here yet: cloud documents open in the browser.

// The window shows people and the role itself (ui.odin).
live_host_state :: proc(json: string) {}

live_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

live_room_url :: proc(doc_id: string) -> (url, bearer: string) {
	return "", ""
}

live_transport_open :: proc(url, bearer: string) -> bool {return false}
live_http :: proc(req: int, method, path, body: string) {live_event(.Http, "", 0, req)}
live_transport_send :: proc(text: string) {}
live_transport_close :: proc() {}
