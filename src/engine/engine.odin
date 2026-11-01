package engine

import "base:runtime"
import "core:slice"
import nvg "../nanovg"

// The .pen engine: the document model and its file format, variables and themes,
// libraries, layout, fonts and text, drawing, PNG and code export. It has no window, no
// input and no platform code: the app (or another host, later through a C API) gives it a
// NanoVG context to draw with, the document to work on and the theme to show.
//
// One engine per process: fonts and their glyph atlas live in the NanoVG context, and the
// state below is shared. It is not to be used from several threads at once.

// The NanoVG context the engine draws and measures text with (the host creates it).
renderer: ^nvg.Context

// The document that drawing, lookups and labels work on. The host points it at its
// document before drawing or asking; the app keeps one Document and swaps tabs into it.
current: ^Document

// Top-level layers on pages that are not shown (the host keeps the set; nil: none).
hidden: ^map[int]bool

is_hidden :: proc(uid: int) -> bool {
	return hidden != nil && hidden[uid]
}

// The theme shown: axis -> value (an axis left out shows its first value).
theme: map[string]string

// The allocator for code called from C (zlib's buffers): the host's, so that what the
// engine frees there and what the host frees match. Empty: the default heap.
allocator: runtime.Allocator

callback_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	if allocator.procedure != nil do c.allocator = allocator
	return c
}

// A map's keys, sorted, in the temporary allocator: maps iterate in an order that changes
// from run to run, and what the engine writes out (overrides, exports) must not.
sorted_keys :: proc(m: $M/map[$K]$V) -> []K {
	keys := make([]K, len(m), context.temp_allocator)
	i := 0
	for k in m {
		keys[i] = k
		i += 1
	}
	slice.sort(keys)
	return keys
}
