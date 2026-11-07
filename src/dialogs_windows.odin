#+build windows
package agentic_design

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// The open and save panels behind dialogs.odin on Windows: the shell's common item dialogs
// (IFileOpenDialog, IFileSaveDialog), modal to the app's window.

@(private = "file")
IID_IShellItem := &win.GUID{0x43826D1E, 0xE718, 0x42EE, {0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE}}

@(private = "file")
item_path :: proc(item: ^win.IShellItem) -> string {
	name: win.LPWSTR
	if item->GetDisplayName(.FILESYSPATH, &name) != win.S_OK || name == nil do return ""
	defer win.CoTaskMemFree(name)
	s, _ := win.wstring_to_utf8(win.wstring(name), -1, context.temp_allocator)
	p, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
	return p
}

@(private = "file")
set_folder :: proc(dialog: ^win.IFileDialog, dir: string) {
	if dir == "" do return
	item: ^win.IShellItem
	w := win.utf8_to_wstring(strings.clone(dir, context.temp_allocator), context.temp_allocator)
	if win.SHCreateItemFromParsingName(w, nil, IID_IShellItem, (^rawptr)(&item)) == win.S_OK {
		dialog->SetFolder(item)
		item->Release()
	}
}

@(private = "file")
com_ready :: proc() {
	@(static) done: bool
	if !done do win.CoInitializeEx(nil, .APARTMENTTHREADED)
	done = true
}

system_open_panel :: proc(p: Open_Panel) -> []string {
	com_ready()
	dialog: ^win.IFileOpenDialog
	if win.CoCreateInstance(win.CLSID_FileOpenDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileOpenDialog, (^rawptr)(&dialog)) != win.S_OK do return nil
	defer dialog->Release()
	opts: win.FILEOPENDIALOGOPTIONS
	dialog->GetOptions(&opts)
	opts |= win.FOS_FORCEFILESYSTEM
	if p.multiple do opts |= win.FOS_ALLOWMULTISELECT
	if p.folders do opts |= win.FOS_PICKFOLDERS
	dialog->SetOptions(opts)
	if p.prompt != "" do dialog->SetOkButtonLabel(win.utf8_to_wstring(p.prompt, context.temp_allocator))
	if p.message != "" do dialog->SetTitle(win.utf8_to_wstring(p.message, context.temp_allocator))
	set_folder(dialog, p.start)
	if dialog->Show(platform_hwnd()) != win.S_OK do return nil // cancelled
	items: ^win.IShellItemArray
	if dialog->GetResults(&items) != win.S_OK do return nil
	defer items->Release()
	n: win.DWORD
	items->GetCount(&n)
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< n {
		item: ^win.IShellItem
		if items->GetItemAt(i, &item) != win.S_OK do continue
		if path := item_path(item); path != "" do append(&out, path)
		item->Release()
	}
	return out[:]
}

system_save_panel :: proc(name: string, types: []string, start: string) -> (path: string, ok: bool) {
	com_ready()
	dialog: ^win.IFileSaveDialog
	if win.CoCreateInstance(win.CLSID_FileSaveDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileSaveDialog, (^rawptr)(&dialog)) != win.S_OK do return "", false
	defer dialog->Release()
	opts: win.FILEOPENDIALOGOPTIONS
	dialog->GetOptions(&opts)
	dialog->SetOptions(opts | win.FOS_FORCEFILESYSTEM | win.FOS_OVERWRITEPROMPT)
	if len(types) > 0 {
		specs := make([]win.COMDLG_FILTERSPEC, len(types), context.temp_allocator)
		for t, i in types {
			label := strings.to_upper(t, context.temp_allocator)
			specs[i] = {win.utf8_to_wstring(label, context.temp_allocator), win.utf8_to_wstring(fmt.tprintf("*.%s", t), context.temp_allocator)}
		}
		dialog->SetFileTypes(win.UINT(len(specs)), raw_data(specs))
		dialog->SetDefaultExtension(win.utf8_to_wstring(types[0], context.temp_allocator))
	}
	dialog->SetFileName(win.utf8_to_wstring(name, context.temp_allocator))
	set_folder(dialog, start)
	if dialog->Show(platform_hwnd()) != win.S_OK do return "", false
	item: ^win.IShellItem
	if dialog->GetResult(&item) != win.S_OK do return "", false
	defer item->Release()
	path = item_path(item)
	return path, path != ""
}
