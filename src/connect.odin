package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "engine"

// Connectors between shapes (D54): the `connect` tool, the connector keys of `update_nodes`
// and the connector tool of the canvas all end up here. The format is in
// engine/connector.odin: a stroked path whose metadata names its two ends.

Connect_Options :: struct {
	from, to:           string, // id paths
	from_side, to_side: engine.Anchor,
	routing:            engine.Routing,
	start, end:         engine.Marker,
	stroke:             string, // raw JSON (a colour or "$variable")
	stroke_width:       f32,
	label:              string,
	parent:             int, // -1: the frame that holds both ends
	id:                 string,
}

default_connect :: proc() -> Connect_Options {
	return {end = .Arrow, stroke = `"#1E1E1E"`, stroke_width = 2, parent = -1}
}

// The real layer an endpoint stands for in the tree: itself, or the instance a copy is in.
endpoint_layer :: proc(n: ^engine.Node) -> ^engine.Node {
	if n == nil || !n.ghost do return n
	inst, _ := engine.doc_find_uid(&app.doc, n.ghost_inst)
	return endpoint_layer(inst)
}

// The innermost frame or group that holds both layers (0: the canvas).
common_container :: proc(a, b: ^engine.Node) -> int {
	for p := a.parent; p != 0; {
		pn, _ := engine.doc_find_uid(&app.doc, p)
		if pn == nil do break
		if (pn.kind == .Frame || pn.kind == .Group) && (b.parent == p || engine.is_descendant(&app.doc, b.uid, p)) do return p
		p = pn.parent
	}
	return 0
}

// A solid background to give a label: the nearest container fill, else white.
label_background :: proc(parent: int) -> string {
	for p := parent; p != 0; {
		pn, _ := engine.doc_find_uid(&app.doc, p)
		if pn == nil do break
		if i := engine.prop_index(pn, "fill"); i >= 0 && pn.has_fill && pn.fill.a == 255 do return pn.props[i].raw
		p = pn.parent
	}
	return `"#FFFFFF"`
}

// Keys in the order the document loader keeps them (sorted), so a file saved right after
// an edit reads back and saves to the same bytes.
connector_metadata :: proc(b: ^strings.Builder, o: Connect_Options) {
	fmt.sbprintf(b, `{{"endMarker":"%s","routing":"%s","source":{{"anchor":"%s","path":`, engine.MARKER_NAMES[o.end], engine.ROUTING_NAMES[o.routing], engine.ANCHOR_NAMES[o.from_side])
	engine.json_write_string(b, o.from)
	fmt.sbprintf(b, `}},"startMarker":"%s","target":{{"anchor":"%s","path":`, engine.MARKER_NAMES[o.start], engine.ANCHOR_NAMES[o.to_side])
	engine.json_write_string(b, o.to)
	strings.write_string(b, `},"type":"connector"}`)
}

// Adds a connector (and its label) and routes it. Returns its uid, or an error.
connect_layers :: proc(o: Connect_Options) -> (uid: int, label_uid: int, err: string) {
	a, b := engine.resolve_path(&app.doc, o.from), engine.resolve_path(&app.doc, o.to)
	if a == nil do return 0, 0, fmt.tprintf("from: '%s' not found", o.from)
	if b == nil do return 0, 0, fmt.tprintf("to: '%s' not found", o.to)
	if a == b do return 0, 0, "from and to are the same layer"
	if a.flow == .Connector || b.flow == .Connector do return 0, 0, "a connector cannot be an end of another connector"
	ra, rb := endpoint_layer(a), endpoint_layer(b)
	parent := o.parent
	if parent < 0 do parent = common_container(ra, rb)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"path","name":"Connector","layoutPosition":"absolute","x":0,"y":0,"width":1,"height":1,"viewBox":[0,0,1,1],"geometry":"M0 0","stroke":`)
	strings.write_string(&sb, o.stroke)
	fmt.sbprintf(&sb, `,"strokeWidth":%s,"strokeLinejoin":"round","strokeLinecap":"round","metadata":`, engine.num_text(o.stroke_width))
	connector_metadata(&sb, o)
	if o.id != "" {
		strings.write_string(&sb, `,"id":`)
		engine.json_write_string(&sb, o.id)
	}
	strings.write_byte(&sb, '}')
	v, perr := json.parse_string(strings.to_string(sb), .JSON5, false, context.temp_allocator)
	if perr != nil do return 0, 0, "internal: connector JSON"
	uid, err = engine.node_from_json(&app.doc, v, parent)
	if err != "" do return
	if o.label != "" do label_uid = add_connector_label(uid, o.label, parent)
	engine.layout_document(&app.doc)
	return
}

add_connector_label :: proc(conn_uid: int, text: string, parent: int) -> int {
	c, _ := engine.doc_find_uid(&app.doc, conn_uid)
	if c == nil do return 0
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"frame","name":"Label","layout":"horizontal","layoutPosition":"absolute","padding":[2,6],"cornerRadius":4,"fill":`)
	strings.write_string(&sb, label_background(parent))
	strings.write_string(&sb, `,"x":0,"y":0,"metadata":{"at":0.5,"connection":`)
	engine.json_write_string(&sb, c.id)
	strings.write_string(&sb, `,"type":"connection-label"},"children":[{"type":"text","content":`)
	engine.json_write_string(&sb, text)
	strings.write_string(&sb, `,"fontSize":12,"fill":"#333333"}]}`)
	v, perr := json.parse_string(strings.to_string(sb), .JSON5, false, context.temp_allocator)
	if perr != nil do return 0
	uid, err := engine.node_from_json(&app.doc, v, parent)
	if err != "" do return 0
	return uid
}

// The label layer of a connector, or nil.
connector_label :: proc(conn: ^engine.Node) -> ^engine.Node {
	for &n in app.doc.nodes {
		if n.flow != .Label do continue
		v, _ := engine.prop_value(&n, "metadata")
		o, _ := v.(json.Object)
		if string(o["connection"].(json.String) or_else "") == conn.id do return &n
	}
	return nil
}

// Reads `from`/`to` style ends: "id", "a/b", or {"path", "anchor"}.
end_param :: proc(v: json.Value, side_key: string, o: json.Object) -> (path: string, side: engine.Anchor, err: string) {
	#partial switch x in v {
	case json.String:
		path = string(x)
	case json.Object:
		path = string(x["path"].(json.String) or_else "")
		if s, has := x["anchor"].(json.String); has {
			ok: bool
			if side, ok = engine.anchor_from(string(s)); !ok do return "", .Center, fmt.tprintf("anchor must be center, top, right, bottom or left, not '%s'", s)
		}
	}
	if s, has := o[side_key].(json.String); has {
		ok: bool
		if side, ok = engine.anchor_from(string(s)); !ok do return "", .Center, fmt.tprintf("%s must be center, top, right, bottom or left, not '%s'", side_key, s)
	}
	return
}

connect_style_params :: proc(o: ^Connect_Options, p: json.Object) -> string {
	if s, has := p["routing"].(json.String); has {
		ok: bool
		if o.routing, ok = engine.routing_from(string(s)); !ok do return "routing must be orthogonal, straight or curved"
	}
	for key, which in ([2]string{"startMarker", "endMarker"}) {
		if s, has := p[key].(json.String); has {
			m, ok := engine.marker_from(string(s))
			if !ok do return fmt.tprintf("%s must be none, arrow, open_arrow, circle, diamond or bar", key)
			if which == 0 do o.start = m
			else do o.end = m
		}
	}
	return ""
}

// `connect` {from, to, fromSide?, toSide?, label?, routing?, startMarker?, endMarker?,
// stroke?, strokeWidth?, parent_id?, id?}
api_connect :: proc(b: ^strings.Builder, params: json.Object) -> string {
	o := default_connect()
	e: string
	if o.from, o.from_side, e = end_param(params["from"], "fromSide", params); e != "" do return e
	if o.to, o.to_side, e = end_param(params["to"], "toSide", params); e != "" do return e
	if o.from == "" || o.to == "" do return "from and to are required: the ids (or id paths) of the two layers"
	if e = connect_style_params(&o, params); e != "" do return e
	if v, has := params["stroke"]; has {
		sb := strings.builder_make(context.temp_allocator)
		engine.write_json_value(&sb, v)
		o.stroke = strings.to_string(sb)
	}
	if w, has := params["strokeWidth"]; has do o.stroke_width = engine.json_f32(w)
	o.label = string(params["label"].(json.String) or_else "")
	o.id = string(params["id"].(json.String) or_else "")
	if pid, has := params["parent_id"].(json.String); has {
		if pid == "" do o.parent = 0
		else {
			p, _ := engine.doc_find(&app.doc, string(pid))
			if p == nil || (p.kind != .Frame && p.kind != .Group) do return "parent_id must be a frame or a group"
			o.parent = p.uid
		}
	}
	push_undo()
	uid, label_uid, err := connect_layers(o)
	if err != "" do return err
	write_connector_result(b, uid, label_uid)
	return ""
}

write_connector_result :: proc(b: ^strings.Builder, uid, label_uid: int) {
	n, _ := engine.doc_find_uid(&app.doc, uid)
	strings.write_string(b, `{"id":`)
	engine.json_write_string(b, n.id)
	if l, _ := engine.doc_find_uid(&app.doc, label_uid); l != nil {
		strings.write_string(b, `,"label":`)
		engine.json_write_string(b, l.id)
	}
	strings.write_string(b, `,"route":[`)
	if route, has := engine.connector_routes[uid]; has {
		for p, i in route {
			if i > 0 do strings.write_byte(b, ',')
			fmt.sbprintf(b, "[%s,%s]", engine.num_text(p.x), engine.num_text(p.y))
		}
	}
	strings.write_string(b, "]}")
}

// update_nodes on a connector: `source`/`target` (an id path or {path, anchor}),
// `fromSide`/`toSide`, `routing`, `startMarker`/`endMarker` rewrite its metadata; `label`
// sets the text of its label (adding one, or "" removing it). Returns the keys it took.
CONNECTOR_KEYS := [?]string{"source", "target", "fromSide", "toSide", "routing", "startMarker", "endMarker", "label"}

is_connector_key :: proc(k: string) -> bool {
	for c in CONNECTOR_KEYS do if c == k do return true
	return false
}

update_connector :: proc(n: ^engine.Node, o: json.Object) -> string {
	c, ok := engine.connector_of(n)
	if !ok do return fmt.tprintf("'%s' is not a connector", n.id)
	opt := Connect_Options{from = c.source, to = c.target, from_side = c.from, to_side = c.to, routing = c.routing, start = c.start, end = c.end}
	e: string
	if v, has := o["source"]; has {
		if opt.from, opt.from_side, e = end_param(v, "fromSide", o); e != "" do return e
	} else if s, has := o["fromSide"].(json.String); has {
		if opt.from_side, ok = engine.anchor_from(string(s)); !ok do return "fromSide must be center, top, right, bottom or left"
	}
	if v, has := o["target"]; has {
		if opt.to, opt.to_side, e = end_param(v, "toSide", o); e != "" do return e
	} else if s, has := o["toSide"].(json.String); has {
		if opt.to_side, ok = engine.anchor_from(string(s)); !ok do return "toSide must be center, top, right, bottom or left"
	}
	if engine.resolve_path(&app.doc, opt.from) == nil do return fmt.tprintf("source: '%s' not found", opt.from)
	if engine.resolve_path(&app.doc, opt.to) == nil do return fmt.tprintf("target: '%s' not found", opt.to)
	if e = connect_style_params(&opt, o); e != "" do return e
	sb := strings.builder_make(context.temp_allocator)
	connector_metadata(&sb, opt)
	engine.node_set_raw(n, "metadata", strings.to_string(sb))
	engine.node_refresh(&app.doc, n)
	if lv, has := o["label"].(json.String); has {
		uid := n.uid
		existing := connector_label(n)
		if lv == "" {
			if existing != nil do engine.doc_delete(&app.doc, existing.uid)
		} else if existing != nil {
			for &t in app.doc.nodes do if t.parent == existing.uid && t.kind == .Text {
				engine.node_set_string(&app.doc, &t, "content", string(lv))
				break
			}
		} else {
			conn, _ := engine.doc_find_uid(&app.doc, uid)
			add_connector_label(uid, string(lv), conn.parent)
		}
	}
	return ""
}

// ---------------------------------------------------------------- shapes with text (D57)

// create_nodes shorthand: `{"type": "frame", "shape": "diamond" | "ellipse" | "capsule",
// "content": "Text", "fill", "stroke", "strokeWidth", "fontSize", "fontFamily",
// "fontWeight", "textFill", "inset", ...frame keys}` becomes the frame (shape metadata,
// centred vertical layout), its outline (diamond: a path, ellipse: an ellipse; a capsule
// keeps the fill and stroke itself) and its text, wrapping when the frame has a width.
SHAPE_TEXT_KEYS := [?]string{"content", "fontSize", "fontFamily", "fontWeight", "fontStyle", "lineHeight", "letterSpacing", "textAlign"}

expand_shape_spec :: proc(v: json.Value) -> (out: json.Value, err: string) {
	o, is_obj := v.(json.Object)
	if !is_obj do return v, ""
	res := make(json.Object, len(o) + 4, context.temp_allocator)
	for k, val in o do res[k] = val
	if kids, has := o["children"].(json.Array); has {
		nk := make(json.Array, len(kids), context.temp_allocator)
		for c, i in kids {
			nk[i], err = expand_shape_spec(c)
			if err != "" do return
		}
		res["children"] = nk
	}
	sv, has_shape := o["shape"].(json.String)
	if !has_shape do return res, ""
	if string(o["type"].(json.String) or_else "frame") != "frame" do return nil, "shape is for frames"
	kind, ok := engine.shape_from(string(sv))
	if !ok do return nil, fmt.tprintf("shape must be diamond, ellipse or capsule, not '%s'", sv)
	res["type"] = json.String("frame")
	delete_key(&res, "shape")
	md := make(json.Object, 3, context.temp_allocator)
	md["type"] = json.String("shape")
	md["shape"] = json.String(engine.SHAPE_NAMES[kind])
	if inset, has := o["inset"]; has {
		md["inset"] = inset
		delete_key(&res, "inset")
	}
	res["metadata"] = md
	if "layout" not_in o do res["layout"] = json.String("vertical")
	// the keys layout writes, present from the start (see connector_metadata)
	if "padding" not_in o do res["padding"] = json.Integer(0)
	if kind == .Capsule && "cornerRadius" not_in o do res["cornerRadius"] = json.Integer(0)
	if "justifyContent" not_in o do res["justifyContent"] = json.String("center")
	if "alignItems" not_in o do res["alignItems"] = json.String("center")
	kids := make([dynamic]json.Value, context.temp_allocator)
	if kind != .Capsule {
		outline := make(json.Object, 10, context.temp_allocator)
		outline["type"] = json.String("path" if kind == .Diamond else "ellipse")
		outline["name"] = json.String("Outline")
		outline["layoutPosition"] = json.String("absolute")
		outline["x"], outline["y"], outline["width"], outline["height"] = json.Integer(0), json.Integer(0), json.Integer(1), json.Integer(1)
		if kind == .Diamond {
			outline["geometry"] = json.String("M0 0")
			vb := make(json.Array, 4, context.temp_allocator)
			vb[0], vb[1], vb[2], vb[3] = json.Integer(0), json.Integer(0), json.Integer(1), json.Integer(1)
			outline["viewBox"] = vb
		}
		omd := make(json.Object, 1, context.temp_allocator)
		omd["type"] = json.String("shape-outline")
		outline["metadata"] = omd
		for k in ([?]string{"fill", "stroke", "strokeWidth", "strokeAlignment", "effect"}) {
			if val, has := o[k]; has {
				outline[k] = val
				delete_key(&res, k)
			}
		}
		append(&kids, outline)
	}
	if content, has := o["content"]; has {
		text := make(json.Object, 10, context.temp_allocator)
		text["type"] = json.String("text")
		text["content"] = content
		text["textAlign"] = json.String("center")
		text["fill"] = o["textFill"] if "textFill" in o else json.String("#1E1E1E")
		for k in SHAPE_TEXT_KEYS {
			if val, has := o[k]; has {
				if k != "content" do text[k] = val
				delete_key(&res, k)
			}
		}
		if is_number(o["width"]) {
			text["textGrowth"] = json.String("fixed-width")
			text["width"] = json.String("fill_container")
		}
		append(&kids, text)
	}
	delete_key(&res, "textFill")
	if existing, has := res["children"].(json.Array); has do append(&kids, ..existing[:])
	res["children"] = json.Array(kids)
	return res, ""
}

is_number :: proc(v: json.Value) -> bool {
	#partial switch _ in v {
	case json.Float, json.Integer: return true
	}
	return false
}
