package agentic_design

import "engine"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// agentic-design              open the editor with the default document
// agentic-design <file.pen>   open the editor with a document
// agentic-design mcp          run the MCP server over stdio (starts the editor if needed)
// agentic-design --version    print the version
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
