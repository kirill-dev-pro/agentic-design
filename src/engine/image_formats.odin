package engine

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import stbiw "vendor:stb/image"

// Image formats for export (pen.dev offers PNG, JPEG, WEBP and PDF). Pixels come from
// render_region: RGBA rows, bottom-up as OpenGL reads them.
//   PNG, JPEG  stb_image_write
//   WEBP       lossless VP8L with fixed 8-bit codes: no compression, but exact and
//              readable everywhere (macOS has no WebP encoder)
//   PDF        one page the size of the image in points at 1×, the image inside

Export_Format :: enum {
	PNG,
	JPEG,
	WEBP,
	PDF,
}

EXPORT_FORMATS := [Export_Format]string{.PNG = "PNG", .JPEG = "JPEG", .WEBP = "WEBP", .PDF = "PDF"}
EXPORT_EXTENSIONS := [Export_Format]string{.PNG = "png", .JPEG = "jpg", .WEBP = "webp", .PDF = "pdf"}

export_format_from :: proc(s: string) -> (Export_Format, bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "png": return .PNG, true
	case "jpg", "jpeg": return .JPEG, true
	case "webp": return .WEBP, true
	case "pdf": return .PDF, true
	}
	return .PNG, false
}

// Encodes GL pixels (flipped here, alpha made opaque) as `format`. `scale` is pixels per
// design unit, for the PDF page size.
encode_image :: proc(pixels: []u8, w, h: i32, format: Export_Format, scale: f32 = 1) -> ([]u8, bool) {
	if format == .PNG do return png_encode(pixels, w, h)
	flip_rows(pixels, w, h)
	switch format {
	case .PNG:
	case .JPEG: return jpeg_encode(pixels, w, h, 92)
	case .WEBP: return webp_encode(pixels, w, h)
	case .PDF:
		jpg, ok := jpeg_encode(pixels, w, h, 95)
		if !ok do return nil, false
		return pdf_with_image(jpg, w, h, f32(w) / scale, f32(h) / scale), true
	}
	return nil, false
}

flip_rows :: proc(pixels: []u8, w, h: i32) {
	row := int(w * 4)
	tmp := make([]u8, row, context.temp_allocator)
	for y in 0 ..< int(h) / 2 {
		a := pixels[y * row:][:row]
		b := pixels[(int(h) - 1 - y) * row:][:row]
		copy(tmp, a)
		copy(a, b)
		copy(b, tmp)
	}
	for i := 3; i < len(pixels); i += 4 do pixels[i] = 255
}

jpeg_encode :: proc(pixels: []u8, w, h: i32, quality: int) -> ([]u8, bool) {
	out := make([dynamic]u8, context.temp_allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = callback_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	// JPEG has no alpha: write RGB
	rgb := make([]u8, int(w * h * 3), context.temp_allocator)
	for i in 0 ..< int(w * h) do rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]
	if stbiw.write_jpg_to_func(write, &out, c.int(w), c.int(h), 3, raw_data(rgb), c.int(quality)) == 0 do return nil, false
	return out[:], true
}

// ---------------------------------------------------------------- WEBP

Bit_Writer :: struct {
	out:  [dynamic]u8,
	acc:  u64,
	bits: uint,
}

bits_put :: proc(w: ^Bit_Writer, v: u64, n: uint) {
	w.acc |= v << w.bits
	w.bits += n
	for w.bits >= 8 {
		append(&w.out, u8(w.acc))
		w.acc >>= 8
		w.bits -= 8
	}
}

// A prefix code in which the first `used` symbols all have length 8 and the others
// none (a complete code when used = 256), written with a two-symbol code-length code.
webp_put_code :: proc(w: ^Bit_Writer, alphabet, used: int) {
	bits_put(w, 0, 1) // normal code
	// code lengths of the code-length alphabet, in the order 17 18 0 1 2 3 4 5 16 6 7 8:
	// symbols 0 and 8 get length 1, everything else 0
	bits_put(w, 12 - 4, 4)
	order := [12]int{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8}
	for s in order do bits_put(w, 1 if s == 0 || s == 8 else 0, 3)
	bits_put(w, 0, 1) // every symbol has a length
	// canonical codes: symbol 0 is "0", symbol 8 is "1"
	for i in 0 ..< alphabet do bits_put(w, 1 if i < used else 0, 1)
}

// An 8-bit canonical code is the value itself, sent most significant bit first.
webp_put_byte :: proc(w: ^Bit_Writer, v: u8) {
	r: u64
	for i in 0 ..< 8 do r |= u64((v >> uint(7 - i)) & 1) << uint(i)
	bits_put(w, r, 8)
}

webp_encode :: proc(pixels: []u8, w, h: i32) -> ([]u8, bool) {
	if w > 16384 || h > 16384 do return nil, false
	bw := Bit_Writer{out = make([dynamic]u8, 0, int(w * h * 4) + 64, context.temp_allocator)}
	bits_put(&bw, 0x2f, 8) // signature
	bits_put(&bw, u64(w - 1), 14)
	bits_put(&bw, u64(h - 1), 14)
	bits_put(&bw, 0, 1) // no alpha
	bits_put(&bw, 0, 3) // version
	bits_put(&bw, 0, 1) // no transform
	bits_put(&bw, 0, 1) // no colour cache
	bits_put(&bw, 0, 1) // one prefix code group
	webp_put_code(&bw, 256 + 24, 256) // green and lengths
	webp_put_code(&bw, 256, 256) // red
	webp_put_code(&bw, 256, 256) // blue
	webp_put_code(&bw, 256, 256) // alpha
	// distance: a simple code with one symbol (never used)
	bits_put(&bw, 1, 1)
	bits_put(&bw, 0, 1)
	bits_put(&bw, 0, 1)
	bits_put(&bw, 0, 1)
	for i in 0 ..< int(w * h) {
		p := pixels[i * 4:]
		webp_put_byte(&bw, p[1])
		webp_put_byte(&bw, p[0])
		webp_put_byte(&bw, p[2])
		webp_put_byte(&bw, p[3])
	}
	if bw.bits > 0 do append(&bw.out, u8(bw.acc))
	vp8l := bw.out[:]
	out := make([dynamic]u8, 0, len(vp8l) + 32, context.temp_allocator)
	le32 :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	pad := len(vp8l) & 1
	append(&out, "RIFF")
	le32(&out, 4 + 8 + len(vp8l) + pad)
	append(&out, "WEBPVP8L")
	le32(&out, len(vp8l))
	append(&out, ..vp8l)
	if pad == 1 do append(&out, 0)
	return out[:], true
}

// ---------------------------------------------------------------- PDF

// A one-page PDF showing a JPEG at `pw` × `ph` points.
pdf_with_image :: proc(jpg: []u8, w, h: i32, pw, ph: f32) -> []u8 {
	out := make([dynamic]u8, 0, len(jpg) + 1024, context.temp_allocator)
	offsets: [6]int
	put :: proc(out: ^[dynamic]u8, s: string) {append(out, s)}
	put(&out, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
	content := fmt.tprintf("q %s 0 0 %s 0 0 cm /Im0 Do Q\n", num_text(pw), num_text(ph))
	offsets[1] = len(out)
	put(&out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
	offsets[2] = len(out)
	put(&out, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
	offsets[3] = len(out)
	put(&out, fmt.tprintf("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n", num_text(pw), num_text(ph)))
	offsets[4] = len(out)
	put(&out, fmt.tprintf("4 0 obj\n<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n", w, h, len(jpg)))
	append(&out, ..jpg)
	put(&out, "\nendstream\nendobj\n")
	offsets[5] = len(out)
	put(&out, fmt.tprintf("5 0 obj\n<< /Length %d >>\nstream\n%sendstream\nendobj\n", len(content), content))
	xref := len(out)
	put(&out, "xref\n0 6\n0000000000 65535 f \n")
	for i in 1 ..< 6 do put(&out, fmt.tprintf("%010d 00000 n \n", offsets[i]))
	put(&out, fmt.tprintf("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", xref))
	return out[:]
}
