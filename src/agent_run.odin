#+build !js
package agentic_design

import "engine"

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// "Ask an agent" in the window (decision 86, agent-input-design.md): the user's own Claude
// Code or Codex runs headless, signed in as the user already is, with only our MCP server.
// The window keeps one thread per document (and one for the dashboard), runs one request
// at a time in each, shows what the agent says and does, stops it on request, and makes
// each request one undo step in every document it changed.

Agent_Kind :: enum {
	Claude,
	Codex,
	Gemini,
}

AGENT_KIND_NAMES := [Agent_Kind]string {
	.Claude = "Claude Code",
	.Codex  = "Codex",
	.Gemini = "Gemini CLI",
}

// What the user attached for the agent to read (decision 88): a folder or a file, kept per
// document.
Context_Item :: struct {
	path:   string,
	folder: bool,
}

// A past or current conversation about a document.
Session_Info :: struct {
	sid:   string, // ours
	title: string,
	agent: Agent_Kind,
	time:  i64, // unix seconds of its last request
}

Run_State :: enum {
	Idle,
	Working,
	Done,
	Stopped,
	Failed,
}

Run_Item_Kind :: enum {
	User,
	Text,
	Tool,
	Error,
}

Run_Item :: struct {
	kind:  Run_Item_Kind,
	text:  string,
	count: int, // tool calls of the same tool in a row
	image: string, // a user request: the marked view sent with it (annotations.odin)
	marks: int, // how many marks it carried
	notes: string, // a request: a line per mark ("Tag 1 · Email field")
	ctx:   string, // a request: the context attached, a name per line ("/" ends a folder's)
}

run_item_free :: proc(it: Run_Item) {
	delete(it.text)
	delete(it.image)
	delete(it.notes)
	delete(it.ctx)
}

Agent_Thread :: struct {
	key:      string, // the document's path, "" for the dashboard
	items:    [dynamic]Run_Item,
	session:  string, // the CLI's session, for follow-ups
	sess_of:  Agent_Kind,
	agent:    Agent_Kind,
	state:    Run_State,
	started:  time.Time,
	seconds:  f64, // how long the last run took
	cost:     f64,
	tools:    int,
	token:    string, // while it runs: the MCP requests that carry it are this run's
	touched:  map[string]bool, // documents this run changed since the user last did
	process:  os.Process,
	running:  bool, // the process lives
	stop_at:  time.Time, // Stop: SIGKILL after this
	stopping: bool,
	err_path: string, // the CLI's stderr
	shown:    bool, // the panel is open
	scroll:   f32,
	undone:   bool, // the user undid the last run's changes (the agent is told)
	sid:      string, // this conversation (Session_Info.sid); "" until the first request
	title:    string, // the agent's title for it; "" until it is named
	attached: [dynamic]Context_Item, // what the agent may read, for this document
	sessions: [dynamic]Session_Info, // every conversation about this document, newest first
	delta:    bool, // Gemini: the last text item still grows
	run_dir:  string, // the run's folder (mcp config, stderr, the marked view)
}

Agent_Title :: struct {
	thread: ^Agent_Thread,
	sid:    string,
	title:  string,
}

Agent_Line :: struct {
	thread: ^Agent_Thread,
	line:   string, // "" with eof
	eof:    bool,
}

agent_state: struct {
	threads: [dynamic]^Agent_Thread,
	choice:  Agent_Kind,
	draft:   string,
	mutex:   sync.Mutex,
	lines:   [dynamic]Agent_Line, // from the reader threads, under mutex
	in_run:  ^Agent_Thread, // the run whose request is being handled (api_dispatch)
	titles:  [dynamic]Agent_Title, // from the title jobs, under mutex
	pending: string, // a request sent from the interface, started by agent_tick
	choice_loaded: bool, // `choice` was read from settings
}

// ---------------------------------------------------------------- the CLIs

agent_cli :: proc(kind: Agent_Kind) -> string {
	// tests point these at a fake CLI that speaks the same stream
	overrides := [Agent_Kind]string{.Claude = "AGENTIC_AGENT_CLAUDE", .Codex = "AGENTIC_AGENT_CODEX", .Gemini = "AGENTIC_AGENT_GEMINI"}
	if p := os.get_env(overrides[kind], context.temp_allocator); p != "" do return p
	home, _ := os.user_home_dir(context.temp_allocator)
	paths: []string
	switch kind {
	case .Claude: paths = {fmt.tprintf("%s/.local/bin/claude", home), "/opt/homebrew/bin/claude", "/usr/local/bin/claude", fmt.tprintf("%s/.claude/local/claude", home)}
	case .Codex: paths = {"/opt/homebrew/bin/codex", "/usr/local/bin/codex", fmt.tprintf("%s/.local/bin/codex", home)}
	case .Gemini: paths = {"/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", fmt.tprintf("%s/.local/bin/gemini", home), fmt.tprintf("%s/.npm-global/bin/gemini", home)}
	}
	for p in paths do if os.exists(p) do return p
	return ""
}

agent_available :: proc(kind: Agent_Kind) -> bool {
	return agent_cli(kind) != ""
}

agent_thread_of :: proc(key: string) -> ^Agent_Thread {
	for t in agent_state.threads do if t.key == key || (key != "" && t.key != "" && same_file(t.key, key)) do return t
	t := new(Agent_Thread)
	t.key = strings.clone(key)
	t.agent = agent_state.choice
	agent_thread_load(t)
	append(&agent_state.threads, t)
	return t
}

// The thread of what the window shows: the document, or the dashboard.
agent_current :: proc() -> ^Agent_Thread {
	return agent_thread_of(app.file_path if app.tab >= 0 else "")
}

agent_busy :: proc() -> bool {
	for t in agent_state.threads do if t.running do return true
	return false
}

// ---------------------------------------------------------------- what the agent is told

AGENT_NEW_FILES :: "Documents/Agentic Design"

// Where a design asked for on the dashboard is created (tests: AGENTIC_AGENT_DIR).
agent_new_files_dir :: proc() -> string {
	if d := os.get_env("AGENTIC_AGENT_DIR", context.temp_allocator); d != "" do return d
	home, _ := os.user_home_dir(context.temp_allocator)
	return fmt.tprintf("%s/%s", home, AGENT_NEW_FILES)
}

agent_guide :: proc(t: ^Agent_Thread) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "You are the design agent inside Agentic Design, a native macOS editor of .pen design files. The user typed this request in the app and watches the canvas while you work. Work only through the agentic-design MCP tools.\n")
	if t.key != "" {
		fmt.sbprintf(&b, "The window shows %s; your calls go to it. To read, change or screenshot another .pen file without showing it, pass \"document\": <its path> to any call.\n", t.key)
		if len(app.sel) > 0 && same_file(app.file_path, t.key) {
			strings.write_string(&b, "Selected layers (the user means these when they say \"this\"):")
			for uid, i in app.sel {
				if i >= 8 {
					fmt.sbprintf(&b, " and %d more", len(app.sel) - 8)
					break
				}
				if n, _ := engine.doc_find_uid(&app.doc, uid); n != nil {
					name := n.name if n.name != "" else fmt.tprintf("%v", n.kind)
					fmt.sbprintf(&b, " %s (\"%s\")", n.id, name)
				}
			}
			strings.write_string(&b, ".\n")
		}
	} else {
		fmt.sbprintf(&b, "No document is open: the user is on the dashboard. For a new design, create the file with open {{\"path\": \"%s/<short-name>.pen\", \"create\": true}} (that folder unless the user names another); it is then shown. To work on an existing file, pass \"document\": <its path>.\n", agent_new_files_dir())
	}
	if len(t.attached) > 0 {
		strings.write_string(&b, "The user attached context for this design; read and search it with your file tools (read only) when the request needs it:")
		for c in t.attached do fmt.sbprintf(&b, "\n- %s: %s", "folder" if c.folder else "file", c.path)
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "Check your work with a screenshot. Answer briefly when done. The whole request is one undo step for the user.")
	return strings.to_string(b)
}

// ---------------------------------------------------------------- running

@(private = "file")
random_token :: proc() -> string {
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], context.temp_allocator))
}

@(private = "file")
agent_env :: proc(token: string) -> []string {
	env := make([dynamic]string, context.temp_allocator)
	home, _ := os.user_home_dir(context.temp_allocator)
	path := os.get_env("PATH", context.temp_allocator)
	append(&env, fmt.tprintf("PATH=%s/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin%s%s", home, ":" if path != "" else "", path))
	all, _ := os.environ(context.temp_allocator)
	for kv in all {
		name := kv[:strings.index_byte(kv, '=')] if strings.contains_rune(kv, '=') else kv
		switch {
		case name == "PATH", strings.has_prefix(name, "AGENTIC_"):
		case name == "HOME", name == "USER", name == "LOGNAME", name == "SHELL", name == "TMPDIR", name == "TERM", name == "LANG", strings.has_prefix(name, "LC_"),
		     strings.has_prefix(name, "ANTHROPIC_"), strings.has_prefix(name, "CLAUDE_"), strings.has_prefix(name, "OPENAI_"), strings.has_prefix(name, "CODEX_"),
		     strings.has_prefix(name, "GEMINI_"), strings.has_prefix(name, "GOOGLE_"),
		     name == "HTTPS_PROXY", name == "HTTP_PROXY", name == "NO_PROXY", name == "SSL_CERT_FILE":
			append(&env, kv)
		}
	}
	return env[:]
}

// Sends the prompt: a new run in the thread of what the window shows. From the interface it
// waits for the next frame's start: the marked view is drawn offscreen, which cannot happen
// inside the window's frame.
agent_send :: proc(prompt: string) {
	delete(agent_state.pending)
	agent_state.pending = strings.clone(prompt)
	platform_wake()
}

@(private = "file")
agent_send_now :: proc(prompt: string) {
	text := strings.trim_space(prompt)
	if text == "" do return
	t := agent_current()
	if t.running {
		set_status("The agent is still working on the last request")
		return
	}
	kind := agent_state.choice
	cli := agent_cli(kind)
	if cli == "" {
		set_status("%s is not installed on this Mac", AGENT_KIND_NAMES[kind])
		return
	}
	if t.key != "" && app.dirty do save_document(app.file_path)
	sent := text
	if t.undone && t.session != "" do sent = fmt.tprintf("(The user undid all the changes of your previous request.)\n%s", text)
	t.undone = false
	if t.sid == "" {
		t.sid = strings.clone(random_token()[:12])
		delete(t.title)
		t.title = ""
	}

	// an empty working folder per thread: the agent has no files of the user's to look at
	// beyond the context the user attached
	dir := fmt.tprintf("%s/agent-runs/%016x", support_dir(), hash.fnv64a(transmute([]u8)t.key))
	_ = fs_mkdir_all(dir)
	delete(t.run_dir)
	t.run_dir = strings.clone(dir)
	// the marks drawn on the canvas go with this request, then leave the canvas
	marks_text, marks_image, marks_n, marks_notes := annotations_take(dir)
	if marks_text != "" do sent = fmt.tprintf("%s\n\n%s", sent, marks_text)
	cb := strings.builder_make(context.temp_allocator)
	for c, i in t.attached {
		if i > 0 do strings.write_byte(&cb, '\n')
		strings.write_string(&cb, fs_base(c.path))
		if c.folder do strings.write_byte(&cb, '/')
	}
	append(&t.items, Run_Item{kind = .User, text = strings.clone(text), image = strings.clone(marks_image), marks = marks_n, notes = strings.clone(marks_notes), ctx = strings.clone(strings.to_string(cb))})
	session_touch(t)
	t.shown, t.scroll = true, 0
	t.agent = kind
	t.state = .Working
	t.started = time.now()
	t.cost, t.tools = 0, 0
	clear(&t.touched)
	delete(t.token)
	t.token = strings.clone(random_token())
	t.stopping = false

	delete(t.err_path)
	t.err_path = fmt.aprintf("%s/stderr.txt", dir)
	exe := mcp_executable()
	port := server_port()
	guide := agent_guide(t)
	resume := t.session if t.session != "" && t.sess_of == kind else ""

	args := make([dynamic]string, context.temp_allocator)
	switch kind {
	case .Claude:
		cfg := fmt.tprintf("%s/mcp.json", dir)
		cb := strings.builder_make(context.temp_allocator)
		strings.write_string(&cb, `{"mcpServers":{"agentic-design":{"command":`)
		engine.json_write_string(&cb, exe)
		fmt.sbprintf(&cb, `,"args":["mcp"],"env":{{"AGENTIC_PORT":"%d","AGENTIC_NO_LAUNCH":"1","AGENTIC_RUN":"%s"}}}}}}}}`, port, t.token)
		_ = fs_write(cfg, strings.to_string(cb))
		// built-in tools: reading only, and only what the user attached (and the marked view)
		readable := make([dynamic]string, context.temp_allocator)
		for c in t.attached do append(&readable, fmt.tprintf("Read(/%s%s)", c.path, "/**" if c.folder else ""))
		if marks_image != "" do append(&readable, fmt.tprintf("Read(/%s)", marks_image))
		// (one rule per argument: paths may hold spaces; the options that take several values
		// come before others, so none of them takes the prompt)
		append(&args, cli, "-p")
		for c in t.attached do append(&args, "--add-dir", c.path if c.folder else fs_dir(c.path))
		append(&args, "--output-format", "stream-json", "--verbose", "--mcp-config", cfg, "--strict-mcp-config", "--tools", "Read,Grep,Glob" if len(readable) > 0 else "", "--allowedTools", "mcp__agentic-design__*")
		append(&args, ..readable[:])
		append(&args, "--setting-sources", "user", "--append-system-prompt", guide)
		agent_args_model(kind, &args)
		if resume != "" do append(&args, "--resume", resume)
		append(&args, sent)
	case .Codex:
		servers := fmt.tprintf(`mcp_servers={{"agentic-design"={{command=%s,args=["mcp"],env={{AGENTIC_PORT="%d",AGENTIC_NO_LAUNCH="1",AGENTIC_RUN="%s"}},default_tools_approval_mode="approve"}}}}`, json_quote(exe), port, t.token)
		append(&args, cli, "exec")
		if marks_image != "" do append(&args, "-i", marks_image) // (it takes several files: before other options)
		append(&args, "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-C", dir, "-c", servers, "-c", `approval_policy="never"`)
		agent_args_model(kind, &args)
		if resume != "" do append(&args, "resume", resume)
		append(&args, fmt.tprintf("%s\n\nRequest: %s", guide, sent))
	case .Gemini:
		// its MCP server comes from settings we write (as system settings for this run only);
		// the server is trusted, so its tools run without asking; other tools that change
		// things would ask, and in a headless run asking means no
		settings := fmt.tprintf("%s/gemini-settings.json", dir)
		gb := strings.builder_make(context.temp_allocator)
		strings.write_string(&gb, `{"mcpServers":{"agentic-design":{"command":`)
		engine.json_write_string(&gb, exe)
		fmt.sbprintf(&gb, `,"args":["mcp"],"trust":true,"env":{{"AGENTIC_PORT":"%d","AGENTIC_NO_LAUNCH":"1","AGENTIC_RUN":"%s"}}}}}}}}`, port, t.token)
		_ = fs_write(settings, strings.to_string(gb))
		append(&args, cli, "--output-format", "stream-json", "--allowed-mcp-server-names", "agentic-design", "--approval-mode", "default")
		for c in t.attached do append(&args, "--include-directories", c.path if c.folder else fs_dir(c.path))
		agent_args_model(kind, &args)
		if resume != "" do append(&args, "--resume", resume)
		g := fmt.tprintf("%s\n\nRequest: %s", guide, sent)
		if marks_image != "" do g = fmt.tprintf("%s\n\nThe marked view: @%s", g, marks_image)
		append(&args, "-p", g)
	}

	r, w, perr := os.pipe()
	if perr != nil {
		agent_fail(t, fmt.tprintf("could not start %s: %v", AGENT_KIND_NAMES[kind], perr))
		return
	}
	errf, _ := os.create(t.err_path)
	env := agent_env(t.token)
	if kind == .Gemini {
		e := make([dynamic]string, context.temp_allocator)
		append(&e, ..env)
		append(&e, fmt.tprintf("GEMINI_CLI_SYSTEM_SETTINGS_PATH=%s/gemini-settings.json", dir))
		env = e[:]
	}
	p, serr := os.process_start({command = args[:], env = env, working_dir = dir, stdout = w, stderr = errf})
	os.close(w)
	if errf != nil do os.close(errf)
	if serr != nil {
		os.close(r)
		agent_fail(t, fmt.tprintf("could not start %s (%s): %v", AGENT_KIND_NAMES[kind], cli, serr))
		return
	}
	t.process, t.running = p, true
	Reader :: struct {
		file:   ^os.File,
		thread: ^Agent_Thread,
	}
	rd := new(Reader)
	rd^ = {r, t}
	thread.create_and_start_with_data(rd, proc(data: rawptr) {
			context = app_context()
			rd := (^Reader)(data)
			buf: [8192]u8
			line := strings.builder_make()
			for {
				n, err := os.read(rd.file, buf[:])
				if n <= 0 || err != nil do break
				for c in buf[:n] {
					if c == '\n' {
						sync.mutex_lock(&agent_state.mutex)
						append(&agent_state.lines, Agent_Line{rd.thread, strings.clone(strings.to_string(line)), false})
						sync.mutex_unlock(&agent_state.mutex)
						strings.builder_reset(&line)
						platform_wake()
					} else do strings.write_byte(&line, c)
				}
			}
			sync.mutex_lock(&agent_state.mutex)
			append(&agent_state.lines, Agent_Line{rd.thread, "", true})
			sync.mutex_unlock(&agent_state.mutex)
			strings.builder_destroy(&line)
			os.close(rd.file)
			free(rd)
			platform_wake()
		}, app_context(), self_cleanup = true)
	app_log("agent: %s started for %s", AGENT_KIND_NAMES[kind], t.key if t.key != "" else "the dashboard")
}

@(private = "file")
agent_fail :: proc(t: ^Agent_Thread, msg: string) {
	append(&t.items, Run_Item{kind = .Error, text = strings.clone(msg)})
	t.state = .Failed
}

agent_stop :: proc(t: ^Agent_Thread) {
	if !t.running || t.stopping do return
	posix.kill(posix.pid_t(t.process.pid), .SIGINT)
	t.stopping = true
	t.stop_at = time.time_add(time.now(), 3 * time.Second)
	// its token stops working at once: requests already sent finish, later ones are refused
	delete(t.token)
	t.token = ""
}

// Stops every run (closing the window, installing an update).
agents_stop_all :: proc() {
	for t in agent_state.threads do if t.running {
		agent_stop(t)
		_ = os.process_kill(t.process)
	}
}

// Drains what the CLIs printed; called every frame.
agent_tick :: proc() {
	if !agent_state.choice_loaded {
		agent_state.choice = Agent_Kind(clamp(settings.agent_choice, 0, len(Agent_Kind) - 1))
		agent_state.choice_loaded = true
	}
	if agent_state.pending != "" {
		p := agent_state.pending
		agent_state.pending = ""
		agent_send_now(p)
		delete(p)
	}
	sync.mutex_lock(&agent_state.mutex)
	lines := make([]Agent_Line, len(agent_state.lines), context.temp_allocator)
	copy(lines, agent_state.lines[:])
	clear(&agent_state.lines)
	sync.mutex_unlock(&agent_state.mutex)
	for l in lines {
		t := l.thread
		if l.eof {
			agent_finished(t)
			continue
		}
		agent_parse(t, l.line)
		delete(l.line)
	}
	for t in agent_state.threads {
		if t.running && t.stopping && time.since(t.stop_at) > 0 do _ = os.process_kill(t.process)
	}
	agent_share_tick()
	titles_take()
}

@(private = "file")
agent_finished :: proc(t: ^Agent_Thread) {
	if !t.running do return
	st, _ := os.process_wait(t.process, 2 * time.Second)
	t.running = false
	t.seconds = time.duration_seconds(time.since(t.started))
	delete(t.token)
	t.token = ""
	// a session the CLI no longer has (it never finished, or it was cleaned up): the next
	// request starts a fresh one
	if t.state != .Done {
		if data, err := os.read_entire_file(t.err_path, context.temp_allocator); err == nil && strings.contains(string(data), "No conversation found") {
			delete(t.session)
			t.session = ""
		}
	}
	switch {
	case t.stopping:
		t.state = .Stopped
	case t.state == .Working:
		// no result line: it failed before answering; its stderr says why
		msg := fmt.tprintf("%s stopped without an answer (exit code %d)", AGENT_KIND_NAMES[t.agent], st.exit_code)
		if data, err := os.read_entire_file(t.err_path, context.temp_allocator); err == nil {
			tail := strings.trim_space(string(data))
			if len(tail) > 300 do tail = tail[len(tail) - 300:]
			if tail != "" do msg = fmt.tprintf("%s: %s", msg, tail)
		}
		agent_fail(t, agent_sign_in_hint(t.agent, msg))
	}
	app_log("agent: %s %v after %.0f s", AGENT_KIND_NAMES[t.agent], t.state, t.seconds)
	session_touch(t)
	agent_thread_save(t)
	if t.state == .Done do agent_title_request(t)
}

agent_sign_in_hint :: proc(kind: Agent_Kind, msg: string) -> string {
	low := strings.to_lower(msg, context.temp_allocator)
	if strings.contains(low, "log in") || strings.contains(low, "login") || strings.contains(low, "not authenticated") || strings.contains(low, "sign in") || strings.contains(low, "api key") {
		cmds := [Agent_Kind]string{.Claude = "claude", .Codex = "codex login", .Gemini = "gemini"}
		return fmt.tprintf("%s\nRun `%s` in Terminal once to sign in, then try again.", msg, cmds[kind])
	}
	return msg
}

@(private = "file")
add_text :: proc(t: ^Agent_Thread, text: string) {
	s := strings.trim_space(text)
	if s == "" do return
	// the panel draws plain text: markdown's bold and heading marks go
	s, _ = strings.remove_all(s, "**", context.temp_allocator)
	s, _ = strings.replace_all(s, "\n### ", "\n", context.temp_allocator)
	s, _ = strings.replace_all(s, "\n## ", "\n", context.temp_allocator)
	append(&t.items, Run_Item{kind = .Text, text = strings.clone(s)})
}

@(private = "file")
add_tool :: proc(t: ^Agent_Thread, name: string) {
	tool := strings.trim_prefix(strings.trim_prefix(name, "mcp__agentic-design__"), "agentic-design__")
	t.tools += 1
	if n := len(t.items); n > 0 && t.items[n - 1].kind == .Tool && t.items[n - 1].text == tool {
		t.items[n - 1].count += 1
		return
	}
	append(&t.items, Run_Item{kind = .Tool, text = strings.clone(tool), count = 1})
}

// One line of the CLI's JSON stream.
agent_parse :: proc(t: ^Agent_Thread, line: string) {
	v, err := json.parse_string(line, .JSON, true, context.temp_allocator)
	if err != nil do return
	o, _ := v.(json.Object)
	typ := string(o["type"].(json.String) or_else "")
	switch t.agent {
	case .Claude:
		if s, ok := o["session_id"].(json.String); ok && string(s) != "" && string(s) != t.session {
			delete(t.session)
			t.session, t.sess_of = strings.clone(string(s)), .Claude
		}
		switch typ {
		case "assistant":
			msg, _ := o["message"].(json.Object)
			content, _ := msg["content"].(json.Array)
			for c in content {
				co, _ := c.(json.Object)
				switch string(co["type"].(json.String) or_else "") {
				case "text": add_text(t, string(co["text"].(json.String) or_else ""))
				case "tool_use": add_tool(t, string(co["name"].(json.String) or_else ""))
				}
			}
		case "result":
			t.cost = f64(o["total_cost_usd"].(json.Float) or_else 0)
			if o["is_error"].(json.Boolean) or_else false {
				msg := string(o["result"].(json.String) or_else "")
				if msg == "" {
					if errs, ok := o["errors"].(json.Array); ok && len(errs) > 0 do msg = string(errs[0].(json.String) or_else "")
				}
				if msg == "" && t.err_path != "" {
					if data, err := os.read_entire_file(t.err_path, context.temp_allocator); err == nil do msg = strings.trim_space(string(data))
				}
				if strings.contains(msg, "No conversation found") {
					delete(t.session)
					t.session = ""
					msg = "The agent's earlier conversation was not found; send the request again to start a fresh one."
				}
				agent_fail(t, agent_sign_in_hint(.Claude, msg if msg != "" else "the request failed"))
			} else if t.state == .Working {
				t.state = .Done
			}
		}
	case .Gemini:
		switch typ {
		case "init":
			if s, ok := o["session_id"].(json.String); ok && string(s) != "" {
				delete(t.session)
				t.session, t.sess_of = strings.clone(string(s)), .Gemini
			}
		case "message":
			if string(o["role"].(json.String) or_else "") != "assistant" do break
			text := string(o["content"].(json.String) or_else "")
			n := len(t.items)
			if (o["delta"].(json.Boolean) or_else false) && t.delta && n > 0 && t.items[n - 1].kind == .Text {
				joined := strings.concatenate({t.items[n - 1].text, text})
				delete(t.items[n - 1].text)
				t.items[n - 1].text = joined
			} else if strings.trim_space(text) != "" {
				append(&t.items, Run_Item{kind = .Text, text = strings.clone(text)})
			}
			t.delta = true
		case "tool_use":
			t.delta = false
			add_tool(t, string(o["tool_name"].(json.String) or_else ""))
		case "tool_result":
			if string(o["status"].(json.String) or_else "") == "error" {
				e, _ := o["error"].(json.Object)
				agent_fail(t, string(e["message"].(json.String) or_else "a tool call failed"))
				t.state = .Working
			}
		case "error":
			if string(o["severity"].(json.String) or_else "") == "error" {
				agent_fail(t, agent_sign_in_hint(.Gemini, string(o["message"].(json.String) or_else "error")))
				t.state = .Working
			}
		case "result":
			if string(o["status"].(json.String) or_else "") == "error" {
				e, _ := o["error"].(json.Object)
				agent_fail(t, agent_sign_in_hint(.Gemini, string(e["message"].(json.String) or_else "the request failed")))
			} else if t.state == .Working {
				t.state = .Done
			}
		}
	case .Codex:
		item, _ := o["item"].(json.Object)
		itype := string(item["type"].(json.String) or_else "")
		switch typ {
		case "thread.started":
			delete(t.session)
			t.session, t.sess_of = strings.clone(string(o["thread_id"].(json.String) or_else "")), .Codex
		case "item.started":
			if itype == "mcp_tool_call" do add_tool(t, string(item["tool"].(json.String) or_else ""))
		case "item.completed":
			switch itype {
			case "agent_message": add_text(t, string(item["text"].(json.String) or_else ""))
			case "mcp_tool_call":
				if string(item["status"].(json.String) or_else "") == "failed" {
					e, _ := item["error"].(json.Object)
					agent_fail(t, string(e["message"].(json.String) or_else "a tool call failed"))
					t.state = .Working // the turn goes on
				}
			}
		case "turn.completed":
			if t.state == .Working do t.state = .Done
		case "turn.failed", "error":
			e, _ := o["error"].(json.Object)
			msg := string(e["message"].(json.String) or_else (o["message"].(json.String) or_else "the request failed"))
			agent_fail(t, agent_sign_in_hint(.Codex, msg))
		}
	}
}

// ---------------------------------------------------------------- the window's side

// The run a request belongs to ("run" next to "method", from the MCP server's AGENTIC_RUN).
// ok is false when it names a run that ended or never was: the request is refused.
agent_run_of :: proc(obj: json.Object) -> (t: ^Agent_Thread, ok: bool) {
	token, has := obj["run"].(json.String)
	if !has || token == "" do return nil, true
	for th in agent_state.threads do if th.running && th.token != "" && th.token == string(token) do return th, true
	return nil, false
}

// Before a request of a run: its second and later changes to a document join the first
// one's undo step.
agent_request_begin :: proc(t: ^Agent_Thread, path: string) -> (saved: bool) {
	saved = undo_suppressed
	agent_state.in_run = t
	if t != nil && t.touched[path] do undo_suppressed = true
	return
}

agent_request_end :: proc(t: ^Agent_Thread, path, method: string, ok: bool, saved: bool) {
	undo_suppressed = saved
	agent_state.in_run = nil
	// a request on the dashboard that made (or opened) a file: the thread goes on there
	if t != nil && ok && method == "open" && t.key == "" && app.tab >= 0 && app.file_path != "" {
		for o, i in agent_state.threads {
			if o != t && o.key != "" && same_file(o.key, app.file_path) && !o.running {
				for it in o.items do run_item_free(it)
				delete(o.items)
				delete(o.key)
				delete(o.session)
				ordered_remove(&agent_state.threads, i)
				free(o)
				break
			}
		}
		delete(t.key)
		t.key = strings.clone(app.file_path)
		t.shown = true
	}
	if t != nil && ok && mcp_edits(method) && method != "undo" && method != "redo" && method != "save" {
		if path != "" && !t.touched[path] do t.touched[strings.clone(path)] = true
	}
}

// The user changed a document by hand: an agent's next change there is a new undo step.
agent_user_edit :: proc(path: string) {
	if agent_state.in_run != nil do return
	for t in agent_state.threads do if path in t.touched do delete_key(&t.touched, path)
}

// Undoes the last run's changes to the document shown (the undo step it made).
agent_undo_last :: proc(t: ^Agent_Thread) {
	if t.running || !(app.file_path in t.touched) do return
	undo()
	delete_key(&t.touched, app.file_path)
	t.undone = true
	agent_thread_save(t)
}

// ---------------------------------------------------------------- history

// Each document's conversations are kept in Application Support/Agentic Design/threads/
// <hash of its path>/: index.json (the current one, every session's title, agent and time,
// and the attached context) and <sid>.json per session (its items and the CLI's session).
// Never in the .pen: shared files must not carry private chats.
@(private = "file")
thread_dir :: proc(key: string) -> string {
	return fmt.tprintf("%s/threads/%016x", support_dir(), hash.fnv64a(transmute([]u8)key))
}

@(private = "file")
history_on :: proc() -> bool {
	return !pf.quiet || os.get_env("AGENTIC_AGENT_INPUT", context.temp_allocator) != ""
}

// The current session in the list, newest first.
session_touch :: proc(t: ^Agent_Thread) {
	now := time.now()._nsec / 1_000_000_000
	for &s, i in t.sessions {
		if s.sid != t.sid do continue
		s.time, s.agent = now, t.agent
		// to the top
		si := s
		ordered_remove(&t.sessions, i)
		inject_at(&t.sessions, 0, si)
		return
	}
	first := ""
	for it in t.items do if it.kind == .User {
		first = it.text
		break
	}
	inject_at(&t.sessions, 0, Session_Info{sid = strings.clone(t.sid), title = strings.clone(t.title if t.title != "" else first), agent = t.agent, time = now})
}

agent_thread_save :: proc(t: ^Agent_Thread) {
	if !history_on() do return
	dir := thread_dir(t.key)
	_ = fs_mkdir_all(dir)
	// the index
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"key":`)
	engine.json_write_string(&b, t.key)
	strings.write_string(&b, `,"current":`)
	engine.json_write_string(&b, t.sid)
	strings.write_string(&b, `,"context":[`)
	for c, i in t.attached {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"path":`)
		engine.json_write_string(&b, c.path)
		fmt.sbprintf(&b, `,"folder":%v}}`, c.folder)
	}
	strings.write_string(&b, `],"sessions":[`)
	for s, i in t.sessions {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"sid":`)
		engine.json_write_string(&b, s.sid)
		strings.write_string(&b, `,"title":`)
		engine.json_write_string(&b, s.title)
		fmt.sbprintf(&b, `,"agent":"%v","time":%d}}`, s.agent, s.time)
	}
	strings.write_string(&b, "]}\n")
	_ = fs_write(fmt.tprintf("%s/index.json", dir), strings.to_string(b))
	if t.sid == "" do return
	// the session
	b = strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"agent":"%v","session":`, t.sess_of)
	engine.json_write_string(&b, t.session)
	strings.write_string(&b, `,"title":`)
	engine.json_write_string(&b, t.title)
	fmt.sbprintf(&b, `,"undone":%v,"items":[`, t.undone)
	first := max(len(t.items) - 200, 0) // the last 200
	for it, i in t.items[first:] {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"kind":"%v","count":%d,"marks":%d,"image":`, it.kind, it.count, it.marks)
		engine.json_write_string(&b, it.image)
		if it.notes != "" {
			strings.write_string(&b, `,"notes":`)
			engine.json_write_string(&b, it.notes)
		}
		if it.ctx != "" {
			strings.write_string(&b, `,"context":`)
			engine.json_write_string(&b, it.ctx)
		}
		strings.write_string(&b, `,"text":`)
		engine.json_write_string(&b, it.text)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}\n")
	_ = fs_write(fmt.tprintf("%s/%s.json", dir, t.sid), strings.to_string(b))
}

@(private = "file")
agent_kind_of :: proc(s: string) -> Agent_Kind {
	switch s {
	case "Codex": return .Codex
	case "Gemini": return .Gemini
	}
	return .Claude
}

@(private = "file")
session_clear :: proc(t: ^Agent_Thread) {
	for it in t.items do run_item_free(it)
	clear(&t.items)
	delete(t.session)
	t.session = ""
	delete(t.title)
	t.title = ""
	delete(t.sid)
	t.sid = ""
	t.undone, t.delta = false, false
	t.state = .Idle
	t.scroll = 0
}

// Loads session `sid` of the thread into it (its items and the CLI's session).
@(private = "file")
session_load :: proc(t: ^Agent_Thread, sid: string) -> bool {
	data, err := fs_read(fmt.tprintf("%s/%s.json", thread_dir(t.key), sid), context.temp_allocator)
	if err != nil do return false
	v, perr := json.parse_string(string(data), .JSON, true, context.temp_allocator)
	if perr != nil do return false
	o, _ := v.(json.Object)
	session_clear(t)
	t.sid = strings.clone(sid)
	t.session = strings.clone(string(o["session"].(json.String) or_else ""))
	t.sess_of = agent_kind_of(string(o["agent"].(json.String) or_else ""))
	t.title = strings.clone(string(o["title"].(json.String) or_else ""))
	t.undone = o["undone"].(json.Boolean) or_else false
	items, _ := o["items"].(json.Array)
	for iv in items {
		io, _ := iv.(json.Object)
		kind: Run_Item_Kind
		switch string(io["kind"].(json.String) or_else "") {
		case "User": kind = .User
		case "Text": kind = .Text
		case "Tool": kind = .Tool
		case "Error": kind = .Error
		}
		append(&t.items, Run_Item{kind = kind, text = strings.clone(string(io["text"].(json.String) or_else "")), count = int(io["count"].(json.Float) or_else 1), image = strings.clone(string(io["image"].(json.String) or_else "")), marks = int(io["marks"].(json.Float) or_else 0), notes = strings.clone(string(io["notes"].(json.String) or_else "")), ctx = strings.clone(string(io["context"].(json.String) or_else ""))})
	}
	if len(t.items) > 0 do t.state = .Done
	return true
}

agent_thread_load :: proc(t: ^Agent_Thread) {
	dir := thread_dir(t.key)
	data, err := fs_read(fmt.tprintf("%s/index.json", dir), context.temp_allocator)
	if err != nil {
		thread_migrate(t)
		return
	}
	v, perr := json.parse_string(string(data), .JSON, true, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if string(o["key"].(json.String) or_else "") != t.key do return
	ctx, _ := o["context"].(json.Array)
	for cv in ctx {
		co, _ := cv.(json.Object)
		append(&t.attached, Context_Item{path = strings.clone(string(co["path"].(json.String) or_else "")), folder = co["folder"].(json.Boolean) or_else false})
	}
	sess, _ := o["sessions"].(json.Array)
	for sv in sess {
		so, _ := sv.(json.Object)
		append(&t.sessions, Session_Info{sid = strings.clone(string(so["sid"].(json.String) or_else "")), title = strings.clone(string(so["title"].(json.String) or_else "")), agent = agent_kind_of(string(so["agent"].(json.String) or_else "")), time = i64(so["time"].(json.Float) or_else 0)})
	}
	if cur := string(o["current"].(json.String) or_else ""); cur != "" do session_load(t, cur)
}

// 0.3.0 and 0.3.1 kept one thread per document in threads/<hash>.json: it becomes the first
// session (the old file stays, unused).
@(private = "file")
thread_migrate :: proc(t: ^Agent_Thread) {
	old := fmt.tprintf("%s.json", thread_dir(t.key))
	data, err := fs_read(old, context.temp_allocator)
	if err != nil do return
	v, perr := json.parse_string(string(data), .JSON, true, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if string(o["key"].(json.String) or_else "") != t.key do return
	sid := strings.clone(random_token()[:12], context.temp_allocator)
	dir := thread_dir(t.key)
	_ = fs_mkdir_all(dir)
	_ = fs_write(fmt.tprintf("%s/%s.json", dir, sid), string(data))
	if !session_load(t, sid) do return
	first := ""
	for it in t.items do if it.kind == .User {
		first = it.text
		break
	}
	append(&t.sessions, Session_Info{sid = strings.clone(sid), title = strings.clone(first), agent = t.sess_of, time = time.now()._nsec / 1_000_000_000})
	agent_thread_save(t)
}

// "New session": the current one stays in the list; the next request starts a fresh one.
agent_session_new :: proc(t: ^Agent_Thread) {
	if t.running do return
	agent_thread_save(t)
	session_clear(t)
	agent_thread_save(t)
}

// Opens an earlier session again; the next request resumes the CLI's session.
agent_session_resume :: proc(t: ^Agent_Thread, sid: string) {
	if t.running || sid == t.sid do return
	agent_thread_save(t)
	if session_load(t, sid) {
		t.shown = true
		agent_thread_save(t)
	}
}

// Forgets every conversation (Settings, Agents); the attached context stays.
agent_history_clear :: proc() {
	for t in agent_state.threads do if !t.running {
		session_clear(t)
		for s in t.sessions {
			delete(s.sid)
			delete(s.title)
		}
		clear(&t.sessions)
		t.shown = false
	}
	dir := fmt.tprintf("%s/threads", support_dir())
	if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for e in entries {
			if sub, serr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator); serr == nil {
				for f in sub do if f.name != "index.json" do _ = os.remove(f.fullpath)
			}
		}
	}
	for t in agent_state.threads do agent_thread_save(t)
}

// ---------------------------------------------------------------- context

agent_context_add :: proc(t: ^Agent_Thread, path: string, folder: bool) {
	for c in t.attached do if same_file(c.path, path) do return
	append(&t.attached, Context_Item{path = strings.clone(path), folder = folder})
	agent_thread_save(t)
}

agent_context_remove :: proc(t: ^Agent_Thread, i: int) {
	if i < 0 || i >= len(t.attached) do return
	delete(t.attached[i].path)
	ordered_remove(&t.attached, i)
	agent_thread_save(t)
}

// ---------------------------------------------------------------- titles

// After a session's first answer, its agent names it in a few words (a short run of the same
// CLI with no tools), in the background.
agent_title_request :: proc(t: ^Agent_Thread) {
	if t.title != "" || t.sid == "" || len(os.get_env("AGENTIC_AGENT_NO_TITLES", context.temp_allocator)) > 0 do return
	cli := agent_cli(t.agent)
	if cli == "" do return
	first := ""
	for it in t.items do if it.kind == .User {
		first = it.text
		break
	}
	if first == "" do return
	ask := fmt.tprintf("Write a title of 3 to 6 words for a design conversation that starts with this request. Answer with the title only, no quotes.\n\nRequest: %s", first)
	args := make([dynamic]string, context.allocator)
	switch t.agent {
	case .Claude: append(&args, cli, "-p", "--model", "haiku", "--tools", "", "--strict-mcp-config", "--setting-sources", "user", ask)
	case .Codex: append(&args, cli, "exec", "--skip-git-repo-check", "--sandbox", "read-only", "-C", t.run_dir, ask)
	case .Gemini: append(&args, cli, "-m", "flash-lite", "-p", ask)
	}
	Job :: struct {
		args:   [dynamic]string,
		thread: ^Agent_Thread,
		sid:    string,
		dir:    string,
		token:  string,
	}
	// everything the thread uses is its own copy (the arguments were temporary strings)
	for &a in args do a = strings.clone(a)
	j := new(Job)
	j^ = {args, t, strings.clone(t.sid), strings.clone(t.run_dir), strings.clone(random_token())}
	thread.create_and_start_with_data(j, proc(data: rawptr) {
			context = app_context()
			j := (^Job)(data)
			defer {
				for a in j.args do delete(a)
				delete(j.args)
				delete(j.dir)
				delete(j.token)
				free(j)
				free_all(context.temp_allocator)
			}
			r, w, perr := os.pipe()
			if perr != nil do return
			p, serr := os.process_start({command = j.args[:], env = agent_env(j.token), working_dir = j.dir, stdout = w})
			os.close(w)
			if serr != nil {
				os.close(r)
				return
			}
			out := strings.builder_make()
			buf: [4096]u8
			for {
				n, err := os.read(r, buf[:])
				if n <= 0 || err != nil do break
				strings.write_bytes(&out, buf[:n])
			}
			os.close(r)
			_, _ = os.process_wait(p, 30 * time.Second)
			// the last non-empty line is the answer (Codex prints its log before it)
			lines := strings.split_lines(strings.to_string(out), context.temp_allocator)
			title := ""
			for i := len(lines) - 1; i >= 0; i -= 1 {
				l := strings.trim(strings.trim_space(lines[i]), "\"'*#")
				if l != "" && !strings.has_prefix(l, "tokens used") && len(l) < 90 {
					title = l
					break
				}
			}
			title = strings.clone(title) // (it points into `out`)
			strings.builder_destroy(&out)
			if title == "" {
				delete(j.sid)
				return
			}
			sync.mutex_lock(&agent_state.mutex)
			append(&agent_state.titles, Agent_Title{j.thread, j.sid, title})
			sync.mutex_unlock(&agent_state.mutex)
			platform_wake()
		}, app_context(), self_cleanup = true)
}

// Titles that came back (agent_tick).
@(private = "file")
titles_take :: proc() {
	sync.mutex_lock(&agent_state.mutex)
	got := make([]Agent_Title, len(agent_state.titles), context.temp_allocator)
	copy(got, agent_state.titles[:])
	clear(&agent_state.titles)
	sync.mutex_unlock(&agent_state.mutex)
	for g in got {
		t := g.thread
		for &s in t.sessions do if s.sid == g.sid {
			delete(s.title)
			s.title = strings.clone(g.title)
		}
		if t.sid == g.sid {
			delete(t.title)
			t.title = strings.clone(g.title)
		}
		agent_thread_save(t)
		delete(g.sid)
		delete(g.title)
	}
}

// ---------------------------------------------------------------- socket (tests)

// {"action": "state" | "context_add" {path, folder} | "context_remove" {index} |
//  "session_new" | "session_resume" {sid} | "annotate" {active, tool}}: the thread of what
// the window shows.
api_agent :: proc(b: ^strings.Builder, params: json.Object) -> string {
	t := agent_current()
	switch string(params["action"].(json.String) or_else "state") {
	case "state":
	case "context_add": agent_context_add(t, engine.absolute_path(string(params["path"].(json.String) or_else "")), params["folder"].(json.Boolean) or_else false)
	case "context_remove": agent_context_remove(t, int(params["index"].(json.Float) or_else -1))
	case "session_new": agent_session_new(t)
	case "choose":
		for k in Agent_Kind do if fmt.tprintf("%v", k) == string(params["agent"].(json.String) or_else "") do agent_choose(k)
		if m, ok := params["model"].(json.String); ok do agent_set_model(agent_state.choice, string(m))
		if e, ok := params["effort"].(json.String); ok do agent_set_effort(agent_state.choice, string(e))
	case "session_resume": agent_session_resume(t, string(params["sid"].(json.String) or_else ""))
	case "mode": set_editor_mode(.Agent if string(params["mode"].(json.String) or_else "") == "agent" else .Design)
	case "annotate":
		annot.active = params["active"].(json.Boolean) or_else true
		set_editor_mode(.Agent if annot.active else .Design) // marks are drawn in Agent mode
		if tool, ok := params["tool"].(json.String); ok {
			for k in Mark_Tool do if strings.to_lower(MARK_TOOL_NAMES[k], context.temp_allocator) == string(tool) do annot.tool = k
		}
	case: return "action: state, context_add, context_remove, session_new, session_resume, choose or annotate"
	}
	strings.write_string(b, `{"key":`)
	engine.json_write_string(b, t.key)
	strings.write_string(b, `,"sid":`)
	engine.json_write_string(b, t.sid)
	strings.write_string(b, `,"title":`)
	engine.json_write_string(b, t.title)
	fmt.sbprintf(b, `,"state":"%v","running":%v,"marks":%d,"annotating":%v,"mode":"%v","agent":"%v","model":%s,"effort":%s,"items":%d,"context":[`, t.state, t.running, annotations_count(), annotations_active(), editor_mode, agent_state.choice, json_quote(agent_model_of(agent_state.choice).id), json_quote(agent_effort_of(agent_state.choice)), len(t.items))
	for c, i in t.attached {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"path":`)
		engine.json_write_string(b, c.path)
		fmt.sbprintf(b, `,"folder":%v}}`, c.folder)
	}
	strings.write_string(b, `],"sessions":[`)
	for s, i in t.sessions {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"sid":`)
		engine.json_write_string(b, s.sid)
		strings.write_string(b, `,"title":`)
		engine.json_write_string(b, s.title)
		fmt.sbprintf(b, `,"agent":"%v"}}`, s.agent)
	}
	strings.write_string(b, "]}")
	return ""
}
