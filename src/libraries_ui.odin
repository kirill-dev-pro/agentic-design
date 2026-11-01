package agentic_design

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "engine"

// Adds a library to the open document (path stored relative to it) and reads it.
library_add :: proc(path: string) -> (string, bool) {
	if path == app.file_path do return "", false
	imports := engine.doc_imports(&app.doc)
	if imports == nil do imports = make(json.Object, 1, context.temp_allocator)
	for _, rel in imports {
		p := string(rel.(json.String) or_else "")
		if !filepath.is_abs(p) do p, _ = filepath.join({filepath.dir(app.file_path), p}, context.temp_allocator)
		if p == path do return "", false
	}
	alias := engine.library_alias(&app.doc, path)
	rel, err := filepath.rel(filepath.dir(app.file_path), path, context.temp_allocator)
	if err != nil do rel = path
	if !strings.has_prefix(rel, ".") && !filepath.is_abs(rel) do rel = fmt.tprintf("./%s", rel)
	imports[alias] = json.String(rel)
	push_undo()
	engine.doc_set_header(&app.doc, "imports", imports)
	engine.doc_load_imports(&app.doc, app.file_path)
	engine.library_merge_axes(&app.doc, path)
	mark_dirty()
	return alias, true
}

library_remove :: proc(alias: string) {
	imports := engine.doc_imports(&app.doc)
	if imports == nil do return
	push_undo()
	delete_key(&imports, alias)
	engine.doc_set_header(&app.doc, "imports", imports if len(imports) > 0 else nil)
	engine.doc_load_imports(&app.doc, app.file_path)
	mark_dirty()
}

libraries_refresh :: proc() -> bool {
	if app.tab < 0 || app.file_path == "" do return false
	now := time.tick_now()
	if engine.lib_checked != {} && time.tick_diff(engine.lib_checked, now) < 2 * time.Second do return false
	engine.lib_checked = now
	imports := engine.doc_imports(&app.doc)
	b := strings.builder_make(context.temp_allocator)
	base := filepath.dir(app.file_path)
	names := make([dynamic]string, context.temp_allocator)
	for alias in imports do append(&names, alias)
	slice.sort(names[:])
	for alias in names {
		path := string(imports[alias].(json.String) or_else "")
		if !filepath.is_abs(path) do path, _ = filepath.join({base, path}, context.temp_allocator)
		mtime: i64 = -1
		if st, serr := os.stat(path, context.temp_allocator); serr == nil do mtime = st.modification_time._nsec
		fmt.sbprintf(&b, "%s=%s@%d;", alias, path, mtime)
	}
	stamp := strings.to_string(b)
	old, seen := engine.lib_stamps[app.file_path]
	if seen && old == stamp do return false
	if seen {
		delete(engine.lib_stamps[app.file_path])
		engine.lib_stamps[app.file_path] = strings.clone(stamp)
	} else {
		engine.lib_stamps[strings.clone(app.file_path)] = strings.clone(stamp)
	}
	// the first look only records; a changed import list is reloaded by set_libraries
	if !seen || len(imports) == 0 do return false
	engine.doc_load_imports(&app.doc, app.file_path)
	app.needs_layout = true
	return true
}
