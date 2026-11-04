#+build !js
package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// agentic-design              open the editor with the default document
// agentic-design <file.pen>   open the editor with a document
// agentic-design mcp          run the MCP server over stdio (starts the editor if needed)
// agentic-design --version    print the version
// agentic-design cloud-vectors <vectors.json>   run the cloud protocol's test vectors
// agentic-design font-instance <font> <tag=value>... <out.ttf>
//                             write a static instance of a variable font (to check the
//                             instancer against fontTools)
main :: proc() {
	if len(os.args) > 1 && (os.args[1] == "--version" || os.args[1] == "version") {
		fmt.println(VERSION)
		return
	}
	if len(os.args) > 1 && os.args[1] == "mcp" {
		mcp_main()
		return
	}
	if len(os.args) > 3 && os.args[1] == "cloud-diff" {
		cloud_diff_main(os.args[2], os.args[3], len(os.args) > 4 && os.args[4] == "-v")
		return
	}
	if len(os.args) > 2 && os.args[1] == "cloud-vectors" {
		cloud_vectors_main(os.args[2])
		return
	}
	if len(os.args) > 3 && os.args[1] == "font-instance" {
		font_instance_main(os.args[2], os.args[3:len(os.args) - 1], os.args[len(os.args) - 1])
		return
	}
	path := os.args[1] if len(os.args) > 1 else default_document_path()
	app_main(path)
}

// <repo>/designs/untitled.pen next to the build directory, or for the installed app a
// scratch file in Application Support (made on first launch; no folder the system asks
// permission for).
default_document_path :: proc() -> string {
	if bundle_path() != "" {
		path := fmt.aprintf("%s/untitled.pen", support_dir())
		if !os.exists(path) {
			_ = os.make_directory_all(support_dir())
			_ = os.write_entire_file(path, "{\n  \"version\": \"2.21\",\n  \"children\": []\n}\n")
		}
		return path
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return "untitled.pen"
	return fmt.aprintf("%s/designs/untitled.pen", os.dir(os.dir(exe)))
}

font_instance_main :: proc(in_path: string, settings: []string, out_path: string) {
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", in_path)
		os.exit(1)
	}
	axes := make([dynamic]engine.Var_Axis)
	for s in settings {
		i := strings.index_byte(s, '=')
		if i < 0 do continue
		v, _ := strconv.parse_f32(s[i + 1:])
		append(&axes, engine.Var_Axis{s[:i], v})
	}
	out, ok := engine.varfont_instance(data, 0, axes[:])
	if !ok {
		fmt.eprintln("not a TrueType variable font")
		os.exit(1)
	}
	_ = os.write_entire_file(out_path, out)
}

// agentic-design cloud-vectors <vectors.json>: runs the protocol's test vectors (cloud-ops.md §8)
// through engine.ops_apply and the .pen serializer; prints one line per vector, exits 1 on a failure.
cloud_vectors_main :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	root, perr := json.parse(data, .JSON, false, context.allocator)
	if perr != nil {
		fmt.eprintln("not JSON:", path)
		os.exit(1)
	}
	failed := 0
	vectors, _ := root.(json.Object)["vectors"].(json.Array)
	for vv in vectors {
		v, _ := vv.(json.Object)
		name := string(v["name"].(json.String) or_else "?")
		doc: engine.Document
		engine.doc_load(&doc, string(v["start"].(json.String) or_else ""))
		state: engine.Cloud_State
		if s, ok := v["start_sorts"].(json.Object); ok do for id, k in s do state.sorts[strings.clone(id)] = strings.clone(string(k.(json.String) or_else ""))
		batches := make(map[string]json.Array)
		if c, ok := v["clients"].(json.Object); ok {
			for _, list in c do for b in list.(json.Array) or_else nil {
				bo, _ := b.(json.Object)
				batches[string(bo["batch"].(json.String) or_else "")] = bo["ops"].(json.Array) or_else nil
			}
		}
		expect, _ := v["expect"].(json.Object)
		problems := make([dynamic]string)
		seq := 0
		for bid in v["server_order"].(json.Array) or_else nil {
			id := string(bid.(json.String) or_else "")
			ops := make([dynamic]engine.Op)
			for o in batches[id] {
				op, ok := engine.op_parse(o)
				if !ok do append(&problems, fmt.aprintf("%s: an op does not parse", id))
				append(&ops, op)
			}
			res := engine.ops_apply(&doc, &state, ops[:])
			want_nack := string(expect["nacks"].(json.Object)[id].(json.String) or_else "") if expect["nacks"] != nil else ""
			if res.ok {
				seq += 1
				if want_nack != "" do append(&problems, fmt.aprintf("%s: acked, expected nack %s", id, want_nack))
				if a, has := expect["acks"].(json.Object)[id]; has && int(a.(json.Float) or_else 0) != seq do append(&problems, fmt.aprintf("%s: seq %d, expected %v", id, seq, a))
				want_skip := 0
				if sk, has := expect["skipped"].(json.Object)[id]; has do want_skip = len(sk.(json.Array) or_else nil)
				if len(res.skipped) != want_skip do append(&problems, fmt.aprintf("%s: %d ops skipped, expected %d", id, len(res.skipped), want_skip))
			} else if want_nack != res.reason {
				append(&problems, fmt.aprintf("%s: nack %s, expected %s", id, res.reason, want_nack if want_nack != "" else "an ack"))
			}
		}
		engine.pages_prune(&doc)
		got := engine.doc_serialize(&doc)
		want := string(expect["pen"].(json.String) or_else "")
		if got != want do append(&problems, "the .pen differs from the expected bytes")
		if len(problems) == 0 {
			fmt.println("ok  ", name)
		} else {
			failed += 1
			fmt.println("FAIL", name)
			for p in problems do fmt.println("     ", p)
			if got != want {
				_ = os.write_entire_file(fmt.tprintf("/tmp/cloud-vector-%d.got.pen", failed), transmute([]u8)got)
				_ = os.write_entire_file(fmt.tprintf("/tmp/cloud-vector-%d.want.pen", failed), transmute([]u8)want)
			}
		}
	}
	fmt.printfln("%d of %d vectors pass", len(vectors) - failed, len(vectors))
	if failed > 0 do os.exit(1)
}

// agentic-design cloud-diff <before.pen> <after.pen> [-v]: the ops that turn one state into the
// other (engine.ops_diff), applied to the first (engine.ops_apply); passes when the result saves
// to the same bytes as the second. -v prints the ops.
cloud_diff_main :: proc(before_path, after_path: string, verbose: bool) {
	load :: proc(path: string, doc: ^engine.Document) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil || !engine.doc_load(doc, string(data)) {
			fmt.eprintln("cannot load", path)
			os.exit(2)
		}
	}
	before, after: engine.Document
	load(before_path, &before)
	load(after_path, &after)
	state: engine.Cloud_State
	engine.sorts_assign(&before, &state)
	ops := engine.ops_diff(before.nodes[:], after.nodes[:], before.header[:], after.header[:], &state, include_derived = true)
	if verbose {
		for op in ops {
			b := strings.builder_make(context.temp_allocator)
			engine.op_write(&b, op)
			fmt.println(strings.to_string(b))
		}
	}
	// the receiver: the wire form parsed again, applied to its own copy of `before`
	wire := make([dynamic]engine.Op)
	for op in ops {
		b := strings.builder_make(context.temp_allocator)
		engine.op_write(&b, op)
		v, _ := json.parse_string(strings.to_string(b), .JSON, false, context.allocator)
		parsed, ok := engine.op_parse(v)
		if !ok {
			fmt.println("FAIL an op does not parse back:", strings.to_string(b))
			os.exit(1)
		}
		append(&wire, parsed)
	}
	recv: engine.Document
	load(before_path, &recv)
	rstate: engine.Cloud_State
	engine.sorts_assign(&recv, &rstate)
	res := engine.ops_apply(&recv, &rstate, wire[:])
	if !res.ok {
		fmt.println("FAIL the batch was refused:", res.reason)
		os.exit(1)
	}
	engine.pages_prune(&recv)
	engine.pages_prune(&after)
	got, want := engine.doc_serialize(&recv), engine.doc_serialize(&after)
	if got != want {
		_ = os.write_entire_file("/tmp/cloud-diff.got.pen", transmute([]u8)got)
		_ = os.write_entire_file("/tmp/cloud-diff.want.pen", transmute([]u8)want)
		fmt.printfln("FAIL %d ops; the result differs (/tmp/cloud-diff.got.pen vs want.pen)", len(ops))
		os.exit(1)
	}
	fmt.printfln("ok   %d ops, %d skipped; the result saves byte-identical", len(ops), len(res.skipped))
}
