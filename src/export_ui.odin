package agentic_design

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "engine"

// Writes the files into a folder next to the document (or `dir`) and returns it.
export_code_to_dir :: proc(format: engine.Code_Format, dir := "", roots: []int = nil) -> (string, bool) {
	files := engine.generate_code(&app.doc, format, roots)
	target := dir
	if target == "" do target = fmt.tprintf("%s/%s-%s", downloads_dir(), engine.file_title(app.file_path), "html" if format == .HTML else "react")
	if err := os.make_directory_all(target); err != nil && !os.is_dir(target) do return target, false // fails on an existing folder
	for f in files {
		if err := os.write_entire_file(fmt.tprintf("%s/%s", target, f.name), f.content); err != nil do return target, false
	}
	// the fonts and images the code refers to, next to it
	for rel, src in engine.export_assets {
		dst := fmt.tprintf("%s/%s", target, rel)
		_ = os.make_directory_all(os.dir(dst))
		if os.exists(dst) do _ = os.remove(dst)
		if err := os.copy_file(dst, src); err != nil do return target, false
	}
	return target, true
}

// Where exports go: ~/Downloads, or for a quiet (test) window a folder in $TMPDIR.
// ~/Downloads is privacy-protected: the first write from a process without access waits
// in open() for the user to answer a system prompt, which froze a fuzzed test window (and
// would show the user a dialog).
downloads_dir :: proc() -> string {
	if pf.quiet {
		dir := fmt.tprintf("%s/agentic-design-downloads", strings.trim_suffix(os.temp_directory(context.temp_allocator) or_else "/tmp", "/"))
		_ = os.make_directory_all(dir)
		return dir
	}
	home, _ := os.user_home_dir(context.temp_allocator)
	return fmt.tprintf("%s/Downloads", home)
}
