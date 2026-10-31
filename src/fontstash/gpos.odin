package fontstash

// Agentic Design patch: pair kerning from the GPOS table.
//
// stb_truetype reads the old `kern` table and only the simplest GPOS layouts. Modern
// fonts (Inter, Source Sans 3, ...) keep their kerning in GPOS "kern" feature lookups,
// usually behind Extension lookups (type 9), so text came out wider than in browsers and
// pen.dev. This reads PairPos subtables (formats 1 and 2) of every lookup the kern
// feature lists, Extension lookups included, and caches the result per glyph pair.

Gpos_Subtable :: struct {
	lookup: int, // lookup index: the first matching subtable of a lookup wins
	offset: int, // absolute offset of the PairPos subtable in the font data
}

Gpos_Kern :: struct {
	parsed:    bool,
	subtables: [dynamic]Gpos_Subtable,
	cache:     map[u32]i32,
}

@(private = "file")
be16 :: #force_inline proc(d: [^]byte, at: int) -> int {
	return int(d[at]) << 8 | int(d[at + 1])
}

@(private = "file")
be16s :: #force_inline proc(d: [^]byte, at: int) -> int {
	return int(i16(u16(d[at]) << 8 | u16(d[at + 1])))
}

@(private = "file")
be32 :: #force_inline proc(d: [^]byte, at: int) -> int {
	return int(d[at]) << 24 | int(d[at + 1]) << 16 | int(d[at + 2]) << 8 | int(d[at + 3])
}

@(private = "file")
popcount16 :: proc(v: int) -> int {
	n := 0
	for i in 0 ..< 16 do if v & (1 << uint(i)) != 0 do n += 1
	return n
}

__gposParse :: proc(font: ^Font) {
	k := &font.gpos
	k.parsed = true
	d := font.info.data
	g := int(font.info.gpos)
	if g == 0 || d == nil do return
	feature_list := g + be16(d, g + 6)
	lookup_list := g + be16(d, g + 8)
	lookups := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< be16(d, feature_list) {
		rec := feature_list + 2 + i * 6
		if !(d[rec] == 'k' && d[rec + 1] == 'e' && d[rec + 2] == 'r' && d[rec + 3] == 'n') do continue
		f := feature_list + be16(d, rec + 4)
		for j in 0 ..< be16(d, f + 2) {
			idx := be16(d, f + 4 + j * 2)
			seen := false
			for l in lookups do if l == idx do seen = true
			if !seen do append(&lookups, idx)
		}
	}
	count := be16(d, lookup_list)
	for idx in lookups {
		if idx >= count do continue
		lk := lookup_list + be16(d, lookup_list + 2 + idx * 2)
		kind := be16(d, lk)
		for s in 0 ..< be16(d, lk + 4) {
			st := lk + be16(d, lk + 6 + s * 2)
			t := kind
			if t == 9 { // Extension: the real subtable sits behind a 32-bit offset
				t = be16(d, st + 2)
				st = st + be32(d, st + 4)
			}
			if t == 2 do append(&k.subtables, Gpos_Subtable{idx, st})
		}
	}
}

// Index of a glyph in a Coverage table, or -1.
@(private = "file")
coverage_index :: proc(d: [^]byte, cov: int, glyph: int) -> int {
	switch be16(d, cov) {
	case 1:
		lo, hi := 0, be16(d, cov + 2) - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			v := be16(d, cov + 4 + mid * 2)
			if v == glyph do return mid
			if v < glyph do lo = mid + 1
			else do hi = mid - 1
		}
	case 2:
		lo, hi := 0, be16(d, cov + 2) - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := cov + 4 + mid * 6
			start, end := be16(d, r), be16(d, r + 2)
			if glyph < start do hi = mid - 1
			else if glyph > end do lo = mid + 1
			else do return be16(d, r + 4) + glyph - start
		}
	}
	return -1
}

// Class of a glyph in a ClassDef table (0 when not listed).
@(private = "file")
class_of :: proc(d: [^]byte, cd: int, glyph: int) -> int {
	switch be16(d, cd) {
	case 1:
		start := be16(d, cd + 2)
		if glyph >= start && glyph < start + be16(d, cd + 4) do return be16(d, cd + 6 + (glyph - start) * 2)
	case 2:
		lo, hi := 0, be16(d, cd + 2) - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := cd + 4 + mid * 6
			start, end := be16(d, r), be16(d, r + 2)
			if glyph < start do hi = mid - 1
			else if glyph > end do lo = mid + 1
			else do return be16(d, r + 4)
		}
	}
	return 0
}

// X advance adjustment of the pair in one PairPos subtable; `hit` when the subtable
// covers the pair (which ends the lookup, even with a zero value).
@(private = "file")
pair_pos :: proc(d: [^]byte, st: int, g1, g2: int) -> (value: int, hit: bool) {
	format := be16(d, st)
	ci := coverage_index(d, st + be16(d, st + 2), g1)
	if ci < 0 do return 0, false
	vf1, vf2 := be16(d, st + 4), be16(d, st + 6)
	size1, size2 := popcount16(vf1) * 2, popcount16(vf2) * 2
	has_xadv := vf1 & 4 != 0
	xadv_at := (2 if vf1 & 1 != 0 else 0) + (2 if vf1 & 2 != 0 else 0)
	switch format {
	case 1:
		if ci >= be16(d, st + 8) do return 0, false
		ps := st + be16(d, st + 10 + ci * 2)
		rec := 2 + size1 + size2
		lo, hi := 0, be16(d, ps) - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := ps + 2 + mid * rec
			second := be16(d, r)
			if second == g2 {
				return (be16s(d, r + 2 + xadv_at) if has_xadv else 0), true
			}
			if second < g2 do lo = mid + 1
			else do hi = mid - 1
		}
		return 0, false
	case 2:
		c1 := class_of(d, st + be16(d, st + 8), g1)
		c2 := class_of(d, st + be16(d, st + 10), g2)
		c1n, c2n := be16(d, st + 12), be16(d, st + 14)
		if c1 >= c1n || c2 >= c2n do return 0, true
		r := st + 16 + (c1 * c2n + c2) * (size1 + size2)
		return (be16s(d, r + xadv_at) if has_xadv else 0), true
	}
	return 0, false
}

// Kerning between two glyphs in font units, from GPOS. `ok` is false when the font has
// no GPOS kerning (callers fall back to the `kern` table).
__gposKern :: proc(font: ^Font, g1, g2: Glyph_Index) -> (adv: i32, ok: bool) {
	k := &font.gpos
	if !k.parsed do __gposParse(font)
	if len(k.subtables) == 0 do return 0, false
	key := u32(g1) << 16 | (u32(g2) & 0xFFFF)
	if v, hit := k.cache[key]; hit do return v, true
	total := 0
	done_lookup := -1
	for s in k.subtables {
		if s.lookup == done_lookup do continue
		v, hit := pair_pos(font.info.data, s.offset, int(g1), int(g2))
		if hit {
			total += v
			done_lookup = s.lookup
		}
	}
	k.cache[key] = i32(total)
	return i32(total), true
}
