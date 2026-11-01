#+build js
package engine

import "core:strings"

// Files in a browser (see files.odin). A page has no file system: the host hands over the
// bytes of each file under the path the document knows it by (files_add), and reads come
// from this table. Reading a file that is not there yet puts its path on files_wanted;
// the host fetches those, adds them and reads the document again (src/web).
//
// Paths are absolute, '/'-separated and cleaned ("/designs/images/a.png"); the web host
// uses the URL path of a file on the page's server.

files_table: map[string][]u8
files_wanted: [dynamic]string
files_version: i64 // bumped by every files_add: the modification time of every folder

@(private = "file")
wanted_seen: map[string]bool

// Takes `data` (default allocator) as the file at `path`. A file is handed over once:
// loaded fonts point into its bytes (map_file), so a second copy is dropped.
files_add :: proc(path: string, data: []u8) {
	p := path_join("/", path)
	if p in files_table {
		delete(data)
		return
	}
	files_table[strings.clone(p)] = data
	files_version += 1
	// an image that could not be read before is read again when drawn
	if img, ok := images[p]; ok && img == 0 do delete_key(&images, p)
}

@(private = "file")
want :: proc(p: string) {
	if p in wanted_seen do return
	wanted_seen[strings.clone(p)] = true
	append(&files_wanted, strings.clone(p))
}

@(private = "file")
lookup :: proc(path: string) -> ([]u8, bool) {
	p := path_join("/", path)
	if data, ok := files_table[p]; ok do return data, true
	want(p)
	return nil, false
}

read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	data, ok := lookup(path)
	if !ok do return nil, false
	out := make([]u8, len(data), allocator)
	copy(out, data)
	return out, true
}

map_file :: proc(path: string) -> ([]u8, bool) {
	data, ok := lookup(path)
	return data, ok && len(data) > 0
}

unmap_file :: proc(data: []u8) {}

file_exists :: proc(path: string) -> bool {
	return path_join("/", path) in files_table
}

// A file's or a folder's "modification time": files_version while it exists, so that a
// folder is read again once files arrive.
file_mtime :: proc(path: string) -> i64 {
	p := path_join("/", path)
	if p in files_table do return files_version
	prefix := strings.concatenate({p, "/"}, context.temp_allocator)
	for k in files_table do if strings.has_prefix(k, prefix) do return files_version
	return -1
}

dir_names :: proc(path: string) -> ([]string, bool) {
	prefix := strings.concatenate({path_join("/", path), "/"}, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for k in files_table {
		if !strings.has_prefix(k, prefix) do continue
		rest := k[len(prefix):]
		if rest != "" && !strings.contains_rune(rest, '/') do append(&names, rest)
	}
	return names[:], len(names) > 0
}

// As core:os does on a POSIX system.

path_is_abs :: proc(path: string) -> bool {
	return strings.has_prefix(path, "/")
}

@(private = "file")
split :: proc(path: string) -> (dir, file: string) {
	i := strings.last_index_byte(path, '/')
	if i == 0 do return path[:1], path[1:]
	if i > 0 do return path[:i], path[i + 1:]
	return "", path
}

path_dir :: proc(path: string) -> string {
	if path == "" do return "."
	d, _ := split(path)
	return d
}

path_base :: proc(path: string) -> string {
	if path == "" do return "."
	_, f := split(path)
	return f
}

path_ext :: proc(path: string) -> string {
	_, f := split(path)
	if i := strings.last_index_byte(f, '.'); i >= 0 do return f[i:]
	return ""
}

// `rel` under `dir`, cleaned ("a/./b/../c" is "a/c"), in the temporary allocator.
path_join :: proc(dir, rel: string) -> string {
	full := rel if dir == "" else (dir if rel == "" else strings.concatenate({dir, "/", rel}, context.temp_allocator))
	abs := strings.has_prefix(full, "/")
	parts := make([dynamic]string, context.temp_allocator)
	for seg in strings.split(full, "/", context.temp_allocator) {
		switch seg {
		case "", ".":
		case "..":
			if len(parts) > 0 && parts[len(parts) - 1] != ".." do pop(&parts)
			else if !abs do append(&parts, seg)
		case:
			append(&parts, seg)
		}
	}
	joined := strings.join(parts[:], "/", context.temp_allocator)
	if abs do return strings.concatenate({"/", joined}, context.temp_allocator)
	return joined if joined != "" else "."
}

working_dir :: proc() -> (string, bool) {
	return "/", true
}

home_dir :: proc() -> string {
	return ""
}

cpu_count :: proc() -> int {
	return 1
}
