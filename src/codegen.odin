package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Code export. HTML + CSS mirrors the document one to one (every node a div with a
// class, variables as custom properties, themes as [data-theme] blocks). React emits
// Tailwind classes, one function per component with props derived from the instance
// overrides, and shadcn/ui primitives for components named after them.

Code_Format :: enum {
	HTML,
	React,
}

Code_File :: struct {
	name, content: string,
}

Gen :: struct {
	doc:      ^Document,
	format:   Code_Format,
	css:      strings.Builder,
	out:      strings.Builder,
	props:    map[string][dynamic]string, // component id -> prop names (override ids)
	shadcn:   map[string]bool, // shadcn components used
	icons:    map[string]bool, // lucide-react components used
	comp_ids: [dynamic]int, // reusable nodes
}

// Generates the files for the current page.
generate_code :: proc(doc: ^Document, format: Code_Format) -> []Code_File {
	g := Gen{doc = doc, format = format}
	g.css = strings.builder_make(context.temp_allocator)
	g.out = strings.builder_make(context.temp_allocator)
	for n in doc.nodes do if n.reusable do append(&g.comp_ids, n.uid)
	for n in doc.nodes do if n.kind == .Icon && n.icon != "" do g.icons[pascal(n.icon)] = true
	for n in doc.nodes do for o in n.overrides do if name := override_icon(o); name != "" do g.icons[pascal(name)] = true
	collect_props(&g)
	files := make([dynamic]Code_File, context.temp_allocator)
	switch format {
	case .HTML:
		gen_css_vars(&g)
		fmt.sbprintf(&g.out, "<!doctype html>\n<html%s>\n<head>\n<meta charset=\"utf-8\">\n", shown_theme_attrs(doc))
		fmt.sbprintf(&g.out, "<title>%s</title>\n<link rel=\"stylesheet\" href=\"styles.css\">\n</head>\n<body>\n", html_escape(file_title(app.file_path)))
		for cu in children_of(doc, 0) {
			if app.page_hidden[cu] do continue
			n, _ := doc_find_uid(doc, cu)
			if n == nil || !n.enabled || n.reusable do continue
			gen_html_node(&g, n, 1, "", true)
		}
		strings.write_string(&g.out, "</body>\n</html>\n")
		append(&files, Code_File{"index.html", strings.clone(strings.to_string(g.out), context.temp_allocator)})
		append(&files, Code_File{"styles.css", strings.clone(strings.to_string(g.css), context.temp_allocator)})
	case .React:
		gen_css_vars(&g)
		append(&files, Code_File{"globals.css", strings.clone(strings.to_string(g.css), context.temp_allocator)})
		gen_react_components(&g)
		append(&files, Code_File{"components.tsx", strings.clone(strings.to_string(g.out), context.temp_allocator)})
		strings.builder_reset(&g.out)
		gen_react_page(&g)
		append(&files, Code_File{"Page.tsx", strings.clone(strings.to_string(g.out), context.temp_allocator)})
	}
	return files[:]
}

// Writes the files into a folder next to the document (or `dir`) and returns it.
export_code_to_dir :: proc(format: Code_Format, dir := "") -> (string, bool) {
	files := generate_code(&app.doc, format)
	target := dir
	if target == "" {
		home, _ := os.user_home_dir(context.temp_allocator)
		target = fmt.tprintf("%s/Downloads/%s-%s", home, file_title(app.file_path), "html" if format == .HTML else "react")
	}
	if err := os.make_directory_all(target); err != nil do return target, false
	for f in files {
		if err := os.write_entire_file(fmt.tprintf("%s/%s", target, f.name), f.content); err != nil do return target, false
	}
	return target, true
}

// ---------------------------------------------------------------- shared helpers

css_name :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_': strings.write_rune(&b, r)
		case: strings.write_byte(&b, '-')
		}
	}
	return strings.to_string(b)
}

pascal :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	up := true
	for r in s {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
			if up {
				strings.write_rune(&b, r - ('a' - 'A') if r >= 'a' && r <= 'z' else r)
				up = false
			} else {
				strings.write_rune(&b, r)
			}
		case: up = true
		}
	}
	out := strings.to_string(b)
	if out == "" do return "Component"
	if out[0] >= '0' && out[0] <= '9' do return fmt.tprintf("C%s", out)
	return out
}

camel :: proc(s: string) -> string {
	p := pascal(s)
	if p == "" do return "value"
	b := strings.builder_make(context.temp_allocator)
	strings.write_rune(&b, rune(p[0]) + ('a' - 'A') if p[0] >= 'A' && p[0] <= 'Z' else rune(p[0]))
	strings.write_string(&b, p[1:])
	return strings.to_string(b)
}

html_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"': strings.write_string(&b, "&quot;")
		case '\n': strings.write_string(&b, "<br>")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

jsx_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '{': strings.write_string(&b, "&#123;")
		case '}': strings.write_string(&b, "&#125;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '\n': strings.write_string(&b, "<br />")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// A color property as CSS: var(--name) when the document binds a variable, else hex.
color_css :: proc(n: ^Node, key: string, c: Color) -> string {
	if s := prop_string(n, key); strings.has_prefix(s, "$") do return fmt.tprintf("var(--%s)", css_name(s[1:]))
	if key == "stroke" {
		if obj, ok := old_stroke_object(n); ok {
			if s, is_str := obj["fill"].(json.String); is_str && strings.has_prefix(string(s), "$") do return fmt.tprintf("var(--%s)", css_name(string(s)[1:]))
		}
	}
	return css_color(c)
}

css_color :: proc(c: Color) -> string {
	if c[3] == 255 do return fmt.tprintf("#%02X%02X%02X", c[0], c[1], c[2])
	return fmt.tprintf("rgba(%d, %d, %d, %.3f)", c[0], c[1], c[2], f32(c[3]) / 255)
}

px :: proc(f: f32) -> string {
	return fmt.tprintf("%spx", num_text(f))
}

// Variables as custom properties, with a block per non-default theme value.
gen_css_vars :: proc(g: ^Gen) {
	doc := g.doc
	names := make([dynamic]string, context.temp_allocator)
	for name in doc.var_defs do append(&names, name)
	slice.sort(names[:])
	saved_theme := make(map[string]string, context.temp_allocator)
	for k, v in app.theme do saved_theme[k] = v
	axes := doc_theme_axes(doc)
	write_block :: proc(g: ^Gen, names: []string, selector: string, axis := "") {
		fmt.sbprintf(&g.css, "%s {{\n", selector)
		for name in names {
			// an axis block only carries the variables that vary along that axis
			if axis != "" && !var_depends_on(g.doc, name, axis, 0) do continue
			v, ok := var_get(g.doc, name)
			if !ok do continue
			switch v.kind {
			case .Color: fmt.sbprintf(&g.css, "  --%s: %s;\n", css_name(name), css_color(v.color))
			case .Number: fmt.sbprintf(&g.css, "  --%s: %s;\n", css_name(name), num_text(v.number))
			case .String: fmt.sbprintf(&g.css, "  --%s: %s;\n", css_name(name), v.str)
			case .Bool:
			}
		}
		strings.write_string(&g.css, "}\n")
	}
	clear(&doc.resolve_theme)
	for a in axes do if len(a.values) > 0 do doc.resolve_theme[a.name] = a.values[0]
	write_block(g, names[:], ":root")
	// a block per value, the default included, so a subtree can pin any value
	// (a light frame inside a dark page)
	for a in axes {
		for v in a.values {
			clear(&doc.resolve_theme)
			for b in axes do if len(b.values) > 0 do doc.resolve_theme[b.name] = b.values[0]
			doc.resolve_theme[a.name] = v
			write_block(g, names[:], fmt.tprintf("[data-theme-%s=\"%s\"]", css_name(a.name), v), a.name)
		}
	}
	clear(&doc.resolve_theme)
	for k, v in saved_theme do doc.resolve_theme[k] = v
	// every element is positioned, so absolute children are placed in their parent and
	// paint in document order like on the canvas
	strings.write_string(&g.css, "* { box-sizing: border-box; margin: 0; position: relative; }\nbody { font-family: Arial, sans-serif; }\n")
}

// The CSS declarations of a node (shared by both formats; React turns them into
// Tailwind arbitrary values).
Decl :: struct {
	prop, value: string,
}

node_decls :: proc(g: ^Gen, n: ^Node, parent_in: ^Node) -> []Decl {
	d := make([dynamic]Decl, context.temp_allocator)
	add :: proc(d: ^[dynamic]Decl, p, v: string) {append(d, Decl{p, v})}
	parent := parent_in
	// the component root inside an instance's element fills it (the instance's element
	// carries the size and the place in the layout)
	instance_root := false
	if parent != nil && parent.kind == .Ref {
		if root := ghost_root_of(g.doc, parent.uid); root != nil && root.uid == n.uid do instance_root = true
	}
	if parent != nil && parent.kind == .Ref && !instance_root {
		// slot content is laid out by the component's slot frame
		if slot, has := g.doc.ghost_slot[parent.uid]; has {
			if sn, _ := doc_find_uid(g.doc, slot); sn != nil do parent = sn
		}
	}
	n := n
	if n.kind == .Ref {
		if root := ghost_root_of(g.doc, n.uid); root != nil {
			sized := n^
			sized.width, sized.height = root.width, root.height
			n = &sized
		}
	}
	in_flex := parent != nil && parent.layout != .None && !n.abs_pos
	if instance_root {
		add(&d, "width", "100%")
		add(&d, "height", "100%")
	} else if parent == nil || parent.layout == .None || n.abs_pos {
		add(&d, "position", "absolute" if parent != nil else "relative")
		if parent != nil {
			add(&d, "left", px(n.pos.x))
			add(&d, "top", px(n.pos.y))
		}
	}
	// size
	main_h := parent != nil && parent.layout == .Horizontal
	if !instance_root do switch n.width.mode {
	case .Fixed: add(&d, "width", px(n.width.value))
	case .Fill:
		if in_flex && main_h do add(&d, "flex", "1 1 0")
		else if in_flex do add(&d, "align-self", "stretch")
		else do add(&d, "width", "100%")
	case .Fit:
		if n.kind == .Text do add(&d, "width", "max-content")
		else do add(&d, "width", "fit-content")
	}
	if !instance_root do switch n.height.mode {
	case .Fixed: add(&d, "height", px(n.height.value))
	case .Fill:
		if in_flex && !main_h do add(&d, "flex", "1 1 0")
		else if in_flex do add(&d, "align-self", "stretch")
		else do add(&d, "height", "100%")
	case .Fit:
		if n.kind != .Text do add(&d, "height", "fit-content")
	}
	if (n.kind == .Frame || n.kind == .Group) && n.layout != .None {
		add(&d, "display", "flex")
		add(&d, "flex-direction", "row" if n.layout == .Horizontal else "column")
		if n.gap != 0 do add(&d, "gap", px(n.gap))
		just := [Justify]string{.Start = "flex-start", .Center = "center", .End = "flex-end", .Space_Between = "space-between", .Space_Around = "space-around"}
		al := [Align]string{.Start = "flex-start", .Center = "center", .End = "flex-end"}
		if n.justify != .Start do add(&d, "justify-content", just[n.justify])
		if n.align != .Start do add(&d, "align-items", al[n.align])
	} else if n.kind == .Frame || n.kind == .Group {
		if parent == nil || parent.layout != .None || n.abs_pos do add(&d, "position", "relative")
	}
	if n.padding != {} {
		p := n.padding
		if p[0] == p[2] && p[1] == p[3] do add(&d, "padding", fmt.tprintf("%s %s", px(p[0]), px(p[1])))
		else do add(&d, "padding", fmt.tprintf("%s %s %s %s", px(p[0]), px(p[1]), px(p[2]), px(p[3])))
	}
	if n.clip do add(&d, "overflow", "hidden")
	if n.kind == .Icon && n.has_fill do add(&d, "color", color_css(n, "fill", n.fill))
	if n.kind != .Text && n.kind != .Icon && n.kind != .Path && n.has_fill {
		if n.image_url != "" {
			add(&d, "background-image", fmt.tprintf("url(%s)", n.image_url))
			add(&d, "background-size", "cover" if n.image_mode == .Cover else ("contain" if n.image_mode == .Contain else "100% 100%"))
			add(&d, "background-position", "center")
		} else {
			add(&d, "background", color_css(n, "fill", n.fill))
		}
	}
	if n.kind == .Ellipse do add(&d, "border-radius", "50%")
	else if n.radius != {} {
		r := n.radius
		if r[0] == r[1] && r[1] == r[2] && r[2] == r[3] do add(&d, "border-radius", px(r[0]))
		else do add(&d, "border-radius", fmt.tprintf("%s %s %s %s", px(r[0]), px(r[1]), px(r[2]), px(r[3])))
	}
	if n.has_stroke && n.stroke_per_side && n.stroke_width > 0 {
		sd := n.stroke_sides
		add(&d, "border-style", "solid")
		add(&d, "border-color", color_css(n, "stroke", n.stroke))
		add(&d, "border-width", fmt.tprintf("%s %s %s %s", px(sd[0]), px(sd[1]), px(sd[2]), px(sd[3])))
	} else if n.has_stroke && n.stroke_width > 0 {
		if n.stroke_align == .Outer do add(&d, "outline", fmt.tprintf("%s solid %s", px(n.stroke_width), color_css(n, "stroke", n.stroke)))
		else do add(&d, "border", fmt.tprintf("%s solid %s", px(n.stroke_width), color_css(n, "stroke", n.stroke)))
	}
	if n.opacity < 1 do add(&d, "opacity", num_text(n.opacity))
	if s := n.shadow; s.has {
		add(&d, "box-shadow", fmt.tprintf("%s%s %s %s %s %s", "inset " if s.inner else "", px(s.offset.x), px(s.offset.y), px(s.blur), px(s.spread), css_color(s.color)))
	}
	if n.kind == .Text {
		fam := n.font_family if n.font_family != "" else "Arial"
		if s := prop_string(n, "fontFamily"); strings.has_prefix(s, "$") do fam = fmt.tprintf("var(--%s)", css_name(s[1:]))
		else if strings.contains(fam, " ") do fam = fmt.tprintf("\"%s\"", fam)
		add(&d, "font-family", fmt.tprintf("%s, sans-serif", fam))
		add(&d, "font-size", px(n.font_size))
		if n.weight != 400 do add(&d, "font-weight", fmt.tprintf("%d", n.weight))
		if n.italic do add(&d, "font-style", "italic")
		if n.letter_spacing != 0 do add(&d, "letter-spacing", px(n.letter_spacing))
		if n.underline || n.strikethrough do add(&d, "text-decoration", "underline" if n.underline else "line-through")
		add(&d, "line-height", num_text(line_height_of(n)))
		if n.has_fill do add(&d, "color", color_css(n, "fill", n.fill))
		if n.text_align != .Left do add(&d, "text-align", "center" if n.text_align == .Center else "right")
		add(&d, "white-space", "pre-wrap" if n.growth != .Auto else "pre")
	}
	return d[:]
}

// ---------------------------------------------------------------- HTML

gen_html_node :: proc(g: ^Gen, n: ^Node, indent: int, prefix: string, top: bool) {
	if !n.enabled do return
	parent: ^Node
	if !top {
		parent, _ = doc_find_uid(g.doc, n.parent)
	}
	cls := css_name(fmt.tprintf("%s%s", prefix, n.ghost_of if n.ghost else n.id))
	fmt.sbprintf(&g.css, ".n-%s {{\n", cls)
	for d in node_decls(g, n, parent) do fmt.sbprintf(&g.css, "  %s: %s;\n", d.prop, d.value)
	strings.write_string(&g.css, "}\n")
	for _ in 0 ..< indent do strings.write_string(&g.out, "  ")
	title := n.name if n.name != "" else ""
	switch n.kind {
	case .Text:
		fmt.sbprintf(&g.out, "<p class=\"n-%s\">%s</p>\n", cls, html_escape(n.content))
	case .Path:
		fmt.sbprintf(&g.out, "<svg class=\"n-%s\" viewBox=\"%s %s %s %s\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"%s\" fill=\"%s\"/></svg>\n", cls, num_text(n.view_box[0]), num_text(n.view_box[1]), num_text(n.view_box[2]), num_text(n.view_box[3]), html_escape(n.geometry), color_css(n, "fill", n.fill) if n.has_fill else "none")
	case .Icon:
		fmt.sbprintf(&g.out, "<svg class=\"n-%s\" data-icon=\"%s\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"%s\"/></svg>\n", cls, html_escape(n.icon), html_escape(n.geometry))
	case .Ref:
		root := ghost_root_of(g.doc, n.uid)
		fmt.sbprintf(&g.out, "<div class=\"n-%s\" data-instance=\"%s\"%s>\n", cls, html_escape(n.ref), theme_attrs(n))
		if root != nil do gen_html_node(g, root, indent + 1, fmt.tprintf("%s%s-", prefix, n.id), false)
		for _ in 0 ..< indent do strings.write_string(&g.out, "  ")
		strings.write_string(&g.out, "</div>\n")
	case .Frame, .Group, .Rectangle, .Ellipse, .Other:
		if title != "" do fmt.sbprintf(&g.out, "<div class=\"n-%s\" data-name=\"%s\"%s>\n", cls, html_escape(title), theme_attrs(n))
		else do fmt.sbprintf(&g.out, "<div class=\"n-%s\"%s>\n", cls, theme_attrs(n))
		for cu in children_for_layout(g.doc, n.uid) {
			c, _ := doc_find_uid(g.doc, cu)
			if c == nil do continue
			gen_html_node(g, c, indent + 1, prefix if !c.ghost || n.ghost else prefix, false)
		}
		for _ in 0 ..< indent do strings.write_string(&g.out, "  ")
		strings.write_string(&g.out, "</div>\n")
	}
}

// ---------------------------------------------------------------- React

SHADCN := [?]string{"Button", "Card", "Input", "Badge", "Avatar", "Checkbox", "Switch", "Separator", "Label", "Textarea"}

shadcn_of :: proc(name: string) -> string {
	base := name
	if i := strings.index_byte(name, '/'); i >= 0 do base = name[:i]
	for s in SHADCN do if strings.equal_fold(base, s) || strings.has_prefix(base, s) do return s
	return ""
}

// Props of each component: every descendant id that any instance overrides.
collect_props :: proc(g: ^Gen) {
	for n in g.doc.nodes {
		if n.kind != .Ref do continue
		comp, _ := doc_find(g.doc, n.ref)
		if comp == nil do continue
		list, has := &g.props[comp.id]
		if !has {
			g.props[comp.id] = make([dynamic]string, context.temp_allocator)
			list = &g.props[comp.id]
		}
		for o in n.overrides {
			dup := false
			for p in list do if p == o.id do dup = true
			if !dup do append(list, strings.clone(o.id, context.temp_allocator))
		}
	}
}

tailwind :: proc(decls: []Decl) -> string {
	b := strings.builder_make(context.temp_allocator)
	first := true
	for d in decls {
		if !first do strings.write_byte(&b, ' ')
		first = false
		val, _ := strings.replace_all(d.value, " ", "_", context.temp_allocator)
		switch d.prop {
		case "display": strings.write_string(&b, "flex")
		case "flex-direction": strings.write_string(&b, "flex-row" if d.value == "row" else "flex-col")
		case "position": strings.write_string(&b, d.value)
		case "left": fmt.sbprintf(&b, "left-[%s]", val)
		case "top": fmt.sbprintf(&b, "top-[%s]", val)
		case "width": fmt.sbprintf(&b, "w-[%s]", val)
		case "height": fmt.sbprintf(&b, "h-[%s]", val)
		case "flex": strings.write_string(&b, "flex-1")
		case "align-self": strings.write_string(&b, "self-stretch")
		case "gap": fmt.sbprintf(&b, "gap-[%s]", val)
		case "padding": fmt.sbprintf(&b, "p-[%s]", val)
		case "justify-content":
			switch d.value {
			case "center": strings.write_string(&b, "justify-center")
			case "flex-end": strings.write_string(&b, "justify-end")
			case "space-between": strings.write_string(&b, "justify-between")
			case "space-around": strings.write_string(&b, "justify-around")
			}
		case "align-items":
			switch d.value {
			case "center": strings.write_string(&b, "items-center")
			case "flex-end": strings.write_string(&b, "items-end")
			}
		case "overflow": strings.write_string(&b, "overflow-hidden")
		case "background": fmt.sbprintf(&b, "bg-[%s]", val)
		case "background-image": fmt.sbprintf(&b, "bg-[%s]", val)
		case "background-size": strings.write_string(&b, "bg-cover" if d.value == "cover" else "bg-contain")
		case "background-position": strings.write_string(&b, "bg-center")
		case "border-radius":
			if d.value == "50%" do strings.write_string(&b, "rounded-full")
			else do fmt.sbprintf(&b, "rounded-[%s]", val)
		case "border": fmt.sbprintf(&b, "border-[%s]", val)
		case "outline": fmt.sbprintf(&b, "outline outline-[%s]", val)
		case "opacity": fmt.sbprintf(&b, "opacity-[%s]", val)
		case "box-shadow": fmt.sbprintf(&b, "shadow-[%s]", val)
		case "font-family": fmt.sbprintf(&b, "font-[%s]", val)
		case "font-size": fmt.sbprintf(&b, "text-[%s]", val)
		case "font-weight": fmt.sbprintf(&b, "font-[%s]", val)
		case "font-style": strings.write_string(&b, "italic")
		case "line-height": fmt.sbprintf(&b, "leading-[%s]", val)
		case "color": fmt.sbprintf(&b, "text-[%s]", val)
		case "text-align": strings.write_string(&b, "text-center" if d.value == "center" else "text-right")
		case "white-space": strings.write_string(&b, "whitespace-pre-wrap" if d.value == "pre-wrap" else "whitespace-pre")
		case "letter-spacing": fmt.sbprintf(&b, "tracking-[%s]", val)
		case "text-decoration": strings.write_string(&b, "underline" if d.value == "underline" else "line-through")
		case: fmt.sbprintf(&b, "[%s:%s]", d.prop, val) // any other property as an arbitrary one
		}
	}
	return strings.to_string(b)
}

gen_react_components :: proc(g: ^Gen) {
	strings.write_string(&g.out, "import React from \"react\";\n")
	// discover shadcn imports first
	for uid in g.comp_ids {
		n, _ := doc_find_uid(g.doc, uid)
		if n == nil do continue
		if s := shadcn_of(node_label(n)); s != "" do g.shadcn[s] = true
	}
	names := make([dynamic]string, context.temp_allocator)
	for s in g.shadcn do append(&names, s)
	slice.sort(names[:])
	for s in names do fmt.sbprintf(&g.out, "import {{ %s }} from \"@/components/ui/%s\";\n", s, strings.to_lower(s, context.temp_allocator))
	strings.write_string(&g.out, "import { cn } from \"@/lib/utils\";\n")
	gen_icon_imports(g)
	if len(g.icons) > 0 do strings.write_string(&g.out, "import type { LucideIcon } from \"lucide-react\";\n")
	strings.write_string(&g.out, "\n")
	for uid in g.comp_ids {
		n, _ := doc_find_uid(g.doc, uid)
		if n == nil do continue
		name := pascal(node_label(n))
		props := g.props[n.id]
		fmt.sbprintf(&g.out, "export type %sProps = {{\n", name)
		for p in props {
			target, _ := doc_find(g.doc, p)
			if target == nil do continue
			kind := "boolean"
			if target.kind == .Text do kind = "string"
			if target.kind == .Icon do kind = "LucideIcon"
			fmt.sbprintf(&g.out, "  %s?: %s;\n", camel(p), kind)
		}
		strings.write_string(&g.out, "  children?: React.ReactNode;\n  className?: string;\n};\n\n")
		fmt.sbprintf(&g.out, "export function %s(props: %sProps) {{\n  return (\n", name, name)
		gen_react_node(g, n, 2, n, true)
		strings.write_string(&g.out, "  );\n}\n\n")
	}
}

// The lucide icon an override swaps in ("" when it does not set one).
override_icon :: proc(o: Override) -> string {
	if o.raw == "" do return ""
	v, err := json.parse_string(o.raw, .JSON5, false, context.temp_allocator)
	obj, ok := v.(json.Object)
	if err != nil || !ok do return ""
	return string(obj["icon"].(json.String) or_else "")
}

// ` data-theme-mode="light"` for a node that pins a theme on its subtree.
theme_attrs :: proc(n: ^Node) -> string {
	b := strings.builder_make(context.temp_allocator)
	for t in n.theme_set do fmt.sbprintf(&b, " data-theme-%s=\"%s\"", css_name(t[0]), html_escape(t[1]))
	return strings.to_string(b)
}

// True when a variable has values for different values of `axis` (directly or through
// the variables it points to).
var_depends_on :: proc(doc: ^Document, name, axis: string, depth: int) -> bool {
	entries, has := doc.var_defs[name]
	if !has || depth > 8 do return false
	for e in entries {
		for t in e.theme do if t[0] == axis do return true
		if e.ref != "" && var_depends_on(doc, e.ref, axis, depth + 1) do return true
	}
	return false
}

// The theme shown in the window where it differs from the defaults, as attributes for
// the page root, so the exported page looks like the canvas.
shown_theme_attrs :: proc(doc: ^Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a in doc_theme_axes(doc) {
		cur, set := app.theme[a.name]
		if set && len(a.values) > 0 && cur != a.values[0] do fmt.sbprintf(&b, " data-theme-%s=\"%s\"", css_name(a.name), html_escape(cur))
	}
	return strings.to_string(b)
}

// True when an instance sets properties of its component's root on itself.
has_root_overrides :: proc(n: ^Node) -> bool {
	for p in n.props do if !root_override_skipped(p.key) do return true
	return false
}

// One import line for the lucide icons the document uses.
gen_icon_imports :: proc(g: ^Gen) {
	if len(g.icons) == 0 do return
	names := make([dynamic]string, context.temp_allocator)
	for s in g.icons do append(&names, s)
	slice.sort(names[:])
	strings.write_string(&g.out, "import { ")
	for s, i in names {
		if i > 0 do strings.write_string(&g.out, ", ")
		strings.write_string(&g.out, s)
	}
	strings.write_string(&g.out, " } from \"lucide-react\";\n")
}

gen_react_page :: proc(g: ^Gen) {
	strings.write_string(&g.out, "import React from \"react\";\nimport \"./globals.css\";\n")
	gen_icon_imports(g)
	used := make(map[string]bool, context.temp_allocator)
	collect_instances :: proc(g: ^Gen, uid: int, used: ^map[string]bool) {
		for cu in children_of(g.doc, uid) {
			c, _ := doc_find_uid(g.doc, cu)
			if c == nil do continue
			if c.kind == .Ref {
				if comp, _ := doc_find(g.doc, c.ref); comp != nil do used[pascal(node_label(comp))] = true
			}
			collect_instances(g, cu, used)
		}
	}
	collect_instances(g, 0, &used)
	names := make([dynamic]string, context.temp_allocator)
	for s in used do append(&names, s)
	slice.sort(names[:])
	if len(names) > 0 {
		strings.write_string(&g.out, "import { ")
		for s, i in names {
			if i > 0 do strings.write_string(&g.out, ", ")
			strings.write_string(&g.out, s)
		}
		strings.write_string(&g.out, " } from \"./components\";\n")
	}
	fmt.sbprintf(&g.out, "\nexport default function Page() {{\n  return (\n    <main className=\"relative\"%s>\n", shown_theme_attrs(g.doc))
	for cu in children_of(g.doc, 0) {
		if app.page_hidden[cu] do continue
		n, _ := doc_find_uid(g.doc, cu)
		if n == nil || !n.enabled || n.reusable do continue
		gen_react_node(g, n, 3, nil, true)
	}
	strings.write_string(&g.out, "    </main>\n  );\n}\n")
}

// `comp` is the component being emitted (its overridable parts become props).
gen_react_node :: proc(g: ^Gen, n: ^Node, indent: int, comp: ^Node, top: bool) {
	if !n.enabled do return
	parent: ^Node
	if !top do parent, _ = doc_find_uid(g.doc, n.parent)
	cls := tailwind(node_decls(g, n, parent))
	pad := strings.repeat("  ", indent, context.temp_allocator)
	is_prop := false
	prop := ""
	if comp != nil && n.uid != comp.uid {
		// copy first: `for p in g.props[key]` iterates through a pointer to the map
		// slot, which is nil for a component no instance overrides
		props := g.props[comp.id]
		for p in props do if p == n.id {
			is_prop = true
			prop = camel(p)
		}
	}
	open_tag := "div"
	if top && comp != nil {
		if s := shadcn_of(node_label(comp)); s != "" do open_tag = s
	}
	// the root merges the className an instance passes (shadcn's cn = clsx + tailwind-merge)
	class_attr := fmt.tprintf("className=\"%s\"", cls)
	if top && comp != nil do class_attr = fmt.tprintf("className={{cn(\"%s\", props.className)}}", cls)
	wrap_hidden := is_prop && n.kind != .Text && n.kind != .Icon
	if wrap_hidden do fmt.sbprintf(&g.out, "%s{{(props.%s ?? true) && (\n", pad, prop)
	switch n.kind {
	case .Text:
		content := jsx_escape(n.content)
		if is_prop do fmt.sbprintf(&g.out, "%s<p className=\"%s\">{{props.%s ?? \"%s\"}}</p>\n", pad, cls, prop, content)
		else do fmt.sbprintf(&g.out, "%s<p className=\"%s\">%s</p>\n", pad, cls, content)
	case .Path:
		fmt.sbprintf(&g.out, "%s<svg className=\"%s\" viewBox=\"%s %s %s %s\"><path d=\"%s\" fill=\"%s\" /></svg>\n", pad, cls, num_text(n.view_box[0]), num_text(n.view_box[1]), num_text(n.view_box[2]), num_text(n.view_box[3]), n.geometry, color_css(n, "fill", n.fill) if n.has_fill else "none")
	case .Icon:
		if is_prop do fmt.sbprintf(&g.out, "%s{{React.createElement(props.%s ?? %s, {{ className: \"%s\" }})}}\n", pad, prop, pascal(n.icon), cls)
		else do fmt.sbprintf(&g.out, "%s<%s className=\"%s\" />\n", pad, pascal(n.icon), cls)
	case .Ref:
		target, _ := doc_find(g.doc, n.ref)
		if target == nil do break
		name := pascal(node_label(target))
		// properties the instance overrides on the component root (fill, radius, size)
		// travel as classes; tailwind-merge in the component lets them win
		inst_cls := cls
		if has_root_overrides(n) {
			if root := ghost_root_of(g.doc, n.uid); root != nil {
				// the instance's own classes win; duplicates dropped
				b := strings.builder_make(context.temp_allocator)
				seen := make(map[string]bool, context.temp_allocator)
				all := fmt.tprintf("%s %s", tailwind(node_decls(g, root, parent)), cls)
				for c in strings.fields(all, context.temp_allocator) {
					if seen[c] do continue
					seen[c] = true
					if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
					strings.write_string(&b, c)
				}
				inst_cls = strings.to_string(b)
			}
		}
		themed := len(n.theme_set) > 0
		if themed do fmt.sbprintf(&g.out, "%s<div className=\"contents\"%s>\n", pad, theme_attrs(n))
		fmt.sbprintf(&g.out, "%s<%s className=\"%s\"", pad, name, inst_cls)
		for o in n.overrides {
			if o.has_content do fmt.sbprintf(&g.out, " %s=\"%s\"", camel(o.id), jsx_escape(o.content))
			if o.set_enabled do fmt.sbprintf(&g.out, " %s={{%v}}", camel(o.id), o.enabled)
			if icon := override_icon(o); icon != "" do fmt.sbprintf(&g.out, " %s={{%s}}", camel(o.id), pascal(icon))
		}
		defer if themed do fmt.sbprintf(&g.out, "%s</div>\n", pad)
		kids := children_of(g.doc, n.uid)
		if len(kids) == 0 {
			strings.write_string(&g.out, " />\n")
		} else {
			strings.write_string(&g.out, ">\n")
			for cu in kids {
				if c, _ := doc_find_uid(g.doc, cu); c != nil do gen_react_node(g, c, indent + 1, comp, false)
			}
			fmt.sbprintf(&g.out, "%s</%s>\n", pad, name)
		}
	case .Frame, .Group, .Rectangle, .Ellipse, .Other:
		fmt.sbprintf(&g.out, "%s<%s %s%s>\n", pad, open_tag, class_attr, theme_attrs(n))
		if comp != nil && n.is_slot do fmt.sbprintf(&g.out, "%s  {{props.children}}\n", pad)
		for cu in children_of(g.doc, n.uid) {
			if c, _ := doc_find_uid(g.doc, cu); c != nil && !c.ghost do gen_react_node(g, c, indent + 1, comp, false)
		}
		if top && comp != nil && comp.kind != .Frame do fmt.sbprintf(&g.out, "%s  {{props.children}}\n", pad)
		fmt.sbprintf(&g.out, "%s</%s>\n", pad, open_tag)
	}
	if wrap_hidden do fmt.sbprintf(&g.out, "%s)}}\n", pad)
}
