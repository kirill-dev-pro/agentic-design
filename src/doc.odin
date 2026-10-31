package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strconv"
import "core:strings"

// Document model: the .pen object tree as a flat array of nodes. Array order is
// the z-order among siblings (later is on top) and `parent` links a node to its
// container. Each node keeps its authored .pen properties as raw JSON in `props`;
// that is what gets written back to disk, so properties this app does not
// understand survive a round trip. The parsed fields below `props` are a cache
// rebuilt by node_refresh. `pos` is relative to the parent like in the file;
// `x, y, w, h` are the absolute boxes computed by the layout pass.

Node_Kind :: enum {
	Frame,
	Group,
	Rectangle,
	Ellipse,
	Path,
	Text,
	Ref,
	Icon,
	Other,
}

KIND_NAMES := [Node_Kind]string {
	.Frame     = "frame",
	.Group     = "group",
	.Rectangle = "rectangle",
	.Ellipse   = "ellipse",
	.Path      = "path",
	.Text      = "text",
	.Ref       = "ref",
	.Icon      = "icon",
	.Other     = "",
}

KIND_LABELS := [Node_Kind]string {
	.Frame     = "Frame",
	.Group     = "Group",
	.Rectangle = "Rectangle",
	.Ellipse   = "Ellipse",
	.Path      = "Path",
	.Text      = "Text",
	.Ref       = "Instance",
	.Icon      = "Icon",
	.Other     = "Object",
}

kind_from_name :: proc(name: string) -> Node_Kind {
	if name == "icon_font" do return .Icon // .pen 2.8: {iconFontFamily, iconFontName}
	for k in Node_Kind {
		if k != .Other && KIND_NAMES[k] == name do return k
	}
	return .Other
}

Size_Mode :: enum {
	Fixed,
	Fit, // fit_content
	Fill, // fill_container
}

Size_Spec :: struct {
	mode:      Size_Mode,
	value:     f32, // the fixed size, or the fallback of fit_content(n) / fill_container(n)
	has_value: bool,
}

Layout_Dir :: enum {
	None,
	Horizontal,
	Vertical,
}

Justify :: enum {
	Start,
	Center,
	End,
	Space_Between,
	Space_Around,
}

Align :: enum {
	Start,
	Center,
	End,
}

Text_Growth :: enum {
	Auto,
	Fixed_Width,
	Fixed_Width_Height,
}

Text_Align :: enum {
	Left,
	Center,
	Right,
	Justify,
}

Image_Mode :: enum {
	Cover,
	Contain,
	Stretch,
}

Line_Cap :: enum u8 {
	Butt,
	Round,
	Square,
}

Line_Join :: enum u8 {
	Miter,
	Round,
	Bevel,
}

Stroke_Align :: enum {
	Center,
	Inner,
	Outer,
}

Color :: [4]u8

Prop :: struct {
	key: string,
	raw: string, // JSON
}

Node :: struct {
	uid:          int, // stable internal handle, never serialized
	parent:       int, // uid of the container, 0 = canvas
	id:           string, // .pen id
	props:        [dynamic]Prop,
	// parsed from props
	kind:         Node_Kind,
	type_name:    string,
	name:         string,
	pos:          [2]f32,
	width:        Size_Spec,
	height:       Size_Spec,
	layout:       Layout_Dir,
	gap:          f32,
	padding:      [4]f32, // top, right, bottom, left
	justify:      Justify,
	align:        Align,
	clip:         bool,
	abs_pos:      bool, // layoutPosition: absolute
	fill:         Color,
	has_fill:     bool,
	stroke:       Color,
	has_stroke:   bool,
	stroke_width: f32,
	stroke_align: Stroke_Align,
	stroke_old:   bool, // stroke authored as {align, thickness, fill} (older .pen versions)
	line_cap:     Line_Cap,
	stroke_sides: [4]f32, // per-side widths (top, right, bottom, left) when stroke_per_side
	stroke_per_side: bool,
	line_join:    Line_Join,
	radius:       [4]f32, // top-left, top-right, bottom-right, bottom-left
	opacity:      f32,
	enabled:      bool,
	reusable:     bool,
	content:      string,
	font_size:    f32,
	bold:         bool,
	weight:       int, // 100..900
	italic:       bool,
	font_family:  string,
	letter_spacing: f32,
	underline:    bool,
	strikethrough: bool,
	image_url:    string, // image fill, relative to the document
	image_mode:   Image_Mode,
	growth:       Text_Growth,
	text_align:   Text_Align,
	text_valign:  Align, // textAlignVertical, used by fixed-width-height text
	line_height:  f32, // multiplier, 0 = default
	geometry:     string,
	view_box:     [4]f32,
	cmds:         [dynamic]Path_Cmd,
	ref:          string,
	icon:         string, // icon node: lucide name ("house"); `geometry` holds its path data
	overrides:    [dynamic]Override, // instance: parsed `descendants`
	is_slot:      bool, // frame marked as the slot of its component
	slot_names:   [dynamic]string, // older files: slot frames named on the component root
	page_seen:    bool, // already assigned to a page (new top-level nodes join the shown page)
	imported:     bool, // read from an imported library (libraries.odin): never saved or shown
	theme_set:    [dynamic][2]string, // own `theme` property as axis/value pairs
	theme_key:    string, // theme in effect here, serialised
	ghost:        bool, // a copy made for an instance; never saved or selected
	ghost_inst:   int, // the instance this ghost belongs to
	ghost_of:     string, // id of the component node it copies
	children_key: bool, // the file had a "children" key (written back even when empty)
	slot_of:      string, // instance content: the id (path) of the component's slot frame it fills ("" = 2.8 style, the instance's own `children`)
	shadow:       Shadow,
	fills:        [MAX_FILLS]Paint, // every fill, in order (n.fill is the first solid color)
	nfills:       int,
	effects:      [MAX_EFFECTS]Effect,
	neffects:     int,
	rotation:     f32, // degrees counter-clockwise around the top-left corner
	flip_x:       bool,
	flip_y:       bool,
	// computed by the layout pass
	mw, mh:       f32, // measured intrinsic size
	x, y, w, h:   f32, // absolute box
}

// Fills: a solid color, a gradient or an image, several per node (drawn in order).
Paint_Kind :: enum u8 {
	Color,
	Linear,
	Radial,
	Angular,
	Image,
}

Gradient_Stop :: struct {
	color: Color,
	pos:   f32,
}

MAX_FILLS :: 6
MAX_STOPS :: 8

Paint :: struct {
	kind:     Paint_Kind,
	enabled:  bool,
	color:    Color, // solid fills
	stops:    [MAX_STOPS]Gradient_Stop,
	nstops:   int,
	center:   [2]f32, // gradients: normalized to the box, default 0.5, 0.5
	size:     [2]f32, // normalized; linear: height is the length
	rotation: f32, // degrees counter-clockwise, 0 = up
	opacity:  f32,
}

Effect_Kind :: enum u8 {
	Drop_Shadow,
	Inner_Shadow,
	Blur,
	Background_Blur,
}

MAX_EFFECTS :: 6

Effect :: struct {
	kind:    Effect_Kind,
	enabled: bool,
	offset:  [2]f32,
	blur:    f32,
	spread:  f32,
	color:   Color,
}

// The first enabled shadow of a node's `effect`.
Shadow :: struct {
	has:    bool,
	inner:  bool,
	offset: [2]f32,
	blur:   f32,
	spread: f32,
	color:  Color,
}

Var_Kind :: enum {
	Color,
	Number,
	String,
	Bool,
}

Var :: struct {
	kind:   Var_Kind,
	color:  Color,
	number: f32,
	str:    string,
	b:      bool,
}

Document :: struct {
	nodes:    [dynamic]Node,
	header:   [dynamic]Prop, // top-level properties other than children (version, themes, variables, ...)
	vars:     map[string]Var, // resolved variables, by name without the '$'
	next_uid: int,
	// lookup caches; `version` changes whenever the tree structure does
	version:      int,
	by_uid:       map[int]int, // uid -> index in nodes (validated on use)
	by_id:        map[string]int,
	kids:         map[int][dynamic]int, // parent uid -> child uids in order
	kids_version: int,
	// instances expanded into copies of their component ("ghosts"); rebuilt with `version`
	ghosts:        [dynamic]Node,
	ghost_by_uid:  map[int]int,
	ghost_kids:    map[int][dynamic]int,
	ghost_root:    map[int]int, // instance uid -> ghost copy of the component root
	ghost_slot:    map[int]int, // instance uid -> ghost frame that takes the instance's children
	ghost_version: int,
	pages:         [dynamic]Page, // parsed header "pages"
	pages_version: int,
	// themes
	var_defs:      map[string][dynamic]Var_Entry, // every themed value of each variable
	theme_axes:    [dynamic]Theme_Axis,
	axes_version:  int,
	axes_valid:    bool,
	resolve_theme: map[string]string, // theme used while parsing the node being refreshed
	building_ghosts: bool, // refreshes inside ghost expansion must not bump the version
	lib_vars:        string, // variables of imported libraries, renamed "alias:name" (JSON)
}

// Property overrides an instance applies to one node of its component.
Override :: struct {
	id:            string,
	replaces:      bool, // override carries a "type": the node is replaced; not supported
	raw:           string, // the whole override as JSON when it sets more than the fields below
	content, name: string,
	has_content:   bool,
	has_name:      bool,
	fill, stroke:  Color,
	fill_on:       bool,
	stroke_on:     bool,
	set_fill:      bool,
	set_stroke:    bool,
	enabled:       bool,
	set_enabled:   bool,
	opacity:       f32,
	set_opacity:   bool,
	font_size:     f32,
	set_font_size: bool,
	bold:          bool,
	weight:        int,
	set_weight:    bool,
}

doc_bump :: proc(doc: ^Document) {
	doc.version += 1
}

doc_index :: proc(doc: ^Document) {
	clear(&doc.by_uid)
	clear(&doc.by_id)
	for n, i in doc.nodes {
		doc.by_uid[n.uid] = i
		doc.by_id[n.id] = i
	}
}

// Child uids of a node (0 = canvas), in stacking order. Rebuilt when the tree changed.
children_of :: proc(doc: ^Document, uid: int) -> []int {
	if doc.kids_version != doc.version {
		for _, &list in doc.kids do clear(&list)
		for n in doc.nodes {
			list, has := &doc.kids[n.parent]
			if !has {
				doc.kids[n.parent] = make([dynamic]int)
				list = &doc.kids[n.parent]
			}
			append(list, n.uid)
		}
		doc.kids_version = doc.version
	}
	if list, has := doc.kids[uid]; has do return list[:]
	return nil
}

// Children for layout and drawing: real children, or for a ghost its ghost children
// plus, for the slot frame, the instance's real children.
children_for_layout :: proc(doc: ^Document, uid: int) -> []int {
	if gi, is_ghost := doc.ghost_by_uid[uid]; is_ghost && gi < len(doc.ghosts) && doc.ghosts[gi].uid == uid {
		own: []int
		if list, has := doc.ghost_kids[uid]; has do own = list[:]
		g := &doc.ghosts[gi]
		inst := g.ghost_inst
		legacy_slot := false
		if slot, has := doc.ghost_slot[inst]; has && slot == uid do legacy_slot = true
		// instance content: 2.8 style (the ref's own children) goes to the legacy slot;
		// 2.21 style (`descendants[slot].children`) to the frame it names, replacing
		// that frame's own children
		extra := make([dynamic]int, 0, 4, context.temp_allocator)
		named := false
		for cu in children_of(doc, inst) {
			c, _ := doc_find_uid(doc, cu)
			if c == nil do continue
			if c.slot_of == "" {
				if legacy_slot do append(&extra, cu)
			} else if c.slot_of == g.ghost_of {
				append(&extra, cu)
				named = true
			}
		}
		if len(extra) == 0 do return own
		if named do return extra[:]
		both := make([dynamic]int, 0, len(own) + len(extra), context.temp_allocator)
		append(&both, ..own)
		append(&both, ..extra[:])
		return both[:]
	}
	return children_of(doc, uid)
}

// The ghost tree an instance draws, or nil.
ghost_root_of :: proc(doc: ^Document, inst_uid: int) -> ^Node {
	if g, has := doc.ghost_root[inst_uid]; has {
		n, _ := doc_find_uid(doc, g)
		return n
	}
	return nil
}

// Rebuilds the ghost copies of every instance when the document changed.
ghosts_sync :: proc(doc: ^Document) {
	if doc.ghost_version == doc.version && doc.kids_version == doc.version do return
	_ = children_of(doc, 0) // refresh the child index first
	for &g in doc.ghosts do node_free(&g)
	clear(&doc.ghosts)
	clear(&doc.ghost_by_uid)
	for _, &l in doc.ghost_kids do delete(l)
	clear(&doc.ghost_kids)
	clear(&doc.ghost_root)
	clear(&doc.ghost_slot)
	doc.ghost_version = doc.version
	doc.building_ghosts = true
	count := len(doc.nodes)
	for i in 0 ..< count {
		if doc.nodes[i].kind == .Ref do expand_instance(doc, doc.nodes[i].uid, nil, 0)
	}
	doc.building_ghosts = false
}

MAX_INSTANCE_DEPTH :: 6

// Copies the component of `inst_uid` under the instance, applying the override
// chain (outer instances first, so inner ones are overridden by outer ones).
expand_instance :: proc(doc: ^Document, inst_uid: int, outer: []^Node, depth: int) {
	inst, _ := doc_find_uid(doc, inst_uid)
	if inst == nil || depth > MAX_INSTANCE_DEPTH do return
	comp, _ := doc_find(doc, inst.ref)
	if comp == nil || comp.ghost do return
	// a real instance inside its own component would recurse forever
	real_inst := inst
	for real_inst.ghost {
		r, _ := doc_find_uid(doc, real_inst.ghost_inst)
		if r == nil do break
		real_inst = r
	}
	if comp.uid == real_inst.uid || is_descendant(doc, real_inst.uid, comp.uid) || is_descendant(doc, comp.uid, real_inst.uid) do return
	chain := make([dynamic]^Node, context.temp_allocator)
	append(&chain, ..outer)
	append(&chain, inst)
	root := ghost_clone_tree(doc, comp.uid, inst_uid, inst_uid, chain[:], depth, 0)
	if root == 0 do return
	doc.ghost_root[inst_uid] = root
	// the slot: a descendant named on the component root (older files), else the
	// first descendant frame marked `slot`, else the root itself
	slot := 0
	for name in comp.slot_names {
		if found := ghost_find_named(doc, root, name, 0); found != 0 {
			slot = found
			break
		}
	}
	if slot == 0 do slot = ghost_find_slot(doc, root, 0)
	if slot == 0 do slot = root
	doc.ghost_slot[inst_uid] = slot
	ghost_rebuilds += 1
}

ghost_rebuilds: int

ghost_find_slot :: proc(doc: ^Document, uid: int, depth: int) -> int {
	if depth > MAX_DEPTH do return 0
	list, has := doc.ghost_kids[uid]
	if !has do return 0
	for cu in list {
		c, _ := doc_find_uid(doc, cu)
		if c == nil do continue
		if c.kind == .Frame && c.is_slot do return cu
		if found := ghost_find_slot(doc, cu, depth + 1); found != 0 do return found
	}
	return 0
}

ghost_find_named :: proc(doc: ^Document, uid: int, name: string, depth: int) -> int {
	if depth > MAX_DEPTH do return 0
	list, has := doc.ghost_kids[uid]
	if !has do return 0
	for cu in list {
		c, _ := doc_find_uid(doc, cu)
		if c == nil do continue
		if c.kind == .Frame && (c.name == name || c.ghost_of == name) do return cu
		if found := ghost_find_named(doc, cu, name, depth + 1); found != 0 do return found
	}
	return 0
}

ghost_clone_tree :: proc(doc: ^Document, orig_uid, parent, inst_uid: int, chain: []^Node, depth, level: int) -> int {
	if level > MAX_DEPTH do return 0
	orig, _ := doc_find_uid(doc, orig_uid)
	if orig == nil do return 0
	g: Node
	// an instance shown under another theme than its component gets a re-parsed copy
	inst_theme := make(map[string]string, context.temp_allocator)
	if inst, _ := doc_find_uid(doc, inst_uid); inst != nil do theme_in_effect(doc, inst, &inst_theme)
	// overrides of properties without a fast path (icon, padding, cornerRadius, ...)
	// are written into a copy of the component node's props, which is then re-parsed
	general := false
	for over in chain do for o in over.overrides do if !o.replaces && o.id == orig.id && o.raw != "" do general = true
	// the instance's own properties override the component root (fill, size, padding, ...)
	root_props: []Prop
	if level == 0 {
		if inst, _ := doc_find_uid(doc, inst_uid); inst != nil {
			src := inst
			if len(inst.props) == 0 && inst.ghost_of != "" {
				if real, _ := doc_find(doc, inst.ghost_of); real != nil do src = real
			}
			for p in src.props do if !root_override_skipped(p.key) {
				root_props = src.props[:]
				break
			}
		}
	}
	if theme_key(inst_theme) != orig.theme_key || general || root_props != nil {
		g = node_clone(orig^)
		for p in root_props do if !root_override_skipped(p.key) do node_set_raw(&g, p.key, p.raw)
		if general {
			for over in chain do for o in over.overrides {
				if o.replaces || o.id != orig.id || o.raw == "" do continue
				v, err := json.parse_string(o.raw, .JSON5, false, context.temp_allocator)
				obj, ok := v.(json.Object)
				if err != nil || !ok do continue
				for k, val in obj {
					if k == "type" || k == "id" || k == "children" do continue
					b := strings.builder_make(context.temp_allocator)
					write_json_value(&b, val)
					node_set_raw(&g, k, strings.to_string(b))
				}
			}
		}
		doc.next_uid += 1
		g.uid = doc.next_uid
		g.parent = parent
		g.ghost = true
		g.ghost_inst = inst_uid
		append(&doc.ghosts, g)
		doc.ghost_by_uid[g.uid] = len(doc.ghosts) - 1
		node_refresh(doc, &doc.ghosts[len(doc.ghosts) - 1])
		g = doc.ghosts[len(doc.ghosts) - 1]
		pop(&doc.ghosts)
		delete_key(&doc.ghost_by_uid, g.uid)
		delete(g.ghost_of)
		g.ghost_of = strings.clone(orig.id)
	} else {
		g = ghost_clone(orig^)
		doc.next_uid += 1
		g.uid = doc.next_uid
		g.parent = parent
		g.ghost = true
		g.ghost_inst = inst_uid
	}
	for over in chain {
		for o in over.overrides {
			if o.replaces || o.id != orig.id do continue
			if o.has_content {
				delete(g.content)
				g.content = strings.clone(o.content)
			}
			if o.has_name {
				delete(g.name)
				g.name = strings.clone(o.name)
			}
			if o.set_fill {
				g.fill, g.has_fill = o.fill, o.fill_on
				g.nfills = 1 if o.fill_on else 0
				g.fills[0] = {kind = .Color, enabled = true, color = o.fill, opacity = 1}
			}
			if o.set_stroke do g.stroke, g.has_stroke = o.stroke, o.stroke_on
			if o.set_enabled do g.enabled = o.enabled
			if o.set_opacity do g.opacity = o.opacity
			if o.set_font_size do g.font_size = o.font_size
			if o.set_weight do g.bold, g.weight = o.bold, o.weight
		}
	}
	append(&doc.ghosts, g)
	idx := len(doc.ghosts) - 1
	doc.ghost_by_uid[g.uid] = idx
	if orig.kind == .Ref {
		expand_instance(doc, g.uid, chain, depth + 1)
	}
	kids := make([dynamic]int)
	for cu in children_of(doc, orig_uid) {
		if gc := ghost_clone_tree(doc, cu, g.uid, inst_uid, chain, depth, level + 1); gc != 0 do append(&kids, gc)
	}
	doc.ghost_kids[g.uid] = kids
	return g.uid
}

// Properties of an instance that belong to the instance itself, not to the component
// root it overrides: identity, position in its parent, visibility and opacity (applied
// when the instance is drawn), and structure.
root_override_skipped :: proc(key: string) -> bool {
	switch key {
	case "type", "id", "ref", "descendants", "children", "x", "y", "name", "theme", "enabled",
	     "opacity", "layoutPosition", "rotation", "flipX", "flipY", "metadata", "context", "reusable":
		return true
	}
	return false
}

// A copy of the parsed fields only (no props); the strings are owned by the ghost.
ghost_clone :: proc(n: Node) -> Node {
	c := n
	c.props = nil
	c.id = ""
	c.ghost_of = strings.clone(n.id)
	c.type_name = strings.clone(n.type_name)
	c.name = strings.clone(n.name)
	c.content = strings.clone(n.content)
	c.geometry = strings.clone(n.geometry)
	c.ref = strings.clone(n.ref)
	c.icon = strings.clone(n.icon)
	c.slot_of = strings.clone(n.slot_of)
	c.font_family = strings.clone(n.font_family)
	c.image_url = strings.clone(n.image_url)
	c.cmds = make([dynamic]Path_Cmd, len(n.cmds))
	copy(c.cmds[:], n.cmds[:])
	c.overrides = make([dynamic]Override, len(n.overrides))
	for o, i in n.overrides {
		c.overrides[i] = o
		c.overrides[i].id = strings.clone(o.id)
		c.overrides[i].content = strings.clone(o.content)
		c.overrides[i].name = strings.clone(o.name)
		c.overrides[i].raw = strings.clone(o.raw)
	}
	c.slot_names = make([dynamic]string, len(n.slot_names))
	for sn, i in n.slot_names do c.slot_names[i] = strings.clone(sn)
	c.theme_set = make([dynamic][2]string, len(n.theme_set))
	for t, i in n.theme_set do c.theme_set[i] = {strings.clone(t[0]), strings.clone(t[1])}
	c.theme_key = strings.clone(n.theme_key)
	return c
}

doc_find :: proc(doc: ^Document, id: string) -> (^Node, int) {
	if i, ok := doc.by_id[id]; ok && i < len(doc.nodes) && doc.nodes[i].id == id do return &doc.nodes[i], i
	doc_index(doc)
	if i, ok := doc.by_id[id]; ok do return &doc.nodes[i], i
	return nil, -1
}

doc_find_uid :: proc(doc: ^Document, uid: int) -> (^Node, int) {
	if uid == 0 do return nil, -1
	if i, ok := doc.by_uid[uid]; ok && i < len(doc.nodes) && doc.nodes[i].uid == uid do return &doc.nodes[i], i
	if i, ok := doc.ghost_by_uid[uid]; ok && i < len(doc.ghosts) && doc.ghosts[i].uid == uid do return &doc.ghosts[i], i
	doc_index(doc)
	if i, ok := doc.by_uid[uid]; ok do return &doc.nodes[i], i
	return nil, -1
}

// Adds a node, assigning a uid and an id when it has none, and parses its props.
doc_add :: proc(doc: ^Document, n: Node) -> ^Node {
	n := n
	doc_bump(doc)
	doc.next_uid += 1
	n.uid = doc.next_uid
	if n.id == "" {
		if existing, _ := doc_find(doc, prop_string(&n, "id")); existing == nil && prop_string(&n, "id") != "" {
			n.id = strings.clone(prop_string(&n, "id"))
		} else {
			n.id = gen_id(doc)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	json_write_string(&b, n.id)
	node_set_raw(&n, "id", strings.to_string(b))
	append(&doc.nodes, n)
	p := &doc.nodes[len(doc.nodes) - 1]
	node_refresh(doc, p)
	return p
}

gen_id :: proc(doc: ^Document) -> string {
	alphabet := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	buf: [5]u8
	for {
		for &c in buf do c = alphabet[rand.int_max(len(alphabet))]
		if n, _ := doc_find(doc, string(buf[:])); n == nil do return strings.clone(string(buf[:]))
	}
}

node_free :: proc(n: ^Node) {
	for p in n.props {
		delete(p.key)
		delete(p.raw)
	}
	delete(n.props)
	delete(n.id)
	delete(n.slot_of)
	n.slot_of = ""
	node_free_derived(n)
}

node_free_derived :: proc(n: ^Node) {
	delete(n.font_family)
	delete(n.image_url)
	delete(n.type_name)
	delete(n.name)
	delete(n.content)
	delete(n.geometry)
	delete(n.ref)
	delete(n.icon)
	delete(n.cmds)
	n.type_name, n.name, n.content, n.geometry, n.ref, n.icon = "", "", "", "", "", ""
	n.font_family, n.image_url = "", ""
	n.cmds = nil
	delete(n.ghost_of)
	n.ghost_of = ""
	for t in n.theme_set {
		delete(t[0])
		delete(t[1])
	}
	delete(n.theme_set)
	n.theme_set = nil
	delete(n.theme_key)
	n.theme_key = ""
	for &o in n.overrides {
		delete(o.id)
		delete(o.content)
		delete(o.name)
		delete(o.raw)
	}
	delete(n.overrides)
	n.overrides = nil
	for sn in n.slot_names do delete(sn)
	delete(n.slot_names)
	n.slot_names = nil
}

node_clone :: proc(n: Node) -> Node {
	c := n
	c.id = strings.clone(n.id)
	c.props = make([dynamic]Prop, len(n.props))
	for p, i in n.props do c.props[i] = {strings.clone(p.key), strings.clone(p.raw)}
	c.type_name = strings.clone(n.type_name)
	c.name = strings.clone(n.name)
	c.content = strings.clone(n.content)
	c.geometry = strings.clone(n.geometry)
	c.ref = strings.clone(n.ref)
	c.icon = strings.clone(n.icon)
	c.slot_of = strings.clone(n.slot_of)
	c.font_family = strings.clone(n.font_family)
	c.image_url = strings.clone(n.image_url)
	c.overrides = make([dynamic]Override, len(n.overrides))
	for o, i in n.overrides {
		c.overrides[i] = o
		c.overrides[i].id = strings.clone(o.id)
		c.overrides[i].content = strings.clone(o.content)
		c.overrides[i].name = strings.clone(o.name)
		c.overrides[i].raw = strings.clone(o.raw)
	}
	c.slot_names = make([dynamic]string, len(n.slot_names))
	for sn, i in n.slot_names do c.slot_names[i] = strings.clone(sn)
	c.cmds = make([dynamic]Path_Cmd, len(n.cmds))
	copy(c.cmds[:], n.cmds[:])
	c.ghost_of = strings.clone(n.ghost_of)
	c.theme_set = make([dynamic][2]string, len(n.theme_set))
	for t, i in n.theme_set do c.theme_set[i] = {strings.clone(t[0]), strings.clone(t[1])}
	c.theme_key = strings.clone(n.theme_key)
	return c
}

doc_clear :: proc(doc: ^Document) {
	for &n in doc.nodes do node_free(&n)
	clear(&doc.nodes)
	doc_bump(doc)
	for p in doc.header {
		delete(p.key)
		delete(p.raw)
	}
	clear(&doc.header)
	vars_clear(doc)
}

vars_clear :: proc(doc: ^Document) {
	for k, v in doc.vars {
		delete(k)
		delete(v.str)
	}
	clear(&doc.vars)
}

// An undo step: the layers and the document's header (variables, themes, pages, imports).
Snapshot :: struct {
	nodes:    []Node,
	header:   []Prop,
	lib_vars: string,
}

doc_snapshot :: proc(doc: ^Document) -> Snapshot {
	out := Snapshot{nodes = make([]Node, len(doc.nodes)), header = make([]Prop, len(doc.header)), lib_vars = strings.clone(doc.lib_vars)}
	for n, i in doc.nodes do out.nodes[i] = node_clone(n)
	for p, i in doc.header do out.header[i] = Prop{strings.clone(p.key), strings.clone(p.raw)}
	return out
}

doc_restore :: proc(doc: ^Document, snap: Snapshot) {
	for &n in doc.nodes do node_free(&n)
	clear(&doc.nodes)
	for n in snap.nodes do append(&doc.nodes, node_clone(n))
	header_changed := len(snap.header) != len(doc.header) || snap.lib_vars != doc.lib_vars
	if !header_changed {
		for p, i in snap.header do if p.key != doc.header[i].key || p.raw != doc.header[i].raw do header_changed = true
	}
	if header_changed {
		for p in doc.header {
			delete(p.key)
			delete(p.raw)
		}
		clear(&doc.header)
		for p in snap.header do append(&doc.header, Prop{strings.clone(p.key), strings.clone(p.raw)})
		delete(doc.lib_vars)
		doc.lib_vars = strings.clone(snap.lib_vars)
		doc_resolve_vars(doc)
		for &n in doc.nodes do node_refresh(doc, &n)
	}
	doc_bump(doc)
}

is_descendant :: proc(doc: ^Document, uid, ancestor: int) -> bool {
	cur := uid
	for cur != 0 {
		n, _ := doc_find_uid(doc, cur)
		if n == nil do return false
		if n.parent == ancestor do return true
		cur = n.parent
	}
	return false
}

// Deletes the node and everything inside it.
doc_delete :: proc(doc: ^Document, uid: int) {
	doc_bump(doc)
	uids := make([dynamic]int, context.temp_allocator)
	append(&uids, uid)
	for n in doc.nodes {
		if is_descendant(doc, n.uid, uid) do append(&uids, n.uid)
	}
	for del in uids {
		_, i := doc_find_uid(doc, del)
		if i < 0 do continue
		node_free(&doc.nodes[i])
		ordered_remove(&doc.nodes, i)
	}
}

// Moves a node by changing its authored position. Children follow because
// their positions are relative.
doc_move :: proc(doc: ^Document, uid: int, dx, dy: f32) {
	n, _ := doc_find_uid(doc, uid)
	if n == nil do return
	node_set_number(doc, n, "x", n.pos.x + dx)
	node_set_number(doc, n, "y", n.pos.y + dy)
}

// Puts a node into another container (0 = canvas), keeping it where it is on
// the page, and brings it to the front there.
doc_reparent :: proc(doc: ^Document, uid, parent: int) {
	n, _ := doc_find_uid(doc, uid)
	if n == nil do return
	doc_bump(doc)
	ox, oy := parent_origin(doc, parent)
	node_set_number(doc, n, "x", n.x - ox)
	node_set_number(doc, n, "y", n.y - oy)
	n.parent = parent
	doc_bring_to_front(doc, uid)
}

// Moves a node (and its subtree) to the end of the array so it renders on top.
doc_bring_to_front :: proc(doc: ^Document, uid: int) {
	doc_bump(doc)
	moved := make([dynamic]Node, context.temp_allocator)
	for i := 0; i < len(doc.nodes); {
		n := doc.nodes[i]
		if n.uid == uid || is_descendant(doc, n.uid, uid) {
			append(&moved, n)
			ordered_remove(&doc.nodes, i)
		} else {
			i += 1
		}
	}
	append(&doc.nodes, ..moved[:])
}

parent_origin :: proc(doc: ^Document, parent: int) -> (f32, f32) {
	p, _ := doc_find_uid(doc, parent)
	if p == nil do return 0, 0
	return p.x, p.y
}

// True when the node's position is managed by a flex parent.
in_flow :: proc(doc: ^Document, n: ^Node) -> bool {
	if n.abs_pos do return false
	p, _ := doc_find_uid(doc, n.parent)
	return p != nil && p.layout != .None
}

node_label :: proc(n: ^Node) -> string {
	if n.name != "" do return n.name
	if n.kind == .Text && n.content != "" do return n.content
	if n.kind == .Other && n.type_name != "" do return n.type_name
	if n.kind == .Icon && n.icon != "" do return n.icon
	if n.kind == .Ref {
		if comp, _ := doc_find(&app.doc, n.ref); comp != nil && comp.uid != n.uid do return node_label(comp)
	}
	return KIND_LABELS[n.kind]
}

// Sets one property override of an instance (`descendants[id][key] = value`);
// a nil value removes the override, an empty entry is dropped.
override_set :: proc(doc: ^Document, inst: ^Node, id, key: string, value: json.Value) {
	desc: json.Object
	if v, ok := prop_value(inst, "descendants"); ok {
		if obj, is_obj := v.(json.Object); is_obj do desc = obj
	}
	if desc == nil do desc = make(json.Object, context.temp_allocator)
	// find an existing entry by its last path segment
	path := id
	for k in desc {
		seg := k
		if i := strings.last_index_byte(k, '/'); i >= 0 do seg = k[i + 1:]
		if seg == id {
			path = k
			break
		}
	}
	entry, has := desc[path].(json.Object)
	if !has do entry = make(json.Object, context.temp_allocator)
	if value == nil do delete_key(&entry, key)
	else do entry[key] = value
	if len(entry) == 0 do delete_key(&desc, path)
	else do desc[path] = entry
	if len(desc) == 0 do node_unset(doc, inst, "descendants")
	else do node_set(doc, inst, "descendants", desc)
}

// ---------------------------------------------------------------- properties

prop_index :: proc(n: ^Node, key: string) -> int {
	for p, i in n.props do if p.key == key do return i
	return -1
}

prop_raw :: proc(n: ^Node, key: string) -> string {
	i := prop_index(n, key)
	return n.props[i].raw if i >= 0 else ""
}

prop_value :: proc(n: ^Node, key: string) -> (json.Value, bool) {
	raw := prop_raw(n, key)
	if raw == "" do return nil, false
	v, err := json.parse_string(raw, .JSON5, false, context.temp_allocator)
	return v, err == nil
}

prop_string :: proc(n: ^Node, key: string) -> string {
	v, ok := prop_value(n, key)
	if !ok do return ""
	s, is_str := v.(json.String)
	return string(s) if is_str else ""
}

node_set_raw :: proc(n: ^Node, key, raw: string) {
	i := prop_index(n, key)
	if i >= 0 {
		delete(n.props[i].raw)
		n.props[i].raw = strings.clone(raw)
	} else {
		append(&n.props, Prop{strings.clone(key), strings.clone(raw)})
	}
}

node_unset :: proc(doc: ^Document, n: ^Node, key: string) {
	i := prop_index(n, key)
	if i < 0 do return
	delete(n.props[i].key)
	delete(n.props[i].raw)
	ordered_remove(&n.props, i)
	node_refresh(doc, n)
}

node_set :: proc(doc: ^Document, n: ^Node, key: string, v: json.Value) {
	b := strings.builder_make(context.temp_allocator)
	write_json_value(&b, v)
	node_set_raw(n, key, strings.to_string(b))
	node_refresh(doc, n)
}

node_set_number :: proc(doc: ^Document, n: ^Node, key: string, f: f32) {
	node_set_raw(n, key, fmt.tprintf("%v", round2(f)))
	node_refresh(doc, n)
}

node_set_string :: proc(doc: ^Document, n: ^Node, key: string, s: string) {
	b := strings.builder_make(context.temp_allocator)
	json_write_string(&b, s)
	node_set_raw(n, key, strings.to_string(b))
	node_refresh(doc, n)
}

node_set_bool :: proc(doc: ^Document, n: ^Node, key: string, v: bool) {
	node_set_raw(n, key, "true" if v else "false")
	node_refresh(doc, n)
}

// Transparent removes the fill.
node_set_fill :: proc(doc: ^Document, n: ^Node, c: Color) {
	if c[3] == 0 do node_unset(doc, n, "fill")
	else do node_set_string(doc, n, "fill", color_hex(c))
}

// Keeps the authored stroke form: {align, thickness, fill} in older files,
// a plain fill plus strokeWidth otherwise.
node_set_stroke :: proc(doc: ^Document, n: ^Node, c: Color) {
	if c[3] == 0 {
		node_unset(doc, n, "stroke")
		return
	}
	if obj, ok := old_stroke_object(n); ok {
		obj["fill"] = json.String(color_hex(c))
		node_set(doc, n, "stroke", obj)
		return
	}
	node_set_string(doc, n, "stroke", color_hex(c))
}

node_set_stroke_width :: proc(doc: ^Document, n: ^Node, w: f32) {
	if obj, ok := old_stroke_object(n); ok {
		obj["thickness"] = json.Float(round2(w))
		node_set(doc, n, "stroke", obj)
		return
	}
	node_set_number(doc, n, "strokeWidth", w)
}

// Padding as .pen authors it: one number, [vertical, horizontal] or [t, r, b, l].
node_set_padding :: proc(doc: ^Document, n: ^Node, pad: [4]f32) {
	t, r, b, l := round2(pad[0]), round2(pad[1]), round2(pad[2]), round2(pad[3])
	switch {
	case t == r && r == b && b == l: node_set_raw(n, "padding", num_text(t))
	case t == b && l == r: node_set_raw(n, "padding", fmt.tprintf("[%s,%s]", num_text(t), num_text(r)))
	case: node_set_raw(n, "padding", fmt.tprintf("[%s,%s,%s,%s]", num_text(t), num_text(r), num_text(b), num_text(l)))
	}
	node_refresh(doc, n)
}

// The first shadow effect of a node as a JSON object (effect may be one or a list).
shadow_object :: proc(n: ^Node) -> (obj: json.Object, index: int, list: json.Array, ok: bool) {
	v, has := prop_value(n, "effect")
	if !has do return
	if arr, is_arr := v.(json.Array); is_arr {
		for e, i in arr {
			if o, is_obj := e.(json.Object); is_obj && string(o["type"].(json.String) or_else "") == "shadow" {
				return o, i, arr, true
			}
		}
		return
	}
	if o, is_obj := v.(json.Object); is_obj && string(o["type"].(json.String) or_else "") == "shadow" do return o, -1, nil, true
	return
}

shadow_write :: proc(doc: ^Document, n: ^Node, obj: json.Object, index: int, list: json.Array) {
	if index >= 0 {
		list[index] = obj
		node_set(doc, n, "effect", list)
	} else {
		node_set(doc, n, "effect", obj)
	}
}

// key: x, y, blur, spread (numbers) or color (hex string); inner toggles the type.
shadow_set :: proc(doc: ^Document, n: ^Node, key: string, value: f32, color := "") {
	obj, index, list, ok := shadow_object(n)
	if !ok do return
	switch key {
	case "x", "y":
		off, _ := obj["offset"].(json.Object)
		if off == nil do off = make(json.Object, context.temp_allocator)
		off[key] = json.Float(round2_64(value))
		obj["offset"] = off
	case "blur", "spread":
		obj[key] = json.Float(round2_64(max(value, 0)))
	case "color":
		obj["color"] = json.String(color)
	case "inner":
		obj["shadowType"] = json.String("inner" if value != 0 else "outer")
	}
	shadow_write(doc, n, obj, index, list)
}

shadow_add :: proc(doc: ^Document, n: ^Node) {
	node_set_raw(n, "effect", `{"type":"shadow","shadowType":"outer","color":"#00000040","offset":{"x":0,"y":4},"blur":16,"spread":0}`)
	node_refresh(doc, n)
}

shadow_remove :: proc(doc: ^Document, n: ^Node) {
	_, index, list, ok := shadow_object(n)
	if !ok do return
	if index >= 0 && len(list) > 1 {
		ordered_remove(&list, index)
		node_set(doc, n, "effect", list)
	} else {
		node_unset(doc, n, "effect")
	}
}

old_stroke_object :: proc(n: ^Node) -> (json.Object, bool) {
	if !n.stroke_old do return nil, false
	v, ok := prop_value(n, "stroke")
	if !ok do return nil, false
	if arr, is_arr := v.(json.Array); is_arr && len(arr) > 0 do v = arr[0]
	obj, is_obj := v.(json.Object)
	return obj, is_obj
}

// Applies a value typed into a panel field.
node_set_text :: proc(doc: ^Document, n: ^Node, key, text: string) -> (err: string) {
	t := strings.trim_space(text)
	switch key {
	case "fill", "stroke":
		c, ok := parse_color(t)
		if !ok do return fmt.tprintf("invalid color '%s'", t)
		if key == "fill" do node_set_fill(doc, n, c)
		else do node_set_stroke(doc, n, c)
	case "strokeWidth":
		f, ok := strconv.parse_f32(t)
		if !ok do return "invalid number"
		node_set_stroke_width(doc, n, max(f, 0))
	case "width", "height":
		f, ok := strconv.parse_f32(t)
		if ok {
			if n.kind == .Text {
				if key == "height" do node_set_string(doc, n, "textGrowth", "fixed-width-height")
				else if n.growth == .Auto do node_set_string(doc, n, "textGrowth", "fixed-width")
			}
			node_set_number(doc, n, key, max(f, 1))
		} else if strings.has_prefix(t, "fit") || strings.has_prefix(t, "fill") {
			node_set_string(doc, n, key, t)
		} else {
			return "use a number, fit_content or fill_container"
		}
	case "name", "content":
		if t == "" && key == "name" do node_unset(doc, n, key)
		else do node_set_string(doc, n, key, text)
	case "opacity":
		f, ok := strconv.parse_f32(strings.trim_suffix(t, "%"))
		if !ok do return "invalid number"
		if strings.has_suffix(t, "%") || f > 1 do f /= 100
		node_set_number(doc, n, key, clamp(f, 0, 1))
	case:
		if f, ok := strconv.parse_f32(t); ok do node_set_number(doc, n, key, f)
		else if t == "true" || t == "false" do node_set_bool(doc, n, key, t == "true")
		else if t == "" do node_unset(doc, n, key)
		else do node_set_string(doc, n, key, t)
	}
	return ""
}

// ---------------------------------------------------------------- parsing props

// Rebuilds the parsed fields from `props`.
node_refresh :: proc(doc: ^Document, n: ^Node) {
	if !doc.building_ghosts do doc_bump(doc)
	node_free_derived(n)
	// the theme in effect decides what every $variable below resolves to
	if v, ok := prop_value(n, "theme"); ok {
		if th, is_obj := v.(json.Object); is_obj {
			for k, val in th do append(&n.theme_set, [2]string{strings.clone(k), strings.clone(string(val.(json.String) or_else ""))})
		}
	}
	theme_in_effect(doc, n, &doc.resolve_theme)
	n.theme_key = theme_key(doc.resolve_theme)
	n.pos = {}
	n.layout, n.gap, n.padding = .None, 0, {}
	n.justify, n.align, n.clip, n.abs_pos = .Start, .Start, false, false
	n.fill, n.has_fill, n.stroke, n.has_stroke = {}, false, {}, false
	n.stroke_width, n.stroke_align, n.stroke_old = 1, .Center, false
	n.radius, n.opacity, n.enabled, n.reusable = {}, 1, true, false
	n.font_size, n.bold, n.growth, n.text_align, n.line_height = 14, false, .Auto, .Left, 0
	n.weight, n.italic, n.image_mode = 400, false, .Cover
	delete(n.font_family)
	n.font_family = ""
	delete(n.image_url)
	n.image_url = ""
	n.view_box = {}
	n.shadow = {}
	n.is_slot = false
	n.line_cap, n.line_join = .Butt, .Miter
	n.nfills, n.neffects, n.rotation, n.flip_x, n.flip_y = 0, 0, 0, false, false
	n.stroke_sides, n.stroke_per_side = {}, false
	n.letter_spacing, n.underline, n.strikethrough = 0, false, false
	n.text_valign = .Start
	icon_lib, icon_name := "", ""

	n.type_name = strings.clone(prop_string(n, "type"))
	n.kind = kind_from_name(n.type_name)
	#partial switch n.kind {
	case .Frame:
		n.layout = .Horizontal
		n.width, n.height = {mode = .Fit}, {mode = .Fit}
	case .Group, .Text, .Ref:
		n.width, n.height = {mode = .Fit}, {mode = .Fit}
	case .Path:
		n.width, n.height = {mode = .Fixed}, {mode = .Fixed}
	case .Icon:
		n.width, n.height = {.Fixed, 24, true}, {.Fixed, 24, true}
	case:
		n.width, n.height = {.Fixed, 100, false}, {.Fixed, 100, false}
	}
	// Without strokeAlignment the stroke is centred on the outline, as pen.dev draws it
	// (checked pixel by pixel). Strokes added in the inspector are written as "inner".

	thickness: f32 = -1
	stroke_width: f32 = -1
	view_box: [4]f32
	has_view_box := false
	for p in n.props {
		v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
		if err != nil do continue
		switch p.key {
		case "name":
			n.name = strings.clone(json_str(doc, v))
		case "x":
			n.pos.x = num(doc, v) or_else 0
		case "y":
			n.pos.y = num(doc, v) or_else 0
		case "width":
			n.width = parse_size(doc, v)
		case "height":
			n.height = parse_size(doc, v)
		case "layout":
			switch json_str(doc, v) {
			case "none": n.layout = .None
			case "horizontal": n.layout = .Horizontal
			case "vertical": n.layout = .Vertical
			}
		case "gap":
			n.gap = num(doc, v) or_else 0
		case "padding":
			n.padding = parse_padding(doc, v)
		case "justifyContent":
			switch json_str(doc, v) {
			case "center": n.justify = .Center
			case "end": n.justify = .End
			case "space_between": n.justify = .Space_Between
			case "space_around": n.justify = .Space_Around
			}
		case "alignItems":
			switch json_str(doc, v) {
			case "center": n.align = .Center
			case "end": n.align = .End
			}
		case "clip":
			n.clip = json_bool(doc, v) or_else false
		case "layoutPosition":
			n.abs_pos = json_str(doc, v) == "absolute"
		case "fill":
			n.fill, n.has_fill = color_of(doc, v)
			if url, mode, ok := image_of(doc, v); ok {
				n.image_url = strings.clone(url)
				n.image_mode = mode
			}
			parse_fills(doc, n, v)
		case "rotation":
			n.rotation = num(doc, v) or_else 0
		case "flipX":
			n.flip_x = json_bool(doc, v) or_else false
		case "flipY":
			n.flip_y = json_bool(doc, v) or_else false
		case "stroke":
			parse_stroke(doc, n, v, &thickness)
		case "strokeWidth":
			stroke_width = parse_thickness(doc, v)
			n.stroke_sides, n.stroke_per_side = parse_sides(doc, v)
		case "strokeAlignment":
			switch json_str(doc, v) {
			case "inner": n.stroke_align = .Inner
			case "center": n.stroke_align = .Center
			case "outer": n.stroke_align = .Outer
			}
		case "cornerRadius":
			if f, ok := num(doc, v); ok {
				n.radius = {f, f, f, f}
			} else if arr, is_arr := v.(json.Array); is_arr && len(arr) == 4 {
				for i in 0 ..< 4 do n.radius[i] = num(doc, arr[i]) or_else 0
			}
		case "opacity":
			n.opacity = clamp(num(doc, v) or_else 1, 0, 1)
		case "enabled":
			n.enabled = json_bool(doc, v) or_else true
		case "reusable":
			n.reusable = v.(json.Boolean) or_else false
		case "content":
			n.content = strings.clone(json_str(doc, v))
		case "fontSize":
			n.font_size = max(num(doc, v) or_else 14, 1)
		case "fontWeight":
			n.bold = weight_is_bold(doc, v)
			n.weight = weight_number(doc, v)
		case "fontFamily":
			n.font_family = strings.clone(json_str(doc, v))
		case "fontStyle":
			n.italic = strings.contains(strings.to_lower(json_str(doc, v), context.temp_allocator), "italic")
		case "letterSpacing":
			n.letter_spacing = num(doc, v) or_else 0
		case "textAlignVertical":
			switch json_str(doc, v) {
			case "middle": n.text_valign = .Center
			case "bottom": n.text_valign = .End
			}
		case "underline":
			n.underline = json_bool(doc, v) or_else false
		case "strikethrough":
			n.strikethrough = json_bool(doc, v) or_else false
		case "strokeLinecap":
			switch json_str(doc, v) {
			case "round": n.line_cap = .Round
			case "square": n.line_cap = .Square
			}
		case "strokeLinejoin":
			switch json_str(doc, v) {
			case "round": n.line_join = .Round
			case "bevel": n.line_join = .Bevel
			}
		case "library", "iconFontFamily":
			icon_lib = json_str(doc, v)
		case "icon", "iconFontName":
			icon_name = json_str(doc, v)
		case "textGrowth":
			switch json_str(doc, v) {
			case "fixed-width": n.growth = .Fixed_Width
			case "fixed-width-height": n.growth = .Fixed_Width_Height
			}
		case "textAlign":
			switch json_str(doc, v) {
			case "center": n.text_align = .Center
			case "right": n.text_align = .Right
			case "justify": n.text_align = .Justify
			}
		case "lineHeight":
			n.line_height = num(doc, v) or_else 0
		case "slot":
			if b, is_bool := v.(json.Boolean); is_bool do n.is_slot = bool(b)
			else do n.is_slot = true
			if arr, is_arr := v.(json.Array); is_arr {
				for item in arr do append(&n.slot_names, strings.clone(string(item.(json.String) or_else "")))
			}
		case "descendants":
			if desc, is_obj := v.(json.Object); is_obj {
				for path, o in desc {
					over, over_obj := o.(json.Object)
					if !over_obj do continue
					id := path
					if i := strings.last_index_byte(path, '/'); i >= 0 do id = path[i + 1:]
					ov := Override{id = strings.clone(id)}
					general := false
					for k, val in over {
						switch k {
						case: general = true // any other property: applied by re-parsing the copy
						case "type": ov.replaces = true
						case "content": ov.content, ov.has_content = strings.clone(json_str(doc, val)), true
						case "name": ov.name, ov.has_name = strings.clone(json_str(doc, val)), true
						case "fill": ov.fill, ov.fill_on = color_of(doc, val); ov.set_fill = true
						case "stroke": ov.stroke, ov.stroke_on = color_of(doc, val); ov.set_stroke = true
						case "enabled": ov.enabled, ov.set_enabled = json_bool(doc, val) or_else true, true
						case "opacity": ov.opacity, ov.set_opacity = clamp(num(doc, val) or_else 1, 0, 1), true
						case "fontSize": ov.font_size, ov.set_font_size = max(num(doc, val) or_else 14, 1), true
						case "fontWeight": ov.bold, ov.weight, ov.set_weight = weight_is_bold(doc, val), weight_number(doc, val), true
						}
					}
					if general {
						b := strings.builder_make(context.temp_allocator)
						write_json_value(&b, over)
						ov.raw = strings.clone(strings.to_string(b))
					}
					append(&n.overrides, ov)
				}
			}
		case "geometry":
			d := json_str(doc, v)
			cmds, box, ok := parse_svg_path(d)
			if ok {
				n.geometry = strings.clone(d)
				n.cmds = cmds
				n.view_box = box
			} else {
				delete(cmds)
			}
		case "viewBox":
			if arr, is_arr := v.(json.Array); is_arr && len(arr) == 4 {
				for i in 0 ..< 4 do view_box[i] = num(doc, arr[i]) or_else 0
				has_view_box = true
			}
		case "ref":
			n.ref = strings.clone(json_str(doc, v))
		case "effect":
			n.shadow = parse_shadow(doc, v)
			parse_effects(doc, n, v)
		}
	}
	if n.kind == .Icon {
		// icons are stroked outlines scaled to the box; the fill is their color
		n.icon = strings.clone(icon_name)
		if d, found := icon_path(icon_lib, icon_name); found {
			if cmds, _, ok := parse_svg_path(d); ok {
				delete(n.cmds)
				delete(n.geometry)
				n.geometry = strings.clone(d)
				n.cmds = cmds
				n.view_box = {0, 0, 24, 24}
				has_view_box = false
			}
		}
	}
	if has_view_box do n.view_box = view_box
	if n.view_box[2] <= 0 do n.view_box[2] = 1
	if n.view_box[3] <= 0 do n.view_box[3] = 1
	if n.kind == .Path {
		if n.width.mode == .Fixed && !n.width.has_value do n.width.value = n.view_box[2]
		if n.height.mode == .Fixed && !n.height.has_value do n.height.value = n.view_box[3]
	}
	n.stroke_width = thickness if thickness >= 0 else (stroke_width if stroke_width >= 0 else 1)
	if n.stroke_per_side do n.stroke_width = max(n.stroke_sides[0], n.stroke_sides[1], n.stroke_sides[2], n.stroke_sides[3])
	if n.kind == .Text {
		#partial switch n.growth {
		case .Auto: n.width, n.height = {mode = .Fit}, {mode = .Fit}
		case .Fixed_Width: n.height = {mode = .Fit}
		}
	}
}

// Number, numeric string, or "$variable".
num :: proc(doc: ^Document, v: json.Value) -> (f32, bool) {
	#partial switch x in v {
	case json.Float:
		return f32(x), true
	case json.Integer:
		return f32(x), true
	case json.String:
		s := string(x)
		if strings.has_prefix(s, "$") {
			vr, ok := var_get(doc, s[1:])
			if !ok do return 0, false
			#partial switch vr.kind {
			case .Number: return vr.number, true
			case .String: return strconv.parse_f32(vr.str)
			}
			return 0, false
		}
		return strconv.parse_f32(s)
	}
	return 0, false
}

json_str :: proc(doc: ^Document, v: json.Value) -> string {
	#partial switch x in v {
	case json.String:
		s := string(x)
		if strings.has_prefix(s, "$") {
			if vr, ok := var_get(doc, s[1:]); ok {
				#partial switch vr.kind {
				case .String: return vr.str
				case .Number: return fmt.tprintf("%v", vr.number)
				case .Color: return color_hex(vr.color)
				}
			}
		}
		return s
	case json.Float:
		return fmt.tprintf("%v", x)
	case json.Integer:
		return fmt.tprintf("%d", x)
	}
	return ""
}

json_bool :: proc(doc: ^Document, v: json.Value) -> (bool, bool) {
	#partial switch x in v {
	case json.Boolean:
		return bool(x), true
	case json.String:
		s := string(x)
		if strings.has_prefix(s, "$") {
			if vr, ok := var_get(doc, s[1:]); ok && vr.kind == .Bool do return vr.b, true
		}
	}
	return false, false
}

parse_size :: proc(doc: ^Document, v: json.Value) -> Size_Spec {
	if f, ok := num(doc, v); ok do return {.Fixed, f, true}
	s, is_str := v.(json.String)
	if !is_str do return {.Fixed, 100, false}
	spec: Size_Spec
	str := string(s)
	switch {
	case strings.has_prefix(str, "fit_content"): spec.mode = .Fit
	case strings.has_prefix(str, "fill_container"): spec.mode = .Fill
	case: return {.Fixed, 100, false}
	}
	if i := strings.index_byte(str, '('); i >= 0 {
		if f, ok := strconv.parse_f32(strings.trim_right(str[i + 1:], ")")); ok {
			spec.value, spec.has_value = f, true
		}
	}
	return spec
}

parse_padding :: proc(doc: ^Document, v: json.Value) -> (pad: [4]f32) {
	if f, ok := num(doc, v); ok do return {f, f, f, f}
	arr, is_arr := v.(json.Array)
	if !is_arr do return
	switch len(arr) {
	case 2:
		vert := num(doc, arr[0]) or_else 0
		horiz := num(doc, arr[1]) or_else 0
		return {vert, horiz, vert, horiz}
	case 4:
		for i in 0 ..< 4 do pad[i] = num(doc, arr[i]) or_else 0
	}
	return
}

// Uniform thickness, or the top side of a per-side object.
parse_thickness :: proc(doc: ^Document, v: json.Value) -> f32 {
	if f, ok := num(doc, v); ok do return f
	if obj, is_obj := v.(json.Object); is_obj {
		for side in ([]string{"top", "left", "right", "bottom"}) {
			if f, ok := num(doc, obj[side]); ok do return f
		}
	}
	return -1
}

// The first solid color of a fill, a fill object, or a list of fills.
// Gradients contribute their first stop; images and shaders a neutral grey.
color_of :: proc(doc: ^Document, v: json.Value) -> (Color, bool) {
	#partial switch x in v {
	case json.String:
		s := string(x)
		if strings.has_prefix(s, "$") {
			if vr, ok := var_get(doc, s[1:]); ok && vr.kind == .Color do return vr.color, true
			return {}, false
		}
		return parse_color(s)
	case json.Object:
		if enabled, has := x["enabled"]; has {
			if on, ok := json_bool(doc, enabled); ok && !on do return {}, false
		}
		switch string(x["type"].(json.String) or_else "color") {
		case "color":
			return color_of(doc, x["color"])
		case "gradient":
			if stops, ok := x["colors"].(json.Array); ok && len(stops) > 0 {
				if stop, is_obj := stops[0].(json.Object); is_obj do return color_of(doc, stop["color"])
			}
		case "image", "shader", "mesh_gradient":
			return {160, 160, 164, 255}, true
		}
	case json.Array:
		for item in x {
			if c, ok := color_of(doc, item); ok do return c, true
		}
	}
	return {}, false
}

// A per-side thickness ({top, right, bottom, left}; missing sides are 0) as
// top, right, bottom, left. False for a single number.
parse_sides :: proc(doc: ^Document, v: json.Value) -> (sides: [4]f32, ok: bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	for side, i in ([]string{"top", "right", "bottom", "left"}) {
		if f, has := num(doc, obj[side]); has do sides[i] = max(f, 0)
	}
	return sides, true
}

parse_stroke :: proc(doc: ^Document, n: ^Node, v: json.Value, thickness: ^f32) {
	v := v
	if arr, is_arr := v.(json.Array); is_arr {
		if len(arr) == 0 do return
		if obj, is_obj := arr[0].(json.Object); is_obj && is_old_stroke(obj) do v = arr[0]
	}
	if obj, is_obj := v.(json.Object); is_obj && is_old_stroke(obj) {
		n.stroke_old = true
		if t, has := obj["thickness"]; has {
			thickness^ = parse_thickness(doc, t)
			n.stroke_sides, n.stroke_per_side = parse_sides(doc, t)
		}
		if f, has := obj["fill"]; has do n.stroke, n.has_stroke = color_of(doc, f)
		switch string(obj["align"].(json.String) or_else "") {
		case "inside": n.stroke_align = .Inner
		case "center": n.stroke_align = .Center
		case "outside": n.stroke_align = .Outer
		}
		return
	}
	n.stroke, n.has_stroke = color_of(doc, v)
}

is_old_stroke :: proc(obj: json.Object) -> bool {
	_, has_type := obj["type"]
	_, has_fill := obj["fill"]
	_, has_thickness := obj["thickness"]
	_, has_align := obj["align"]
	return !has_type && (has_fill || has_thickness || has_align)
}

// Every fill of a `fill` value (a color, a fill object or an array of them).
parse_fills :: proc(doc: ^Document, n: ^Node, v: json.Value) {
	items: []json.Value = {v}
	if arr, is_arr := v.(json.Array); is_arr do items = arr[:]
	n.nfills = 0
	for item in items {
		if n.nfills >= MAX_FILLS do break
		p := Paint{enabled = true, opacity = 1, center = {0.5, 0.5}, size = {1, 1}}
		obj, is_obj := item.(json.Object)
		if !is_obj {
			c, ok := color_of(doc, item)
			if !ok do continue
			p.color = c
		} else {
			if e, has := obj["enabled"]; has do p.enabled = json_bool(doc, e) or_else true
			p.opacity = clamp(num(doc, obj["opacity"]) or_else 1, 0, 1)
			switch string(obj["type"].(json.String) or_else "color") {
			case "color":
				p.color = color_of(doc, obj["color"]) or_else Color{0, 0, 0, 255}
			case "image":
				p.kind = .Image
			case "gradient":
				switch string(obj["gradientType"].(json.String) or_else "linear") {
				case "radial": p.kind = .Radial
				case "angular": p.kind = .Angular
				case: p.kind = .Linear
				}
				if c, ok := obj["center"].(json.Object); ok do p.center = {num(doc, c["x"]) or_else 0.5, num(doc, c["y"]) or_else 0.5}
				if sz, ok := obj["size"].(json.Object); ok do p.size = {num(doc, sz["width"]) or_else 1, num(doc, sz["height"]) or_else 1}
				p.rotation = num(doc, obj["rotation"]) or_else 0
				if colors, ok := obj["colors"].(json.Array); ok {
					for c in colors {
						if p.nstops >= MAX_STOPS do break
						co, cok := c.(json.Object)
						if !cok do continue
						p.stops[p.nstops] = {color_of(doc, co["color"]) or_else Color{0, 0, 0, 255}, clamp(num(doc, co["position"]) or_else 0, 0, 1)}
						p.nstops += 1
					}
				}
				if p.nstops == 0 do continue
				p.color = p.stops[0].color
			case:
				continue // shaders, mesh gradients: kept in the file, not drawn
			}
		}
		n.fills[n.nfills] = p
		n.nfills += 1
	}
	// the representative color (text, selection colors, code export)
	for i in 0 ..< n.nfills do if n.fills[i].enabled && n.fills[i].kind != .Image {
		n.fill, n.has_fill = n.fills[i].color, true
		return
	}
	has_image := false
	for i in 0 ..< n.nfills do if n.fills[i].enabled && n.fills[i].kind == .Image do has_image = true
	if !has_image do n.has_fill = false
}

// Every effect of an `effect` value.
parse_effects :: proc(doc: ^Document, n: ^Node, v: json.Value) {
	items: []json.Value = {v}
	if arr, is_arr := v.(json.Array); is_arr do items = arr[:]
	n.neffects = 0
	for item in items {
		if n.neffects >= MAX_EFFECTS do break
		obj, ok := item.(json.Object)
		if !ok do continue
		e := Effect{enabled = true}
		if en, has := obj["enabled"]; has do e.enabled = json_bool(doc, en) or_else true
		switch string(obj["type"].(json.String) or_else "") {
		case "shadow":
			e.kind = .Inner_Shadow if string(obj["shadowType"].(json.String) or_else "outer") == "inner" else .Drop_Shadow
			if off, has := obj["offset"].(json.Object); has do e.offset = {num(doc, off["x"]) or_else 0, num(doc, off["y"]) or_else 0}
			e.blur = num(doc, obj["blur"]) or_else 0
			e.spread = num(doc, obj["spread"]) or_else 0
			e.color = color_of(doc, obj["color"]) or_else Color{0, 0, 0, 64}
		case "blur":
			e.kind = .Blur
			e.blur = num(doc, obj["radius"]) or_else 4
		case "background_blur":
			e.kind = .Background_Blur
			e.blur = num(doc, obj["radius"]) or_else 4
		case:
			continue
		}
		n.effects[n.neffects] = e
		n.neffects += 1
	}
}

parse_shadow :: proc(doc: ^Document, v: json.Value) -> (s: Shadow) {
	effects: []json.Value = {v}
	if arr, is_arr := v.(json.Array); is_arr do effects = arr[:]
	for e in effects {
		obj, is_obj := e.(json.Object)
		if !is_obj || string(obj["type"].(json.String) or_else "") != "shadow" do continue
		if enabled, has := obj["enabled"]; has {
			if on, ok := json_bool(doc, enabled); ok && !on do continue
		}
		s.has = true
		s.inner = string(obj["shadowType"].(json.String) or_else "outer") == "inner"
		if off, ok := obj["offset"].(json.Object); ok {
			s.offset = {num(doc, off["x"]) or_else 0, num(doc, off["y"]) or_else 0}
		}
		s.blur = num(doc, obj["blur"]) or_else 0
		s.spread = num(doc, obj["spread"]) or_else 0
		s.color = color_of(doc, obj["color"]) or_else Color{0, 0, 0, 64}
		return
	}
	return
}

weight_number :: proc(doc: ^Document, v: json.Value) -> int {
	if f, ok := num(doc, v); ok do return clamp(int(f), 100, 900)
	switch strings.to_lower(json_str(doc, v), context.temp_allocator) {
	case "thin", "hairline": return 100
	case "extralight", "extra-light", "ultralight": return 200
	case "light": return 300
	case "medium": return 500
	case "semibold", "semi-bold", "demibold": return 600
	case "bold": return 700
	case "extrabold", "extra-bold", "ultrabold": return 800
	case "black", "heavy": return 900
	}
	return 400
}

// The first enabled image fill, if any.
image_of :: proc(doc: ^Document, v: json.Value) -> (url: string, mode: Image_Mode, ok: bool) {
	#partial switch x in v {
	case json.Object:
		if string(x["type"].(json.String) or_else "") != "image" do return
		if enabled, has := x["enabled"]; has {
			if on, bok := json_bool(doc, enabled); bok && !on do return
		}
		url = string(x["url"].(json.String) or_else "")
		switch string(x["mode"].(json.String) or_else "cover") {
		case "contain": mode = .Contain
		case "stretch": mode = .Stretch
		}
		return url, mode, url != ""
	case json.Array:
		for item in x do if u, m, iok := image_of(doc, item); iok do return u, m, true
	}
	return
}

weight_is_bold :: proc(doc: ^Document, v: json.Value) -> bool {
	if f, ok := num(doc, v); ok do return f >= 600
	switch strings.to_lower(json_str(doc, v), context.temp_allocator) {
	case "bold", "semibold", "semi-bold", "extrabold", "extra-bold", "black", "heavy", "ultrabold":
		return true
	}
	return false
}

// ---------------------------------------------------------------- colors

parse_color :: proc(str: string) -> (c: Color, ok: bool) {
	s := strings.trim_space(str)
	if s == "none" || s == "transparent" || s == "" do return {0, 0, 0, 0}, true
	if !strings.has_prefix(s, "#") do return
	s = s[1:]
	hex :: proc(b: u8) -> (u8, bool) {
		switch b {
		case '0' ..= '9': return b - '0', true
		case 'a' ..= 'f': return b - 'a' + 10, true
		case 'A' ..= 'F': return b - 'A' + 10, true
		}
		return 0, false
	}
	switch len(s) {
	case 3, 4:
		for i in 0 ..< len(s) {
			v := hex(s[i]) or_return
			c[i] = v * 17
		}
		if len(s) == 3 do c[3] = 255
	case 6, 8:
		for i in 0 ..< len(s) / 2 {
			hi := hex(s[i * 2]) or_return
			lo := hex(s[i * 2 + 1]) or_return
			c[i] = hi * 16 + lo
		}
		if len(s) == 6 do c[3] = 255
	case:
		return
	}
	return c, true
}

color_hex :: proc(c: Color, allocator := context.temp_allocator) -> string {
	if c[3] == 0 do return "none"
	if c[3] == 255 do return fmt.aprintf("#%02X%02X%02X", c[0], c[1], c[2], allocator = allocator)
	return fmt.aprintf("#%02X%02X%02X%02X", c[0], c[1], c[2], c[3], allocator = allocator)
}

round2 :: proc(f: f32) -> f32 {
	return math.round(f * 100) / 100
}

// Rounds to 2 decimals in f64, so the value prints without f32 noise.
round2_64 :: proc(f: f32) -> f64 {
	return math.round(f64(f) * 100) / 100
}

// An f32 as a JSON number, rounded in f64 to `digits` decimals so the file gets 12.3
// rather than 12.300000190734863.
json_num :: proc(f: f32, digits := 3) -> json.Value {
	scale := math.pow(10, f64(digits))
	return json.Float(math.round(f64(f) * scale) / scale)
}

// Number formatting for JSON: integral values as ints, others with at most 2 decimals.
num_text :: proc(f: f32, allocator := context.temp_allocator) -> string {
	v := round2_64(f)
	if v == f64(i64(v)) do return fmt.aprintf("%d", i64(v), allocator = allocator)
	t := fmt.tprintf("%.2f", v)
	t = strings.trim_right(t, "0")
	t = strings.trim_right(t, ".")
	return strings.clone(t, allocator)
}


// ---------------------------------------------------------------- variables (editing)

// The raw "variables" object of the document header.
doc_variables :: proc(doc: ^Document) -> json.Object {
	for p in doc.header do if p.key == "variables" {
		v, err := json.parse_string(p.raw, .JSON5, false, context.temp_allocator)
		if err == nil {
			if obj, ok := v.(json.Object); ok do return obj
		}
	}
	return make(json.Object, context.temp_allocator)
}

doc_write_variables :: proc(doc: ^Document, vars: json.Object) {
	b := strings.builder_make(context.temp_allocator)
	write_json_value(&b, vars)
	found := false
	for &p in doc.header do if p.key == "variables" {
		delete(p.raw)
		p.raw = strings.clone(strings.to_string(b))
		found = true
	}
	if !found do append(&doc.header, Prop{strings.clone("variables"), strings.clone(strings.to_string(b))})
	doc_resolve_vars(doc)
	for &n in doc.nodes do node_refresh(doc, &n)
}

// Sets a variable to a literal value: "#RRGGBB" (color), a number, or any string.
doc_set_variable :: proc(doc: ^Document, name, kind, value: string) {
	vars := doc_variables(doc)
	def, has := vars[name].(json.Object)
	if !has do def = make(json.Object, context.temp_allocator)
	def["type"] = json.String(kind)
	// keep themed values: replace the first entry's value
	if arr, is_arr := def["value"].(json.Array); is_arr && len(arr) > 0 {
		if first, is_obj := arr[0].(json.Object); is_obj {
			first["value"] = variable_literal(kind, value)
			arr[0] = first
		} else {
			arr[0] = variable_literal(kind, value)
		}
		def["value"] = arr
	} else {
		def["value"] = variable_literal(kind, value)
	}
	vars[name] = def
	doc_write_variables(doc, vars)
}

variable_literal :: proc(kind, value: string) -> json.Value {
	if kind == "number" {
		if f, ok := strconv.parse_f64(strings.trim_space(value)); ok do return json.Float(f)
	}
	if kind == "boolean" do return json.Boolean(value == "true")
	return json.String(value)
}

doc_remove_variable :: proc(doc: ^Document, name: string) {
	vars := doc_variables(doc)
	delete_key(&vars, name)
	doc_write_variables(doc, vars)
}

// Renames a variable and every "$old" reference in the document.
doc_rename_variable :: proc(doc: ^Document, old, new: string) {
	if new == "" || old == new do return
	vars := doc_variables(doc)
	def, has := vars[old]
	if !has do return
	if _, taken := vars[new]; taken do return
	delete_key(&vars, old)
	vars[new] = def
	from := fmt.tprintf(`"$%s"`, old)
	to := fmt.tprintf(`"$%s"`, new)
	for &n in doc.nodes {
		for &pr in n.props {
			if strings.contains(pr.raw, from) {
				r, _ := strings.replace_all(pr.raw, from, to)
				delete(pr.raw)
				pr.raw = r
			}
		}
	}
	for &p in doc.header do if p.key != "variables" && strings.contains(p.raw, from) {
		r, _ := strings.replace_all(p.raw, from, to)
		delete(p.raw)
		p.raw = r
	}
	doc_write_variables(doc, vars)
}
