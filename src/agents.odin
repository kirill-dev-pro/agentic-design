package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Agent clients the onboarding can connect to the built-in MCP server. Each one keeps
// its MCP servers in its own config file; connecting adds one entry there, as
// `agentic-design mcp` with this executable's path. JSON configs are edited in place
// (one member inserted or replaced, comments and key order kept) and re-parsed before
// they are written; Claude Code is registered through its own CLI when it is installed.
// Test windows (AGENTIC_QUIET) never write configs unless AGENTIC_HOME points them at
// a sandbox home.

MCP_NAME :: "agentic-design"

Agent_Config :: enum {
	Claude_Code, // ~/.claude.json "mcpServers", or `claude mcp add`
	Mcp_Servers, // { "mcpServers": { name: {command, args} } }
	Vscode, // { "servers": { name: {type, command, args} } }
	Opencode, // { "mcp": { name: {type: "local", command: [...], enabled} } }
	Codex, // ~/.codex/config.toml [mcp_servers.name]
}

Agent_Client :: struct {
	name:      string,
	blurb:     string,
	icon:      string, // lucide
	config:    Agent_Config,
	file:      string, // config path, relative to home
	detect:    []string, // any of these existing means installed ("~/..." or absolute)
	installed: bool,
	connected: bool,
	outdated:  bool, // registered with another executable path
	message:   string,
}

agent_clients := [?]Agent_Client {
	{name = "Claude Code", blurb = "Design from the terminal with your Claude account.", icon = "square-terminal", config = .Claude_Code, file = ".claude.json", detect = {"~/.claude.json", "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"}},
	{name = "Codex", blurb = "Design with your ChatGPT account in Codex.", icon = "code", config = .Codex, file = ".codex/config.toml", detect = {"~/.codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app"}},
	{name = "Claude Desktop", blurb = "The Claude app.", icon = "message-square-code", config = .Mcp_Servers, file = "Library/Application Support/Claude/claude_desktop_config.json", detect = {"/Applications/Claude.app"}},
	{name = "Cursor", blurb = "AI code editor.", icon = "mouse-pointer-2", config = .Mcp_Servers, file = ".cursor/mcp.json", detect = {"/Applications/Cursor.app", "~/.cursor"}},
	{name = "Gemini CLI", blurb = "Google's agent in the terminal.", icon = "sparkles", config = .Mcp_Servers, file = ".gemini/settings.json", detect = {"~/.gemini"}},
	{name = "OpenCode", blurb = "Open-source terminal agent.", icon = "terminal", config = .Opencode, file = ".config/opencode/opencode.json", detect = {"~/.config/opencode", "~/.opencode"}},
	{name = "Windsurf", blurb = "Codeium's editor.", icon = "wind", config = .Mcp_Servers, file = ".codeium/windsurf/mcp_config.json", detect = {"/Applications/Windsurf.app", "~/.codeium/windsurf"}},
	{name = "VS Code", blurb = "Copilot agent mode.", icon = "file-code", config = .Vscode, file = "Library/Application Support/Code/User/mcp.json", detect = {"/Applications/Visual Studio Code.app"}},
	{name = "Kiro", blurb = "Spec-driven agent IDE.", icon = "bot", config = .Mcp_Servers, file = ".kiro/settings/mcp.json", detect = {"/Applications/Kiro.app", "~/.kiro"}},
}

agents_home :: proc() -> string {
	if h := os.get_env("AGENTIC_HOME", context.temp_allocator); h != "" do return h
	home, _ := os.user_home_dir(context.temp_allocator)
	return home
}

agents_sandboxed :: proc() -> bool {
	return os.get_env("AGENTIC_HOME", context.temp_allocator) != ""
}

agent_path :: proc(p: string) -> string {
	if strings.has_prefix(p, "~/") do return fmt.tprintf("%s/%s", agents_home(), p[2:])
	if strings.has_prefix(p, "/") do return p
	return fmt.tprintf("%s/%s", agents_home(), p)
}

mcp_executable :: proc() -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return os.args[0]
	return exe
}

claude_cli :: proc() -> string {
	if agents_sandboxed() do return "" // never touch the real registration from a sandbox
	home, _ := os.user_home_dir(context.temp_allocator)
	for p in ([]string{fmt.tprintf("%s/.local/bin/claude", home), "/opt/homebrew/bin/claude", "/usr/local/bin/claude", fmt.tprintf("%s/.claude/local/claude", home)}) {
		if os.exists(p) do return p
	}
	return ""
}

// Refreshes installed / connected for every client.
agents_detect :: proc() {
	exe := mcp_executable()
	for &c in agent_clients {
		c.installed, c.connected, c.outdated = false, false, false
		for d in c.detect do if os.exists(agent_path(d)) do c.installed = true
		if os.exists(agent_path(c.file)) do c.installed = true
		data, err := os.read_entire_file(agent_path(c.file), context.temp_allocator)
		if err != nil do continue
		text := string(data)
		if c.config == .Codex {
			at := strings.index(text, "[mcp_servers." + MCP_NAME + "]")
			if at < 0 do continue
			c.connected = true
			end := strings.index(text[at + 1:], "\n[")
			block := text[at:] if end < 0 else text[at:at + 1 + end]
			c.outdated = !strings.contains(block, exe)
			continue
		}
		root, perr := json.parse_string(text, .JSON5, false, context.temp_allocator)
		if perr != nil do continue
		obj, _ := root.(json.Object)
		container, _ := obj[agent_container(c.config)].(json.Object)
		entry, has := container[MCP_NAME].(json.Object)
		if !has do continue
		c.connected = true
		command := ""
		#partial switch v in entry["command"] {
		case json.String: command = string(v)
		case json.Array: if len(v) > 0 do command = string(v[0].(json.String) or_else "")
		}
		c.outdated = command != exe
	}
}

agent_container :: proc(cfg: Agent_Config) -> string {
	switch cfg {
	case .Vscode: return "servers"
	case .Opencode: return "mcp"
	case .Claude_Code, .Mcp_Servers, .Codex: return "mcpServers"
	}
	return "mcpServers"
}

agent_entry_json :: proc(cfg: Agent_Config, exe: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch cfg {
	case .Opencode:
		strings.write_string(&b, `{"type": "local", "command": [`)
		json_write_string(&b, exe)
		strings.write_string(&b, `, "mcp"], "enabled": true}`)
	case .Vscode:
		strings.write_string(&b, `{"type": "stdio", "command": `)
		json_write_string(&b, exe)
		strings.write_string(&b, `, "args": ["mcp"]}`)
	case .Claude_Code:
		strings.write_string(&b, `{"type": "stdio", "command": `)
		json_write_string(&b, exe)
		strings.write_string(&b, `, "args": ["mcp"], "env": {}}`)
	case .Mcp_Servers, .Codex:
		strings.write_string(&b, `{"command": `)
		json_write_string(&b, exe)
		strings.write_string(&b, `, "args": ["mcp"]}`)
	}
	return strings.to_string(b)
}

// Registers the MCP server with one client. Returns a message for the user.
agent_connect :: proc(c: ^Agent_Client) -> bool {
	if pf.quiet && !agents_sandboxed() {
		delete(c.message)
		c.message = strings.clone("Disabled in test windows")
		return false
	}
	exe := mcp_executable()
	ok := false
	switch c.config {
	case .Claude_Code:
		if cli := claude_cli(); cli != "" {
			if c.connected do run_quietly({cli, "mcp", "remove", "--scope", "user", MCP_NAME})
			ok = run_quietly({cli, "mcp", "add", "--scope", "user", MCP_NAME, "--", exe, "mcp"})
		} else {
			ok = json_config_put(agent_path(c.file), agent_container(c.config), MCP_NAME, agent_entry_json(c.config, exe))
		}
	case .Codex:
		ok = toml_config_put(agent_path(c.file), exe)
	case .Mcp_Servers, .Vscode, .Opencode:
		ok = json_config_put(agent_path(c.file), agent_container(c.config), MCP_NAME, agent_entry_json(c.config, exe))
	}
	delete(c.message)
	c.message = strings.clone(fmt.tprintf("Connected. New %s sessions can use the canvas.", c.name) if ok else "Could not update the config")
	agents_detect()
	return ok
}

run_quietly :: proc(command: []string) -> bool {
	p, err := os.process_start({command = command})
	if err != nil do return false
	state, werr := os.process_wait(p)
	return werr == nil && state.exited && state.exit_code == 0
}

// ---------------------------------------------------------------- config editing

// Puts `name: value` into the object `container` at the top level of a JSON (or JSONC)
// file, creating the file or the container when missing and replacing an existing
// member. Everything else in the file is left as it was.
json_config_put :: proc(path, container, name, value: string) -> bool {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	text := string(data) if rerr == nil else ""
	out: string
	if strings.trim_space(text) == "" {
		out = fmt.tprintf("{{\n  \"%s\": {{\n    \"%s\": %s\n  }}\n}}\n", container, name, value)
	} else {
		root := json_skip(text, 0)
		if root >= len(text) || text[root] != '{' do return false
		if ks, vs, ve, found := json_member(text, root, container); found {
			_ = ks
			if text[vs] != '{' do return false
			if mks, mvs, mve, mfound := json_member(text, vs, name); mfound {
				_ = mks
				out = strings.concatenate({text[:mvs], value, text[mve:]}, context.temp_allocator)
			} else {
				out = json_insert_first(text, vs, fmt.tprintf("\"%s\": %s", name, value), "    ")
			}
			_ = ve
		} else {
			out = json_insert_first(text, root, fmt.tprintf("\"%s\": {{\n    \"%s\": %s\n  }}", container, name, value), "  ")
		}
	}
	// never write something that does not parse back
	if _, perr := json.parse_string(out, .JSON5, false, context.temp_allocator); perr != nil do return false
	_ = os.make_directory_all(dir_of(path))
	return os.write_entire_file(path, out) == nil
}

dir_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[:i] if i > 0 else "."
}

// Inserts a member right after the `{` at `open`, adding a comma when the object
// already has members.
json_insert_first :: proc(text: string, open: int, member, indent: string) -> string {
	next := json_skip(text, open + 1)
	empty := next < len(text) && text[next] == '}'
	// an object written on one line gets the member on that line too
	if !strings.contains(text[open + 1:next], "\n") && !empty {
		return strings.concatenate({text[:open + 1], member, ", ", text[next:]}, context.temp_allocator)
	}
	sep := "" if empty else ","
	tail := "\n" if empty else ""
	return strings.concatenate({text[:open + 1], "\n", indent, member, sep, tail, text[open + 1:]}, context.temp_allocator)
}

// Skips whitespace and // or /* */ comments.
json_skip :: proc(t: string, i: int) -> int {
	i := i
	for i < len(t) {
		c := t[i]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			i += 1
		} else if c == '/' && i + 1 < len(t) && t[i + 1] == '/' {
			for i < len(t) && t[i] != '\n' do i += 1
		} else if c == '/' && i + 1 < len(t) && t[i + 1] == '*' {
			i += 2
			for i + 1 < len(t) && !(t[i] == '*' && t[i + 1] == '/') do i += 1
			i += 2
		} else {
			break
		}
	}
	return i
}

// End (exclusive) of the JSON value starting at i.
json_value_end :: proc(t: string, i: int) -> int {
	if i >= len(t) do return i
	switch t[i] {
	case '"':
		j := i + 1
		for j < len(t) && t[j] != '"' {
			if t[j] == '\\' do j += 1
			j += 1
		}
		return j + 1
	case '{', '[':
		depth := 0
		j := i
		for j < len(t) {
			c := t[j]
			if c == '"' {
				j = json_value_end(t, j)
				continue
			}
			if c == '/' && j + 1 < len(t) && (t[j + 1] == '/' || t[j + 1] == '*') {
				j = json_skip(t, j)
				continue
			}
			if c == '{' || c == '[' do depth += 1
			if c == '}' || c == ']' {
				depth -= 1
				if depth == 0 do return j + 1
			}
			j += 1
		}
		return j
	}
	j := i
	for j < len(t) && t[j] != ',' && t[j] != '}' && t[j] != ']' && t[j] != '\n' do j += 1
	return j
}

// Finds member `key` of the object whose `{` is at `open`.
json_member :: proc(t: string, open: int, key: string) -> (key_start, value_start, value_end: int, found: bool) {
	i := json_skip(t, open + 1)
	for i < len(t) && t[i] != '}' {
		if t[i] != '"' do return
		ks := i
		ke := json_value_end(t, i)
		name := t[ks + 1:ke - 1]
		i = json_skip(t, ke)
		if i >= len(t) || t[i] != ':' do return
		vs := json_skip(t, i + 1)
		ve := json_value_end(t, vs)
		if name == key do return ks, vs, ve, true
		i = json_skip(t, ve)
		if i < len(t) && t[i] == ',' do i = json_skip(t, i + 1)
	}
	return
}

// Adds (or rewrites) the [mcp_servers.agentic-design] table of Codex's config.toml.
toml_config_put :: proc(path, exe: string) -> bool {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	text := string(data)
	header := "[mcp_servers." + MCP_NAME + "]"
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, header)
	strings.write_string(&b, "\ncommand = ")
	json_write_string(&b, exe) // a TOML basic string has the same escapes
	strings.write_string(&b, "\nargs = [ \"mcp\" ]\n")
	table := strings.to_string(b)
	out: string
	if at := strings.index(text, header); at >= 0 {
		rest := text[at + len(header):]
		end := strings.index(rest, "\n[")
		after := "" if end < 0 else rest[end + 1:]
		out = strings.concatenate({text[:at], table, "\n" if after != "" else "", after}, context.temp_allocator)
	} else {
		sep := "" if text == "" || strings.has_suffix(text, "\n\n") else ("\n" if strings.has_suffix(text, "\n") else "\n\n")
		out = strings.concatenate({text, sep, table}, context.temp_allocator)
	}
	_ = os.make_directory_all(dir_of(path))
	return os.write_entire_file(path, out) == nil
}
