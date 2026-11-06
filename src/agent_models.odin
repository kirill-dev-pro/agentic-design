#+build !js
package agentic_design

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The model and reasoning effort each agent runs with (app-ui.pen "4 · Agent picker"):
// chosen in the picker, kept in settings.json, passed to the CLI (agent_args_model).
//
//   Claude Code: --model fable | opus | sonnet | haiku, --effort low … max  (claude --help)
//   Codex:       -m <slug>, -c model_reasoning_effort="…"; the models and the efforts each
//                takes come from Codex's own list (~/.codex/models_cache.json)
//   Gemini CLI:  -m <model>; it has no effort option
// "" leaves the CLI's own setting.

Agent_Model :: struct {
	id, name, hint: string,
	efforts:        []string,
}

CLAUDE_EFFORTS := [?]string{"low", "medium", "high", "xhigh", "max"}

@(private = "file")
codex_cache: struct {
	models:  [dynamic]Agent_Model,
	read_at: time.Time,
}

// Codex's models (visible ones, in its order), read again at most every 30 s.
@(private = "file")
codex_models :: proc() -> []Agent_Model {
	if codex_cache.read_at != {} && time.since(codex_cache.read_at) < 30 * time.Second do return codex_cache.models[:]
	codex_cache.read_at = time.now()
	for m in codex_cache.models {
		delete(m.id)
		delete(m.name)
		delete(m.hint)
		for e in m.efforts do delete(e)
		delete(m.efforts)
	}
	clear(&codex_cache.models)
	home, _ := os.user_home_dir(context.temp_allocator)
	data, err := os.read_entire_file(fmt.tprintf("%s/.codex/models_cache.json", home), context.temp_allocator)
	if err != nil do return codex_cache.models[:]
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil do return codex_cache.models[:]
	root, _ := v.(json.Object)
	list, _ := root["models"].(json.Array)
	Entry :: struct {
		m:        Agent_Model,
		priority: f64,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	for item in list {
		o, ok := item.(json.Object)
		if !ok || string(o["visibility"].(json.String) or_else "list") != "list" do continue
		m := Agent_Model {
			id   = strings.clone(string(o["slug"].(json.String) or_else "")),
			name = strings.clone(string(o["display_name"].(json.String) or_else "")),
			hint = strings.clone(string(o["description"].(json.String) or_else "")),
		}
		efforts := make([dynamic]string)
		if levels, lok := o["supported_reasoning_levels"].(json.Array); lok {
			for l in levels {
				if lo, ook := l.(json.Object); ook do append(&efforts, strings.clone(string(lo["effort"].(json.String) or_else "")))
			}
		}
		m.efforts = efforts[:]
		if m.id == "" {
			delete(m.id)
			delete(m.name)
			delete(m.hint)
			delete(efforts)
			continue
		}
		append(&entries, Entry{m, f64(o["priority"].(json.Float) or_else 99)})
	}
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.priority < b.priority})
	for e in entries do append(&codex_cache.models, e.m)
	return codex_cache.models[:]
}

// The models the picker lists for an agent: the CLI's own setting first.
agent_models :: proc(k: Agent_Kind) -> []Agent_Model {
	out := make([dynamic]Agent_Model, context.temp_allocator)
	switch k {
	case .Claude:
		append(&out, Agent_Model{"", "Default", "Your Claude Code setting", CLAUDE_EFFORTS[:]})
		append(&out, Agent_Model{"fable", "Fable 5.1", "Most capable, for the hardest work", CLAUDE_EFFORTS[:]})
		append(&out, Agent_Model{"opus", "Opus 5.5", "For big redesigns", CLAUDE_EFFORTS[:]})
		append(&out, Agent_Model{"sonnet", "Sonnet 5.5", "Balanced", CLAUDE_EFFORTS[:]})
		append(&out, Agent_Model{"haiku", "Haiku 5.5", "Fastest, for small edits", CLAUDE_EFFORTS[:]})
	case .Codex:
		cm := codex_models()
		all := cm[0].efforts if len(cm) > 0 else nil
		append(&out, Agent_Model{"", "Default", "Your Codex setting", all})
		append(&out, ..cm)
	case .Gemini:
		append(&out, Agent_Model{"", "Default", "Your Gemini CLI setting", nil})
	}
	return out[:]
}

agent_model_of :: proc(k: Agent_Kind) -> Agent_Model {
	models := agent_models(k)
	for m in models do if m.id == settings.agent_model[int(k)] do return m
	return models[0]
}

agent_effort_of :: proc(k: Agent_Kind) -> string {
	e := settings.agent_effort[int(k)]
	if e == "" do return ""
	m := agent_model_of(k)
	return e if slice.contains(m.efforts, e) else ""
}

agent_set_model :: proc(k: Agent_Kind, id: string) {
	delete(settings.agent_model[int(k)])
	settings.agent_model[int(k)] = strings.clone(id)
	settings_save()
}

agent_set_effort :: proc(k: Agent_Kind, e: string) {
	delete(settings.agent_effort[int(k)])
	settings.agent_effort[int(k)] = strings.clone(e)
	settings_save()
}

effort_title :: proc(e: string) -> string {
	switch e {
	case "xhigh": return "XHigh"
	case "": return ""
	}
	return fmt.tprintf("%s%s", strings.to_upper(e[:1], context.temp_allocator), e[1:])
}

// "Sonnet 5.5 · High", "" when both are the CLI's own.
agent_model_label :: proc(k: Agent_Kind) -> string {
	m := agent_model_of(k)
	e := effort_title(agent_effort_of(k))
	name := m.name if m.id != "" else ""
	switch {
	case name != "" && e != "": return fmt.tprintf("%s · %s", name, e)
	case name != "": return name
	case e != "": return e
	}
	return ""
}

// The CLI options for the chosen model and effort.
agent_args_model :: proc(k: Agent_Kind, args: ^[dynamic]string) {
	m := agent_model_of(k).id
	e := agent_effort_of(k)
	switch k {
	case .Claude:
		if m != "" do append(args, "--model", m)
		if e != "" do append(args, "--effort", e)
	case .Codex:
		if m != "" do append(args, "-m", m)
		if e != "" do append(args, "-c", fmt.tprintf(`model_reasoning_effort="%s"`, e))
	case .Gemini:
		if m != "" do append(args, "-m", m)
	}
}

agent_choose :: proc(k: Agent_Kind) {
	agent_state.choice = k
	agent_state.choice_loaded = true
	settings.agent_choice = int(k)
	settings_save()
}
