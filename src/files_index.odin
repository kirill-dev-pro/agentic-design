#+build !js
package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Every .pen file on this Mac, for the dashboard (decision 82): what Spotlight knows
// (`mdfind`, instant) and a background walk of the home folder (Spotlight skips folders the
// user excluded, such as ~/Temp here), merged with the files opened in the app (recents).
// The walk skips what is never a user's design (~/Library, hidden folders, node_modules,
// build output, app bundles, tmp) and sleeps every few dozen folders, so a first scan costs
// about a second of one core spread over a few. It runs at launch of the dashboard and
// again when the dashboard is shown after FILES_RESCAN. Files and folders the user hid stay
// out (settings.dash_hidden).
//
// Test windows (AGENTIC_QUIET) index nothing unless AGENTIC_FILES_ROOT names a folder to
// index instead of the home folder, so a fuzzed window never lists the user's files.

FILES_RESCAN :: 10 * time.Minute

File_Item :: struct {
	path:              string,
	modified, created: i64, // unix seconds
	opened:            i64, // from recents (0 = never opened in the app)
}

files: struct {
	items:      [dynamic]File_Item, // main thread
	mutex:      sync.Mutex,
	found:      [dynamic]File_Item, // the worker's result, under mutex
	ready:      bool, // atomic: `found` waits to be taken
	running:    bool, // atomic: a scan is on
	scanned_at: time.Time,
	// the last scan, for the socket and the sidebar
	scan_ms:    int,
	scan_dirs:  int,
	spotlight:  int, // paths Spotlight returned
	last_trashed: string, // where the last file moved to the Trash went (tests)
}

files_root :: proc() -> string {
	if r := os.get_env("AGENTIC_FILES_ROOT", context.temp_allocator); r != "" do return r
	if pf.quiet do return ""
	home, _ := os.user_home_dir(context.temp_allocator)
	return home
}

// Starts a scan if none ran for FILES_RESCAN (or `force`).
files_refresh :: proc(force := false) {
	if sync.atomic_load(&files.running) do return
	root := files_root()
	if root == "" do return
	if !force && files.scanned_at != {} && time.since(files.scanned_at) < FILES_RESCAN do return
	files.scanned_at = time.now()
	sync.atomic_store(&files.running, true)
	r := new(string)
	r^ = strings.clone(root)
	thread.create_and_start_with_data(r, proc(data: rawptr) {
			context = app_context()
			r := (^string)(data)
			root := r^
			free(r)
			files_scan(root)
		}, app_context(), self_cleanup = true)
}

// A folder that never holds a user's designs.
files_skip_dir :: proc(name: string) -> bool {
	if strings.has_prefix(name, ".") do return true
	switch name {
	case "Library", "node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData", "tmp", "Caches", "__pycache__":
		return true
	}
	return strings.has_suffix(name, ".app") || strings.has_suffix(name, ".bundle") || strings.has_suffix(name, ".framework")
}

@(private = "file")
is_pen :: proc(name: string) -> bool {
	return len(name) > 4 && strings.equal_fold(name[len(name) - 4:], ".pen")
}

@(private = "file")
files_scan :: proc(root: string) {
	defer delete(root)
	defer sync.atomic_store(&files.running, false)
	start := time.tick_now()
	seen := make(map[string]File_Item, 256, context.allocator)
	defer delete(seen)
	add :: proc(seen: ^map[string]File_Item, path: string, modified, created: i64) {
		if path in seen do return
		seen[strings.clone(path)] = File_Item{path = "", modified = modified, created = created}
	}
	// what Spotlight knows, at once (the walk below finds the rest)
	spot := 0
	if os.get_env("AGENTIC_FILES_NO_SPOTLIGHT", context.temp_allocator) == "" {
		state, out, _, err := os.process_exec({command = {"/usr/bin/mdfind", "-0", "-onlyin", root, "kMDItemFSName == '*.pen'c"}}, context.allocator)
		if err == nil && state.exited && state.exit_code == 0 {
			for p in strings.split(string(out), "\x00", context.temp_allocator) {
				if p == "" || !is_pen(p) || !files_wanted(p, root) do continue
				st, serr := os.stat(p, context.temp_allocator)
				if serr != nil do continue
				add(&seen, p, st.modification_time._nsec / 1e9, st.creation_time._nsec / 1e9)
				spot += 1
			}
		}
		delete(out)
	}
	// the walk: folders by hand, no symlinks followed
	stack := make([dynamic]string, context.allocator)
	defer delete(stack)
	append(&stack, strings.clone(root))
	dirs := 0
	for len(stack) > 0 && dirs < 200_000 {
		dir := pop(&stack)
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		delete(dir)
		if err != nil do continue
		for info in infos {
			#partial switch info.type {
			case .Directory:
				if !files_skip_dir(info.name) do append(&stack, strings.clone(info.fullpath))
			case .Regular:
				if is_pen(info.name) do add(&seen, info.fullpath, info.modification_time._nsec / 1e9, info.creation_time._nsec / 1e9)
			}
		}
		os.file_info_slice_delete(infos, context.allocator)
		dirs += 1
		if dirs % 48 == 0 {
			free_all(context.temp_allocator)
			time.sleep(2 * time.Millisecond) // a background chore: leave the cores to the user
		}
	}
	for d in stack do delete(d)

	found := make([dynamic]File_Item, 0, len(seen), context.allocator)
	for path, it in seen {
		item := it
		item.path = path // the key's clone, now owned by `found`
		append(&found, item)
	}
	sync.mutex_lock(&files.mutex)
	for it in files.found do delete(it.path)
	delete(files.found)
	files.found = found
	files.scan_ms = int(time.duration_milliseconds(time.tick_since(start)))
	files.scan_dirs = dirs
	files.spotlight = spot
	sync.mutex_unlock(&files.mutex)
	sync.atomic_store(&files.ready, true)
	platform_wake()
}

// Not under a skipped folder (Spotlight's paths are checked the same way as the walk's).
@(private = "file")
files_wanted :: proc(path, root: string) -> bool {
	if !strings.has_prefix(path, root) do return false
	rest := strings.trim_prefix(path[len(root):], "/")
	parts := strings.split(rest, "/", context.temp_allocator)
	for p in parts[:max(len(parts) - 1, 0)] do if files_skip_dir(p) do return false
	return true // hidden ones are left out when listed (settings belong to the main thread)
}

// Hidden by the user: the file, or a folder above it.
files_hidden :: proc(path: string) -> bool {
	for h in settings.dash_hidden {
		if path == h || (strings.has_prefix(path, h) && len(path) > len(h) && path[len(h)] == '/') do return true
	}
	return false
}

// Once a frame while the dashboard shows: takes a finished scan, merges the recents in.
files_poll :: proc() {
	if !sync.atomic_load(&files.ready) do return
	sync.mutex_lock(&files.mutex)
	found := files.found
	files.found = {}
	sync.atomic_store(&files.ready, false)
	sync.mutex_unlock(&files.mutex)
	for it in files.items do delete(it.path)
	delete(files.items)
	files.items = found
}

// The files to show: the scan, plus recents it does not have (outside the home folder, or
// opened before the first scan finished), without hidden or vanished ones, with the time
// each was last opened. Temporary allocator.
files_list :: proc(only_opened: bool) -> []File_Item {
	out := make([dynamic]File_Item, 0, len(files.items) + len(recents), context.temp_allocator)
	opened := make(map[string]i64, len(recents), context.temp_allocator)
	for r in recents do opened[r.path] = r.time
	listed := make(map[string]bool, len(files.items), context.temp_allocator)
	for it in files.items {
		item := it
		item.opened = opened[it.path] or_else 0
		listed[it.path] = true
		if only_opened && item.opened == 0 do continue
		if files_hidden(it.path) || !fs_exists(it.path) do continue
		append(&out, item)
	}
	for r in recents {
		if r.path in listed || files_hidden(r.path) do continue
		st, err := os.stat(r.path, context.temp_allocator)
		if err != nil do continue
		append(&out, File_Item{r.path, st.modification_time._nsec / 1e9, st.creation_time._nsec / 1e9, r.time})
	}
	switch {
	case only_opened:
		slice.sort_by(out[:], proc(a, b: File_Item) -> bool {return a.opened > b.opened})
	case:
		switch settings.dash_sort {
		case .Modified: slice.sort_by(out[:], proc(a, b: File_Item) -> bool {return a.modified > b.modified})
		case .Created: slice.sort_by(out[:], proc(a, b: File_Item) -> bool {return a.created > b.created})
		case .Opened:
			// opened ones first, by when; the rest by last modified
			slice.sort_by(out[:], proc(a, b: File_Item) -> bool {
				if a.opened != b.opened do return a.opened > b.opened
				return a.modified > b.modified
			})
		case .Name:
			slice.sort_by(out[:], proc(a, b: File_Item) -> bool {
				na, nb := strings.to_lower(fs_base(a.path), context.temp_allocator), strings.to_lower(fs_base(b.path), context.temp_allocator)
				if na != nb do return na < nb
				return a.path < b.path
			})
		}
	}
	return out[:]
}

// Hides a file, or every file under a folder, from the dashboard (the files stay).
files_hide :: proc(path: string) {
	if files_hidden(path) do return
	append(&settings.dash_hidden, strings.clone(path))
	settings_save()
	recents_remove(path) // a hidden file is not a recent one either
}

files_unhide_all :: proc() {
	for h in settings.dash_hidden do delete(h)
	clear(&settings.dash_hidden)
	settings_save()
	files_refresh(force = true)
}

// Moves a file to the Trash (never deletes it). Refused for a document open in a tab, and in
// a test window for anything outside AGENTIC_FILES_ROOT.
files_trash :: proc(path: string) -> (ok: bool, msg: string) {
	for t, i in app.tabs {
		p := app.file_path if i == app.tab else t.path
		if same_file(p, path) do return false, fmt.tprintf("“%s” is open in a tab. Close the tab first.", fs_base(path))
	}
	if pf.quiet {
		root := os.get_env("AGENTIC_FILES_ROOT", context.temp_allocator)
		if root == "" || !strings.has_prefix(path, root) do return false, "Test windows only move files under AGENTIC_FILES_ROOT to the Trash"
	}
	if !fs_exists(path) do return false, fmt.tprintf("“%s” is no longer there", fs_base(path))
	trashed, err := move_to_trash(path)
	if err != "" do return false, fmt.tprintf("Could not move “%s” to the Trash: %s", fs_base(path), err)
	delete(files.last_trashed)
	files.last_trashed = strings.clone(trashed)
	recents_remove(path)
	for it, i in files.items do if it.path == path {
		delete(it.path)
		ordered_remove(&files.items, i)
		break
	}
	return true, fmt.tprintf("Moved “%s” to the Trash", fs_base(path))
}

// ---------------------------------------------------------------- socket (tests)

// {"action": "status" | "refresh" | "sort" | "view" | "select" | "remove" | "hide" |
// "unhide" | "trash", "path", "sort": "modified" | "opened" | "name" | "created",
// "view": "all" | "recents"}: the dashboard's list as shown, the last scan and the previews
// waiting. "trash" asks for the confirmation, as the Delete key does.
api_dashboard :: proc(b: ^strings.Builder, params: json.Object) -> string {
	action := string(params["action"].(json.String) or_else "status")
	path := string(params["path"].(json.String) or_else "")
	switch action {
	case "status":
	case "refresh": files_refresh(force = true)
	case "sort":
		key := string(params["sort"].(json.String) or_else "")
		found := false
		for k in Dash_Sort do if DASH_SORT_KEYS[k] == key {
			settings.dash_sort = k
			found = true
		}
		if !found do return "sort: modified, opened, name or created"
		settings_save()
	case "view": dash.recents = string(params["view"].(json.String) or_else "all") == "recents"
	case "select":
		delete(dash.selected)
		dash.selected = strings.clone(path)
	case "remove": files_hide(path)
	case "hide": files_hide(fs_dir(path))
	case "unhide": files_unhide_all()
	case "trash":
		if app.tab >= 0 do return "the dashboard is not shown"
		dash_confirm_trash(path)
	case:
		return "action: status, refresh, sort, view, select, remove, hide, unhide or trash"
	}
	files_poll()
	items := files_list(dash.recents)
	fmt.sbprintf(b, `{{"scanning":%v,"scanMs":%d,"scanDirs":%d,"spotlight":%d,"sort":"%s","view":"%s","selected":%s,"dialog":%v,"previewsWaiting":%d,"lastTrashed":%s,"hidden":%s,"items":[`, sync.atomic_load(&files.running), files.scan_ms, files.scan_dirs, files.spotlight, DASH_SORT_KEYS[settings.dash_sort], "recents" if dash.recents else "all", json_quote(dash.selected), ui.dialog.open, len(thumb_queue), json_quote(files.last_trashed), json_string_array(settings.dash_hidden[:]))
	for it, i in items {
		has_thumb := false
		if st, err := os.stat(thumb_path(it.path), context.temp_allocator); err == nil do has_thumb = st.modification_time._nsec / 1e9 >= it.modified
		fmt.sbprintf(b, `%s{{"path":%s,"modified":%d,"created":%d,"opened":%d,"preview":%v}}`, "," if i > 0 else "", json_quote(it.path), it.modified, it.created, it.opened, has_thumb)
	}
	strings.write_string(b, "]}")
	return ""
}
