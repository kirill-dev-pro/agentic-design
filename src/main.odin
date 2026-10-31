package agentic_design

import "core:fmt"
import "core:os"

// agentic-design              open the editor with the default document
// agentic-design <file.pen>   open the editor with a document
// agentic-design mcp          run the MCP server over stdio (starts the editor if needed)
main :: proc() {
	if len(os.args) > 1 && os.args[1] == "mcp" {
		mcp_main()
		return
	}
	path := os.args[1] if len(os.args) > 1 else default_document_path()
	app_main(path)
}

// <repo>/designs/untitled.pen, next to the build directory.
default_document_path :: proc() -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return "untitled.pen"
	return fmt.aprintf("%s/designs/untitled.pen", os.dir(os.dir(exe)))
}
