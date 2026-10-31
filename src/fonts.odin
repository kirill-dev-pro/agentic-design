package agentic_design

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import nvg "nanovg"

// Installed fonts, found by file name (NanoVG reads .ttf/.otf, not .ttc collections).
// A face is loaded into NanoVG the first time text needs it.

Face :: struct {
	path:   string,
	weight: int, // 100..900
	italic: bool,
	font:   int, // nanovg font handle, -1 until loaded, -2 if it failed
}

Family :: struct {
	name:  string,
	faces: [dynamic]Face,
}

families: [dynamic]Family
family_names: [dynamic]string // sorted, for menus
fonts_scanned: bool

// the app's own folder first: static instances of variable fonts (tools/font_instances.py)
FONT_DIRS := [?]string{"~/Library/Application Support/Agentic Design/fonts", "~/Library/Fonts", "/Library/Fonts", "/System/Library/Fonts/Supplemental", "/System/Library/Fonts"}

fonts_scan :: proc() {
	if fonts_scanned do return
	fonts_scanned = true
	home, _ := os.user_home_dir(context.temp_allocator)
	for dir in FONT_DIRS {
		d := dir
		if strings.has_prefix(d, "~") do d = fmt.tprintf("%s%s", home, d[1:])
		infos, err := os.read_all_directory_by_path(d, context.temp_allocator)
		if err != nil do continue
		for info in infos {
			lower := strings.to_lower(info.name, context.temp_allocator)
			if !(strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf")) do continue
			path := fmt.tprintf("%s/%s", d, info.name)
			// the font's own names first ("Source Sans 3" from SourceSans3-It.ttf); the
			// file name only when the tables cannot be read
			family, weight, italic, ok := font_file_names(path)
			if !ok do family, weight, italic = parse_font_name(info.name[:len(info.name) - 4])
			if family == "" || script_only_font(family) do continue
			fam := family_find(family)
			if fam == nil {
				append(&families, Family{name = strings.clone(family)})
				fam = &families[len(families) - 1]
			}
			dup := false
			for f in fam.faces do if f.weight == weight && f.italic == italic do dup = true
			if dup do continue
			append(&fam.faces, Face{strings.clone(path), weight, italic, -1})
		}
	}
	for fam in families do append(&family_names, fam.name)
	slice.sort(family_names[:])
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
	best := -1
	best_score := 1 << 30
	for f, i in fam.faces {
		score := abs(f.weight - weight) + (0 if f.italic == italic else 350)
		if score < best_score do best, best_score = i, score
	}
	face := &fam.faces[best]
	if face.font == -1 {
		name := strings.clone(face.path)
		face.font = nvg.CreateFont(app.vg, name, face.path)
		if face.font < 0 do face.font = -2
	}
	if face.font < 0 do return "sans-bold" if weight >= 600 else "sans"
	return face.path
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

// Family name, weight and style read from a TrueType/OpenType file: the typographic
// family (name ID 16) or family (ID 1) from the `name` table, usWeightClass and the
// italic bit of fsSelection from `OS/2`. Only the table directory and these two tables
// are read.
font_file_names :: proc(path: string) -> (family: string, weight: int, italic: bool, ok: bool) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	be16 :: proc(b: []u8, at: int) -> int {return int(b[at]) << 8 | int(b[at + 1])}
	be32 :: proc(b: []u8, at: int) -> int {return int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])}
	head: [12]u8
	if n, _ := os.read_at(f, head[:], 0); n != 12 do return
	tag := be32(head[:], 0)
	if tag != 0x00010000 && tag != 0x4F54544F && tag != 0x74727565 do return // TrueType, 'OTTO', 'true'
	count := be16(head[:], 4)
	if count <= 0 || count > 200 do return
	dir := make([]u8, count * 16, context.temp_allocator)
	if n, _ := os.read_at(f, dir, 12); n != len(dir) do return
	table :: proc(f: ^os.File, dir: []u8, name: string) -> []u8 {
		for i := 0; i + 16 <= len(dir); i += 16 {
			if string(dir[i:i + 4]) != name do continue
			off := int(dir[i + 8]) << 24 | int(dir[i + 9]) << 16 | int(dir[i + 10]) << 8 | int(dir[i + 11])
			length := int(dir[i + 12]) << 24 | int(dir[i + 13]) << 16 | int(dir[i + 14]) << 8 | int(dir[i + 15])
			if length <= 0 || length > 1 << 20 do return nil
			buf := make([]u8, length, context.temp_allocator)
			if n, _ := os.read_at(f, buf, i64(off)); n != length do return nil
			return buf
		}
		return nil
	}
	weight = 400
	if os2 := table(f, dir, "OS/2"); len(os2) >= 64 {
		if w := be16(os2, 4); w >= 1 && w <= 1000 do weight = w
		italic = be16(os2, 62) & 1 != 0
	}
	names := table(f, dir, "name")
	if len(names) < 6 do return
	records, strings_at := be16(names, 2), be16(names, 4)
	best_score := -1
	for r in 0 ..< records {
		at := 6 + r * 12
		if at + 12 > len(names) do break
		platform, encoding, language, id := be16(names, at), be16(names, at + 2), be16(names, at + 4), be16(names, at + 6)
		length, offset := be16(names, at + 8), be16(names, at + 10)
		if id != 1 && id != 16 do continue
		start := strings_at + offset
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
			family = strings.trim_space(value)
		}
	}
	ok = family != ""
	return
}
