#+build !js
package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:strings"
import "core:sync"
import "core:thread"

// Opening a cloud document in the app (the site's "Open in app": agentic-design://open?doc=<id>).
// Its latest version, the .pen and the files beside it, comes down into the app's cache
// (<support>/cloud/<id>/), opens in a tab, and goes live: the room's document replaces the
// version's at once (cloud_live.odin). The cache only holds the tab's files; the room keeps
// the document.

@(private = "file")
Opened :: struct {
	id, name, path, err: string,
}

@(private = "file")
opening: struct {
	lock:    sync.Mutex,
	done:    [dynamic]Opened,
	pending: map[string]bool,
}

// agentic-design://open?doc=<id>
cloud_open_url :: proc(url: string) {
	q := url[strings.index_byte(url, '?') + 1:] if strings.contains_rune(url, '?') else ""
	for part in strings.split(q, "&", context.temp_allocator) {
		if strings.has_prefix(part, "doc=") {
			if id := url_decode(part[4:]); id != "" do cloud_open_doc(id)
			return
		}
	}
	set_status("That link names no cloud file")
}

cloud_open_doc :: proc(id: string) {
	cloud_load()
	if !cloud_signed_in() {
		set_status("Sign in to the cloud first (Settings → Account), then open the file again")
		return
	}
	// open already: its tab
	if live.doc_id == id {
		for t, i in app.tabs do if t.path == live.path do tab_activate(i)
		if app.file_path == live.path do return
	}
	if opening.pending[id] do return
	opening.pending[strings.clone(id)] = true
	set_status("Opening the cloud file…")
	job := new(string)
	job^ = strings.clone(id)
	thread.create_and_start_with_data(job, cloud_open_worker, app_context(), self_cleanup = true)
}

// Runs between frames: what the downloads finished.
cloud_open_tick :: proc() {
	sync.mutex_lock(&opening.lock)
	done := opening.done
	opening.done = {}
	sync.mutex_unlock(&opening.lock)
	defer delete(done)
	for o in done {
		if k, ok := opening.pending[o.id]; ok {
			_ = k
			delete_key(&opening.pending, o.id)
		}
		if o.err != "" {
			set_status("%s", o.err)
		} else if open_in_tab(o.path) {
			live_open(o.id, o.path, o.name)
			set_status("“%s” is open live: changes go to everyone in it", o.name)
		} else {
			set_status("The cloud file could not be read")
		}
		delete(o.id)
		delete(o.name)
		delete(o.path)
		delete(o.err)
	}
}

// Whether a path is a cloud document's copy in the cache (kept out of Recents).
cloud_cache_path :: proc(path: string) -> bool {
	return strings.has_prefix(path, fmt.tprintf("%s/cloud/", support_dir()))
}

@(private = "file")
cloud_open_worker :: proc(data: rawptr) {
	job := (^string)(data)
	id := job^
	free(job)
	out := Opened{id = id}
	defer {
		sync.mutex_lock(&opening.lock)
		append(&opening.done, out)
		sync.mutex_unlock(&opening.lock)
		platform_wake()
		free_all(context.temp_allocator)
	}
	base := cloud_url()
	r := cloud_http("GET", fmt.tprintf("%s/api/docs/%s", base, id), bearer = cloud.token)
	switch {
	case r.status == 401:
		out.err = strings.clone("Sign in to the cloud again (Settings → Account) to open this file")
		return
	case r.status == 404:
		out.err = strings.clone("This cloud file is not there: it was deleted, or it is not shared with this account")
		return
	case r.status != 200:
		out.err = fmt.aprintf("The cloud file could not be opened: %s", r.err)
		return
	}
	o := r.json.(json.Object) or_else nil
	doc_url := string(o["docUrl"].(json.String) or_else "")
	name := string(o["name"].(json.String) or_else "Untitled")
	if doc_url == "" {
		out.err = strings.clone("This cloud file has no version yet")
		return
	}
	// /api/docs/<id>/v/<version>/<the .pen's path>
	marker := fmt.tprintf("/api/docs/%s/v/", id)
	at := strings.index(doc_url, marker)
	if at < 0 {
		out.err = strings.clone("The cloud answered with an unexpected file address")
		return
	}
	after := doc_url[at + len(marker):]
	slash := strings.index_byte(after, '/')
	version_base := doc_url[:at + len(marker) + slash + 1]
	rel := after[slash + 1:]
	rel_dir := slashpath.dir(rel)
	if rel_dir == "." do rel_dir = ""
	dir := fmt.tprintf("%s/cloud/%s", support_dir(), safe_name(id))
	pen_dir := slashpath.join({dir, rel_dir}, context.temp_allocator) if rel_dir != "" else dir
	_ = os.make_directory_all(pen_dir)
	pen := cloud_http("GET", fmt.tprintf("%s%s", base, doc_url), bearer = cloud.token)
	if pen.status != 200 {
		out.err = fmt.aprintf("The cloud file could not be downloaded (%d)", pen.status)
		return
	}
	path := fmt.tprintf("%s/%s.pen", pen_dir, safe_name(name))
	if os.write_entire_file(path, transmute([]u8)pen.body) != nil {
		out.err = strings.clone("The cloud file could not be written to the app's cache")
		return
	}
	// the images, fonts and libraries beside it (relative to the .pen)
	for a in o["assets"].(json.Array) or_else nil {
		p := string(a.(json.String) or_else "")
		if p == "" do continue
		local := slashpath.join({pen_dir, p}, context.temp_allocator)
		if !strings.has_prefix(local, dir) do continue // outside the document's folder
		if os.exists(local) do continue
		in_version := slashpath.join({rel_dir, p}, context.temp_allocator) if rel_dir != "" else slashpath.clean(p, context.temp_allocator)
		got := cloud_http("GET", fmt.tprintf("%s%s%s", base, version_base, url_path_encode(in_version)), bearer = cloud.token)
		if got.status != 200 do continue
		_ = os.make_directory_all(slashpath.dir(local))
		_ = os.write_entire_file(local, transmute([]u8)got.body)
	}
	out.name = strings.clone(name)
	out.path = strings.clone(path)
}

// A name for a file: what the systems refuse in names goes.
@(private = "file")
safe_name :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in s {
		switch c {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 ..< ' ': strings.write_byte(&b, ' ')
		case: strings.write_rune(&b, c)
		}
	}
	out := strings.trim_space(strings.to_string(b))
	return out if out != "" && out != "." && out != ".." else "Untitled"
}

// Each segment of a relative path, percent-encoded.
@(private = "file")
url_path_encode :: proc(p: string) -> string {
	parts := strings.split(p, "/", context.temp_allocator)
	for &s in parts do s = url_encode(s)
	return strings.join(parts, "/", context.temp_allocator)
}
