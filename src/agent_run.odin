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
}

AGENT_KIND_NAMES := [Agent_Kind]string {
	.Claude = "Claude Code",
	.Codex  = "Codex",
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
}

// ---------------------------------------------------------------- the CLIs

agent_cli :: proc(kind: Agent_Kind) -> string {
	// tests point these at a fake CLI that speaks the same stream
	override := "AGENTIC_AGENT_CLAUDE" if kind == .Claude else "AGENTIC_AGENT_CODEX"
	if p := os.get_env(override, context.temp_allocator); p != "" do return p
	home, _ := os.user_home_dir(context.temp_allocator)
	paths: []string
	if kind == .Claude {
		paths = {fmt.tprintf("%s/.local/bin/claude", home), "/opt/homebrew/bin/claude", "/usr/local/bin/claude", fmt.tprintf("%s/.claude/local/claude", home)}
	} else {
		paths = {"/opt/homebrew/bin/codex", "/usr/local/bin/codex", fmt.tprintf("%s/.local/bin/codex", home)}
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
		     name == "HTTPS_PROXY", name == "HTTP_PROXY", name == "NO_PROXY", name == "SSL_CERT_FILE":
			append(&env, kv)
		}
	}
	return env[:]
}

// Sends the prompt: a new run in the thread of what the window shows.
agent_send :: proc(prompt: string) {
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
	append(&t.items, Run_Item{kind = .User, text = strings.clone(text)})
	t.shown, t.scroll = true, 0
	t.agent = kind
	t.state = .Working
	t.started = time.now()
	t.cost, t.tools = 0, 0
	clear(&t.touched)
	delete(t.token)
	t.token = strings.clone(random_token())
	t.stopping = false

	// an empty working folder per thread: the agent has no files of the user's to look at
	dir := fmt.tprintf("%s/agent-runs/%016x", support_dir(), hash.fnv64a(transmute([]u8)t.key))
	_ = fs_mkdir_all(dir)
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
		append(&args, cli, "-p", "--output-format", "stream-json", "--verbose", "--mcp-config", cfg, "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__agentic-design__*", "--setting-sources", "user", "--append-system-prompt", guide)
		if resume != "" do append(&args, "--resume", resume)
		append(&args, sent)
	case .Codex:
		servers := fmt.tprintf(`mcp_servers={{"agentic-design"={{command=%s,args=["mcp"],env={{AGENTIC_PORT="%d",AGENTIC_NO_LAUNCH="1",AGENTIC_RUN="%s"}},default_tools_approval_mode="approve"}}}}`, json_quote(exe), port, t.token)
		append(&args, cli, "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-C", dir, "-c", servers, "-c", `approval_policy="never"`)
		if resume != "" do append(&args, "resume", resume)
		append(&args, fmt.tprintf("%s\n\nRequest: %s", guide, sent))
	}

	r, w, perr := os.pipe()
	if perr != nil {
		agent_fail(t, fmt.tprintf("could not start %s: %v", AGENT_KIND_NAMES[kind], perr))
		return
	}
	errf, _ := os.create(t.err_path)
	p, serr := os.process_start({command = args[:], env = agent_env(t.token), working_dir = dir, stdout = w, stderr = errf})
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
		}, self_cleanup = true)
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
}

@(private = "file")
agent_finished :: proc(t: ^Agent_Thread) {
	if !t.running do return
	st, _ := os.process_wait(t.process, 2 * time.Second)
	t.running = false
	t.seconds = time.duration_seconds(time.since(t.started))
	delete(t.token)
	t.token = ""
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
	agent_thread_save(t)
}

agent_sign_in_hint :: proc(kind: Agent_Kind, msg: string) -> string {
	low := strings.to_lower(msg, context.temp_allocator)
	if strings.contains(low, "log in") || strings.contains(low, "login") || strings.contains(low, "not authenticated") || strings.contains(low, "sign in") || strings.contains(low, "api key") {
		return fmt.tprintf("%s\nRun `%s` in Terminal once to sign in, then try again.", msg, "claude" if kind == .Claude else "codex login")
	}
	return msg
}

@(private = "file")
add_text :: proc(t: ^Agent_Thread, text: string) {
	s := strings.trim_space(text)
	if s == "" do return
	append(&t.items, Run_Item{kind = .Text, text = strings.clone(s)})
}

@(private = "file")
add_tool :: proc(t: ^Agent_Thread, name: string) {
	tool := strings.trim_prefix(name, "mcp__agentic-design__")
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
				agent_fail(t, agent_sign_in_hint(.Claude, string(o["result"].(json.String) or_else "the request failed")))
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
				for it in o.items do delete(it.text)
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

// Each thread is kept in Application Support/Agentic Design/threads/<hash of its key>.json
// (never in the .pen: shared files must not carry private chats).
@(private = "file")
thread_file :: proc(key: string) -> string {
	return fmt.tprintf("%s/threads/%016x.json", support_dir(), hash.fnv64a(transmute([]u8)key))
}

agent_thread_save :: proc(t: ^Agent_Thread) {
	if pf.quiet && os.get_env("AGENTIC_AGENT_INPUT", context.temp_allocator) == "" do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"key":`)
	engine.json_write_string(&b, t.key)
	fmt.sbprintf(&b, `,"agent":"%v","session":`, t.sess_of)
	engine.json_write_string(&b, t.session)
	fmt.sbprintf(&b, `,"undone":%v,"items":[`, t.undone)
	first := max(len(t.items) - 200, 0) // the last 200
	for it, i in t.items[first:] {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"kind":"%v","count":%d,"text":`, it.kind, it.count)
		engine.json_write_string(&b, it.text)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}\n")
	_ = fs_mkdir_all(fmt.tprintf("%s/threads", support_dir()))
	_ = fs_write(thread_file(t.key), strings.to_string(b))
}

agent_thread_load :: proc(t: ^Agent_Thread) {
	data, err := fs_read(thread_file(t.key), context.temp_allocator)
	if err != nil do return
	v, perr := json.parse_string(string(data), .JSON, true, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if string(o["key"].(json.String) or_else "") != t.key do return
	t.session = strings.clone(string(o["session"].(json.String) or_else ""))
	t.sess_of = .Codex if string(o["agent"].(json.String) or_else "") == "Codex" else .Claude
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
		append(&t.items, Run_Item{kind = kind, text = strings.clone(string(io["text"].(json.String) or_else "")), count = int(io["count"].(json.Float) or_else 1)})
	}
	if len(t.items) > 0 do t.state = .Done
}

// Forgets every thread (Settings, Agents).
agent_history_clear :: proc() {
	for t in agent_state.threads do if !t.running {
		clear(&t.items)
		delete(t.session)
		t.session = ""
		t.state = .Idle
		t.shown = false
	}
	dir := fmt.tprintf("%s/threads", support_dir())
	if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for e in entries do _ = os.remove(e.fullpath)
	}
}
