package agentic_design

import "core:strings"

// Icon libraries for `icon` nodes. Lucide is embedded as one line per icon,
// "name<TAB>svg path data" in a 24×24 box (assets/lucide.txt, built by
// tools/lucide_assets.py; ISC licence in assets/LICENSE-lucide.txt). Icons are
// stroked 2 units wide with round caps and joins, like lucide's own SVGs.
// Other libraries (Material Symbols, phosphor, feather) still draw placeholders.

LUCIDE_DATA :: #load("../assets/lucide.txt", string)

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
