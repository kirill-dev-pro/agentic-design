package agentic_design

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "engine"

// Copies font files into the `fonts` folder next to the document and lists them in its
// "fonts", as pen.dev's "Add custom fonts" does, so the file shows them in both apps and on
// any machine (an undoable change to the document).
import_font_files :: proc(paths: []string) -> (count: int) {
	dir := fmt.tprintf("%s/fonts", fs_dir(app.file_path))
	// make_directory_all fails on a folder that exists: a second import used to stop here
	if err := fs_mkdir_all(dir); err != nil && !fs_is_dir(dir) {
		set_status("Could not create %s", dir)
		return
	}
	list := make(json.Array, 0, 4, context.temp_allocator)
	for p in app.doc.header do if p.key == "fonts" {
		if v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator); err == nil do if a, ok := v.(json.Array); ok do append(&list, ..a[:])
	}
	for p in paths {
		if !engine.is_font_file(p) do continue
		data, err := fs_read(p, context.temp_allocator)
		if err != nil do continue
		to := fmt.tprintf("%s/%s", dir, fs_base(p))
		if fs_write(to, data) != nil do continue
		count += 1
		if strings.has_suffix(strings.to_lower(to, context.temp_allocator), ".ttc") do continue // pen.dev reads no collections
		url := fmt.tprintf("./fonts/%s", fs_base(p))
		infos := engine.font_file_infos(to)
		if len(infos) == 0 do continue
		for i := len(list) - 1; i >= 0; i -= 1 {
			if e, ok := list[i].(json.Object); ok && string(e["url"].(json.String) or_else "") == url do ordered_remove(&list, i)
		}
		append(&list, engine.font_declaration(infos[0], url))
	}
	if count == 0 {
		set_status("No .ttf, .otf, .ttc or .woff files to import (woff2 is not supported)")
		return
	}
	if dir in engine.font_dirs_seen do engine.font_dirs_seen[dir] = -2 // read it again
	engine.fonts_scan_dir(dir)
	engine.fonts_sort_names()
	push_undo()
	engine.doc_set_header(&app.doc, "fonts", list if len(list) > 0 else nil)
	engine.fonts_add_declared(list, fs_dir(app.file_path)) // the families count as the document's now (lint, font menu)
	mark_dirty()
	set_status("Added %d font file%s to the document (fonts/ next to it)", count, "" if count == 1 else "s")
	return
}

// add_fonts: font files by path, or installed families by name, copied into the
// document's fonts/ folder and listed under "fonts" (one undo step per call).
api_add_fonts :: proc(b: ^strings.Builder, params: json.Object) -> string {
	if app.file_path == "" do return "no document is open"
	paths := make([dynamic]string, context.temp_allocator)
	if arr, ok := params["paths"].(json.Array); ok {
		for v in arr {
			p := engine.absolute_path(string(v.(json.String) or_else ""))
			if !fs_exists(p) do return fmt.tprintf("no such file: %s", p)
			if !engine.is_font_file(p) do return fmt.tprintf("%s is not a .ttf, .otf, .ttc or .woff file (woff2 is not supported)", p)
			append(&paths, p)
		}
	}
	engine.fonts_scan()
	if arr, ok := params["families"].(json.Array); ok {
		for v in arr {
			name := string(v.(json.String) or_else "")
			fam := engine.family_find(name)
			if fam == nil do return fmt.tprintf("font family \"%s\" is not installed on this Mac; pass its files in paths", name)
			usable := 0
			for f in fam.faces {
				if strings.has_suffix(strings.to_lower(f.path, context.temp_allocator), ".ttc") do continue
				usable += 1
				if !slice.contains(paths[:], f.path) do append(&paths, f.path)
			}
			if usable == 0 do return fmt.tprintf("\"%s\" is installed only as a .ttc collection (%s), which pen.dev cannot read, so it cannot become part of the document; use a font with .ttf or .otf files (for code, a Google Fonts family such as JetBrains Mono or Roboto Mono)", name, fam.faces[0].path if len(fam.faces) > 0 else "")
		}
	}
	if len(paths) == 0 do return "pass paths (font files) or families (installed family names)"
	count := import_font_files(paths[:])
	if count == 0 do return "no font file could be copied"
	fmt.sbprintf(b, `{{"copied":%d,"fonts":`, count)
	write_header_value(b, "fonts")
	strings.write_byte(b, '}')
	return ""
}
