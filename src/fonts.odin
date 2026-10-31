package agentic_design

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "fontstash"
import nvg "nanovg"

// Installed fonts (.ttf, .otf, every font of a .ttc collection, .woff), and those in a
// `fonts` folder next to the open document. A face is loaded into NanoVG the first time
// text needs it; a TrueType variable font is instanced at the weight asked for
// (varfont.odin).

Face :: struct {
	path:       string,
	index:      int, // font inside a .ttc collection
	weight:     int, // 100..900; a variable font's default
	italic:     bool,
	wmin, wmax: int, // a variable font's weight range (0 for static fonts)
	woff:       bool,
	font:       int, // nanovg font handle, -1 until loaded, -2 if it failed
	name:       string, // its nanovg name once loaded
}

Family :: struct {
	name:  string,
	faces: [dynamic]Face,
}

families: [dynamic]Family
family_names: [dynamic]string // sorted, for menus
fonts_scanned: bool
font_dirs_seen: map[string]bool
// "path#index@weight" -> the instance's nanovg name and font (-2 if it failed); font_face
// memoizes the names, so they live as long as the app
var_instances: map[string]struct {
	name: string,
	font: int,
}

// the app's own folder first: static instances of variable fonts (tools/font_instances.py)
FONT_DIRS := [?]string{"~/Library/Application Support/Agentic Design/fonts", "~/Library/Fonts", "/Library/Fonts", "/System/Library/Fonts/Supplemental", "/System/Library/Fonts"}

fonts_scan :: proc() {
	if fonts_scanned do return
	fonts_scanned = true
	home, _ := os.user_home_dir(context.temp_allocator)
	for dir in FONT_DIRS {
		d := dir
		if strings.has_prefix(d, "~") do d = fmt.tprintf("%s%s", home, d[1:])
		fonts_scan_dir(d)
	}
	fonts_sort_names()
}

// Fonts that travel with a document: the `fonts` folder next to it.
fonts_add_document_dir :: proc(doc_path: string) {
	fonts_scan()
	if fonts_scan_dir(fmt.tprintf("%s/fonts", os.dir(absolute_path(doc_path)))) do fonts_sort_names()
}

fonts_sort_names :: proc() {
	clear(&family_names)
	for fam in families do append(&family_names, fam.name)
	slice.sort(family_names[:])
	clear(&face_memo)
}

// Adds the faces of every font file in a folder (once per folder); true if it was new.
fonts_scan_dir :: proc(d: string) -> bool {
	if d in font_dirs_seen do return false
	font_dirs_seen[strings.clone(d)] = true
	infos, err := os.read_all_directory_by_path(d, context.temp_allocator)
	if err != nil do return false
	for info in infos {
		lower := strings.to_lower(info.name, context.temp_allocator)
		ext := lower[strings.last_index_byte(lower, '.') + 1:] if strings.contains_rune(lower, '.') else ""
		if ext != "ttf" && ext != "otf" && ext != "ttc" && ext != "woff" do continue
		path := fmt.tprintf("%s/%s", d, info.name)
		for fi in font_file_infos(path) {
			// the font's own names first ("Source Sans 3" from SourceSans3-It.ttf); the
			// file name only when the tables cannot be read
			family, weight, italic := fi.family, fi.weight, fi.italic
			if family == "" do family, weight, italic = parse_font_name(info.name[:len(info.name) - len(ext) - 1])
			if family == "" || script_only_font(family) do continue
			fam := family_find(family)
			if fam == nil {
				append(&families, Family{name = strings.clone(family)})
				fam = &families[len(families) - 1]
			}
			dup := false
			for f in fam.faces do if f.weight == weight && f.italic == italic && (f.wmax > 0) == (fi.wmax > 0) do dup = true
			if dup do continue
			append(&fam.faces, Face{strings.clone(path), fi.index, weight, italic, fi.wmin, fi.wmax, ext == "woff", -1, ""})
		}
	}
	return true
}

family_find :: proc(name: string) -> ^Family {
	key := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	for &fam in families do if strings.to_lower(fam.name, context.temp_allocator) == key do return &fam
	return nil
}

// "Inter-SemiBoldItalic", "Arial Bold Italic", "aptos-extrabold" -> family, weight, italic.
parse_font_name :: proc(stem: string) -> (family: string, weight: int, italic: bool) {
	weight = 400
	words := make([dynamic]string, context.temp_allocator)
	// split on '-', '_' and spaces; also split CamelCase style suffixes like "SemiBoldItalic"
	cleaned := strings.builder_make(context.temp_allocator)
	for r in stem do strings.write_rune(&cleaned, ' ' if r == '-' || r == '_' else r)
	for part in strings.fields(strings.to_string(cleaned), context.temp_allocator) do append(&words, part)
	name_words := make([dynamic]string, context.temp_allocator)
	for w in words {
		lw := strings.to_lower(w, context.temp_allocator)
		rest := lw
		matched := false
		for rest != "" {
			hit := false
			for s in STYLE_WORDS {
				if strings.has_prefix(rest, s.word) {
					if s.weight > 0 do weight = s.weight
					if s.italic do italic = true
					rest = rest[len(s.word):]
					hit = true
					matched = true
					break
				}
			}
			if !hit do break
		}
		if !matched || rest != "" {
			if matched && rest != "" {
				// style words followed by junk: treat the whole word as part of the name
				weight, italic = 400, false
			}
			append(&name_words, w)
		}
	}
	family = strings.join(name_words[:], " ", context.temp_allocator)
	return
}

Style_Word :: struct {
	word:   string,
	weight: int,
	italic: bool,
}

STYLE_WORDS := [?]Style_Word {
	{"extralight", 200, false}, {"ultralight", 200, false}, {"extrabold", 800, false}, {"ultrabold", 800, false},
	{"semibold", 600, false}, {"demibold", 600, false}, {"thin", 100, false}, {"hairline", 100, false},
	{"light", 300, false}, {"regular", 400, false}, {"normal", 400, false}, {"book", 400, false}, {"roman", 400, false},
	{"medium", 500, false}, {"bold", 700, false}, {"heavy", 900, false}, {"black", 900, false},
	{"italic", 0, true}, {"oblique", 0, true}, {"it", 0, true},
}

face_memo: map[string]string // "family|weight|italic" -> face name

// NanoVG font name for a family/weight/style; falls back to Arial.
font_face :: proc(family: string, weight: int, italic: bool) -> string {
	if family == "" do return "sans-bold" if weight >= 600 else "sans"
	key := fmt.tprintf("%s|%d|%v", family, weight, italic)
	if hit, ok := face_memo[key]; ok do return hit
	face := font_face_lookup(family, weight, italic)
	face_memo[strings.clone(key)] = face
	return face
}

font_face_lookup :: proc(family: string, weight: int, italic: bool) -> string {
	fonts_scan()
	fam := family_find(family) if family != "" else nil
	if fam == nil || len(fam.faces) == 0 do return "sans-bold" if weight >= 600 else "sans"
	// the closest face; a variable font covering the weight counts as exact, after a
	// static face of that weight
	best := -1
	best_score := 1 << 30
	for f, i in fam.faces {
		dist := abs(f.weight - weight)
		if f.wmax > 0 && weight >= f.wmin && weight <= f.wmax do dist = 0
		score := dist * 2 + (1 if f.wmax > 0 else 0) + (0 if f.italic == italic else 700)
		if score < best_score do best, best_score = i, score
	}
	face := &fam.faces[best]
	if face.wmax > 0 && weight != face.weight && weight >= face.wmin && weight <= face.wmax {
		if name, ok := face_instance(face, weight); ok do return name
	}
	if face.font == -1 {
		face.name = fmt.aprintf("%s#%d", face.path, face.index)
		if data, ok := font_file_bytes(face); ok do face.font = fontstash.AddFontMem(&app.vg.fs, face.name, data, true, face.index if !face.woff else 0)
		if face.font < 0 do face.font = -2
	}
	if face.font < 0 do return "sans-bold" if weight >= 600 else "sans"
	return face.name
}

// A variable font at another weight, instanced once and kept.
face_instance :: proc(face: ^Face, weight: int) -> (string, bool) {
	key := fmt.tprintf("%s#%d@%d", face.path, face.index, weight)
	if v, ok := var_instances[key]; ok do return v.name, v.font >= 0
	owned := strings.clone(key)
	var_instances[owned] = {owned, -2}
	data, ok := font_file_bytes(face)
	if !ok do return owned, false
	defer delete(data)
	offset := 0
	if string(data[:4]) == "ttcf" && 12 + face.index * 4 + 4 <= len(data) {
		at := 12 + face.index * 4
		offset = int(data[at]) << 24 | int(data[at + 1]) << 16 | int(data[at + 2]) << 8 | int(data[at + 3])
	}
	inst, iok := varfont_instance(data, offset, {{"wght", f32(weight)}})
	if !iok do return owned, false
	h := fontstash.AddFontMem(&app.vg.fs, owned, inst, true, 0)
	var_instances[owned] = {owned, h}
	return owned, h >= 0
}

// The bytes of a font file, a WOFF unpacked to a plain font (default allocator).
font_file_bytes :: proc(face: ^Face) -> ([]u8, bool) {
	data, err := os.read_entire_file(face.path, context.allocator)
	if err != nil do return nil, false
	if !face.woff do return data, true
	defer delete(data)
	return woff_to_sfnt(data)
}

WEIGHT_NAMES := [?]string{"Thin", "Extra light", "Light", "Regular", "Medium", "Semi bold", "Bold", "Extra bold", "Black"}

weight_name :: proc(weight: int) -> string {
	return WEIGHT_NAMES[clamp((weight + 50) / 100 - 1, 0, 8)]
}

// Script-specific Noto faces (Noto Sans Mandaic, NotoSerifTibetan, ...) have no Latin
// glyphs; they only clutter the font menu.
script_only_font :: proc(family: string) -> bool {
	for prefix in ([?]string{"Noto Sans ", "Noto Serif ", "NotoSans", "NotoSerif"}) {
		if strings.has_prefix(family, prefix) {
			rest := family[len(prefix):]
			return rest != "" && rest != "Mono" && rest != "Display" && !strings.has_prefix(rest, "Mono") && !strings.has_prefix(rest, "Display")
		}
	}
	return false
}

@(private = "file")
fbe16 :: proc(b: []u8, at: int) -> int {
	if at < 0 || at + 2 > len(b) do return 0
	return int(b[at]) << 8 | int(b[at + 1])
}

@(private = "file")
fbe32 :: proc(b: []u8, at: int) -> int {
	if at < 0 || at + 4 > len(b) do return 0
	return int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])
}

Font_Info :: struct {
	family:     string,
	weight:     int,
	italic:     bool,
	index:      int,
	wmin, wmax: int,
}

// Family, weight, style and weight axis of every font in a file: one, or each font of a
// .ttc collection. Only the table directories and the name, OS/2 and fvar tables are read.
font_file_infos :: proc(path: string) -> []Font_Info {
	out := make([dynamic]Font_Info, context.temp_allocator)
	f, err := os.open(path)
	if err != nil do return nil
	defer os.close(f)
	head: [12]u8
	if n, _ := os.read_at(f, head[:], 0); n != 12 do return nil
	switch string(head[:4]) {
	case "ttcf":
		count := min(fbe32(head[:], 8), 64)
		offs := make([]u8, count * 4, context.temp_allocator)
		if n, _ := os.read_at(f, offs, 12); n != len(offs) do return nil
		for i in 0 ..< count {
			if fi, ok := sfnt_info(f, fbe32(offs, i * 4), false); ok {
				fi.index = i
				append(&out, fi)
			}
		}
	case "wOFF":
		if fi, ok := sfnt_info(f, 0, true); ok do append(&out, fi)
	case:
		if fi, ok := sfnt_info(f, 0, false); ok do append(&out, fi)
	}
	return out[:]
}

// One font's names: the typographic family (name ID 16) or family (ID 1), usWeightClass
// and the italic bit of OS/2, and the weight axis of a TrueType variable font.
sfnt_info :: proc(f: ^os.File, offset: int, woff: bool) -> (info: Font_Info, ok: bool) {
	hdr: [44]u8
	hlen := 44 if woff else 12
	if n, _ := os.read_at(f, hdr[:hlen], i64(offset)); n != hlen do return
	tag := fbe32(hdr[:], 4 if woff else 0)
	if tag != 0x00010000 && tag != 0x4F54544F && tag != 0x74727565 do return // TrueType, 'OTTO', 'true'
	count := fbe16(hdr[:], 12 if woff else 4)
	if count <= 0 || count > 200 do return
	rec := 20 if woff else 16
	dir := make([]u8, count * rec, context.temp_allocator)
	if n, _ := os.read_at(f, dir, i64(offset + hlen)); n != len(dir) do return
	Dir :: struct {
		f:    ^os.File,
		dir:  []u8,
		rec:  int,
		woff: bool,
	}
	d := Dir{f, dir, rec, woff}
	has :: proc(d: Dir, name: string) -> bool {
		for i := 0; i + d.rec <= len(d.dir); i += d.rec do if string(d.dir[i:i + 4]) == name do return true
		return false
	}
	table :: proc(d: Dir, name: string) -> []u8 {
		for i := 0; i + d.rec <= len(d.dir); i += d.rec {
			if string(d.dir[i:i + 4]) != name do continue
			off := fbe32(d.dir, i + 4 if d.woff else i + 8)
			length := fbe32(d.dir, i + 8 if d.woff else i + 12)
			if length <= 0 || length > 1 << 20 do return nil
			buf := make([]u8, length, context.temp_allocator)
			if n, _ := os.read_at(d.f, buf, i64(off)); n != length do return nil
			if d.woff {
				orig := fbe32(d.dir, i + 12)
				if length < orig do return inflate_table(buf, orig)
			}
			return buf
		}
		return nil
	}
	info.weight = 400
	if os2 := table(d, "OS/2"); len(os2) >= 64 {
		if w := fbe16(os2, 4); w >= 1 && w <= 1000 do info.weight = w
		info.italic = fbe16(os2, 62) & 1 != 0
	}
	if has(d, "gvar") && has(d, "glyf") {
		if lo, def, hi, wok := varfont_weight_axis(table(d, "fvar")); wok && hi > lo {
			info.wmin, info.wmax, info.weight = int(lo), int(hi), int(def)
		}
	}
	names := table(d, "name")
	if len(names) < 6 do return info, false
	records, strings_at := fbe16(names, 2), fbe16(names, 4)
	best_score := -1
	for r in 0 ..< records {
		at := 6 + r * 12
		if at + 12 > len(names) do break
		platform, encoding, language, id := fbe16(names, at), fbe16(names, at + 2), fbe16(names, at + 4), fbe16(names, at + 6)
		length, off := fbe16(names, at + 8), fbe16(names, at + 10)
		if id != 1 && id != 16 do continue
		start := strings_at + off
		if start + length > len(names) do continue
		raw := names[start:start + length]
		value: string
		if platform == 3 || platform == 0 { // UTF-16BE
			b := strings.builder_make(context.temp_allocator)
			for k := 0; k + 1 < len(raw); k += 2 do strings.write_rune(&b, rune(int(raw[k]) << 8 | int(raw[k + 1])))
			value = strings.to_string(b)
		} else if platform == 1 && encoding == 0 {
			value = string(raw)
		} else {
			continue
		}
		// typographic family over family, English over other languages
		score := (2 if id == 16 else 0) + (1 if language == 0x409 || (platform == 1 && language == 0) else 0)
		if score > best_score && strings.trim_space(value) != "" {
			best_score = score
			info.family = strings.trim_space(value)
		}
	}
	return info, info.family != ""
}

inflate_table :: proc(data: []u8, size: int) -> []u8 {
	buf: bytes.Buffer
	if err := zlib.inflate(data, &buf, false, size); err != nil {
		bytes.buffer_destroy(&buf)
		return nil
	}
	out := make([]u8, len(buf.buf), context.temp_allocator)
	copy(out, buf.buf[:])
	bytes.buffer_destroy(&buf)
	return out
}

// A WOFF file as the plain TrueType/OpenType font it wraps (default allocator).
woff_to_sfnt :: proc(data: []u8) -> ([]u8, bool) {
	if len(data) < 44 || string(data[:4]) != "wOFF" do return nil, false
	num := fbe16(data, 12)
	out := make([dynamic]u8)
	put16 :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v >> 8), u8(v))}
	put32 :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	put32(&out, fbe32(data, 4))
	put16(&out, num)
	sr := 1
	for sr * 2 <= num do sr *= 2
	put16(&out, sr * 16)
	log := 0
	for (1 << uint(log + 1)) <= sr do log += 1
	put16(&out, log)
	put16(&out, num * 16 - sr * 16)
	bodies := make([dynamic][]u8, context.temp_allocator)
	at := 12 + num * 16
	for i in 0 ..< num {
		rec := 44 + i * 20
		off, comp, orig := fbe32(data, rec + 4), fbe32(data, rec + 8), fbe32(data, rec + 12)
		if off + comp > len(data) {
			delete(out)
			return nil, false
		}
		body := data[off:off + comp]
		if comp < orig do body = inflate_table(body, orig)
		if len(body) != orig {
			delete(out)
			return nil, false
		}
		append(&out, ..data[rec:rec + 4])
		put32(&out, fbe32(data, rec + 16))
		put32(&out, at)
		put32(&out, orig)
		at += (orig + 3) &~ 3
		append(&bodies, body)
	}
	for b in bodies {
		append(&out, ..b)
		for len(out) % 4 != 0 do append(&out, 0)
	}
	return out[:], true
}

is_font_file :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for ext in ([?]string{".ttf", ".otf", ".ttc", ".woff"}) do if strings.has_suffix(lower, ext) do return true
	return false
}

// Copies font files into the `fonts` folder next to the document, where they load from
// whenever the document is opened, here or on another machine.
import_font_files :: proc(paths: []string) {
	dir := fmt.tprintf("%s/fonts", os.dir(app.file_path))
	if err := os.make_directory_all(dir); err != nil {
		set_status("Could not create %s", dir)
		return
	}
	count := 0
	for p in paths {
		if !is_font_file(p) do continue
		data, err := os.read_entire_file(p, context.temp_allocator)
		if err != nil do continue
		if os.write_entire_file(fmt.tprintf("%s/%s", dir, os.base(p)), data) == nil do count += 1
	}
	if count == 0 {
		set_status("No .ttf, .otf, .ttc or .woff files to import (woff2 is not supported)")
		return
	}
	if dir in font_dirs_seen {
		for k in font_dirs_seen do if k == dir {delete_key(&font_dirs_seen, k); break}
	}
	fonts_scan_dir(dir)
	fonts_sort_names()
	set_status("Imported %d font file%s into fonts/ next to the document", count, "" if count == 1 else "s")
}

