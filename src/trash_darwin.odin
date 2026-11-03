package agentic_design

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSFileManager")
File_Manager :: struct {
	using _: NS.Object,
}

// Moves a file to the Trash of its volume, as Finder does (it can be put back). Returns where
// it went, or the error.
move_to_trash :: proc(path: string) -> (trashed: string, err_text: string) {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	fm := intrinsics.objc_send(^File_Manager, File_Manager, "defaultManager")
	err: ^NS.Error
	result: ^NS.URL
	if intrinsics.objc_send(NS.BOOL, fm, "trashItemAtURL:resultingItemURL:error:", ns_file_url(path), &result, &err) {
		if result != nil do trashed = string_clone_temp(intrinsics.objc_send(^NS.String, result, "path")->odinString())
		return trashed, ""
	}
	if err != nil do return "", string_clone_temp(err->localizedDescription()->odinString())
	return "", "the system refused"
}

@(private = "file")
string_clone_temp :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	copy(b, s)
	return string(b)
}
