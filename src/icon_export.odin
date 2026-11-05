#+build !js
package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Icon sets from one layer (D67): every size drawn from the layer itself (not scaled down from
// one big image), on a transparent background.
//
//   macos:   AppIcon.iconset (16-512 at 1x and 2x) and AppIcon.icns (iconutil)
//   favicon: favicon.ico (16, 32, 48), favicon-16.png, favicon-32.png,
//            apple-touch-icon.png (180), icon-192.png, icon-512.png

@(private = "file")
Icon_File :: struct {
	name: string,
	size: int,
}

@(private = "file")
MACOS_ICONSET := [?]Icon_File {
	{"icon_16x16.png", 16},
	{"icon_16x16@2x.png", 32},
	{"icon_32x32.png", 32},
	{"icon_32x32@2x.png", 64},
	{"icon_128x128.png", 128},
	{"icon_128x128@2x.png", 256},
	{"icon_256x256.png", 256},
	{"icon_256x256@2x.png", 512},
	{"icon_512x512.png", 512},
	{"icon_512x512@2x.png", 1024},
}

@(private = "file")
FAVICONS := [?]Icon_File{{"favicon-16.png", 16}, {"favicon-32.png", 32}, {"apple-touch-icon.png", 180}, {"icon-192.png", 192}, {"icon-512.png", 512}}

// The layer at `size` × `size` pixels (its longer side), transparent, as a PNG.
@(private = "file")
icon_png :: proc(n: ^engine.Node, size: int) -> ([]u8, bool) {
	r := engine.node_page_box(n)
	if r[2] <= 0 || r[3] <= 0 do return nil, false
	pixels, w, h, ok := render_region(r, f32(size) / max(r[2], r[3]), n, {0, 0, 0, 0})
	if !ok do return nil, false
	return engine.png_encode(pixels, w, h, true)
}

// An .ico holding PNG images (Windows Vista and every browser read those).
@(private = "file")
ico_from_pngs :: proc(sizes: []int, pngs: [][]u8) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	u16le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8))}
	u32le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	u16le(&b, 0)
	u16le(&b, 1) // icon
	u16le(&b, len(pngs))
	offset := 6 + 16 * len(pngs)
	for p, i in pngs {
		s := sizes[i]
		append(&b, u8(s if s < 256 else 0), u8(s if s < 256 else 0), 0, 0)
		u16le(&b, 1) // planes
		u16le(&b, 32) // bits per pixel
		u32le(&b, len(p))
		u32le(&b, offset)
		offset += len(p)
	}
	for p in pngs do append(&b, ..p)
	return b[:]
}

// {"id", "path": folder, "kinds": ["macos", "favicon"]}: writes the icon files and lists them.
api_export_icons :: proc(b: ^strings.Builder, params: json.Object) -> string {
	id := string(params["id"].(json.String) or_else "")
	n, _ := engine.doc_find(&app.doc, id)
	if n == nil do return "pass the id of the layer to make icons from (a square frame, e.g. 1024 × 1024)"
	dir := string(params["path"].(json.String) or_else "")
	if dir == "" do return "pass path: the folder to write the icons into"
	dir = engine.absolute_path(dir)
	kinds := make([dynamic]string, context.temp_allocator)
	if arr, ok := params["kinds"].(json.Array); ok {
		for k in arr do append(&kinds, string(k.(json.String) or_else ""))
	} else do append(&kinds, "macos", "favicon")
	// an existing folder is fine (D109)
	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil do return fmt.tprintf("could not create %s: %v", dir, err)
	}
	written := make([dynamic]string, context.temp_allocator)
	warnings := make([dynamic]string, context.temp_allocator)
	write :: proc(path: string, data: []u8, written: ^[dynamic]string) -> string {
		if err := os.write_entire_file(path, data); err != nil do return fmt.tprintf("could not write %s: %v", path, err)
		append(written, path)
		return ""
	}
	box := engine.node_page_box(n)
	if abs(box[2] - box[3]) > 0.5 do append(&warnings, fmt.tprintf("the layer is %s × %s, not square: icons keep its shape inside a square of each size", engine.num_text(box[2]), engine.num_text(box[3])))
	for kind in kinds {
		switch kind {
		case "macos":
			set := fmt.tprintf("%s/AppIcon.iconset", dir)
			_ = os.make_directory_all(set)
			for f in MACOS_ICONSET {
				png, ok := icon_png(n, f.size)
				if !ok do return fmt.tprintf("could not draw %d px", f.size)
				if e := write(fmt.tprintf("%s/%s", set, f.name), png, &written); e != "" do return e
			}
			icns := fmt.tprintf("%s/AppIcon.icns", dir)
			p, perr := os.process_start({command = {"/usr/bin/iconutil", "-c", "icns", set, "-o", icns}})
			if perr == nil {
				st, _ := os.process_wait(p)
				if st.exit_code == 0 do append(&written, icns)
				else do append(&warnings, "iconutil could not make AppIcon.icns; the .iconset is written")
			} else do append(&warnings, "iconutil is not available; the .iconset is written")
		case "favicon":
			ico_sizes := [3]int{16, 32, 48}
			pngs := make([][]u8, 3, context.temp_allocator)
			for s, i in ico_sizes {
				png, ok := icon_png(n, s)
				if !ok do return fmt.tprintf("could not draw %d px", s)
				pngs[i] = png
			}
			if e := write(fmt.tprintf("%s/favicon.ico", dir), ico_from_pngs(ico_sizes[:], pngs), &written); e != "" do return e
			for f in FAVICONS {
				png, ok := icon_png(n, f.size)
				if !ok do return fmt.tprintf("could not draw %d px", f.size)
				if e := write(fmt.tprintf("%s/%s", dir, f.name), png, &written); e != "" do return e
			}
		case:
			return fmt.tprintf("kinds: macos (iconset and .icns) and favicon (favicon.ico and web PNGs), not %s", kind)
		}
	}
	strings.write_string(b, `{"files":[`)
	for f, i in written {
		if i > 0 do strings.write_byte(b, ',')
		engine.json_write_string(b, f)
	}
	strings.write_byte(b, ']')
	write_warnings(b, warnings[:])
	strings.write_byte(b, '}')
	return ""
}
