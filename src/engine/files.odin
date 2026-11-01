package engine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Files: paths, and mapping a file into memory.

absolute_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if os.is_absolute_path(path) do return strings.clone(path, allocator)
	wd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return strings.clone(path, allocator)
	return fmt.aprintf("%s/%s", wd, path, allocator = allocator)
}
file_title :: proc(path: string) -> string {
	base := os.base(path)
	if strings.has_suffix(base, ".pen") do base = base[:len(base) - 4]
	return base
}

// ---------------------------------------------------------------- sidebar
// A file mapped read-only into memory: its pages are the file's, clean, and the system
// drops and rereads them as it likes; they do not count against the app as a copy read
// into memory does. Fonts are used this way (the system UI font alone is 9 MB).
map_file :: proc(path: string) -> ([]u8, bool) {
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

unmap_file :: proc(data: []u8) {
	if len(data) > 0 do posix.munmap(raw_data(data), uint(len(data)))
}
