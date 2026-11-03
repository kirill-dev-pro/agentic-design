#+build js
package agentic_design

import "base:runtime"
import "core:strings"
import "core:time"
import "engine"

// The app's file system in a browser, with the names of fs_native.odin. Reads come from
// what the app wrote in this session (written) and then from the files the page handed the
// engine (engine.read_file: the document, its images, fonts and libraries). Writes are kept
// here and passed to the page (page_fs_write), which stores them where the document lives:
// the browser's private storage, a folder the user picked, later the cloud.

Fs_Error :: union {
	string,
}

Fs_File_Type :: enum {
	Undetermined,
	Regular,
	Directory,
}

Fs_File_Info :: struct {
	fullpath:          string,
	name:              string,
	size:              i64,
	type:              Fs_File_Type,
	modification_time: time.Time,
}

foreign import page "editor"

@(default_calling_convention = "contextless")
foreign page {
	page_fs_write :: proc(path: string, data: []u8) ---
	page_fs_remove :: proc(path: string) ---
	page_fs_rename :: proc(from, to: string) ---
}

@(private = "file")
written: map[string][]u8 // path -> bytes written in this session
@(private = "file")
written_time: map[string]time.Time

@(private = "file")
clean :: proc(path: string) -> string {
	return engine.path_join("/", path)
}

fs_read :: proc(path: string, allocator: runtime.Allocator) -> ([]u8, Fs_Error) {
	if data, ok := written[clean(path)]; ok {
		out := make([]u8, len(data), allocator)
		copy(out, data)
		return out, nil
	}
	if data, ok := engine.read_file(path, allocator); ok do return data, nil
	return nil, "not found"
}

fs_write_bytes :: proc(path: string, data: []u8, truncate := true) -> Fs_Error {
	p := clean(path)
	if old, ok := written[p]; ok {
		delete(old)
		written[p] = make([]u8, len(data))
	} else {
		written[strings.clone(p)] = make([]u8, len(data))
	}
	copy(written[p], data)
	if p in written_time do written_time[p] = time.now()
	else do written_time[strings.clone(p)] = time.now()
	page_fs_write(p, data)
	return nil
}

fs_write_string :: proc(path: string, data: string, truncate := true) -> Fs_Error {
	return fs_write_bytes(path, transmute([]u8)data, truncate)
}

fs_write :: proc {
	fs_write_bytes,
	fs_write_string,
}

fs_mkdir_all :: proc(path: string) -> Fs_Error {
	return nil // folders are implied by the files in them
}

fs_exists :: proc(path: string) -> bool {
	return clean(path) in written || engine.file_exists(path) || fs_is_dir(path)
}

fs_is_dir :: proc(path: string) -> bool {
	prefix := strings.concatenate({strings.trim_suffix(clean(path), "/"), "/"}, context.temp_allocator)
	for p in written do if strings.has_prefix(p, prefix) do return true
	names, ok := engine.dir_names(path)
	return ok && len(names) > 0
}

fs_copy :: proc(dst, src: string) -> Fs_Error {
	data, err := fs_read(src, context.temp_allocator)
	if err != nil do return err
	return fs_write_bytes(dst, data)
}

fs_rename :: proc(from, to: string) -> Fs_Error {
	data, err := fs_read(from, context.temp_allocator)
	if err != nil do return err
	if e := fs_write_bytes(to, data); e != nil do return e
	if old, ok := written[clean(from)]; ok {
		delete(old)
		delete_key(&written, clean(from))
	}
	page_fs_rename(clean(from), clean(to))
	return nil
}

fs_remove :: proc(path: string) -> Fs_Error {
	if old, ok := written[clean(path)]; ok {
		delete(old)
		delete_key(&written, clean(path))
	}
	page_fs_remove(clean(path))
	return nil
}

fs_stat :: proc(path: string, allocator: runtime.Allocator) -> (Fs_File_Info, Fs_Error) {
	p := clean(path)
	info := Fs_File_Info{fullpath = strings.clone(p, allocator), name = strings.clone(engine.path_base(p), allocator)}
	if data, ok := written[p]; ok {
		info.type = .Regular
		info.size = i64(len(data))
		info.modification_time = written_time[p]
		return info, nil
	}
	if engine.file_exists(p) {
		info.type = .Regular
		info.modification_time = time.Time{_nsec = engine.file_mtime(p)}
		return info, nil
	}
	if fs_is_dir(p) {
		info.type = .Directory
		return info, nil
	}
	return {}, "not found"
}

fs_list :: proc(path: string, allocator: runtime.Allocator) -> ([]Fs_File_Info, Fs_Error) {
	dir := strings.trim_suffix(clean(path), "/")
	seen := make(map[string]bool, 16, context.temp_allocator)
	out := make([dynamic]Fs_File_Info, allocator)
	add :: proc(out: ^[dynamic]Fs_File_Info, seen: ^map[string]bool, dir, name: string, allocator: runtime.Allocator) {
		if name == "" || name in seen do return
		seen[name] = true
		if info, err := fs_stat(strings.concatenate({dir, "/", name}, context.temp_allocator), allocator); err == nil do append(out, info)
	}
	for p in written {
		if !strings.has_prefix(p, dir) || len(p) <= len(dir) + 1 || p[len(dir)] != '/' do continue
		rest := p[len(dir) + 1:]
		name := rest[:strings.index_byte(rest, '/')] if strings.contains_rune(rest, '/') else rest
		add(&out, &seen, dir, name, allocator)
	}
	if names, ok := engine.dir_names(dir); ok do for n in names do add(&out, &seen, dir, n, allocator)
	return out[:], nil
}

fs_env :: proc(key: string, allocator: runtime.Allocator) -> string {
	return "" // a page has no environment
}

fs_home :: proc(allocator: runtime.Allocator) -> (string, Fs_Error) {
	return strings.clone(engine.home_dir(), allocator), nil
}

fs_temp_dir :: proc(allocator: runtime.Allocator) -> (string, Fs_Error) {
	return strings.clone("/tmp", allocator), nil
}

fs_executable :: proc(allocator: runtime.Allocator) -> (string, Fs_Error) {
	return "", "a page has no executable"
}

fs_dir :: proc(path: string) -> string {
	return engine.path_dir(path)
}

fs_base :: proc(path: string) -> string {
	return engine.path_base(path)
}

fs_path_is_abs :: proc(path: string) -> bool {
	return engine.path_is_abs(path)
}

fs_path_join :: proc(elems: []string, allocator := context.allocator) -> (string, Fs_Error) {
	out := ""
	for e in elems do out = engine.path_join(out, e) if out != "" else e
	return strings.clone(out, allocator), nil
}

// `target` relative to the folder `base` (both absolute): "a/b.png", "../x.png".
fs_path_rel :: proc(base, target: string, allocator := context.allocator) -> (string, Fs_Error) {
	a := strings.split(strings.trim(clean(base), "/"), "/", context.temp_allocator)
	b := strings.split(strings.trim(clean(target), "/"), "/", context.temp_allocator)
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] && a[i] != "" do i += 1
	parts := make([dynamic]string, context.temp_allocator)
	for k in i ..< len(a) do if a[k] != "" do append(&parts, "..")
	for p in b[i:] do append(&parts, p)
	return strings.join(parts[:], "/", allocator), nil
}

fs_args :: proc() -> []string {
	return nil
}
