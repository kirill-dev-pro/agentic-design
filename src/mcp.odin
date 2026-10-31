package agentic_design

import "core:bufio"
import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

// `agentic-design mcp`: an MCP server over stdio. It forwards tool calls to the running
// Agentic Design window over the local control socket and starts the window if needed.

MCP_INSTRUCTIONS :: `Agentic Design is a native design canvas running on this Mac that edits .pen files (pencil.design). The user sees every change live.
Nodes are exchanged in the .pen format itself. A node has "type", "id" (a unique string, auto-generated if omitted) and properties:
- types: frame (container; "layout": "none" | "horizontal" | "vertical", "gap", "padding" (n or [v,h] or [t,r,b,l]), "justifyContent", "alignItems", "clip"), group, rectangle, ellipse, path ("geometry": SVG path data), text ("content", "fontSize", "fontWeight" "400".."700", "textGrowth": "auto" | "fixed-width" | "fixed-width-height", "textAlign", "letterSpacing", "underline"), icon ("library": "lucide", "icon": "house"; its "fill" is the color), ref (instance of a node with "reusable": true; "ref": its id; "descendants": {"<id inside the component>": {"content": ...}} overrides its parts).
- Design tokens: set_variables defines variables and theme axes; use them as "$name" in any property.
- "x"/"y" are relative to the parent frame (ignored for children of a frame with a flex layout; y grows downward).
- "width"/"height": a number, "fit_content" or "fill_container". Frames default to horizontal layout and fit_content; set "layout": "none" and a fixed size for a free-form board.
- "fill"/"stroke": hex colors "#RRGGBB" or "#RRGGBBAA", or "$variable"; "strokeWidth", "cornerRadius", "opacity", "enabled": false hides a node.
Children nest in "children". get_document returns the tree plus "bounds": [x, y, width, height] in absolute page coordinates after layout.
Typical flow: get_document, create_nodes (a frame with nested children), then screenshot to check the result.`

TOOLS_JSON :: `[
{"name":"get_document","description":"Return the .pen document: variables and the node tree (type, id, properties, children) with computed absolute 'bounds', plus the current selection.","inputSchema":{"type":"object","properties":{}}},
{"name":"get_selection","description":"Return the nodes the user has selected in the Agentic Design window, as a tree.","inputSchema":{"type":"object","properties":{}}},
{"name":"create_nodes","description":"Add .pen nodes (frames may nest 'children'). Returns the created ids.","inputSchema":{"type":"object","properties":{"parent_id":{"type":"string","description":"Frame or group to create the nodes in; omit for the canvas."},"nodes":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string","enum":["frame","group","rectangle","ellipse","text","path","icon","ref"]},"id":{"type":"string"},"name":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"width":{},"height":{},"layout":{"type":"string","enum":["none","horizontal","vertical"]},"gap":{"type":"number"},"padding":{},"justifyContent":{"type":"string"},"alignItems":{"type":"string"},"clip":{"type":"boolean"},"fill":{"type":"string"},"stroke":{"type":"string"},"strokeWidth":{"type":"number"},"cornerRadius":{},"opacity":{"type":"number"},"content":{"type":"string"},"fontSize":{"type":"number"},"fontWeight":{"type":"string"},"textGrowth":{"type":"string","enum":["auto","fixed-width","fixed-width-height"]},"textAlign":{"type":"string"},"geometry":{"type":"string","description":"SVG path data"},"library":{"type":"string","description":"icon: icon library, \"lucide\""},"icon":{"type":"string","description":"icon: lucide icon name, e.g. \"house\"; the fill is its color"},"fontFamily":{"type":"string"},"letterSpacing":{"type":"number"},"lineHeight":{"type":"number"},"underline":{"type":"boolean"},"effect":{},"theme":{"type":"object","description":"theme for this subtree, e.g. {\"mode\": \"dark\"}"},"ref":{"type":"string"},"reusable":{"type":"boolean"},"children":{"type":"array","items":{"type":"object"}}},"required":["type"]}}},"required":["nodes"]}},
{"name":"update_nodes","description":"Change properties of existing nodes. Each update has an 'id' plus any .pen properties (null removes a property); 'parent_id' moves a node into another frame ('' = canvas).","inputSchema":{"type":"object","properties":{"updates":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}},"required":["updates"]}},
{"name":"delete_nodes","description":"Delete nodes (and everything inside them).","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}},"required":["ids"]}},
{"name":"reorder","description":"Move a node to the front or back of its siblings.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"position":{"type":"string","enum":["front","back"]}},"required":["id"]}},
{"name":"select","description":"Select nodes in the window, optionally zooming to them.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"zoom":{"type":"boolean"}},"required":["ids"]}},
{"name":"zoom_to_fit","description":"Zoom the window to the given nodes, or to everything.","inputSchema":{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}}}},
{"name":"screenshot","description":"Render a node (or the whole canvas when id is omitted) to PNG and return the image. With view=true, capture the whole Agentic Design window as the user sees it, including panels.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"scale":{"type":"number","description":"Pixels per unit, default 2"},"view":{"type":"boolean"}}}},
{"name":"undo","description":"Undo the last change.","inputSchema":{"type":"object","properties":{}}},
{"name":"redo","description":"Redo the last undone change.","inputSchema":{"type":"object","properties":{}}},
{"name":"save","description":"Save the document (autosave also runs after every change). Optional new path.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"open","description":"Open a .pen document from disk.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"set_variables","description":"Edit design tokens. 'variables' merges .pen variable definitions by name ({\"color-bg\": {\"type\": \"color\", \"value\": [{\"value\": \"#FFFFFF\"}, {\"value\": \"#1A1A1A\", \"theme\": {\"mode\": \"dark\"}}]}}; a value may be \"$other\"; null removes a variable). 'themes' replaces the theme axes ({\"mode\": [\"light\", \"dark\"]}, the first value is the default). 'show' switches the theme displayed in the window ({\"mode\": \"dark\"}). Nodes use variables as \"$name\" in any property.","inputSchema":{"type":"object","properties":{"variables":{"type":"object"},"themes":{"type":"object"},"show":{"type":"object"}}}},
{"name":"set_pages","description":"Replace the document's pages: 'pages' is [{\"name\": \"Components\", \"nodes\": [top-level node ids]}] (nodes listed under no page stay on the first one); 'show' is the index of the page to display.","inputSchema":{"type":"object","properties":{"pages":{"type":"array","items":{"type":"object"}},"show":{"type":"number"}}}},
{"name":"export_code","description":"Generate code for the current page: 'html' gives index.html + styles.css (variables as CSS custom properties, themes as [data-theme] blocks); 'react' gives components.tsx (one function per component, props from instance overrides, shadcn/ui for components named Button, Card, Input, ...), Page.tsx and globals.css with Tailwind classes. Returns the file contents; with dir, also writes them there.","inputSchema":{"type":"object","properties":{"format":{"type":"string","enum":["html","react"]},"dir":{"type":"string"}}}}
]`

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
		version := string(params["protocolVersion"].(json.String) or_else "2025-06-18")
		fmt.sbprintf(&b, `"result":{{"protocolVersion":"%s","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"agentic-design","version":"0.2.0"}},"instructions":`, version)
		json_write_string(&b, MCP_INSTRUCTIONS)
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
		json_write_string(b, msg)
		strings.write_string(b, "}]}")
	}
	request := fmt.tprintf(`{{"method":"%s","params":%s}}`, name, args_json)
	response, ok := app_request(request)
	if !ok {
		tool_error(b, "Could not reach the Agentic Design window. It failed to start or is not responding.")
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
	result := obj["result"]
	if ro, is_obj := result.(json.Object); is_obj {
		if png, has := ro["png_base64"].(json.String); has {
			fmt.sbprintf(b, `{{"content":[{{"type":"image","mimeType":"image/png","data":"%s"}},{{"type":"text","text":"%vx%v px"}}]}}`, png, ro["width"], ro["height"])
			return
		}
	}
	text := strings.builder_make(context.temp_allocator)
	write_json_value(&text, result)
	strings.write_string(b, `{"content":[{"type":"text","text":`)
	json_write_string(b, strings.to_string(text))
	strings.write_string(b, "}]}")
}

// Sends one request line to the window, starting it if it is not running.
app_request :: proc(request: string) -> (string, bool) {
	sock, err := net.dial_tcp_from_hostname_and_port_string(fmt.tprintf("127.0.0.1:%d", server_port()))
	if err != nil {
		launch_app()
		for _ in 0 ..< 50 {
			time.sleep(200 * time.Millisecond)
			sock, err = net.dial_tcp_from_hostname_and_port_string(fmt.tprintf("127.0.0.1:%d", server_port()))
			if err == nil do break
		}
		if err != nil do return "", false
	}
	defer net.close(sock)
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
