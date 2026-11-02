#+build js
package engine

import "core:c"
import stbiw "vendor:stb/image"

// PNG encoding in a browser, where there is no system zlib (png.odin): stb_image_write's
// encoder, on one thread. The same image as png.odin's (RGB, alpha ignored), compressed a
// little less.

PNG_LEVEL :: 6

png_write :: proc(pixels: []u8, w, h: int, allocator := context.allocator, level := PNG_LEVEL, threads := 0) -> (png: []u8, ok: bool) {
	if w <= 0 || h <= 0 || len(pixels) < w * h * 4 do return
	out := make([dynamic]u8, allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = callback_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	rgb := make([]u8, w * h * 3, context.temp_allocator)
	for i in 0 ..< w * h do rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]
	if stbiw.write_png_to_func(write, &out, c.int(w), c.int(h), 3, raw_data(rgb), c.int(w * 3)) == 0 {
		delete(out)
		return nil, false
	}
	return out[:], true
}

// RGBA rows, top row first (as gpu_read gives them), to a PNG in the temporary allocator.
png_encode :: proc(pixels: []u8, w, h: i32) -> (png: []u8, ok: bool) {
	return png_write(pixels, int(w), int(h), context.temp_allocator)
}

// No zlib here: PDF streams are written uncompressed (pdf.odin's stream takes nil as that).
pdf_deflate :: proc(data: []u8) -> []u8 {
	return nil
}
