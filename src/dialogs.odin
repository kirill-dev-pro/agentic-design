#+build !js
package agentic_design

import "core:fmt"

// The file pickers behind Open, Import font, Import library, Place image, the agent's
// context and exports. What each one does with the answer is here, for every system; the
// system's own panel is two calls, system_open_panel and system_save_panel
// (dialogs_darwin.odin, dialogs_linux.odin, dialogs_windows.odin). A quiet (test) window
// never shows a panel: tests and the fuzzer cannot wait on a modal one.

Open_Panel :: struct {
	multiple: bool,
	folders:  bool, // folders instead of files
	prompt:   string, // the confirm button ("" leaves the system's)
	message:  string, // a line above the list ("" for none)
	start:    string, // the folder it opens in ("" lets the system choose)
}

// Opens .pen files chosen in the system panel, each in a tab.
open_file_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode")
		return
	}
	for path in system_open_panel({multiple = true}) {
		if !open_in_tab(path) do set_status("%s is not a .pen document", path)
	}
}

// "Import font": font files chosen in the system panel go into the document's fonts folder.
import_font_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; drop a font file instead")
		return
	}
	import_font_files(system_open_panel({multiple = true}))
}

// "Import library": .pen files chosen in the system panel become imported libraries.
import_library_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; use the set_libraries tool")
		return
	}
	for path in system_open_panel({multiple = true}) {
		if alias, ok := library_add(path); ok do set_status("Imported %s as \"%s\"", path, alias)
	}
}

// "Place image": the system open panel, then the images go to the canvas centre.
place_image_dialog :: proc() {
	if pf.quiet {
		set_status("File dialogs are disabled in quiet (test) mode; drop a file instead")
		return
	}
	at := to_page(canvas_center())
	for path in system_open_panel({multiple = true}) {
		if place_image(path, at) do at += {24, 24}
	}
}

// Context for the agent (agent_input.odin): folders or files chosen in the system panel.
ask_context_paths :: proc(folders: bool) -> []string {
	if pf.quiet do return nil
	return system_open_panel({multiple = true, folders = folders, prompt = "Attach", message = "The agent may read and search what you attach, for this design."})
}

// The system save panel, opened in export_start_dir with `name` filled in. `types` limits
// the extensions (the first is added when the name has none of them); nil for a folder
// name. Cancel returns false. A quiet window answers its default folder.
ask_save_path :: proc(name: string, types: []string) -> (path: string, ok: bool) {
	if pf.quiet {
		file := name if len(types) == 0 else fmt.tprintf("%s.%s", name, types[0])
		return fmt.tprintf("%s/%s", downloads_dir(), file), true
	}
	return system_save_panel(name, types, export_start_dir())
}

// The system open panel choosing a folder (several layers exported at once).
ask_folder :: proc() -> (dir: string, ok: bool) {
	if pf.quiet do return downloads_dir(), true
	dirs := system_open_panel({folders = true, prompt = "Export", message = "Choose a folder: each layer is saved as a file named after it.", start = export_start_dir()})
	if len(dirs) == 0 do return "", false
	return dirs[0], true
}
