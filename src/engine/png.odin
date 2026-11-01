package engine

import "base:runtime"
import "core:c"
import "core:os"
import "core:thread"

// PNG encoding with the system's zlib. stb_image_write used to do it, in C with C's malloc:
// each window-sized screenshot left 20-30 MB of freed blocks that macOS's malloc kept, and
// a session of agent screenshots grew to hundreds of megabytes. Here every buffer comes
// from the app's allocator (memory.odin), so it goes back when freed. Screenshots are
// opaque, so the image is RGB; each row gets the PNG filter with the smallest sum of
// magnitudes, as libpng and stb choose; zlib compresses better than stb's encoder did.
//
// The rows are split into horizontal strips that are filtered and deflated on several
// threads at once, as pigz does: each strip is a raw deflate stream that ends on a byte
// boundary (Z_SYNC_FLUSH), the last one finishes the stream, and the strips' Adler-32
// checksums are combined. A 16384 × 3535 canvas takes 40 ms instead of 1.2 s on one
// thread (2.5 s with stb); see docs/performance.md.

foreign import libz "system:z"

Z_Stream :: struct {
	next_in:   [^]u8,
	avail_in:  c.uint,
	total_in:  c.ulong,
	next_out:  [^]u8,
	avail_out: c.uint,
	total_out: c.ulong,
	msg:       cstring,
	state:     rawptr,
	zalloc:    proc "c" (opaque: rawptr, items, size: c.uint) -> rawptr,
	zfree:     proc "c" (opaque: rawptr, address: rawptr),
	opaque:    rawptr,
	data_type: c.int,
	adler:     c.ulong,
	reserved:  c.ulong,
}

Z_OK :: 0
Z_STREAM_END :: 1
Z_SYNC_FLUSH :: 2
Z_FINISH :: 4
Z_DEFLATED :: 8
Z_DEFAULT_STRATEGY :: 0
Z_FILTERED :: 1

@(default_calling_convention = "c")
foreign libz {
	zlibVersion :: proc() -> cstring ---
	deflateInit2_ :: proc(strm: ^Z_Stream, level, method, windowBits, memLevel, strategy: c.int, version: cstring, stream_size: c.int) -> c.int ---
	deflate :: proc(strm: ^Z_Stream, flush: c.int) -> c.int ---
	deflateEnd :: proc(strm: ^Z_Stream) -> c.int ---
	deflateBound :: proc(strm: ^Z_Stream, sourceLen: c.ulong) -> c.ulong ---
	crc32 :: proc(crc: c.ulong, buf: [^]u8, len: c.uint) -> c.ulong ---
	adler32 :: proc(adler: c.ulong, buf: [^]u8, len: c.uint) -> c.ulong ---
	adler32_combine :: proc(adler1, adler2: c.ulong, len2: i64) -> c.ulong ---
}

PNG_LEVEL :: 6

// zlib's allocations (its window and hash tables) through the app's allocator.
@(private = "file")
z_alloc :: proc "c" (opaque: rawptr, items, size: c.uint) -> rawptr {
	context = callback_context()
	n := int(items) * int(size)
	// a header in front keeps the size for the free
	p, err := runtime.mem_alloc_non_zeroed(n + 16, 16)
	if err != nil do return nil
	(^int)(raw_data(p))^ = n + 16
	return rawptr(uintptr(raw_data(p)) + 16)
}

@(private = "file")
z_free :: proc "c" (opaque: rawptr, address: rawptr) {
	context = callback_context()
	base := rawptr(uintptr(address) - 16)
	runtime.mem_free_with_size(base, (^int)(base)^)
}

@(private = "file")
Png_Strip :: struct {
	src:        []u8, // RGBA rows, top-down order handled by the caller's row lookup
	pixels:     []u8,
	w, h:       int,
	y0, y1:     int, // rows of the image (top-down) this strip covers
	last:       bool,
	level:      c.int,
	filtered:   []u8,
	out:        []u8,
	out_len:    int,
	adler:      c.ulong,
	ok:         bool,
}

// Row y of the image.
@(private = "file")
png_row :: #force_inline proc(s: ^Png_Strip, y: int) -> []u8 {
	stride := s.w * 4
	return s.pixels[y * stride:][:stride]
}

@(private = "file")
png_filter_rows :: proc(s: ^Png_Strip) {
	w := s.w
	n := w * 3
	line := n + 1
	scratch := make([]u8, line * 5 + n * 2)
	defer delete(scratch)
	cand: [5][]u8
	for f in 0 ..< 5 do cand[f] = scratch[f * line:][:line]
	cur := scratch[line * 5:][:n]
	prev := scratch[line * 5 + n:][:n] // zero above the first row, as PNG defines it
	rgb :: proc(dst, src: []u8, w: int) {
		for x in 0 ..< w do dst[x * 3], dst[x * 3 + 1], dst[x * 3 + 2] = src[x * 4], src[x * 4 + 1], src[x * 4 + 2]
	}
	if s.y0 > 0 do rgb(prev, png_row(s, s.y0 - 1), w)
	for y in s.y0 ..< s.y1 {
		rgb(cur, png_row(s, y), w)
		best, best_sum := 0, max(int)
		for f in 0 ..< 5 {
			o := cand[f]
			png_filter_one(o, cur, prev, f)
			sum := 0
			for v in o[1:] do sum += int(abs(i8(v))) if v != 128 else 128
			if sum < best_sum do best, best_sum = f, sum
		}
		copy(s.filtered[(y - s.y0) * line:][:line], cand[best])
		cur, prev = prev, cur
	}
}

// One PNG filter of a row; `prev` is the row above (zeros for the first row).
@(private = "file")
png_filter_one :: proc(dst, cur, prev: []u8, f: int) {
	dst[0] = u8(f)
	n := len(cur)
	d := dst[1:]
	switch f {
	case 0:
		copy(d, cur)
	case 1:
		for i in 0 ..< 3 do d[i] = cur[i]
		for i in 3 ..< n do d[i] = cur[i] - cur[i - 3]
	case 2:
		for i in 0 ..< n do d[i] = cur[i] - prev[i]
	case 3:
		for i in 0 ..< 3 do d[i] = cur[i] - prev[i] / 2
		for i in 3 ..< n do d[i] = cur[i] - u8((u32(cur[i - 3]) + u32(prev[i])) / 2)
	case 4:
		for i in 0 ..< 3 do d[i] = cur[i] - prev[i] // Paeth with a = c = 0 predicts b
		for i in 3 ..< n {
			a, b, cc := i32(cur[i - 3]), i32(prev[i]), i32(prev[i - 3])
			pa, pb, pc := abs(b - cc), abs(a - cc), abs(a + b - 2 * cc)
			pred := a if pa <= pb && pa <= pc else (b if pb <= pc else cc)
			d[i] = cur[i] - u8(pred)
		}
	}
}

@(private = "file")
png_strip_work :: proc(s: ^Png_Strip) {
	png_filter_rows(s)
	n := len(s.filtered)
	s.adler = adler32(adler32(0, nil, 0), raw_data(s.filtered), c.uint(n))
	z := Z_Stream{zalloc = z_alloc, zfree = z_free}
	if deflateInit2_(&z, s.level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), size_of(Z_Stream)) != Z_OK do return
	defer deflateEnd(&z)
	bound := int(deflateBound(&z, c.ulong(n))) + 64
	s.out = make([]u8, bound)
	z.next_in = raw_data(s.filtered)
	z.avail_in = c.uint(n)
	z.next_out = raw_data(s.out)
	z.avail_out = c.uint(bound)
	r := deflate(&z, Z_FINISH if s.last else Z_SYNC_FLUSH)
	if s.last && r != Z_STREAM_END do return
	if !s.last && (r != Z_OK || z.avail_in != 0) do return
	s.out_len = bound - int(z.avail_out)
	s.ok = true
}

// Encodes w × h RGBA pixels (top row first, alpha ignored) as an RGB PNG.
// The result is allocated with `allocator`.
png_write :: proc(pixels: []u8, w, h: int, allocator := context.allocator, level := PNG_LEVEL, threads := 0) -> (png: []u8, ok: bool) {
	if w <= 0 || h <= 0 || len(pixels) < w * h * 4 do return
	line := w * 3 + 1
	// strips of at least 64 rows and 256 KB of input, one per core at most
	n := threads if threads > 0 else max(1, os.get_processor_core_count())
	n = clamp(min(n, h / 64, (line * h) / (256 * 1024)), 1, 16)
	filtered := make([]u8, line * h)
	defer delete(filtered)
	strips := make([]Png_Strip, n)
	defer delete(strips)
	for i in 0 ..< n {
		y0, y1 := h * i / n, h * (i + 1) / n
		strips[i] = {
			pixels    = pixels,
			w         = w,
			h         = h,
			y0        = y0,
			y1        = y1,
			last      = i == n - 1,
			level     = c.int(level),
			filtered  = filtered[y0 * line:y1 * line],
		}
	}
	if n == 1 {
		png_strip_work(&strips[0])
	} else {
		ts := make([]^thread.Thread, n - 1)
		defer delete(ts)
		for i in 1 ..< n {
			ts[i - 1] = thread.create_and_start_with_poly_data(&strips[i], png_strip_work, callback_context())
		}
		png_strip_work(&strips[0])
		for t in ts {
			thread.join(t)
			thread.destroy(t)
		}
	}
	defer for s in strips do delete(s.out)
	total := 0
	adler := adler32(0, nil, 0)
	for s in strips {
		if !s.ok do return
		total += s.out_len
		adler = adler32_combine(adler, s.adler, i64(len(s.filtered)))
	}

	// signature, IHDR, IDAT (zlib header + strips + Adler-32), IEND
	size := 8 + (12 + 13) + (12 + 2 + total + 4) + 12
	out := make([]u8, size, allocator)
	p := 0
	put :: proc(out: []u8, p: ^int, b: []u8) {
		copy(out[p^:], b)
		p^ += len(b)
	}
	put_u32 :: proc(out: []u8, p: ^int, v: u32) {
		out[p^], out[p^ + 1], out[p^ + 2], out[p^ + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
		p^ += 4
	}
	chunk_end :: proc(out: []u8, p: ^int, start: int) {
		// CRC over type and data
		crc := crc32(crc32(0, nil, 0), raw_data(out[start:]), c.uint(p^ - start))
		put_u32(out, p, u32(crc))
	}
	put(out, &p, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	put_u32(out, &p, 13)
	start := p
	put(out, &p, {'I', 'H', 'D', 'R'})
	put_u32(out, &p, u32(w))
	put_u32(out, &p, u32(h))
	put(out, &p, {8, 2, 0, 0, 0}) // 8 bits, RGB, deflate, adaptive filtering, no interlace
	chunk_end(out, &p, start)
	put_u32(out, &p, u32(2 + total + 4))
	start = p
	put(out, &p, {'I', 'D', 'A', 'T'})
	put(out, &p, {0x78, 0x9c}) // zlib header: deflate, 32 KB window, default level
	for s in strips do put(out, &p, s.out[:s.out_len])
	put_u32(out, &p, u32(adler))
	// crc32 takes a c.uint length: chunks over 4 GB never happen (at most 100 Mpx)
	chunk_end(out, &p, start)
	put_u32(out, &p, 0)
	start = p
	put(out, &p, {'I', 'E', 'N', 'D'})
	chunk_end(out, &p, start)
	return out, true
}


// Bottom-up RGBA rows (as glReadPixels gives them) to a PNG, in the temporary allocator.
png_encode :: proc(pixels: []u8, w, h: i32) -> (png: []u8, ok: bool) {
	return png_write(pixels, int(w), int(h), context.temp_allocator)
}
