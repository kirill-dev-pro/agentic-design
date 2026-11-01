package engine

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "../fontstash"
import nvg "../nanovg"

// Fonts by family: those a document lists under "fonts" (as pen.dev does), installed
// fonts and those in a `fonts` folder next to the open document (.ttf, .otf, every font of
// a .ttc collection, .woff), and the built-in Noto Sans for a family that is missing. A face
// is loaded into NanoVG the first time text needs it; a TrueType variable font is
// instanced at the weight asked for (varfont.odin).

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
font_dirs_seen: map[string]i64 // folder -> its modification time when last read
fonts_checked: time.Tick // the last look at the folders' times (fonts_refresh)
// "path#index@weight" -> the instance's nanovg name and font (-2 if it failed); font_face
// memoizes the names, so they live as long as the app
var_instances: map[string]struct {
	name: string,
	font: int,
}

// the app's own folder first: static instances of variable fonts (tools/font_instances.py);
// in a browser, the fonts the page serves under /fonts
when ODIN_OS == .JS {
	FONT_DIRS := [?]string{"/fonts"}
} else {
	FONT_DIRS := [?]string{"~/Library/Application Support/Agentic Design/fonts", "~/Library/Fonts", "/Library/Fonts", "/System/Library/Fonts/Supplemental", "/System/Library/Fonts"}
}

fonts_scan :: proc() {
	if fonts_scanned do return
	fonts_scanned = true
	home := home_dir()
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
	if fonts_scan_dir(fmt.tprintf("%s/fonts", path_dir(absolute_path(doc_path)))) do fonts_sort_names()
}

// Fonts a document lists under "fonts", as pen.dev keeps those added to a file (its "Add
// custom fonts"): [{"name": "Scto Grotesk A", "url": "./fonts/SctoGroteskA-Light.ttf",
// "weight": 300 or [100, 900], "style": "normal" | "italic"}], each url relative to the
// file. pen.dev draws no installed fonts, so this is how a file brings the fonts it needs,
// and its libraries' fonts count for the files that import them. An entry becomes a face
// of the family `name`, whatever the font file calls itself.
declared_fonts: map[string]bool // "family|path" already added
declared_missing: map[string]string // family -> the url of a listed file that cannot be read

fonts_add_declared :: proc(fonts: json.Value, base_dir: string) {
	list, _ := fonts.(json.Array)
	if len(list) == 0 do return
	fonts_scan()
	added := false
	for item in list {
		e, _ := item.(json.Object)
		name := strings.trim_space(string(e["name"].(json.String) or_else ""))
		url := string(e["url"].(json.String) or_else "")
		if name == "" || url == "" || strings.has_prefix(url, "data:") || strings.contains(url, "://") && !strings.has_prefix(url, "file://") do continue
		path := strings.trim_prefix(url, "file://")
		if !path_is_abs(path) do path = path_join(base_dir, path)
		key := fmt.tprintf("%s|%s", strings.to_lower(name, context.temp_allocator), path)
		if key in declared_fonts do continue
		infos := font_file_infos(path)
		if len(infos) == 0 {
			if name not_in declared_missing do declared_missing[strings.clone(name)] = strings.clone(url)
			continue
		}
		declared_fonts[strings.clone(key)] = true
		for k in declared_missing do if strings.to_lower(k, context.temp_allocator) == strings.to_lower(name, context.temp_allocator) {
			delete_key(&declared_missing, k)
			break
		}
		fi := infos[0]
		weight, wmin, wmax := fi.weight, fi.wmin, fi.wmax
		number :: proc(v: json.Value) -> (int, bool) {
			#partial switch x in v {
			case json.Integer:
				return int(x), true
			case json.Float:
				return int(x), true
			}
			return 0, false
		}
		if w, ok := number(e["weight"]); ok {
			weight = w
		} else if r, rok := e["weight"].(json.Array); rok && len(r) == 2 {
			a, _ := number(r[0])
			z, _ := number(r[1])
			if fi.wmax > 0 do wmin, wmax = max(a, fi.wmin), min(z, fi.wmax)
			else do weight = a
		}
		italic := string(e["style"].(json.String) or_else "") == "italic"
		fam := family_find(name)
		if fam == nil {
			append(&families, Family{name = strings.clone(name)})
			fam = &families[len(families) - 1]
		}
		dup := false
		for f in fam.faces do if f.weight == weight && f.italic == italic && (f.wmax > 0) == (wmax > 0) do dup = true
		if dup do continue
		lower := strings.to_lower(path, context.temp_allocator)
		append(&fam.faces, Face{strings.clone(path), fi.index, weight, italic, wmin, wmax, strings.has_suffix(lower, ".woff"), -1, ""})
		added = true
	}
	if added do fonts_sort_names()
}

Font_Source :: enum {
	Missing, // drawn with the system font, as pen.dev does
	Installed, // on this Mac (or in fonts/ next to the file) but not listed in the document: pen.dev and other machines draw the system font
	Document, // listed in the document's (or a library's) fonts
}

font_source :: proc(family: string) -> Font_Source {
	if family_find(family) == nil do return .Missing
	prefix := fmt.tprintf("%s|", strings.to_lower(strings.trim_space(family), context.temp_allocator))
	for k in declared_fonts do if strings.has_prefix(k, prefix) do return .Document
	return .Installed
}

// What is wrong with a family that is not in the document's fonts, and the way out.
font_state :: proc(family: string) -> string {
	fix :: "add its files to the document: the add_fonts tool (an installed family by name, or font files by path), the import button next to the font in Typography or a file dropped on the canvas copies them into fonts/ next to the file and lists them under \"fonts\" (pen.dev: Add custom fonts)"
	for k, url in declared_missing do if strings.to_lower(k, context.temp_allocator) == strings.to_lower(family, context.temp_allocator) {
		return fmt.tprintf("is listed in the document's fonts, but its file %s is missing; it is drawn with Noto Sans, as in pen.dev", url)
	}
	switch font_source(family) {
	case .Missing:
		return fmt.tprintf("is not installed and not in the document, so this app draws Noto Sans (pen.dev does the same unless it is a Google Fonts family, which pen.dev loads by name); %s", fix)
	case .Installed:
		return fmt.tprintf("is installed on this Mac but not in the document, so other machines draw Noto Sans, and so does pen.dev (which reads no installed fonts) unless it is a Google Fonts family; %s", fix)
	case .Document:
	}
	return ""
}

// The entry pen.dev writes for a font file it adds to a document (see fonts_add_declared).
font_declaration :: proc(fi: Font_Info, url: string) -> json.Object {
	e := make(json.Object, 4, context.temp_allocator)
	e["name"] = json.String(fi.family)
	e["url"] = json.String(url)
	if fi.wmax > 0 {
		r := make(json.Array, 2, context.temp_allocator)
		r[0], r[1] = json.Integer(fi.wmin), json.Integer(fi.wmax)
		e["weight"] = r
	} else {
		e["weight"] = json.Integer(fi.weight)
	}
	e["style"] = json.String("italic" if fi.italic else "normal")
	return e
}

// A font installed while the app runs (into ~/Library/Fonts, the document's fonts/ folder,
// ...) is picked up within a couple of seconds: the folders' modification times are
// checked, and a changed folder is read again. Returns the families that gained faces
// ("" if none); text using them is measured again, as its cache key holds the face name.
fonts_refresh :: proc() -> string {
	if !fonts_scanned do return ""
	now := time.tick_now()
	if fonts_checked != {} && time.tick_diff(fonts_checked, now) < 2 * time.Second do return ""
	fonts_checked = now
	before := make(map[string]int, context.temp_allocator)
	for fam in families do before[fam.name] = len(fam.faces)
	dirs := make([dynamic]string, context.temp_allocator)
	for d in font_dirs_seen do append(&dirs, d)
	changed := false
	for d in dirs do if fonts_scan_dir(d) do changed = true
	if !changed do return ""
	names := make([dynamic]string, context.temp_allocator)
	for fam in families do if len(fam.faces) != before[fam.name] do append(&names, fam.name)
	if len(names) == 0 do return ""
	fonts_sort_names()
	return strings.join(names[:], ", ", context.temp_allocator)
}

fonts_sort_names :: proc() {
	layout_invalidate() // other fonts measure text differently
	clear(&family_names)
	for fam in families do append(&family_names, fam.name)
	slice.sort(family_names[:])
	clear(&face_memo)
}

// Adds the faces of every font file in a folder; true if the folder is new or has changed
// since it was last read (faces already known are skipped).
fonts_scan_dir :: proc(d: string) -> bool {
	mtime := file_mtime(d) // -1: a folder that does not exist (yet)
	if seen, ok := font_dirs_seen[d]; ok {
		if seen == mtime do return false
		font_dirs_seen[d] = mtime
	} else {
		font_dirs_seen[strings.clone(d)] = mtime
	}
	if mtime < 0 do return false
	names, ok := dir_names(d)
	if !ok do return false
	for name in names {
		lower := strings.to_lower(name, context.temp_allocator)
		ext := lower[strings.last_index_byte(lower, '.') + 1:] if strings.contains_rune(lower, '.') else ""
		if ext != "ttf" && ext != "otf" && ext != "ttc" && ext != "woff" do continue
		path := fmt.tprintf("%s/%s", d, name)
		for fi in font_file_infos(path) {
			// the font's own names first ("Source Sans 3" from SourceSans3-It.ttf); the
			// file name only when the tables cannot be read
			family, weight, italic := fi.family, fi.weight, fi.italic
			if family == "" do family, weight, italic = parse_font_name(name[:len(name) - len(ext) - 1])
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

face_memo: map[string]Face_Pick // "family|weight|italic" -> the face drawn

Face_Pick :: struct {
	name:     string, // nanovg font name
	embolden: bool, // drawn thicker: bold asked of a family without a bold face
}

// NanoVG font name for a family/weight/style. Unnamed text uses Arial.
font_face :: proc(family: string, weight: int, italic: bool) -> string {
	return font_pick(family, weight, italic).name
}

sans_fallbacks: bool

font_pick :: proc(family: string, weight: int, italic: bool) -> Face_Pick {
	if family == "" {
		// the default family (Arial) gets the same fallbacks as document fonts, once
		if !sans_fallbacks {
			sans_fallbacks = true
			for name, i in ([2]string{"sans", "sans-bold"}) {
				if id := fontstash.GetFontByName(&renderer.fs, name); id >= 0 do add_noto_fallback(id, 700 if i == 1 else 400, false)
			}
		}
		return {name = "sans-bold" if weight >= 600 else "sans"}
	}
	key := fmt.tprintf("%s|%d|%v", family, weight, italic)
	if hit, ok := face_memo[key]; ok do return hit
	pick := font_face_lookup(family, weight, italic)
	face_memo[strings.clone(key)] = pick
	return pick
}

// A family that is not available is drawn with Noto Sans, as pen.dev does: its renderer
// (Skia in WebAssembly) reads no installed fonts and stands the first of its fallback fonts,
// Noto Sans, in for a family it cannot load. Measured: six Larken headings on the Sample
// About screen match Noto Sans widths to pen.dev's rounding, SF Pro is off by up to 4 px.
// The same Noto Sans 2.015 files pen.dev fetches from Google Fonts are built in (OFL,
// assets/fonts), instanced at the weight asked for; they also supply glyphs a font lacks
// (Cyrillic in a Latin-only font), as Noto does in pen.dev.
NOTO_SANS :: #load("../../assets/fonts/NotoSans-VF.ttf")
NOTO_SANS_ITALIC :: #load("../../assets/fonts/NotoSans-Italic-VF.ttf")

noto_face :: proc(weight: int, italic: bool) -> (name: string, font: int) {
	key := fmt.tprintf("Noto Sans%s@%d", " Italic" if italic else "", clamp(weight, 100, 900))
	if v, ok := var_instances[key]; ok do return v.name, v.font
	owned := strings.clone(key)
	var_instances[owned] = {owned, -2}
	inst, ok := varfont_instance(NOTO_SANS_ITALIC if italic else NOTO_SANS, 0, {{"wght", f32(clamp(weight, 100, 900))}})
	if !ok do return owned, -2
	h := fontstash.AddFontMem(&renderer.fs, owned, inst, true, 0)
	var_instances[owned] = {owned, h}
	add_symbol_fallbacks(h)
	return owned, h
}

// A document font gets Noto Sans for the characters it has no glyph for, then the
// system's symbol fonts (arrows, ✓ ✕ ★ ⌘ and other dingbats Noto Sans lacks).
add_noto_fallback :: proc(font, weight: int, italic: bool) {
	if font < 0 do return
	if _, noto := noto_face(weight, italic); noto >= 0 do fontstash.AddFallbackFont(&renderer.fs, font, noto)
	add_symbol_fallbacks(font)
}

when ODIN_OS == .JS {
	SYMBOL_FONTS := [0]string{} // (a page has no system fonts)
} else {
	SYMBOL_FONTS := [?]string{"/System/Library/Fonts/Apple Symbols.ttf", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"}
}
symbol_fonts: [len(SYMBOL_FONTS)]int // fontstash handles, 0 until loaded, -1 if missing

add_symbol_fallbacks :: proc(font: int) {
	if font < 0 do return
	for path, i in SYMBOL_FONTS {
		if symbol_fonts[i] == 0 {
			symbol_fonts[i] = -1
			// mapped for the app's life, like document fonts
			if data, ok := map_file(path); ok {
				h := fontstash.AddFontMem(&renderer.fs, fmt.aprintf("symbols#%d", i), data, false, 0)
				if h >= 0 do symbol_fonts[i] = h
			}
		}
		if symbol_fonts[i] > 0 && symbol_fonts[i] != font do fontstash.AddFallbackFont(&renderer.fs, font, symbol_fonts[i])
	}
}

font_face_lookup :: proc(family: string, weight: int, italic: bool) -> Face_Pick {
	fonts_scan()
	fam := family_find(family) if family != "" else nil
	if fam == nil || len(fam.faces) == 0 {
		if name, font := noto_face(weight, italic); font >= 0 do return {name = name}
		return {name = "sans-bold" if weight >= 600 else "sans"}
	}
	// the closest face, a matching style first (as pen.dev picks); a variable font covering
	// the weight counts as exact, after a static face of that weight
	best := -1
	best_score := 1 << 30
	for f, i in fam.faces {
		dist := abs(f.weight - weight)
		if f.wmax > 0 do dist = 0 if weight >= f.wmin && weight <= f.wmax else min(abs(f.wmin - weight), abs(f.wmax - weight))
		score := dist * 2 + (1 if f.wmax > 0 else 0) + (0 if f.italic == italic else 10000)
		if score < best_score do best, best_score = i, score
	}
	face := &fam.faces[best]
	// Skia draws a face thicker when bold (600+) is asked and the face is lighter than 600,
	// so "Scto Grotesk A" 700 with only the Light file comes out bold, 500 stays Light
	drawn := face.weight
	if face.wmax > 0 do drawn = clamp(weight, face.wmin, face.wmax)
	embolden := weight >= 600 && drawn < 600
	if face.wmax > 0 && drawn != face.weight {
		if name, ok := face_instance(face, drawn); ok do return {name = name, embolden = embolden}
	}
	if face.font == -1 {
		face.name = fmt.aprintf("%s#%d", face.path, face.index)
		// a mapped file stays mapped as long as the font is loaded (the app's life)
		if data, ok, mapped := font_file_bytes(face); ok do face.font = fontstash.AddFontMem(&renderer.fs, face.name, data, !mapped, face.index if !face.woff else 0)
		if face.font < 0 do face.font = -2
		add_noto_fallback(face.font, face.weight, face.italic)
	}
	if face.font < 0 do return {name = "sans-bold" if weight >= 600 else "sans"}
	return {name = face.name, embolden = embolden}
}

// A variable font at another weight, instanced once and kept.
face_instance :: proc(face: ^Face, weight: int) -> (string, bool) {
	key := fmt.tprintf("%s#%d@%d", face.path, face.index, weight)
	if v, ok := var_instances[key]; ok do return v.name, v.font >= 0
	owned := strings.clone(key)
	var_instances[owned] = {owned, -2}
	data, ok, mapped := font_file_bytes(face)
	if !ok do return owned, false
	defer if mapped do unmap_file(data)
	else do delete(data)
	offset := 0
	if string(data[:4]) == "ttcf" && 12 + face.index * 4 + 4 <= len(data) {
		at := 12 + face.index * 4
		offset = int(data[at]) << 24 | int(data[at + 1]) << 16 | int(data[at + 2]) << 8 | int(data[at + 3])
	}
	inst, iok := varfont_instance(data, offset, {{"wght", f32(weight)}})
	if !iok do return owned, false
	h := fontstash.AddFontMem(&renderer.fs, owned, inst, true, 0)
	var_instances[owned] = {owned, h}
	add_noto_fallback(h, weight, face.italic)
	return owned, h >= 0
}

// The bytes of a font file, a WOFF unpacked to a plain font (default allocator).
// A face's font file: mapped (memory.odin), or for a WOFF unpacked into memory. `mapped`
// tells which, so the caller unmaps or frees it, or hands it to fontstash for good.
font_file_bytes :: proc(face: ^Face) -> (data: []u8, ok, mapped: bool) {
	if !face.woff {
		data, ok = map_file(face.path)
		return data, ok, true
	}
	raw, rok := read_file(face.path, context.allocator)
	if !rok do return nil, false, false
	defer delete(raw)
	data, ok = woff_to_sfnt(raw)
	return data, ok, false
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
	typo:       bool, // the family came from name ID 16 (typographic family)
	license:    string, // name IDs 13 and 14: license description and URL
	weight:     int,
	italic:     bool,
	index:      int,
	wmin, wmax: int,
}

// Family, weight, style and weight axis of every font in a file: one, or each font of a
// .ttc collection. The file is mapped (map_file): only the pages of the table
// directories and the name, OS/2 and fvar tables are read.
font_file_infos :: proc(path: string) -> []Font_Info {
	out := make([dynamic]Font_Info, context.temp_allocator)
	file, mok := map_file(path)
	if !mok do return nil
	defer unmap_file(file)
	if len(file) < 12 do return nil
	switch string(file[:4]) {
	case "ttcf":
		count := min(fbe32(file, 8), 64)
		if 12 + count * 4 > len(file) do return nil
		for i in 0 ..< count {
			if fi, ok := sfnt_info(file, fbe32(file, 12 + i * 4), false); ok {
				fi.index = i
				append(&out, fi)
			}
		}
	case "wOFF":
		if fi, ok := sfnt_info(file, 0, true); ok do append(&out, fi)
	case:
		if fi, ok := sfnt_info(file, 0, false); ok do append(&out, fi)
	}
	// Web fonts (fontsource, Google Fonts subsets) often lack the typographic family, so
	// a 500 file says "JetBrains Mono Medium". Outside the system's font folders, a family
	// name ending in a weight word that matches the file's weight loses the word: one
	// family with several weights, as CSS and pen.dev expect. (Installed fonts keep their
	// names: "Arial Black" stays a family of its own.)
	system := strings.has_prefix(path, "/System/") || strings.has_prefix(path, "/Library/") || strings.contains(path, "/Library/Fonts/")
	if !system do for &fi in out {
		if fi.typo do continue
		fam, w, it := parse_font_name(fi.family)
		if fam == "" || fam == fi.family || it != fi.italic && it do continue
		if w != 400 && abs(w - fi.weight) > 50 do continue
		fi.family = fam
	}
	return out[:]
}

// One font's names: the typographic family (name ID 16) or family (ID 1), usWeightClass
// and the italic bit of OS/2, and the weight axis of a TrueType variable font.
// What it returns is copied out of `file` (temp allocator).
sfnt_info :: proc(file: []u8, offset: int, woff: bool) -> (info: Font_Info, ok: bool) {
	hlen := 44 if woff else 12
	if offset < 0 || offset + hlen > len(file) do return
	hdr := file[offset:][:hlen]
	tag := fbe32(hdr, 4 if woff else 0)
	if tag != 0x00010000 && tag != 0x4F54544F && tag != 0x74727565 do return // TrueType, 'OTTO', 'true'
	count := fbe16(hdr, 12 if woff else 4)
	if count <= 0 || count > 200 do return
	rec := 20 if woff else 16
	if offset + hlen + count * rec > len(file) do return
	dir := file[offset + hlen:][:count * rec]
	Dir :: struct {
		file: []u8,
		dir:  []u8,
		rec:  int,
		woff: bool,
	}
	d := Dir{file, dir, rec, woff}
	has :: proc(d: Dir, name: string) -> bool {
		for i := 0; i + d.rec <= len(d.dir); i += d.rec do if string(d.dir[i:i + 4]) == name do return true
		return false
	}
	table :: proc(d: Dir, name: string) -> []u8 {
		for i := 0; i + d.rec <= len(d.dir); i += d.rec {
			if string(d.dir[i:i + 4]) != name do continue
			off := fbe32(d.dir, i + 4 if d.woff else i + 8)
			length := fbe32(d.dir, i + 8 if d.woff else i + 12)
			if length <= 0 || length > 1 << 20 || off < 0 || off + length > len(d.file) do return nil
			buf := slice.clone(d.file[off:][:length], context.temp_allocator) // (the file is unmapped after)
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
		if id != 1 && id != 16 && id != 13 && id != 14 do continue
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
		if id == 13 || id == 14 {
			if !strings.contains(info.license, value) do info.license = strings.concatenate({info.license, " ", value}, context.temp_allocator)
			continue
		}
		// typographic family over family, English over other languages
		score := (2 if id == 16 else 0) + (1 if language == 0x409 || (platform == 1 && language == 0) else 0)
		if score > best_score && strings.trim_space(value) != "" {
			best_score = score
			info.family = strings.trim_space(value)
			info.typo = id == 16
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

// Whether a font file says it is under a license that allows redistribution (the SIL
// Open Font License, Apache, the Ubuntu Font Licence): what Google Fonts and fontsource
// ship. Anything else is treated as licensed per user.
font_open_license :: proc(path: string) -> bool {
	infos := font_file_infos(path)
	if len(infos) == 0 do return false
	l := strings.to_lower(infos[0].license, context.temp_allocator)
	for marker in ([?]string{"open font license", "scripts.sil.org/ofl", "openfontlicense.org", "ofl", "apache license", "apache.org/licenses", "ubuntu font licence"}) {
		if strings.contains(l, marker) do return true
	}
	return false
}

// Works around two bugs in Odin's fontstash/nanovg ports. When the glyph atlas fills up,
// fontstash doubles it and asks nanovg for a new texture, but nanovg uploads the old,
// smaller pixel buffer into it (a crash inside glTexImage2D). And nothing ever resets the
// atlas, so glyphs rasterised at every zoom level accumulate until the texture is huge.
font_atlas_init :: proc(vg: ^nvg.Context) {
	vg.fs.callbackResize = proc(data: rawptr, w, h: int) {
		ctx := (^nvg.Context)(data)
		old := ctx.fontImages[ctx.fontImageIdx]
		// no pixels: fontstash marks the used area dirty and re-uploads it on the next flush
		ctx.fontImages[ctx.fontImageIdx] = ctx.params.renderCreateTexture(ctx.params.userPtr, .Alpha, w, h, {}, nil)
		if old != 0 do ctx.params.renderDeleteTexture(ctx.params.userPtr, old)
	}
}

FONT_ATLAS_MAX :: 2048

// Between frames: once the atlas has outgrown its budget, start over with an empty one.
font_atlas_trim :: proc(vg: ^nvg.Context) {
	if vg.fs.width <= FONT_ATLAS_MAX && vg.fs.height <= FONT_ATLAS_MAX do return
	fontstash.ResetAtlas(&vg.fs, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
	fontstash.__atlasReset(&vg.fs, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
	vg.fs.callbackResize(vg, FONT_ATLAS_MAX, FONT_ATLAS_MAX)
}
