package agentic_design

import "core:strings"

// The app's version: the one place it is written. The bundle script puts it into
// Info.plist, the release workflow checks the tag against it, and the updater compares
// it with the update manifest. A build can override it (-define:VERSION=0.1.1) to make a
// test update; releases never do.
VERSION :: #config(VERSION, "0.5.2")

BUNDLE_ID :: "dev.kcrz.agentic-design"
APP_NAME :: "Agentic Design"

// The .app this binary runs from ("/Applications/Agentic Design.app"), or "" when it runs
// from a build directory.
bundle_path :: proc() -> string {
	exe, err := fs_executable(context.temp_allocator)
	if err != nil do return ""
	i := strings.index(exe, ".app/Contents/MacOS/")
	if i < 0 do return ""
	return exe[:i + len(".app")]
}

// macOS runs a quarantined app that was not moved out of its download folder from a
// random read-only copy (App Translocation). Updates and agent registration need the real
// location.
bundle_translocated :: proc() -> bool {
	return strings.contains(bundle_path(), "/AppTranslocation/")
}

// Contents/Resources of the bundle, or "" outside one.
bundle_resources :: proc() -> string {
	b := bundle_path()
	return strings.concatenate({b, "/Contents/Resources"}, context.temp_allocator) if b != "" else ""
}

// "0.1.10" > "0.1.9": the numeric parts compared in order (a missing part is 0).
version_newer :: proc(a, b: string) -> bool {
	pa, pb := strings.split(a, ".", context.temp_allocator), strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< max(len(pa), len(pb)) {
		x := version_part(pa[i]) if i < len(pa) else 0
		y := version_part(pb[i]) if i < len(pb) else 0
		if x != y do return x > y
	}
	return false
}

@(private = "file")
version_part :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c < '0' || c > '9' do break
		n = n * 10 + int(c - '0')
	}
	return n
}
