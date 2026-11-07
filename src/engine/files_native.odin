#+build !js
package engine

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// Files on a desktop system (see files.odin).

read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, allocator)
	return data, err == nil
}

// A file mapped read-only into memory: its pages are the file's, clean, and the system
// drops and rereads them as it likes; they do not count against the app as a copy read
// into memory does. Fonts are used this way (the system UI font alone is 9 MB).
map_file :: proc(path: string) -> ([]u8, bool) {
	when ODIN_OS == .Windows {
		// (a mapping would hold the file open: read it; unmap_file frees it)
		data, err := os.read_entire_file(path, context.allocator)
		return data, err == nil && len(data) > 0
	} else {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		fd := posix.open(cpath, {})
		if fd < 0 do return nil, false
		defer posix.close(fd)
		st: posix.stat_t
		if posix.fstat(fd, &st) != .OK || st.st_size <= 0 do return nil, false
		p := posix.mmap(nil, uint(st.st_size), {.READ}, {.PRIVATE}, fd, 0)
		if p == posix.MAP_FAILED do return nil, false
		return ([^]u8)(p)[:int(st.st_size)], true
	}
}

unmap_file :: proc(data: []u8) {
	when ODIN_OS == .Windows do delete(data)
	else do if len(data) > 0 do posix.munmap(raw_data(data), uint(len(data)))
}

file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

file_mtime :: proc(path: string) -> i64 {
	st, err := os.stat(path, context.temp_allocator)
	return st.modification_time._nsec if err == nil else -1
}

dir_names :: proc(path: string) -> ([]string, bool) {
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil do return nil, false
	names := make([]string, len(infos), context.temp_allocator)
	for info, i in infos do names[i] = info.name
	return names, true
}

path_is_abs :: proc(path: string) -> bool {
	return os.is_absolute_path(path)
}

path_dir :: proc(path: string) -> string {
	return os.dir(path)
}

path_base :: proc(path: string) -> string {
	return os.base(path)
}

path_ext :: proc(path: string) -> string {
	return os.ext(path)
}

// `rel` under `dir`, cleaned ("a/./b/../c" is "a/c"), in the temporary allocator.
path_join :: proc(dir, rel: string) -> string {
	p, _ := filepath.join({dir, rel}, context.temp_allocator)
	return p
}

working_dir :: proc() -> (string, bool) {
	wd, err := os.get_working_directory(context.temp_allocator)
	return wd, err == nil
}

home_dir :: proc() -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	return home
}

cpu_count :: proc() -> int {
	return os.get_processor_core_count()
}
