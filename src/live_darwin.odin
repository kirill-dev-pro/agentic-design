#+build darwin
package agentic_design

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:thread"
import NS "core:sys/darwin/Foundation"

// The Mac app's WebSocket to a cloud document's room (cloud_live.odin): NSURLSessionWebSocketTask
// with the device token as Authorization: Bearer (the room's route checks it like a cookie).
// Its completion handlers run on the session's queue; they hand what arrives to live_event,
// which queues it for the next frame and wakes the loop.
//
// The handlers are blocks. Foundation's Odin bindings make blocks of one argument; a message
// arrives with two (the message, an error), so these are built here: global blocks (copying
// one gives itself), two per connection, each knowing the connection it belongs to. They are
// never freed: the session releases them after it calls them, and an old connection's may
// still be called after a new one starts (a few bytes per connection).

@(objc_class = "NSURLSession")
URL_Session :: struct {
	using _: NS.Object,
}
@(objc_class = "NSURLSessionConfiguration")
URL_Session_Config :: struct {
	using _: NS.Object,
}
@(objc_class = "NSMutableURLRequest")
Mutable_Request :: struct {
	using _: NS.Object,
}
@(objc_class = "NSURLSessionWebSocketTask")
WS_Task :: struct {
	using _: NS.Object,
}
@(objc_class = "NSURLSessionWebSocketMessage")
WS_Message :: struct {
	using _: NS.Object,
}

@(private = "file")
Block_Desc :: struct {
	reserved: uint,
	size:     uint,
}

@(private = "file")
Live_Block :: struct {
	isa:        rawptr,
	flags:      i32,
	reserved:   i32,
	invoke:     rawptr,
	descriptor: ^Block_Desc,
	gen:        int, // the connection it was made for
}

foreign import libSystem "system:System"
@(private = "file")
foreign libSystem {
	@(link_name = "_NSConcreteGlobalBlock")
	global_block_class: intrinsics.objc_class
}

@(private = "file")
block_desc := Block_Desc{0, size_of(Live_Block)}

@(private = "file")
make_block :: proc(invoke: rawptr) -> ^Live_Block {
	b := new(Live_Block, runtime.heap_allocator())
	b^ = {&global_block_class, 1 << 28 /* BLOCK_IS_GLOBAL */, 0, invoke, &block_desc, ws.gen}
	return b
}

@(private = "file")
ws: struct {
	session:  ^URL_Session,
	task:     ^WS_Task,
	gen:      int, // bumps with each connection: handlers of an old one do nothing
	received: ^Live_Block, // this connection's handlers
	sent:     ^Live_Block,
}

// The window shows people and the role itself (ui.odin).
live_host_state :: proc(json: string) {}

live_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// wss://<the cloud>/api/docs/<id>/room, with the device token ("" when signed out).
live_room_url :: proc(doc_id: string) -> (url, bearer: string) {
	cloud_load()
	if !cloud_signed_in() do return "", ""
	base := cloud_url()
	scheme := "wss" if strings.has_prefix(base, "https:") else "ws"
	rest := base[strings.index_byte(base, ':'):]
	return strings.concatenate({scheme, rest, "/api/docs/", doc_id, "/room"}, context.temp_allocator), cloud.token
}

live_transport_open :: proc(url, bearer: string) -> bool {
	live_transport_close()
	pool := NS.scoped_autoreleasepool()
	_ = pool
	ws.gen += 1
	if ws.session == nil {
		cfg := intrinsics.objc_send(^URL_Session_Config, URL_Session_Config, "defaultSessionConfiguration")
		ws.session = intrinsics.objc_send(^URL_Session, URL_Session, "sessionWithConfiguration:", cfg)
		intrinsics.objc_send(nil, ws.session, "retain")
	}
	u := intrinsics.objc_send(^NS.URL, NS.URL, "URLWithString:", ns_string(url))
	if u == nil do return false
	req := intrinsics.objc_send(^Mutable_Request, Mutable_Request, "requestWithURL:", u)
	if bearer != "" do intrinsics.objc_send(nil, req, "setValue:forHTTPHeaderField:", ns_string(strings.concatenate({"Bearer ", bearer}, context.temp_allocator)), ns_string("Authorization"))
	ws.task = intrinsics.objc_send(^WS_Task, ws.session, "webSocketTaskWithRequest:", req)
	if ws.task == nil do return false
	intrinsics.objc_send(nil, ws.task, "retain")
	intrinsics.objc_send(nil, ws.task, "setMaximumMessageSize:", NS.Integer(4 << 20))
	ws.received = make_block(rawptr(on_message))
	ws.sent = make_block(rawptr(on_sent))
	intrinsics.objc_send(nil, ws.task, "resume")
	// sends before the handshake ends wait for it; a refused handshake ends the first receive
	live_event(.Open, "")
	receive()
	return true
}

@(private = "file")
receive :: proc() {
	if ws.task == nil do return
	intrinsics.objc_send(nil, ws.task, "receiveMessageWithCompletionHandler:", ws.received)
}

@(private = "file")
on_message :: proc "c" (b: ^Live_Block, msg: ^WS_Message, err: ^NS.Object) {
	context = runtime.default_context()
	if b.gen != ws.gen do return
	if err != nil || msg == nil {
		task := ws.task
		code := int(intrinsics.objc_send(NS.Integer, task, "closeCode")) if task != nil else 0
		reason := ""
		if task != nil {
			if d := intrinsics.objc_send(^NS.Data, task, "closeReason"); d != nil {
				n := int(intrinsics.objc_send(NS.UInteger, d, "length"))
				p := intrinsics.objc_send([^]u8, d, "bytes")
				if p != nil && n > 0 do reason = strings.clone(string(p[:n]), context.temp_allocator)
			}
			// the handshake was refused: the route's status says why
			if code == 0 {
				if r := intrinsics.objc_send(^NS.Object, task, "response"); r != nil {
					switch intrinsics.objc_send(NS.Integer, r, "statusCode") {
					case 401: reason = "SIGNED_OUT"
					case 403, 404: reason = "REVOKED"
					}
				}
			}
		}
		live_event(.Close, reason, code)
		return
	}
	text := ""
	if intrinsics.objc_send(NS.Integer, msg, "type") == 1 {
		if s := intrinsics.objc_send(^NS.String, msg, "string"); s != nil do text = s->odinString()
	} else if d := intrinsics.objc_send(^NS.Data, msg, "data"); d != nil {
		n := int(intrinsics.objc_send(NS.UInteger, d, "length"))
		p := intrinsics.objc_send([^]u8, d, "bytes")
		if p != nil do text = string(p[:n])
	}
	live_event(.Message, text)
	receive()
}

@(private = "file")
on_sent :: proc "c" (b: ^Live_Block, err: ^NS.Object) {
	// a failed send shows as the receive ending
}

live_transport_send :: proc(text: string) {
	if ws.task == nil do return
	pool := NS.scoped_autoreleasepool()
	m := intrinsics.objc_send(^WS_Message, intrinsics.objc_send(^WS_Message, WS_Message, "alloc"), "initWithString:", ns_string(text))
	intrinsics.objc_send(nil, ws.task, "sendMessage:completionHandler:", m, ws.sent)
	intrinsics.objc_send(nil, m, "release")
	_ = pool
}

live_transport_close :: proc() {
	ws.gen += 1
	if ws.task == nil do return
	intrinsics.objc_send(nil, ws.task, "cancelWithCloseCode:reason:", NS.Integer(1000), rawptr(nil))
	intrinsics.objc_send(nil, ws.task, "release")
	ws.task = nil
}

// A request to the cloud's API with the device token, on a thread of its own; the answer comes
// back as live_event(.Http).
live_http :: proc(req: int, method, path, body: string) {
	Job :: struct {
		req:                       int,
		method, url, body, bearer: string,
	}
	a := runtime.heap_allocator()
	job := new(Job, a)
	job^ = {req, strings.clone(method, a), strings.concatenate({cloud_url(), path}, a), strings.clone(body, a), strings.clone(cloud.token, a)}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := (^Job)(data)
		a := runtime.heap_allocator()
		r := cloud_http(job.method, job.url, job.body, job.bearer)
		live_event(.Http, r.body, r.status, job.req)
		delete(job.method, a)
		delete(job.url, a)
		delete(job.body, a)
		delete(job.bearer, a)
		free(job, a)
		free_all(context.temp_allocator)
	}, app_context(), self_cleanup = true)
}
