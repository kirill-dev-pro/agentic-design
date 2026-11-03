#+build !js
package agentic_design

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import NS "core:sys/darwin/Foundation"
import "base:intrinsics"

import "engine"

// The cloud from the Mac app (M1: the API contract, Shared/agentic-design/m1-api-contract.md
// §3, §4, §8; docs/cloud-design.md): sign in through the browser, share the open file by
// link.
//
// Sign-in never shows a password field: PKCE (S256) through the system browser and a
// loopback port. The app listens on 127.0.0.1:<port>, opens <site>/auth/app with the
// challenge, the user approves this Mac on the site, the browser comes back to
// /callback?code=…&state=…, and the app trades the code and its verifier for a device
// token. The token is a 30-day session renewed while used; it lives in the Keychain (one
// item per site) and goes to the API as `Authorization: Bearer`. curl does the HTTP, with
// its options on stdin, so the token is never in a command line.
//
// Sharing uploads the saved .pen and the files it refers to (images, fonts, libraries and
// what those refer to), each by SHA-256: the server asks only for the blobs it does not
// have, they are PUT to presigned URLs, the version is committed, and the file keeps one
// link. The file's id and link are remembered per file (shared.json), so sharing again
// uploads a new version behind the same link.
//
// Test windows (AGENTIC_QUIET) keep the token and the shares in memory only, and never
// open a browser: the socket's `cloud` method reports the sign-in URL for the test to follow.

CLOUD_URL :: #config(CLOUD_URL, "https://agentic-design.kcrz.dev")
CLOUD_KEYCHAIN_SERVICE :: "dev.kcrz.agentic-design.cloud"
CLOUD_SIGNIN_TIMEOUT :: 10 * time.Minute

Cloud_Phase :: enum i32 {
	Idle,
	Signing_In, // waiting for the browser
	Working, // a request or an upload
	Failed,
}

Cloud_Share :: struct {
	doc_id, version_id, link_id, url: string,
	allow_download, allow_embed:      bool,
	missing:                          [dynamic]string,
}

cloud: struct {
	loaded:     bool, // the token was looked up
	token:      string, // device session ("" = signed out)
	email:      string,
	name:       string,
	verified:   bool,
	phase:      Cloud_Phase, // atomic
	running:    bool, // a worker thread is busy
	cancel:     bool, // atomic: stop waiting for the browser
	mutex:      sync.Mutex, // guards the strings below and `shares`
	progress:   string,
	error:      string,
	signin_url: string,
	shares:     map[string]Cloud_Share, // by cloud_share_key
	shares_loaded: bool,
	copied:     bool, // a finished share put its link on the clipboard (main thread does it)
}

cloud_url :: proc() -> string {
	if u := os.get_env("AGENTIC_CLOUD_URL", context.temp_allocator); u != "" do return strings.trim_right(u, "/")
	return CLOUD_URL
}

cloud_phase :: proc() -> Cloud_Phase {
	return Cloud_Phase(sync.atomic_load(cast(^i32)&cloud.phase))
}

@(private = "file")
set_phase :: proc(p: Cloud_Phase) {
	sync.atomic_store(cast(^i32)&cloud.phase, i32(p))
	platform_wake()
}

@(private = "file")
set_text :: proc(field: ^string, format: string, args: ..any) {
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	delete(field^)
	field^ = fmt.aprintf(format, ..args)
	platform_wake()
}

@(private = "file")
fail :: proc(format: string, args: ..any) {
	set_text(&cloud.error, format, ..args)
	set_text(&cloud.progress, "")
	set_phase(.Failed)
}

// A copy of a shared string, for the interface (temporary allocator).
cloud_text :: proc(field: ^string) -> string {
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	return strings.clone(field^, context.temp_allocator)
}

// The token from the Keychain, once (test windows have none until they sign in).
cloud_load :: proc() {
	if cloud.loaded do return
	cloud.loaded = true
	if pf.quiet do return
	cloud.token = keychain_get(CLOUD_KEYCHAIN_SERVICE, cloud_url())
	if cloud.token != "" && !cloud.running {
		// who it is, in the background; a 401 means the session ended
		cloud.running = true
		thread.create_and_start(proc() {
				context = app_context()
				defer cloud.running = false
				cloud_fetch_me()
			}, app_context(), self_cleanup = true)
	}
}

cloud_signed_in :: proc() -> bool {
	cloud_load()
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	return cloud.token != ""
}

// ---------------------------------------------------------------- HTTP (curl)

Http_Result :: struct {
	status: int, // 0 when the request did not complete
	body:   string,
	json:   json.Value,
	err:    string, // a message for people: the server's, or curl's
	reason: string, // details.reason or code
}

// One request. `body` is JSON (or ""), `upload` a file to PUT as is; `headers` are extra
// "Name: value" lines. Bearer is the device token, or "" for none.
cloud_http :: proc(method, url: string, body := "", bearer := "", upload := "", headers: []string = nil) -> (r: Http_Result) {
	cfg := strings.builder_make(context.temp_allocator)
	q :: proc(b: ^strings.Builder, key, value: string) {
		fmt.sbprintf(b, "%s = \"", key)
		for c in value {
			switch c {
			case '"': strings.write_string(b, `\"`)
			case '\\': strings.write_string(b, `\\`)
			case '\n', '\r': // never in a value
			case: strings.write_rune(b, c)
			}
		}
		strings.write_string(b, "\"\n")
	}
	q(&cfg, "url", url)
	q(&cfg, "request", method)
	strings.write_string(&cfg, "silent\nshow-error\n")
	q(&cfg, "max-time", "600" if upload != "" else "60")
	strings.write_string(&cfg, "write-out = \"\\n%{http_code}\"\n") // curl's \n: the status on a line of its own
	q(&cfg, "proto", "=https,http")
	if bearer != "" do q(&cfg, "header", fmt.tprintf("Authorization: Bearer %s", bearer))
	for h in headers do q(&cfg, "header", h)
	body_file := ""
	if body != "" {
		dir := fmt.tprintf("%s/cloud", update_cache_dir())
		_ = os.make_directory_all(dir)
		body_file = fmt.tprintf("%s/request-%d-%d.json", dir, os.get_pid(), time.now()._nsec)
		if os.write_entire_file(body_file, transmute([]u8)body) != nil {
			r.err = "could not write the request"
			return
		}
		q(&cfg, "header", "Content-Type: application/json")
		q(&cfg, "data-binary", fmt.tprintf("@%s", body_file))
	}
	defer if body_file != "" do os.remove(body_file)
	if upload != "" do q(&cfg, "upload-file", upload)

	rd, wr, perr := os.pipe()
	if perr != nil {
		r.err = "could not start curl"
		return
	}
	text := strings.to_string(cfg)
	_, _ = os.write(wr, transmute([]u8)text)
	os.close(wr)
	state, out, errout, xerr := os.process_exec({command = {"/usr/bin/curl", "--config", "-"}, stdin = rd}, context.temp_allocator)
	os.close(rd)
	if xerr != nil {
		r.err = "could not start curl"
		return
	}
	s := string(out)
	nl := strings.last_index_byte(s, '\n')
	code := 0
	if nl >= 0 {
		for c in s[nl + 1:] do if c >= '0' && c <= '9' do code = code * 10 + int(c - '0')
		s = s[:nl]
	}
	r.status = code
	r.body = s
	if code == 0 || !state.exited {
		msg := strings.trim_space(string(errout))
		r.err = fmt.tprintf("could not reach %s%s%s", cloud_url(), ": " if msg != "" else "", msg)
		return
	}
	if v, err := json.parse_string(s, .JSON, false, context.temp_allocator); err == nil do r.json = v
	if code >= 400 {
		obj, _ := r.json.(json.Object)
		msg := string(obj["error"].(json.String) or_else (obj["message"].(json.String) or_else ""))
		if d, ok := obj["details"].(json.Object); ok do r.reason = string(d["reason"].(json.String) or_else "")
		if r.reason == "" do r.reason = string(obj["code"].(json.String) or_else "")
		r.err = msg if msg != "" else fmt.tprintf("the server answered %d", code)
	}
	return
}

// GET /api/me: the account's email and name. 401 signs out (the session ended).
@(private = "file")
cloud_fetch_me :: proc() -> bool {
	r := cloud_http("GET", fmt.tprintf("%s/api/me", cloud_url()), bearer = cloud.token)
	if r.status == 401 {
		cloud_forget_token()
		return false
	}
	if r.status != 200 do return false
	obj, _ := r.json.(json.Object)
	user, _ := obj["user"].(json.Object)
	set_text(&cloud.email, "%s", string(user["email"].(json.String) or_else ""))
	set_text(&cloud.name, "%s", string(user["name"].(json.String) or_else ""))
	cloud.verified = user["emailVerified"].(json.Boolean) or_else false
	return true
}

@(private = "file")
cloud_forget_token :: proc() {
	sync.mutex_lock(&cloud.mutex)
	delete(cloud.token)
	cloud.token = ""
	delete(cloud.email)
	cloud.email = ""
	sync.mutex_unlock(&cloud.mutex)
	if !pf.quiet do keychain_delete(CLOUD_KEYCHAIN_SERVICE, cloud_url())
	platform_wake()
}

// ---------------------------------------------------------------- sign-in

@(private = "file")
b64url :: proc(data: []u8) -> string {
	s := base64.encode(data, allocator = context.temp_allocator)
	s, _ = strings.replace_all(s, "+", "-", context.temp_allocator)
	s, _ = strings.replace_all(s, "/", "_", context.temp_allocator)
	return strings.trim_right(s, "=")
}

@(private = "file")
random_b64url :: proc(n: int) -> string {
	buf := make([]u8, n, context.temp_allocator)
	crypto.rand_bytes(buf)
	return b64url(buf)
}

@(private = "file")
url_encode :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~': strings.write_byte(&b, c)
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// The Mac's name as the user set it ("Kirill's MacBook Pro"), for the site's device list.
@(private = "file")
device_name :: proc() -> string {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	host := intrinsics.objc_send(^NS.Object, Host, "currentHost")
	name := intrinsics.objc_send(^NS.String, host, "localizedName") if host != nil else nil
	s := strings.clone(name->odinString(), context.temp_allocator) if name != nil else "Mac"
	return s[:min(len(s), 80)]
}

@(objc_class = "NSHost")
Host :: struct {
	using _: NS.Object,
}

@(private = "file")
Signin :: struct {
	listener: net.TCP_Socket,
	verifier: string,
	state:    string,
}

// Starts the sign-in: listens on a loopback port and opens the browser at the site's
// approval page. The rest happens on a worker thread.
cloud_sign_in :: proc() {
	if cloud.running do return
	cloud_load()
	listener, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0}, 4)
	if lerr != nil {
		fail("could not open a local port for the browser to come back to")
		return
	}
	ep, _ := net.bound_endpoint(listener)
	verifier := random_b64url(32)
	challenge := b64url(hash.hash_string(.SHA256, verifier, context.temp_allocator))
	state := random_b64url(24)
	url := fmt.tprintf("%s/auth/app?challenge=%s&port=%d&state=%s&device=%s", cloud_url(), challenge, ep.port, state, url_encode(device_name()))
	set_text(&cloud.signin_url, "%s", url)
	set_text(&cloud.error, "")
	set_text(&cloud.progress, "Waiting for the browser…")
	sync.atomic_store(&cloud.cancel, false)
	set_phase(.Signing_In)
	open_url(url)
	s := new(Signin)
	s^ = {listener, strings.clone(verifier), strings.clone(state)}
	cloud.running = true
	thread.create_and_start_with_data(s, signin_worker, app_context(), self_cleanup = true)
}

cloud_cancel :: proc() {
	sync.atomic_store(&cloud.cancel, true)
}

@(private = "file")
signin_worker :: proc(data: rawptr) {
	context = app_context()
	s := (^Signin)(data)
	defer {
		net.close(s.listener)
		delete(s.verifier)
		delete(s.state)
		free(s)
		cloud.running = false
	}
	_ = net.set_blocking(s.listener, false)
	deadline := time.time_add(time.now(), CLOUD_SIGNIN_TIMEOUT)
	code := ""
	for code == "" {
		if sync.atomic_load(&cloud.cancel) {
			set_text(&cloud.progress, "")
			set_phase(.Idle)
			return
		}
		if time.diff(deadline, time.now()) > 0 {
			fail("The sign-in timed out. Try again.")
			return
		}
		conn, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil {
			time.sleep(150 * time.Millisecond)
			continue
		}
		code = loopback_request(conn, s.state)
		net.close(conn)
		free_all(context.temp_allocator)
	}
	if code == "-" {
		fail("The browser came back from another sign-in. Try again.")
		return
	}
	set_text(&cloud.progress, "Signing in…")
	body := fmt.tprintf(`{{"code":%s,"verifier":%s}}`, json_quote(code), json_quote(s.verifier))
	r := cloud_http("POST", fmt.tprintf("%s/api/app-auth/token", cloud_url()), body)
	obj, _ := r.json.(json.Object)
	token := string(obj["token"].(json.String) or_else "")
	if r.status != 200 || token == "" {
		fail("Sign-in failed: %s", r.err if r.err != "" else "no token")
		return
	}
	sync.mutex_lock(&cloud.mutex)
	delete(cloud.token)
	cloud.token = strings.clone(token)
	sync.mutex_unlock(&cloud.mutex)
	if !pf.quiet && !keychain_set(CLOUD_KEYCHAIN_SERVICE, cloud_url(), "Agentic Design (cloud)", token) {
		app_log("cloud: the Keychain refused the device token; signed in until the app quits")
	}
	cloud_fetch_me()
	set_text(&cloud.progress, "")
	set_phase(.Idle)
}

// Reads one request from the browser. Returns the code, "-" for a state that is not ours,
// or "" to keep waiting (another path, a favicon).
@(private = "file")
loopback_request :: proc(conn: net.TCP_Socket, state: string) -> string {
	_ = net.set_blocking(conn, true)
	buf: [8192]u8
	n := 0
	for n < len(buf) {
		got, err := net.recv_tcp(conn, buf[n:])
		if err != nil || got <= 0 do break
		n += got
		if strings.contains(string(buf[:n]), "\r\n\r\n") do break
	}
	line := string(buf[:n])
	if i := strings.index(line, "\r\n"); i >= 0 do line = line[:i]
	parts := strings.split(line, " ", context.temp_allocator)
	target := parts[1] if len(parts) >= 3 && parts[0] == "GET" else ""
	path, query := target, ""
	if i := strings.index_byte(target, '?'); i >= 0 do path, query = target[:i], target[i + 1:]
	if path != "/callback" {
		respond(conn, 404, "Not found", "")
		return ""
	}
	code, got_state, err_param := "", "", ""
	for kv in strings.split(query, "&", context.temp_allocator) {
		eq := strings.index_byte(kv, '=')
		if eq < 0 do continue
		k, v := kv[:eq], url_decode(kv[eq + 1:])
		switch k {
		case "code": code = v
		case "state": got_state = v
		case "error": err_param = v
		}
	}
	if got_state != state {
		respond(conn, 400, "This sign-in did not start in this app", "Start again from Agentic Design.")
		return "-"
	}
	if code == "" {
		respond(conn, 400, "Sign-in was not completed", err_param)
		return "-"
	}
	respond(conn, 200, "Back to Agentic Design", "You can close this tab. The app finishes signing in.")
	return strings.clone(code)
}

@(private = "file")
respond :: proc(conn: net.TCP_Socket, status: int, title, text: string) {
	html := fmt.tprintf(`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>%s</title><style>body{{font:16px/1.5 system-ui,sans-serif;max-width:28rem;margin:15vh auto;padding:0 1.5rem;color:#1a1a1b}}@media(prefers-color-scheme:dark){{body{{background:#1a1a1b;color:#eee}}}}</style></head><body><h1>%s</h1><p>%s</p></body></html>`, title, title, text)
	reason := "OK" if status == 200 else "Bad Request" if status == 400 else "Not Found"
	head := fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n", status, reason, len(html))
	_, _ = net.send_tcp(conn, transmute([]u8)head)
	_, _ = net.send_tcp(conn, transmute([]u8)html)
}

@(private = "file")
url_decode :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			if v, ok := hex.decode_sequence(s[i + 1:i + 3]); ok {
				strings.write_byte(&b, v)
				i += 2
				continue
			}
		}
		strings.write_byte(&b, ' ' if c == '+' else c)
	}
	return strings.to_string(b)
}

cloud_sign_out :: proc() {
	if cloud.running do return
	token := cloud.token
	if token == "" do return
	cloud.running = true
	thread.create_and_start(proc() {
			context = app_context()
			defer cloud.running = false
			_ = cloud_http("POST", fmt.tprintf("%s/api/auth/sign-out", cloud_url()), "{}", cloud.token)
			cloud_forget_token()
		}, app_context(), self_cleanup = true)
}

// ---------------------------------------------------------------- the files of a document

// The media types the server keeps, by extension.
asset_type :: proc(ext: string) -> (string, bool) {
	switch ext {
	case "png": return "image/png", true
	case "jpg", "jpeg": return "image/jpeg", true
	case "webp": return "image/webp", true
	case "gif": return "image/gif", true
	case "svg": return "image/svg+xml", true
	case "ttf": return "font/ttf", true
	case "otf": return "font/otf", true
	case "woff": return "font/woff", true
	case "woff2": return "font/woff2", true
	case "pen": return "application/json", true
	}
	return "", false
}

Share_Asset :: struct {
	rel, abs, type: string, // "./images/a.png" from the document's folder; the file; its media type
}

// The files a saved document refers to: every relative `url` (image fills, fonts) and every
// library in `imports`, and the same for each library, by their paths from the document's
// folder (as the viewer reads them). Files that are not there, or of a kind the server
// does not keep, are `missing`.
share_collect :: proc(doc_path: string) -> (assets: [dynamic]Share_Asset, missing: [dynamic]string) {
	assets = make([dynamic]Share_Asset, context.temp_allocator)
	missing = make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	root := fs_dir(engine.absolute_path(doc_path))
	seen[engine.absolute_path(doc_path)] = true
	visit :: proc(file: string, root: string, seen: ^map[string]bool, assets: ^[dynamic]Share_Asset, missing: ^[dynamic]string) {
		data, ok := engine.read_file(file, context.temp_allocator)
		if !ok do return
		v, err := json.parse(data, .JSON, false, context.temp_allocator)
		if err != nil do return
		dir := fs_dir(file)
		refs := make([dynamic]string, context.temp_allocator)
		walk :: proc(v: json.Value, key: string, refs: ^[dynamic]string) {
			#partial switch x in v {
			case json.Object:
				for k, child in x {
					if k == "imports" {
						if imp, ok := child.(json.Object); ok {
							for _, p in imp do if s, sok := p.(json.String); sok do append(refs, string(s))
							continue
						}
					}
					walk(child, k, refs)
				}
			case json.Array:
				for child in x do walk(child, key, refs)
			case json.String:
				if key == "url" do append(refs, string(x))
			}
		}
		walk(v, "", &refs)
		for ref in refs {
			lower := strings.to_lower(ref, context.temp_allocator)
			if ref == "" || strings.has_prefix(ref, "$") || strings.contains(lower, "://") || strings.has_prefix(lower, "data:") || strings.has_prefix(lower, "blob:") do continue
			abs := ref if fs_path_is_abs(ref) else engine.path_join(dir, ref)
			if abs in seen do continue
			seen[strings.clone(abs, context.temp_allocator)] = true
			rel := relative_path(root, abs)
			ext := strings.to_lower(strings.trim_prefix(os.ext(abs), "."), context.temp_allocator)
			type, known := asset_type(ext)
			if !known || !fs_exists(abs) {
				append(missing, rel)
				continue
			}
			append(assets, Share_Asset{rel, strings.clone(abs, context.temp_allocator), type})
			if ext == "pen" do visit(abs, root, seen, assets, missing) // a library's own files
		}
	}
	visit(engine.absolute_path(doc_path), root, &seen, &assets, &missing)
	return
}

// `to` as seen from the folder `from`: "./a/b.png", "../x.png" (web/upload.js relative()).
relative_path :: proc(from, to: string) -> string {
	a := strings.split(strings.trim(from, "/"), "/", context.temp_allocator)
	b := strings.split(strings.trim(to, "/"), "/", context.temp_allocator)
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	up := len(a) - i
	sb := strings.builder_make(context.temp_allocator)
	if up == 0 do strings.write_string(&sb, "./")
	for _ in 0 ..< up do strings.write_string(&sb, "../")
	strings.write_string(&sb, strings.join(b[i:], "/", context.temp_allocator))
	return strings.to_string(sb)
}

@(private = "file")
sha256_file :: proc(path: string) -> (sum: string, size: int, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", 0, false
	defer delete(data)
	return string(hex.encode(hash.hash_bytes(.SHA256, data, context.temp_allocator), context.temp_allocator)), len(data), true
}

// ---------------------------------------------------------------- shares of files

cloud_share_key :: proc(path: string) -> string {
	return fmt.tprintf("%s|%s", cloud_url(), engine.absolute_path(path))
}

@(private = "file")
shares_path :: proc() -> string {
	return fmt.tprintf("%s/shared.json", support_dir())
}

@(private = "file")
shares_load :: proc() {
	if cloud.shares_loaded do return
	cloud.shares_loaded = true
	if pf.quiet do return
	data, err := os.read_entire_file(shares_path(), context.temp_allocator)
	if err != nil do return
	v, perr := json.parse(data, .JSON, false, context.temp_allocator)
	if perr != nil do return
	obj, _ := v.(json.Object)
	for k, e in obj {
		o, _ := e.(json.Object)
		cloud.shares[strings.clone(k)] = Cloud_Share {
			doc_id         = strings.clone(string(o["docId"].(json.String) or_else "")),
			version_id     = strings.clone(string(o["versionId"].(json.String) or_else "")),
			link_id        = strings.clone(string(o["linkId"].(json.String) or_else "")),
			url            = strings.clone(string(o["url"].(json.String) or_else "")),
			allow_download = o["allowDownload"].(json.Boolean) or_else false,
			allow_embed    = o["allowEmbed"].(json.Boolean) or_else false,
		}
	}
}

// Under cloud.mutex.
@(private = "file")
shares_save :: proc() {
	if pf.quiet do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n")
	i := 0
	for k, s in cloud.shares {
		if i > 0 do strings.write_string(&b, ",\n")
		i += 1
		fmt.sbprintf(&b, `  %s: {{"docId":%s,"versionId":%s,"linkId":%s,"url":%s,"allowDownload":%v,"allowEmbed":%v}}`, json_quote(k), json_quote(s.doc_id), json_quote(s.version_id), json_quote(s.link_id), json_quote(s.url), s.allow_download, s.allow_embed)
	}
	strings.write_string(&b, "\n}\n")
	_ = os.make_directory_all(support_dir())
	_ = os.write_entire_file(shares_path(), transmute([]u8)strings.to_string(b))
}

// The open file's share (a copy, temporary allocator), if it has one.
cloud_share_of :: proc(path: string) -> (Cloud_Share, bool) {
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	shares_load()
	s, ok := cloud.shares[cloud_share_key(path)]
	if !ok do return {}, false
	c := s
	c.missing = make([dynamic]string, context.temp_allocator)
	for m in s.missing do append(&c.missing, strings.clone(m, context.temp_allocator))
	return c, true
}

@(private = "file")
share_store :: proc(key: string, s: Cloud_Share) {
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	if old, ok := cloud.shares[key]; ok {
		delete(old.doc_id)
		delete(old.version_id)
		delete(old.link_id)
		delete(old.url)
		for m in old.missing do delete(m)
		delete(old.missing)
	}
	k := key
	if key not_in cloud.shares do k = strings.clone(key)
	cloud.shares[k] = s
	shares_save()
}

@(private = "file")
share_forget :: proc(key: string) {
	sync.mutex_lock(&cloud.mutex)
	defer sync.mutex_unlock(&cloud.mutex)
	if _, ok := cloud.shares[key]; ok do delete_key(&cloud.shares, key)
	shares_save()
}

// ---------------------------------------------------------------- share

@(private = "file")
Share_Job :: struct {
	path, name: string,
	kind:       enum {
		Upload,
		Update_Link,
		Revoke,
	},
	download, embed: bool,
}

// Shares the saved file at `path` (a new file, or a new version behind the same link).
cloud_share :: proc(path, name: string) {
	start_job({path = strings.clone(path), name = strings.clone(name), kind = .Upload})
}

// Changes the link's download and embed permissions.
cloud_share_settings :: proc(path: string, download, embed: bool) {
	start_job({path = strings.clone(path), kind = .Update_Link, download = download, embed = embed})
}

// Revokes the link and forgets the share (the file stays in the account's files).
cloud_share_revoke :: proc(path: string) {
	start_job({path = strings.clone(path), kind = .Revoke})
}

@(private = "file")
start_job :: proc(job: Share_Job) {
	if cloud.running || !cloud_signed_in() do return
	j := new(Share_Job)
	j^ = job
	set_text(&cloud.error, "")
	set_phase(.Working)
	cloud.running = true
	thread.create_and_start_with_data(j, share_worker, app_context(), self_cleanup = true)
}

@(private = "file")
share_worker :: proc(data: rawptr) {
	context = app_context()
	j := (^Share_Job)(data)
	defer {
		delete(j.path)
		delete(j.name)
		free(j)
		free_all(context.temp_allocator)
		cloud.running = false
	}
	ok := false
	switch j.kind {
	case .Upload: ok = share_upload(j.path, j.name)
	case .Update_Link: ok = share_link_update(j.path, j.download, j.embed)
	case .Revoke: ok = share_revoke(j.path)
	}
	if ok {
		set_text(&cloud.progress, "")
		set_phase(.Idle)
	}
}

// Signs out on 401, otherwise says what failed. Always false.
@(private = "file")
request_failed :: proc(what: string, r: Http_Result) -> bool {
	if r.status == 401 {
		cloud_forget_token()
		fail("Your session ended. Sign in again.")
		return false
	}
	msg := r.err
	switch r.reason {
	case "QUOTA_EXCEEDED": msg = "the account's storage or shared-file limit is reached"
	case "TOO_LARGE", "PAYLOAD_TOO_LARGE": msg = "a file is larger than the account allows (50 MB per .pen, 25 MB per file)"
	case "TOO_MANY_REQUESTS": msg = "too many uploads in the last hour; try again later"
	case "INVALID_PEN": msg = "the server could not read the .pen"
	}
	fail("%s failed: %s", what, msg)
	return false
}

@(private = "file")
share_upload :: proc(path, name: string) -> bool {
	set_text(&cloud.progress, "Reading the files…")
	pen_sum, pen_size, pen_ok := sha256_file(path)
	if !pen_ok {
		fail("Could not read %s", path)
		return false
	}
	assets, missing := share_collect(path)
	blobs := make(map[string]string, context.temp_allocator) // hash -> file
	blobs[pen_sum] = path
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"name":%s,"pen":{{"hash":"%s","size":%d}},"assets":[`, json_quote(name), pen_sum, pen_size)
	for a, i in assets {
		sum, size, ok := sha256_file(a.abs)
		if !ok do continue
		blobs[sum] = a.abs
		fmt.sbprintf(&b, `%s{{"path":%s,"hash":"%s","size":%d,"type":"%s"}}`, "," if i > 0 else "", json_quote(a.rel), sum, size, a.type)
	}
	strings.write_string(&b, `],"missing":[`)
	for m, i in missing do fmt.sbprintf(&b, `%s%s`, "," if i > 0 else "", json_quote(m))
	strings.write_string(&b, "]}")
	body := strings.to_string(b)

	key := cloud_share_key(path)
	prev, had := cloud_share_of(path)
	set_text(&cloud.progress, "Preparing the upload…")
	start: Http_Result
	if had && prev.doc_id != "" {
		start = cloud_http("POST", fmt.tprintf("%s/api/docs/%s/versions", cloud_url(), prev.doc_id), body, cloud.token)
		if start.status == 404 { 	// deleted on the site: a new file
			had = false
			share_forget(key)
		}
	}
	if !had || prev.doc_id == "" do start = cloud_http("POST", fmt.tprintf("%s/api/docs", cloud_url()), body, cloud.token)
	if start.status != 201 && start.status != 200 do return request_failed("Sharing", start)
	obj, _ := start.json.(json.Object)
	doc_id := string(obj["docId"].(json.String) or_else "")
	version_id := string(obj["versionId"].(json.String) or_else "")
	uploads, _ := obj["uploads"].(json.Array)
	for u, i in uploads {
		uo, _ := u.(json.Object)
		sum := string(uo["hash"].(json.String) or_else "")
		file, known := blobs[sum]
		if !known {
			fail("The server asked for a file this document does not have")
			return false
		}
		set_text(&cloud.progress, "Uploading %d of %d…", i + 1, len(uploads))
		headers := make([dynamic]string, context.temp_allocator)
		if h, ok := uo["headers"].(json.Object); ok {
			for k, v in h do if s, sok := v.(json.String); sok do append(&headers, fmt.tprintf("%s: %s", k, string(s)))
		}
		method := string(uo["method"].(json.String) or_else "PUT")
		r := cloud_http(method, string(uo["url"].(json.String) or_else ""), upload = file, headers = headers[:])
		if r.status < 200 || r.status >= 300 do return request_failed("Uploading", r)
	}
	set_text(&cloud.progress, "Finishing…")
	commit := cloud_http("POST", fmt.tprintf("%s/api/docs/%s/versions/%s/commit", cloud_url(), doc_id, version_id), "{}", cloud.token)
	if commit.status != 200 do return request_failed("Sharing", commit)
	file_obj, _ := commit.json.(json.Object)
	if f, ok := file_obj["file"].(json.Object); ok do file_obj = f
	link: json.Object
	if links, ok := file_obj["links"].(json.Array); ok && len(links) > 0 do link, _ = links[0].(json.Object)
	if link == nil {
		r := cloud_http("POST", fmt.tprintf("%s/api/docs/%s/links", cloud_url(), doc_id), "{}", cloud.token)
		if r.status != 201 && r.status != 200 do return request_failed("Making the link", r)
		link, _ = r.json.(json.Object)
	}
	s := Cloud_Share {
		doc_id         = strings.clone(doc_id),
		version_id     = strings.clone(version_id),
		link_id        = strings.clone(string(link["id"].(json.String) or_else "")),
		url            = strings.clone(string(link["url"].(json.String) or_else "")),
		allow_download = link["allowDownload"].(json.Boolean) or_else false,
		allow_embed    = link["allowEmbed"].(json.Boolean) or_else false,
	}
	for m in missing do append(&s.missing, strings.clone(m))
	share_store(key, s)
	cloud.copied = true // the main thread puts the link on the clipboard
	platform_wake()
	return true
}

@(private = "file")
share_link_update :: proc(path: string, download, embed: bool) -> bool {
	s, ok := cloud_share_of(path)
	if !ok || s.link_id == "" do return true
	set_text(&cloud.progress, "Saving…")
	r := cloud_http("PATCH", fmt.tprintf("%s/api/links/%s", cloud_url(), s.link_id), fmt.tprintf(`{{"allowDownload":%v,"allowEmbed":%v}}`, download, embed), cloud.token)
	if r.status != 200 do return request_failed("Changing the link", r)
	link, _ := r.json.(json.Object)
	n := Cloud_Share {
		doc_id         = strings.clone(s.doc_id),
		version_id     = strings.clone(s.version_id),
		link_id        = strings.clone(s.link_id),
		url            = strings.clone(s.url),
		allow_download = link["allowDownload"].(json.Boolean) or_else download,
		allow_embed    = link["allowEmbed"].(json.Boolean) or_else embed,
	}
	for m in s.missing do append(&n.missing, strings.clone(m))
	share_store(cloud_share_key(path), n)
	return true
}

@(private = "file")
share_revoke :: proc(path: string) -> bool {
	s, ok := cloud_share_of(path)
	if !ok do return true
	set_text(&cloud.progress, "Turning the link off…")
	if s.link_id != "" {
		r := cloud_http("DELETE", fmt.tprintf("%s/api/links/%s", cloud_url(), s.link_id), bearer = cloud.token)
		if r.status != 200 && r.status != 204 && r.status != 404 && r.status != 410 do return request_failed("Turning the link off", r)
	}
	share_forget(cloud_share_key(path))
	return true
}

// ---------------------------------------------------------------- socket (tests)

// {"action": "status" | "signin" | "cancel" | "signout" | "share" | "settings" | "revoke",
//  "download", "embed"}: the state of the cloud for the open file. Sign-in reports the URL
// a test follows instead of a browser.
api_cloud :: proc(b: ^strings.Builder, params: json.Object) -> string {
	action := string(params["action"].(json.String) or_else "status")
	switch action {
	case "status":
	case "signin": cloud_sign_in()
	case "cancel": cloud_cancel()
	case "signout": cloud_sign_out()
	case "share":
		if app.tab < 0 do return "no document is open"
		if app.dirty do save_document(app.file_path)
		cloud_share(app.file_path, engine.file_title(app.file_path))
	case "settings":
		if app.tab < 0 do return "no document is open"
		cloud_share_settings(app.file_path, params["download"].(json.Boolean) or_else false, params["embed"].(json.Boolean) or_else false)
	case "revoke":
		if app.tab < 0 do return "no document is open"
		cloud_share_revoke(app.file_path)
	case "keychain-test":
		// stores, reads, replaces and deletes an item of a test service (not the token's)
		S :: "dev.kcrz.agentic-design.keychain-test"
		ok1 := keychain_set(S, "test", "Agentic Design (test)", "one")
		got1 := keychain_get(S, "test", context.temp_allocator)
		ok2 := keychain_set(S, "test", "Agentic Design (test)", "two")
		got2 := keychain_get(S, "test", context.temp_allocator)
		keychain_delete(S, "test")
		got3 := keychain_get(S, "test", context.temp_allocator)
		fmt.sbprintf(b, `{{"set":%v,"get":%s,"replace":%v,"after":%s,"deleted":%v}}`, ok1, json_quote(got1), ok2, json_quote(got2), got3 == "")
		return ""
	case "files":
		// what sharing would upload, without uploading
		if app.tab < 0 do return "no document is open"
		assets, missing := share_collect(app.file_path)
		strings.write_string(b, `{"assets":[`)
		for a, i in assets do fmt.sbprintf(b, `%s{{"path":%s,"type":"%s"}}`, "," if i > 0 else "", json_quote(a.rel), a.type)
		strings.write_string(b, `],"missing":[`)
		for m, i in missing do fmt.sbprintf(b, `%s%s`, "," if i > 0 else "", json_quote(m))
		strings.write_string(b, "]}")
		return ""
	case:
		return "action: status, signin, cancel, signout, share, settings, revoke or files"
	}
	phases := [Cloud_Phase]string{.Idle = "idle", .Signing_In = "signing in", .Working = "working", .Failed = "failed"}
	fmt.sbprintf(b, `{{"phase":"%s","running":%v,"signedIn":%v,"email":%s,"progress":%s,"error":%s,"signinUrl":%s,"cloud":%s`, phases[cloud_phase()], cloud.running, cloud_signed_in(), json_quote(cloud_text(&cloud.email)), json_quote(cloud_text(&cloud.progress)), json_quote(cloud_text(&cloud.error)), json_quote(cloud_text(&cloud.signin_url)), json_quote(cloud_url()))
	if app.tab >= 0 {
		if s, ok := cloud_share_of(app.file_path); ok {
			fmt.sbprintf(b, `,"share":{{"docId":%s,"versionId":%s,"linkId":%s,"url":%s,"allowDownload":%v,"allowEmbed":%v,"missing":[`, json_quote(s.doc_id), json_quote(s.version_id), json_quote(s.link_id), json_quote(s.url), s.allow_download, s.allow_embed)
			for m, i in s.missing do fmt.sbprintf(b, `%s%s`, "," if i > 0 else "", json_quote(m))
			strings.write_string(b, "]}")
		}
	}
	strings.write_string(b, "}")
	return ""
}
