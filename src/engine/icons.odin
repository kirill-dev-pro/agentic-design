package engine

import "core:fmt"
import "core:strings"

// Icon libraries for `icon` nodes. Lucide is embedded as one line per icon,
// "name<TAB>svg path data" in a 24×24 box (assets/lucide.txt, built by
// tools/lucide_assets.py; ISC licence in assets/LICENSE-lucide.txt). Icons are
// stroked 2 units wide with round caps and joins, like lucide's own SVGs.
// Other libraries (Material Symbols, phosphor, feather) still draw placeholders.

LUCIDE_DATA :: #load("../../assets/lucide.txt", string)

lucide_index: map[string]string // name -> path data (slices of LUCIDE_DATA)

icon_path :: proc(library, name: string) -> (string, bool) {
	lib := strings.to_lower(library, context.temp_allocator)
	if lib != "lucide" && lib != "" do return "", false
	if len(lucide_index) == 0 {
		data := LUCIDE_DATA
		for line in strings.split_lines_iterator(&data) {
			tab := strings.index_byte(line, '\t')
			if tab > 0 do lucide_index[line[:tab]] = line[tab + 1:]
		}
	}
	d, ok := lucide_index[name]
	return d, ok
}

// Up to three Lucide names close to an unknown one: names containing it or contained in
// it, then by edit distance.
icon_suggestions :: proc(name: string) -> []string {
	icon_path("lucide", "x") // builds the index
	Cand :: struct {
		name:  string,
		score: int,
	}
	cands := make([dynamic]Cand, context.temp_allocator)
	key := strings.to_lower(name, context.temp_allocator)
	for k in lucide_index {
		score := 1000
		if strings.contains(k, key) do score = len(k) - len(key)
		else if len(k) >= 3 && strings.contains(key, k) do score = 10 + len(key) - len(k)
		else {
			d := strings.levenshtein_distance(k, key, context.temp_allocator)
			if d <= max(2, len(key) / 3) do score = 20 + d
		}
		if score < 1000 do append(&cands, Cand{k, score})
	}
	for i in 1 ..< len(cands) {
		for j := i; j > 0 && (cands[j].score < cands[j - 1].score || cands[j].score == cands[j - 1].score && cands[j].name < cands[j - 1].name); j -= 1 {
			cands[j], cands[j - 1] = cands[j - 1], cands[j]
		}
	}
	out := make([dynamic]string, context.temp_allocator)
	for c in cands[:min(len(cands), 3)] do append(&out, c.name)
	return out[:]
}

// An icon node whose name its library does not have (Lucide only; other libraries draw
// placeholders anyway). The message suggests close names.
icon_problem :: proc(n: ^Node) -> string {
	if n.kind != .Icon do return ""
	lib := prop_string(n, "iconFontFamily")
	if lib == "" do lib = prop_string(n, "library")
	if l := strings.to_lower(lib, context.temp_allocator); l != "" && l != "lucide" do return ""
	if n.icon == "" do return "icon without a name (\"icon\": \"<lucide name>\")"
	if _, ok := icon_path("lucide", n.icon); ok do return ""
	sugg := icon_suggestions(n.icon)
	if len(sugg) == 0 do return fmt.tprintf("Lucide has no icon \"%s\"; it draws as a placeholder (Lucide has no brand logos: draw those as a path)", n.icon)
	return fmt.tprintf("Lucide has no icon \"%s\"; it draws as a placeholder. Close names: %s", n.icon, strings.join(sugg, ", ", context.temp_allocator))
}
