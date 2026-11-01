package engine

import "core:fmt"
import "core:strings"

// Files: everything the engine asks of the system goes through these few procs. On a
// desktop (files_native.odin) they are core:os; in a browser (files_js.odin) there are no
// files, and the page hands the engine the bytes of each file the document needs.
//
//   read_file(path, allocator) -> ([]u8, bool)
//                           a file's bytes (a copy, the caller's to free)
//   map_file(path) -> ([]u8, bool), unmap_file(data)
//                           a file's bytes without a copy where the system can map it
//   file_exists(path) -> bool
//   file_mtime(path) -> i64 a file's or folder's modification time (-1: none)
//   dir_names(path) -> ([]string, bool)
//                           the names in a folder (temp allocator)
//   path_is_abs, path_dir, path_base, path_ext, path_join
//                           paths as core:os reads them ('/' separators)
//   working_dir() -> (string, bool), home_dir() -> string

absolute_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path_is_abs(path) do return strings.clone(path, allocator)
	wd, ok := working_dir()
	if !ok do return strings.clone(path, allocator)
	return fmt.aprintf("%s/%s", wd, path, allocator = allocator)
}

file_title :: proc(path: string) -> string {
	base := path_base(path)
	if strings.has_suffix(base, ".pen") do base = base[:len(base) - 4]
	return base
}
