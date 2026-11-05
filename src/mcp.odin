#+build !js
package agentic_design

import "engine"

import "core:bufio"
import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// `agentic-design mcp`: an MCP server over stdio. It forwards tool calls to the running
// Agentic Design window over the local control socket and starts the window if needed.

MCP_INSTRUCTIONS :: `Agentic Design is a native design canvas running on this Mac that edits .pen files (pencil.design). The user sees every change live.
Your session works on one document: the one the window shows when you first call a tool, the one you open, or the one a call names with "document": <path>. Any call (edits, get_document, screenshot) can pass "document" to work on another .pen file without showing it: it is read, changed and saved in place while the user keeps looking at theirs, and later calls stay on it. open shows a document in the window ("create": true starts a new one). If the window shows only the dashboard, open or name a document first. Every reply names the "file" it read or changed.
Nodes are exchanged in the .pen format itself. A node has "type", "id" (a unique string, auto-generated if omitted) and properties:
- types: frame (container; "layout": "none" | "horizontal" | "vertical", "gap", "padding" (n or [v,h] or [t,r,b,l]), "justifyContent", "alignItems", "clip"), group, rectangle, ellipse, path ("geometry": SVG path data), text ("content", "fontSize", "fontWeight" "400".."700", "textGrowth": "auto" | "fixed-width" | "fixed-width-height", "textAlign", "letterSpacing", "underline"), icon ("library": "lucide", "icon": "house"; its "fill" is the color), ref (instance of a node with "reusable": true; "ref": its id; "descendants": {"<id inside the component>": {"content": ...}} overrides its parts).
- Design tokens: set_variables defines variables and theme axes; use them as "$name" in any property.
- "x"/"y" are relative to the parent frame (ignored for children of a frame with a flex layout; y grows downward).
- "width"/"height": a number, "fit_content" or "fill_container". Frames default to horizontal layout and fit_content; set "layout": "none" and a fixed size for a free-form board.
- "fill"/"stroke": hex colors "#RRGGBB" or "#RRGGBBAA", or "$variable"; "strokeWidth", "cornerRadius", "opacity", "enabled": false hides a node. "strokeAlignment": "inner" | "center" | "outer"; a dashed stroke adds "strokeDashPattern": [dash, gap] (null removes it). The app keeps it in the node's "metadata" (as metadata.strokeDashPattern), the only place pen.dev keeps data it does not know; pen.dev draws the stroke solid.
- "fill" may also be a paint or a list of paints, bottom first: {"type": "gradient", "gradientType": "linear" | "radial" | "angular", "rotation": degrees (linear 0 runs bottom to top, counter-clockwise), "center": {"x", "y"} and "size": {"width", "height"} as fractions of the box, "colors": [{"color", "position": 0..1}], "opacity"}, or {"type": "color", "color"}, or an image {"type": "image", "url": "./images/photo.png", "mode": "cover" | "contain" | "stretch"}: give any local path as "url" and the file is copied into images/ next to the document and the url rewritten.
- "effect": an effect or a list: {"type": "shadow", "shadowType": "outer" | "inner", "offset": {"x", "y"}, "blur", "spread", "color"}, {"type": "blur", "radius"}, {"type": "background_blur", "radius"}.
- "rotation" (degrees counter-clockwise) and "flipX"/"flipY" turn and mirror a node around its top-left corner.
- text also takes "textAlign": "justify", "textAlignVertical": "top" | "middle" | "bottom" (for fixed-width-height), "strikethrough".
Children nest in "children". get_document returns the tree plus "bounds": [x, y, width, height] in absolute page coordinates after layout; a layer that is rotated or flipped (or inside one) also has "visual_bounds", the box around it as drawn.
Typical flow: get_guide, get_document (with depth on big files), batch or create_nodes, screenshot to look, lint to review.`

TOOLS_JSON :: `[
{"name":"get_document","description":"Return the .pen document: the node tree (type, id, properties, children) with computed absolute 'bounds', the current selection and the variables. On big files pass 'depth' (containers below it report 'childCount') and fetch parts with 'ids'.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"description":"Return only these subtrees."},"depth":{"type":"number","description":"Levels of children to include; omit for all."},"libraries":{"type":"boolean","description":"Include the imported libraries and their components (default: only when no ids are given). Pass a library component's id (alias:id) in ids to see its parts and their override keys."},"variables":{"type":"boolean","description":"Include variable definitions (default true)."}}}},
{"name":"get_selection","description":"Return the nodes the user has selected in the Agentic Design window, as a tree.","inputSchema":{"type":"object","properties":{"depth":{"type":"number"},"variables":{"type":"boolean","description":"Include variable definitions (default false)."}}}},
{"name":"set_libraries","description":"Import design libraries (other .pen files, by convention .lib.pen) into the document, or remove them by alias. A library's components are used as refs \"alias:componentId\", its variables as \"$alias:name\", and overrides inside them use descendant keys \"alias:childId\". get_document lists the libraries and their components. Libraries are read again within seconds after their file changes on disk; reload: true does it at once. Importing merges the library's theme axes into the document.","inputSchema":{"type":"object","properties":{"reload":{"type":"boolean"},"add":{"type":"array","items":{"type":"string"},"description":"paths of .pen files"},"remove":{"type":"array","items":{"type":"string"},"description":"aliases"}}}},
{"name":"get_guide","description":"Start here: what this document holds and how its parts are named (pages, themes, variables, components, libraries, fonts) and how to work with it efficiently.","inputSchema":{"type":"object","properties":{}}},
{"name":"batch","description":"Apply several edits as one step: all of them or none (the first failure undoes the rest), one undo for the user. operations: [{\"op\": \"create\", \"parent_id\"?, \"nodes\": [...]}, {\"op\": \"update\", \"id\", ...properties} or {\"op\": \"update\", \"updates\": [...]}, {\"op\": \"delete\", \"ids\": [...]}, {\"op\": \"move\", \"id\", \"parent_id\"?, \"before\"?|\"after\"? (sibling id), \"position\"?: \"front\"|\"back\"}, {\"op\": \"set_variables\", ...}, {\"op\": \"connect\", ...the connect arguments}]. Give new nodes your own ids to refer to them in later operations.","inputSchema":{"type":"object","properties":{"operations":{"type":"array","items":{"type":"object"}}},"required":["operations"]}},
{"name":"outline_text","description":"Turn text layers into paths of their glyph outlines (kerning, letter spacing, line breaks and underlines as drawn), one undo step. The path keeps the text's box, position, rotation and fill; the content and font are gone. pen.dev drops a stroke on text, so outline a text to give it a stroke (outlined + or = signs): then update the path with stroke and strokeWidth. Text inside an instance must be outlined in its component.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}},"required":["ids"]}},
{"name":"find_nodes","description":"Find layers without reading the whole document: by name, type, text content, component (ref or component: instances whose ref is the id), variable (layers using $name), within a subtree. Returns ids, types, names, parents and bounds. A text search also finds text shown inside instances (the component's or an override): such hits have in_instance, the instance id and the descendant path to override.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string"},"text":{"type":"string"},"ref":{"type":"string","description":"Component id: find its instances."},"component":{"type":"string","description":"Same as ref."},"variable":{"type":"string"},"within":{"type":"string"},"limit":{"type":"number"}}}},
{"name":"lint","description":"Review the design (the current page, or the given subtrees): hard-coded colours that should be variables (with the matching variable), missing fonts, text taller than its fixed box, layers cut off by a clipping frame, refs to missing components, positions and sizes off whole pixels, empty text, a frame fitting its content around a child that fills it (pen.dev's collapsed size), unknown icons; for diagrams, connectors running through boxes or along each other, labels on labels or boxes, connectors whose end is gone, and arrows drawn as free paths. Each issue has a rule; ignore skips rules for this call, and a layer with \"metadata\": {\"lintIgnore\": true} (or a list of rules) is skipped with its subtree, for intentional artwork or brand colours.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"limit":{"type":"number"},"ignore":{"type":"array","items":{"type":"string"},"description":"Rules to skip, e.g. [\"fractional\"]"}}}},
{"name":"rename_references","description":"Point references at other names in every layer and variable: variables {\"old\": \"new\"} (\"$old\" becomes \"$new\"), refs {\"oldComponentId\": \"newId\"}, or library \"alias\": every variable and component that the imported library also has now points to the library's (\"$alias:name\", refs \"alias:id\", descendant keys \"alias:child\"). One undo step. Typical move to a library: set_libraries add, rename_references library, then delete the local components and variables.","inputSchema":{"type":"object","properties":{"variables":{"type":"object"},"refs":{"type":"object"},"library":{"type":"string"}}}},
{"name":"get_variables","description":"Return the design tokens: variable definitions, theme axes and the theme shown in the window.","inputSchema":{"type":"object","properties":{}}},
{"name":"get_styles","description":"Return the CSS that code export writes for nodes (layout, size, fills and gradients, borders, shadows, blurs, transforms, typography; variables as var(--name)) with their bounds. Defaults to the selection.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}}}},
{"name":"create_nodes","description":"Add .pen nodes (frames may nest 'children'). Returns the created ids and, after layout, each one's bounds in page coordinates (nodes: [{id, bounds: [x, y, w, h]}]), so the next layer can be placed without get_document. Shorthand for a shape whose text wraps inside it: {\"type\": \"frame\", \"shape\": \"diamond\" | \"ellipse\" | \"capsule\", \"content\": \"...\", \"caption\"?: a smaller second line, \"fill\", \"stroke\", \"fontSize\", \"width\"?} (without a width it fits its text; join shapes with connect).","inputSchema":{"type":"object","properties":{"parent_id":{"type":"string","description":"Frame or group to create the nodes in; omit for the canvas. An instance takes them as slot content."},"slot":{"type":"string","description":"With an instance as parent_id: the id of the component's slot frame to fill (default: its frame marked slot)."},"nodes":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string","enum":["frame","group","rectangle","ellipse","text","path","icon","ref"]},"id":{"type":"string"},"name":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"width":{},"height":{},"layout":{"type":"string","enum":["none","horizontal","vertical"]},"gap":{"type":"number"},"padding":{},"justifyContent":{"type":"string"},"alignItems":{"type":"string"},"clip":{"type":"boolean"},"fill":{"description":"color, \"$variable\", a paint object or a list of them (see instructions)"},"stroke":{"type":"string"},"strokeWidth":{"type":"number"},"cornerRadius":{},"opacity":{"type":"number"},"content":{"type":"string"},"fontSize":{"type":"number"},"fontWeight":{"type":"string"},"textGrowth":{"type":"string","enum":["auto","fixed-width","fixed-width-height"]},"textAlign":{"type":"string"},"geometry":{"type":"string","description":"SVG path data"},"library":{"type":"string","description":"icon: icon library, \"lucide\""},"icon":{"type":"string","description":"icon: lucide icon name, e.g. \"house\"; the fill is its color"},"fontFamily":{"type":"string"},"letterSpacing":{"type":"number"},"lineHeight":{"type":"number"},"underline":{"type":"boolean"},"strikethrough":{"type":"boolean"},"textAlignVertical":{"type":"string","enum":["top","middle","bottom"]},"rotation":{"type":"number","description":"degrees counter-clockwise around the top-left corner"},"flipX":{"type":"boolean"},"flipY":{"type":"boolean"},"effect":{"description":"an effect object or a list of them (see instructions)"},"theme":{"type":"object","description":"theme for this subtree, e.g. {\"mode\": \"dark\"}"},"ref":{"type":"string"},"reusable":{"type":"boolean"},"children":{"type":"array","items":{"type":"object"}}},"required":["type"]}}},"required":["nodes"]}},
{"name":"update_nodes","description":"Change properties of existing nodes. Each update has an 'id' plus any .pen properties (null removes a property); 'parent_id' moves a node into another frame ('' = canvas). The reply has each changed layer's bounds after layout (nodes: [{id, bounds}]).","inputSchema":{"type":"object","properties":{"updates":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}},"required":["updates"]}},
{"name":"delete_nodes","description":"Delete nodes (and everything inside them).","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}},"required":["ids"]}},
{"name":"connect","description":"Join two layers with a connector: a line that stays attached and re-routes when either layer moves, resizes or grows. It is saved as a stroked path (pen.dev draws it as last routed) whose metadata names its ends. from/to: layer ids, or id paths through instances (\"card/title\"); fromSide/toSide: center (the side facing the other layer, default), top, right, bottom or left. routing: orthogonal (default), straight or curved. startMarker/endMarker: none, arrow (end default), open_arrow, circle, diamond, bar. label: text on the line (a small frame that follows it, moved off other lines and boxes; labelFill defaults to the stroke colour, labelFontSize). Orthogonal routes go around other boxes, and connectors sharing a side spread along it. stroke (default #1E1E1E), strokeWidth (default 2). parent_id: the frame to put it in (default: the innermost frame holding both ends). Returns its id, its label's id and the route in page coordinates. Change it later with update_nodes (source, target, fromSide, toSide, routing, startMarker, endMarker, label, stroke...); deleting a layer deletes its connectors.","inputSchema":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"},"fromSide":{"type":"string","enum":["center","top","right","bottom","left"]},"toSide":{"type":"string","enum":["center","top","right","bottom","left"]},"routing":{"type":"string","enum":["orthogonal","straight","curved"]},"startMarker":{"type":"string","enum":["none","arrow","open_arrow","circle","diamond","bar"]},"endMarker":{"type":"string","enum":["none","arrow","open_arrow","circle","diamond","bar"]},"label":{"type":"string"},"stroke":{"type":"string"},"strokeWidth":{"type":"number"},"strokeDashPattern":{"type":"array","items":{"type":"number"}},"labelFill":{"type":"string"},"labelFontSize":{"type":"number"},"parent_id":{"type":"string"},"id":{"type":"string"}},"required":["from","to"]}},
{"name":"export_pages","description":"Write a vector PDF, one page per top-level frame: real text in the document's fonts (selectable, searchable), shapes and lines as vectors, images as themselves; gradients and shadows as images at 2x. ids picks frames; page (a page's name or index) takes that page's frames; neither: every page's frames in order. screenshot with format pdf writes one layer the same way.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"page":{"type":["string","number"]},"format":{"type":"string","enum":["pdf"]}},"required":["path"]}},
{"name":"reorder","description":"Move a node to the front or back of its siblings (inside its parent). When it is already there, nothing changes and the reply has moved: false and a note naming the parent: reorder the parent to bring the whole group over its neighbours.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"position":{"type":"string","enum":["front","back"]}},"required":["id"]}},
{"name":"select","description":"Select nodes in the window, optionally zooming to them.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"zoom":{"type":"boolean"}},"required":["ids"]}},
{"name":"zoom_to_fit","description":"Zoom the window to the given nodes, or to everything.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}}}},
{"name":"screenshot","description":"Render a node (or the whole canvas when id is omitted) to PNG and return the image. With view=true, capture the whole Agentic Design window as the user sees it, including panels. With path, write the image there instead (format png, jpeg, webp, or pdf: vector with real text, see export_pages). theme renders with given theme values (e.g. {\"mode\": \"dark\"}) whatever the window shows.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"scale":{"type":"number","description":"Pixels per unit, default 2, at most 16; big areas get less (GPU texture size, 100 Mpx). The result reports the scale used."},"view":{"type":"boolean"},"theme":{"type":"object"},"format":{"type":"string","enum":["png","jpeg","webp","pdf"]},"path":{"type":"string"}}}},
{"name":"undo","description":"Undo the last change.","inputSchema":{"type":"object","properties":{}}},
{"name":"redo","description":"Redo the last undone change.","inputSchema":{"type":"object","properties":{}}},
{"name":"save","description":"Save the document (autosave also runs after every change). Optional new path.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"scale_nodes","description":"Scale layers and everything inside them by a factor (0.64 = 64% as big), as a smaller copy for mobile: sizes, positions inside, font sizes, letter spacing, gaps, padding, radii, strokes, dashes and effects are rewritten, in overrides and slot content too. The layers keep their place. Plain .pen, one undo step. Variables are left as they are and listed; instances keep their component's inner sizes.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"factor":{"type":"number"}},"required":["ids","factor"]}},
{"name":"add_fonts","description":"Make fonts part of the document so it renders the same everywhere (and in pen.dev): copies font files (paths) or every file of installed families (families, e.g. [\"Inter\"]) into fonts/ next to the document and lists them under \"fonts\". Fixes lint missing-font.","inputSchema":{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}},"families":{"type":"array","items":{"type":"string"}}}}},
{"name":"open","description":"Open a .pen document from disk in a tab (an absolute path is safest). With create: true a missing file is created as an empty document first, so new work does not land in the scratch file the window opened with.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"create":{"type":"boolean"}},"required":["path"]}},
{"name":"share","description":"Put the document (the session's, or \"document\") in the Agentic Design cloud of the person signed in on this Mac, and set who may see it. access: private (default: only them, in their cloud files at <site>/files), link (anyone with the link can view it) or public. A link needs the user's yes in the window; ask only when the user wants the file shared. allow_download, allow_embed: what the link allows. Sharing again uploads the current file as a new version behind the same link. Returns access, url (the link, empty when private) and files (their cloud files page). If nobody is signed in, the user signs in under Settings, Account.","inputSchema":{"type":"object","properties":{"access":{"type":"string","enum":["private","link","public"]},"allow_download":{"type":"boolean"},"allow_embed":{"type":"boolean"},"document":{"type":"string"}}}},
{"name":"unshare","description":"Turn off the link of a document shared with share (the file stays in the cloud, private).","inputSchema":{"type":"object","properties":{"document":{"type":"string"}}}},
{"name":"invite","description":"Give one person access to the document (the session's, or \"document\") in the Agentic Design cloud: role viewer (default, sees it) or editor (can change it, live with others). The user confirms in the window first. The file goes to the cloud privately if it is not there yet. Returns url, an invitation link (14 days, used once) to give to the person: they open it signed in with that email. No email is sent. Inviting a current member again changes their role.","inputSchema":{"type":"object","properties":{"email":{"type":"string"},"role":{"type":"string","enum":["viewer","editor"]},"document":{"type":"string"}},"required":["email"]}},
{"name":"people","description":"Who has access to the document in the cloud: owner, members with their roles, open invitations (inCloud false when it was never uploaded).","inputSchema":{"type":"object","properties":{"document":{"type":"string"}}}},
{"name":"remove_access","description":"Take a person's access to the document away, or cancel their invitation, by email.","inputSchema":{"type":"object","properties":{"email":{"type":"string"},"document":{"type":"string"}},"required":["email"]}},
{"name":"set_variables","description":"Edit design tokens. 'variables' merges .pen variable definitions by name ({\"color-bg\": {\"type\": \"color\", \"value\": [{\"value\": \"#FFFFFF\"}, {\"value\": \"#1A1A1A\", \"theme\": {\"mode\": \"dark\"}}]}}; a value may be \"$other\"; null removes a variable). 'themes' replaces the theme axes ({\"mode\": [\"light\", \"dark\"]}, the first value is the default). 'show' switches the theme displayed in the window ({\"mode\": \"dark\"}). Nodes use variables as \"$name\" in any property.","inputSchema":{"type":"object","properties":{"variables":{"type":"object"},"themes":{"type":"object"},"show":{"type":"object"}}}},
{"name":"set_pages","description":"Replace the document's pages: 'pages' is [{\"name\": \"Components\", \"nodes\": [top-level node ids]}] (nodes listed under no page stay on the first one); 'show' is the index of the page to display.","inputSchema":{"type":"object","properties":{"pages":{"type":"array","items":{"type":"object"}},"show":{"type":"number"}}}},
{"name":"export_code","description":"Generate code for the current page: 'html' gives index.html + styles.css (variables as CSS custom properties, themes as [data-theme] blocks); 'react' gives components.tsx (one function per component, props from instance overrides, shadcn/ui for components named Button, Card, Input, ...), Page.tsx and globals.css with Tailwind classes. Returns the file contents; with dir, also writes them there. ids exports only those layers (one frame for one page). A theme axis named viewport (or breakpoint) becomes media queries: each value applies below the middle between its pinned frame's width and the next wider one, number variables are written as var(), and exported frames are fluid up to their width.","inputSchema":{"type":"object","properties":{"format":{"type":"string","enum":["html","react"]},"dir":{"type":"string"},"ids":{"type":"array","items":{"type":"string"},"description":"Layers to export (default: every top-level layer of the page)"},"copy_all_fonts":{"type":"boolean","description":"With dir, also copy declared fonts that name no open license (default: they are referenced, not copied, and listed in warnings)"}}}}
]`

// The MCP client this proxy serves (its `clientInfo`), sent along with every request.
mcp_client, mcp_client_title: string

// The document this session works on (decision 75):
// set by `open`, or by a call's "document" argument. Every request then names it, and the
// window refuses one when it shows another document; edits without one are refused here,
// so they never land in whatever happens to be open (after a restart, untitled.pen).
mcp_file: string

// Tools that change the document (or save it).
mcp_edits :: proc(name: string) -> bool {
	switch name {
	case "batch", "create_nodes", "update_nodes", "delete_nodes", "reorder", "connect", "set_variables", "set_pages", "set_libraries", "rename_references", "scale_nodes", "outline_text", "add_fonts", "undo", "redo", "save":
		return true
	}
	return false
}

mcp_main :: proc() {
	posix_ignore_sigpipe()
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(os.stdin), 1 << 20)
	for {
		free_all(context.temp_allocator)
		line, err := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if err != nil && len(line) == 0 do return
		line = strings.trim_space(line)
		if line == "" do continue
		mcp_handle(line)
	}
}

// stdio transport: one message per line, so drop the literal newlines in TOOLS_JSON.
mcp_send :: proc(s: string) {
	line, _ := strings.replace_all(s, "\n", "", context.temp_allocator)
	os.write_string(os.stdout, line)
	os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}

mcp_handle :: proc(line: string) {
	msg, err := json.parse_string(line, .JSON, true, context.temp_allocator)
	if err != nil {
		mcp_send(`{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}`)
		return
	}
	obj, _ := msg.(json.Object)
	method := string(obj["method"].(json.String) or_else "")
	id_val, has_id := obj["id"]
	if !has_id do return // notification

	id_json, _ := json.marshal(id_val, allocator = context.temp_allocator)
	id := string(id_json)
	params, _ := obj["params"].(json.Object)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"jsonrpc":"2.0","id":%s,`, id)
	switch method {
	case "initialize":
		// who is calling: requests carry it, so the window shows the agent's cursor
		if info, ok := params["clientInfo"].(json.Object); ok {
			mcp_client = strings.clone(string(info["name"].(json.String) or_else ""))
			mcp_client_title = strings.clone(string(info["title"].(json.String) or_else ""))
		}
		version := string(params["protocolVersion"].(json.String) or_else "2025-06-18")
		fmt.sbprintf(&b, `"result":{{"protocolVersion":"%s","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"agentic-design","version":"0.2.0"}},"instructions":`, version)
		engine.json_write_string(&b, MCP_INSTRUCTIONS)
		strings.write_string(&b, "}}")
	case "ping":
		strings.write_string(&b, `"result":{}}`)
	case "tools/list":
		strings.write_string(&b, `"result":{"tools":`)
		strings.write_string(&b, TOOLS_JSON)
		strings.write_string(&b, "}}")
	case "tools/call":
		name := string(params["name"].(json.String) or_else "")
		args_json := "{}"
		if a, has := params["arguments"]; has {
			m, _ := json.marshal(a, allocator = context.temp_allocator)
			args_json = string(m)
		}
		strings.write_string(&b, `"result":`)
		mcp_call_tool(&b, name, args_json)
		strings.write_string(&b, "}")
	case:
		strings.write_string(&b, `"error":{"code":-32601,"message":"method not found"}}`)
	}
	mcp_send(strings.to_string(b))
}

mcp_call_tool :: proc(b: ^strings.Builder, name, args_json: string) {
	tool_error :: proc(b: ^strings.Builder, msg: string) {
		strings.write_string(b, `{"isError":true,"content":[{"type":"text","text":`)
		engine.json_write_string(b, msg)
		strings.write_string(b, "}]}")
	}
	agent := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&agent, `{{"id":"%d","client":`, posix.getpid())
	engine.json_write_string(&agent, mcp_client)
	strings.write_string(&agent, `,"title":`)
	engine.json_write_string(&agent, mcp_client_title)
	strings.write_string(&agent, "}")
	// which document: the call's own "document", else the session's
	file := mcp_file
	if args, aerr := json.parse_string(args_json, .JSON, true, context.temp_allocator); aerr == nil {
		if ao, is_obj := args.(json.Object); is_obj {
			if d, has := ao["document"].(json.String); has && d != "" do file = engine.absolute_path(string(d))
		}
	}
	if name == "open" do file = ""
	if file == "" && (mcp_edits(name) || name == "share" || name == "unshare" || name == "invite" || name == "remove_access") {
		// no document yet: the one the window shows, from now on this session's (decision 85)
		shown := ""
		if r, rok := app_request(`{"method":"window","params":{}}`); rok {
			if v, perr := json.parse_string(r, .JSON, true, context.temp_allocator); perr == nil {
				if vo, is_obj := v.(json.Object); is_obj do shown = string(vo["file"].(json.String) or_else "")
			}
		}
		if shown == "" {
			tool_error(b, "The window shows the dashboard, no document, so nothing was changed. Call open with the path of a .pen file (\"create\": true for a new one), or pass \"document\": <path> to work on a file without showing it.")
			return
		}
		file = engine.absolute_path(shown)
	}
	file_json := ""
	if file != "" {
		fb := strings.builder_make(context.temp_allocator)
		strings.write_string(&fb, `,"file":`)
		engine.json_write_string(&fb, file)
		file_json = strings.to_string(fb)
	}
	// a run started from the window's agent input (agent_run.odin): its requests say so
	run_json := ""
	if run := os.get_env("AGENTIC_RUN", context.temp_allocator); run != "" do run_json = fmt.tprintf(`,"run":"%s"`, run)
	request := fmt.tprintf(`{{"method":"%s","params":%s,"agent":%s%s%s}}`, name, args_json, strings.to_string(agent), file_json, run_json)
	response, ok := app_request(request)
	if !ok {
		if !mcp_may_launch() do tool_error(b, fmt.tprintf("No Agentic Design window answers on port %d, and starting one is off (--no-launch or AGENTIC_NO_LAUNCH).", server_port()))
		else do tool_error(b, "Could not reach the Agentic Design window. It failed to start or is not responding.")
		return
	}
	res, err := json.parse_string(response, .JSON, true, context.temp_allocator)
	if err != nil {
		tool_error(b, "invalid response from Agentic Design")
		return
	}
	obj, _ := res.(json.Object)
	if !(obj["ok"].(json.Boolean) or_else false) {
		tool_error(b, string(obj["error"].(json.String) or_else "unknown error"))
		return
	}
	// the session follows the document it opened, or saved under another name
	shown := string(obj["file"].(json.String) or_else "")
	if shown != "" && (name == "open" || mcp_edits(name) || file != "") {
		delete(mcp_file)
		mcp_file = strings.clone(shown)
	}
	result := obj["result"]
	// say which document was read or changed
	if ro, is_obj := result.(json.Object); is_obj && shown != "" && !("file" in ro) && !("markdown" in ro) && !("png_base64" in ro) {
		ro["file"] = json.String(shown)
		result = ro
	}
	if ro, is_obj := result.(json.Object); is_obj {
		if md, has := ro["markdown"].(json.String); has {
			// a guide: the text itself, not JSON around it
			strings.write_string(b, `{"content":[{"type":"text","text":`)
			engine.json_write_string(b, string(md))
			strings.write_string(b, "}]}")
			return
		}
		if png, has := ro["png_base64"].(json.String); has {
			caption := fmt.tprintf("%vx%v px", ro["width"], ro["height"])
			if sc, ok := ro["scale"].(json.Float); ok do caption = fmt.tprintf("%s at scale %v", caption, sc)
			if note, ok := ro["note"].(json.String); ok do caption = fmt.tprintf("%s (%s)", caption, note)
			fmt.sbprintf(b, `{{"content":[{{"type":"image","mimeType":"image/png","data":"%s"}},{{"type":"text","text":`, png)
			engine.json_write_string(b, caption)
			strings.write_string(b, "}]}")
			return
		}
	}
	text := strings.builder_make(context.temp_allocator)
	engine.write_json_value(&text, result)
	strings.write_string(b, `{"content":[{"type":"text","text":`)
	engine.json_write_string(b, strings.to_string(text))
	strings.write_string(b, "}]}")
}

// Whether the MCP server may start a window when none answers on the port: yes for agents
// (the app opens when they first need it), no with `mcp --no-launch` or AGENTIC_NO_LAUNCH=1,
// for scripts that drive a window that must already be there (D90).
mcp_may_launch :: proc() -> bool {
	for a in os.args[2:] do if a == "--no-launch" do return false
	v := os.get_env("AGENTIC_NO_LAUNCH", context.temp_allocator)
	return v == "" || v == "0"
}

// Sends one request line to the window, starting it if it is not running (and allowed to).
app_request :: proc(request: string) -> (string, bool) {
	sock, err := net.dial_tcp_from_hostname_and_port_string(fmt.tprintf("127.0.0.1:%d", server_port()))
	if err != nil {
		if !mcp_may_launch() do return "", false
		launch_app()
		for _ in 0 ..< 50 {
			time.sleep(200 * time.Millisecond)
			sock, err = net.dial_tcp_from_hostname_and_port_string(fmt.tprintf("127.0.0.1:%d", server_port()))
			if err == nil do break
		}
		if err != nil do return "", false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .TCP_Nodelay, true) // the "\n" would wait for a delayed ACK (server.odin)
	if !send_all(sock, transmute([]u8)request) || !send_all(sock, {'\n'}) do return "", false

	buf := make([dynamic]u8, context.temp_allocator)
	tmp: [64 * 1024]u8
	for {
		n, rerr := net.recv_tcp(sock, tmp[:])
		if rerr != nil || n == 0 do return "", false
		append(&buf, ..tmp[:n])
		if idx := bytes.index_byte(buf[:], '\n'); idx >= 0 do return string(buf[:idx]), true
	}
}

launch_app :: proc() {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintln("agentic-design: executable path:", err)
		return
	}
	// the window's stderr goes to a log so crashes leave a trace
	// (braces doubled: fmt would read "${...}" as a format directive)
	cmd := fmt.tprintf("AGENTIC_NO_FOCUS=1 nohup '%s' >>\"${{TMPDIR:-/tmp}}/agentic-design.log\" 2>&1 &", exe)
	p, perr := os.process_start({command = {"/bin/sh", "-c", cmd}})
	if perr != nil {
		fmt.eprintln("agentic-design: launch failed:", perr, cmd)
		return
	}
	if st, werr := os.process_wait(p); werr != nil || !st.success do fmt.eprintln("agentic-design: launch failed:", st, werr, cmd)
}
