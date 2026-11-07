#+build windows
package agentic_design

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "engine"
import "vendor:glfw"

// The Windows side of what macOS does in *_darwin.odin: the shell (open, Explorer, the
// Recycle Bin), the user's locale, the Credential Manager and the window's HWND for WebGPU.

@(private = "file")
wide :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s, context.temp_allocator)
}

// The app window's handle (dialogs are modal to it).
platform_hwnd :: proc() -> win.HWND {
	return glfw.GetWin32Window(pf.window) if pf.window != nil else nil
}

// Opens a web address in the default browser. Test windows open nothing.
open_url :: proc(url: string) {
	if pf.quiet {
		set_status("Test window: not opening %s", url)
		return
	}
	win.ShellExecuteW(nil, wide("open"), wide(url), nil, nil, win.SW_SHOWNORMAL)
}

// Shows `path` selected in an Explorer window.
reveal_in_finder :: proc(path: string) {
	if pf.quiet || path == "" do return
	p, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	win.ShellExecuteW(nil, wide("open"), wide("explorer.exe"), wide(fmt.tprintf("/select,\"%s\"", p)), nil, win.SW_SHOWNORMAL)
}

// Moves a file to the Recycle Bin, so it can be put back. Returns the error, if any.
move_to_trash :: proc(path: string) -> (trashed: string, err_text: string) {
	p, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	from := win.utf8_to_utf16(strings.concatenate({p, "\x00"}, context.temp_allocator), context.temp_allocator) // double-nul terminated
	op := win.SHFILEOPSTRUCTW {
		wFunc  = win.FO_DELETE,
		pFrom  = win.wstring(raw_data(from)),
		fFlags = win.FOF_ALLOWUNDO | win.FOF_NOCONFIRMATION | win.FOF_SILENT | win.FOF_NOERRORUI,
	}
	if r := win.SHFileOperationW(&op); r != 0 || op.fAnyOperationsAborted do return "", fmt.tprintf("the Recycle Bin refused (error %d)", r)
	return "", ""
}

foreign import kernel32 "system:Kernel32.lib"
@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(lpLocaleName: win.LPWSTR, cchLocaleName: i32) -> i32 ---
}

// The user's locale ("ru-RU", "en-US"), or "".
preferred_language :: proc() -> string {
	buf: [85]u16
	n := GetUserDefaultLocaleName(&buf[0], len(buf))
	if n <= 1 do return ""
	s, _ := win.utf16_to_utf8(buf[:n - 1], context.temp_allocator)
	return s
}

// ---------------------------------------------------------------- secrets

// The cloud's token in the Credential Manager (generic credentials, one per service and
// account), readable only by the signed-in user.

@(private = "file")
CREDENTIALW :: struct {
	Flags:              win.DWORD,
	Type:               win.DWORD,
	TargetName:         win.wstring,
	Comment:            win.wstring,
	LastWritten:        win.FILETIME,
	CredentialBlobSize: win.DWORD,
	CredentialBlob:     [^]u8,
	Persist:            win.DWORD,
	AttributeCount:     win.DWORD,
	Attributes:         rawptr,
	TargetAlias:        win.wstring,
	UserName:           win.wstring,
}
@(private = "file")
CRED_TYPE_GENERIC :: 1
@(private = "file")
CRED_PERSIST_LOCAL_MACHINE :: 2

foreign import advapi32 "system:Advapi32.lib"
@(private = "file", default_calling_convention = "system")
foreign advapi32 {
	CredReadW :: proc(TargetName: win.LPCWSTR, Type: win.DWORD, Flags: win.DWORD, Credential: ^^CREDENTIALW) -> win.BOOL ---
	CredWriteW :: proc(Credential: ^CREDENTIALW, Flags: win.DWORD) -> win.BOOL ---
	CredDeleteW :: proc(TargetName: win.LPCWSTR, Type: win.DWORD, Flags: win.DWORD) -> win.BOOL ---
	CredFree :: proc(Buffer: rawptr) ---
}

@(private = "file")
cred_target :: proc(service, account: string) -> win.wstring {
	return wide(fmt.tprintf("%s/%s", service, account))
}

keychain_get :: proc(service, account: string, allocator := context.allocator) -> string {
	cred: ^CREDENTIALW
	if !CredReadW(cred_target(service, account), CRED_TYPE_GENERIC, 0, &cred) do return ""
	defer CredFree(cred)
	return strings.clone(string(cred.CredentialBlob[:cred.CredentialBlobSize]), allocator)
}

keychain_set :: proc(service, account, label, secret: string) -> bool {
	cred := CREDENTIALW {
		Type               = CRED_TYPE_GENERIC,
		TargetName         = cred_target(service, account),
		Comment            = wide(label),
		CredentialBlobSize = win.DWORD(len(secret)),
		CredentialBlob     = raw_data(transmute([]u8)secret),
		Persist            = CRED_PERSIST_LOCAL_MACHINE,
		UserName           = wide(account),
	}
	return bool(CredWriteW(&cred, 0))
}

keychain_delete :: proc(service, account: string) {
	CredDeleteW(cred_target(service, account), CRED_TYPE_GENERIC, 0)
}

// This computer's name, for the cloud's device list.
device_name :: proc() -> string {
	name := os.get_env("COMPUTERNAME", context.temp_allocator)
	return name[:min(len(name), 80)] if name != "" else "Windows PC"
}

// ---------------------------------------------------------------- window

// The window's surface for WebGPU (Direct3D 12 or Vulkan behind wgpu).
platform_native_surface :: proc(window: glfw.WindowHandle) -> engine.Gpu_Surface {
	return {hwnd = glfw.GetWin32Window(window), hinstance = win.GetModuleHandleW(nil)}
}
