package agentic_design


import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

// Local control server: newline-delimited JSON requests on 127.0.0.1.
// Network threads only queue requests; the main thread executes them
// between frames so the document is never touched concurrently.

DEFAULT_PORT :: 4410

// The control port: AGENTIC_PORT, else 4410. Tests use another port so they can run
// next to the window someone is working in.
server_port :: proc() -> int {
	if v := os.get_env("AGENTIC_PORT", context.temp_allocator); v != "" {
		if p, ok := strconv.parse_int(v); ok && p > 0 && p < 65536 do return p
	}
	return DEFAULT_PORT
}

Request :: struct {
	body:     string,
	response: string,
	done:     sync.Sema,
}

req_mutex: sync.Mutex
req_queue: [dynamic]^Request
server_listening: bool

posix_ignore_sigpipe :: proc() {
	posix.signal(.SIGPIPE, transmute(proc "c" (posix.Signal))posix.SIG_IGN)
}

server_start :: proc() {
	thread.create_and_start(server_thread)
}

server_thread :: proc() {
	context.allocator = big_allocator()
	ep, _ := net.parse_endpoint(fmt.tprintf("127.0.0.1:%d", server_port()))
	sock, err := net.listen_tcp(ep)
	if err != nil do return
	server_listening = true
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil do continue
		thread.create_and_start_with_poly_data(client, handle_client, self_cleanup = true)
	}
}

handle_client :: proc(client: net.TCP_Socket) {
	context.allocator = big_allocator() // it frees responses the main thread made
	defer net.close(client)
	// a response goes out as two writes (the JSON, then "\n"); with Nagle's algorithm
	// the second waited for the client's delayed ACK, about 170 ms on every request
	_ = net.set_option(client, .TCP_Nodelay, true)
	buf: [dynamic]u8
	defer delete(buf)
	tmp: [16 * 1024]u8
	for {
		n, err := net.recv_tcp(client, tmp[:])
		if err != nil || n == 0 do return
		append(&buf, ..tmp[:n])
		for {
			idx := bytes.index_byte(buf[:], '\n')
			if idx < 0 do break
			req := new(Request)
			req.body = strings.clone(string(buf[:idx]))
			remove_range(&buf, 0, idx + 1)

			sync.mutex_lock(&req_mutex)
			append(&req_queue, req)
			sync.mutex_unlock(&req_mutex)
			platform_wake() // the main loop may be asleep (idle_wait)
			sync.sema_post(&pace_wake) // or pacing frames (app.odin)
			sync.sema_wait(&req.done)

			ok := send_all(client, transmute([]u8)req.response) && send_all(client, {'\n'})
			delete(req.body)
			delete(req.response)
			free(req)
			if !ok do return
		}
	}
}

send_all :: proc(s: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(s, data[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// Called once per frame on the main thread.
// Runs queued requests on the main thread; true when any ran.
process_requests :: proc() -> bool {
	sync.mutex_lock(&req_mutex)
	pending := req_queue[:]
	batch := make([]^Request, len(pending), context.temp_allocator)
	copy(batch, pending)
	clear(&req_queue)
	sync.mutex_unlock(&req_mutex)

	for req in batch {
		resp, deferred := api_dispatch(req)
		if deferred do continue
		req.response = resp
		sync.sema_post(&req.done)
	}
	return len(batch) > 0
}

finish_request :: proc(req: ^Request, response: string) {
	req.response = response
	sync.sema_post(&req.done)
}
