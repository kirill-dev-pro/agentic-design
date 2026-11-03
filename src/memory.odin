#+build !js
package agentic_design

import "engine"

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"

foreign import libc "system:System.framework"

@(default_calling_convention = "c")
foreign libc {
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: uint) -> uint ---
}

// The app's allocator. Blocks of 256 KB and more come straight from the system (mmap)
// and go straight back when freed (munmap); smaller ones from the usual heap. macOS's
// malloc keeps freed large blocks for reuse ("Malloc Large (empty)"), and they counted
// against the app: 20 screenshots left 77 MB that no pressure relief returned. The
// per-frame arena's extra blocks, a screenshot's pixels and PNG, and big responses are
// such blocks. Freeing a pointer this allocator did not make (a heap block) works too.
BIG_BLOCK :: 256 * 1024

big_blocks: map[uintptr]int
big_sites: map[uintptr]runtime.Source_Code_Location // where each was asked for (the `memory` report)
big_mutex: sync.Mutex

big_allocator :: proc "contextless" () -> runtime.Allocator {
	return {big_allocator_proc, nil}
}

// The context for code called from C (GLFW and Cocoa callbacks, crash handler): the app's
// allocator, so that what it frees and what the rest of the app frees match.
app_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = big_allocator()
	return c
}

big_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	heap := runtime.heap_allocator()
	big_size :: proc(p: rawptr) -> (int, bool) {
		// mmap hands out whole pages: anything else is the heap's
		if p == nil || uintptr(p) & 4095 != 0 do return 0, false
		sync.mutex_lock(&big_mutex)
		defer sync.mutex_unlock(&big_mutex)
		n, ok := big_blocks[uintptr(p)]
		return n, ok
	}
	big_alloc :: proc(size: int, loc: runtime.Source_Code_Location) -> ([]byte, runtime.Allocator_Error) {
		p := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		if p == posix.MAP_FAILED do return nil, .Out_Of_Memory
		sync.mutex_lock(&big_mutex)
		// The maps live on the heap, always: a map takes its allocator from the context of
		// its first insert, which could be the per-frame arena (cleared every frame) or an
		// allocator that comes back here, so that growing it under big_mutex locked
		// big_mutex again on the same thread (a window frozen for good).
		if big_blocks == nil do big_blocks = make(map[uintptr]int, 64, runtime.heap_allocator())
		if big_sites == nil do big_sites = make(map[uintptr]runtime.Source_Code_Location, 64, runtime.heap_allocator())
		big_blocks[uintptr(p)] = size
		big_sites[uintptr(p)] = loc
		sync.mutex_unlock(&big_mutex)
		return ([^]byte)(p)[:size], nil // zeroed by the system
	}
	big_free :: proc(p: rawptr, size: int) {
		sync.mutex_lock(&big_mutex)
		delete_key(&big_blocks, uintptr(p))
		delete_key(&big_sites, uintptr(p))
		sync.mutex_unlock(&big_mutex)
		posix.munmap(p, uint(size))
	}
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size < BIG_BLOCK || alignment > 4096 do return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
		return big_alloc(size, loc)
	case .Free:
		if n, ok := big_size(old_memory); ok {
			big_free(old_memory, n)
			return nil, nil
		}
		return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil do return big_allocator_proc(data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		n, was_big := big_size(old_memory)
		if !was_big && size < BIG_BLOCK do return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
		if size == 0 {
			big_allocator_proc(data, .Free, 0, alignment, old_memory, old_size, loc)
			return nil, nil
		}
		out, err := big_allocator_proc(data, .Alloc, size, alignment, nil, 0, loc)
		if err != nil do return nil, err
		have := n if was_big else old_size
		copy(out, ([^]byte)(old_memory)[:min(have, size)])
		big_allocator_proc(data, .Free, 0, alignment, old_memory, old_size, loc)
		return out, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

// The per-frame arena takes its new blocks from it (set once, on the main thread).
use_big_allocator_for_temp :: proc() {
	if temp := (^runtime.Default_Temp_Allocator)(context.temp_allocator.data); temp != nil {
		temp.arena.backing_allocator = big_allocator()
	}
}

// Gives memory freed after a burst of work (a screenshot's pixels, a big request, the
// temporary arena's extra blocks) back to the system: macOS keeps freed large blocks
// for reuse, and they count against the app until it does. Once per quiet spell.
memory_trim :: proc() -> uint {
	engine.gpu_trim()
	return malloc_zone_pressure_relief(nil, 0)
}

// What the app holds, for the `memory` request: where the bytes go, so that performance
// work measures instead of guessing. Sizes are estimates of the data structures (the
// allocator's overhead and the GPU's own copies are not counted).

node_bytes :: proc(n: ^engine.Node) -> int {
	b := size_of(engine.Node) + len(n.id) + len(n.name) + len(n.content) + len(n.font_family) + len(n.type_name)
	b += cap(n.props) * size_of(engine.Prop)
	for p in n.props do b += len(p.key) + len(p.raw)
	return b
}

// A step's own part: its list of layers (the records it shares are counted once, in
// undo_records_bytes).
snapshot_bytes :: proc(s: engine.Snapshot) -> int {
	return len(s.nodes) * size_of(rawptr)
}

undo_records_bytes :: proc() -> int {
	b := 0
	for _, r in engine.node_records do b += size_of(engine.Node_Record) + node_bytes(&r.node) - size_of(engine.Node)
	for _, r in engine.header_records {
		b += size_of(engine.Header_Record) + len(r.lib_vars)
		for p in r.props do b += len(p.key) + len(p.raw) + size_of(engine.Prop)
	}
	return b
}

api_memory :: proc(b: ^strings.Builder) {
	doc := &app.doc
	nodes_b, ghosts_b := 0, 0
	for &n in doc.nodes do nodes_b += node_bytes(&n)
	for &n in doc.ghosts do ghosts_b += node_bytes(&n)
	undo_b, redo_b := 0, 0
	for s in app.undo_stack do undo_b += snapshot_bytes(s)
	for s in app.redo_stack do redo_b += snapshot_bytes(s)
	tabs_b := 0
	for &t, i in app.tabs {
		if i == app.tab do continue // the open one lives in app.doc
		for &n in t.doc.nodes do tabs_b += node_bytes(&n)
		for s in t.undo_stack do tabs_b += snapshot_bytes(s)
		for s in t.redo_stack do tabs_b += snapshot_bytes(s)
	}
	text_b := 0
	for _, m in engine.text_cache do text_b += size_of(engine.Text_Metrics) + len(m.rows) * size_of([2]int)
	outline_b := 0
	for _, o in engine.outline_cache do outline_b += len(o.verts) * size_of(o.verts[0]) + len(o.signs)
	fonts_b, glyphs := 0, 0
	for f in app.vg.fs.fonts {
		fonts_b += len(f.loadedData)
		glyphs += len(f.glyphs)
	}
	blur_px := 0
	for bb in engine.blur_buffers do blur_px += bb.w * bb.h * 2
	temp := (^runtime.Default_Temp_Allocator)(context.temp_allocator.data)
	temp_cap := 0
	if temp != nil do temp_cap = int(temp.arena.total_capacity)
	fb := platform_framebuffer_size()
	// big blocks by where they were asked for
	big_total := 0
	by_site := make(map[string]int, 16, context.temp_allocator)
	sync.mutex_lock(&big_mutex)
	for p, n in big_blocks {
		big_total += n
		l := big_sites[p]
		by_site[fmt.tprintf("%s:%d %s", l.file_path[strings.last_index_byte(l.file_path, '/') + 1:], l.line, l.procedure)] += n
	}
	sync.mutex_unlock(&big_mutex)
	fmt.sbprintf(b, `{{"big_blocks":%d,"big_bytes":%d,"big_sites":{{`, len(big_blocks), big_total)
	first := true
	for k, n in by_site {
		if !first do strings.write_byte(b, ',')
		first = false
		engine.json_write_string(b, k)
		fmt.sbprintf(b, ":%d", n)
	}
	strings.write_string(b, "},")
	fmt.sbprintf(
		b,
		`"node_size":%d,"nodes":%d,"nodes_bytes":%d,"ghosts":%d,"ghosts_bytes":%d,"undo":%d,"undo_bytes":%d,"undo_records":%d,"undo_records_bytes":%d,"redo":%d,"redo_bytes":%d,"other_tabs_bytes":%d,"text_cache":%d,"text_cache_bytes":%d,"outline_cache":%d,"outline_bytes":%d,"fonts":%d,"font_data_bytes":%d,"glyphs":%d,"atlas":[%d,%d],"images":%d,"gradient_textures":%d,"thumbnails":%d,"blur_buffers":%d,"blur_texture_bytes":%d,"var_instances":%d,"temp_arena_bytes":%d,"framebuffer":[%d,%d],"gpu_allocated_bytes":%d}}`,
		size_of(engine.Node), len(doc.nodes), nodes_b, len(doc.ghosts), ghosts_b, len(app.undo_stack), undo_b, len(engine.node_records), undo_records_bytes(), len(app.redo_stack), redo_b, tabs_b,
		len(engine.text_cache), text_b, len(engine.outline_cache), outline_b, len(app.vg.fs.fonts), fonts_b, glyphs, app.vg.fs.width, app.vg.fs.height,
		len(engine.images), len(engine.gradient_images), len(thumbs), len(engine.blur_buffers), blur_px * 4, len(engine.var_instances), temp_cap, fb.x, fb.y, engine.gpu_allocated(),
	)
}
