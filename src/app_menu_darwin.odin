package agentic_design

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// Additions to the application menu GLFW builds (About, Services, Hide, Quit):
// "What's New in Agentic Design…" under About (whats_new.odin). Its action is a method
// added to GLFW's application delegate, which is the item's target. Runs after glfwInit,
// once the menu exists.

app_menu_install :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	nsapp := NS.Application.sharedApplication()
	delegate := intrinsics.objc_send(^NS.Object, nsapp, "delegate")
	cls := NS.objc_lookUpClass("GLFWApplicationDelegate")
	main_menu := intrinsics.objc_send(^NS.Menu, nsapp, "mainMenu")
	if delegate == nil || cls == nil || main_menu == nil do return
	if intrinsics.objc_send(NS.Integer, main_menu, "numberOfItems") < 1 do return
	app_item := intrinsics.objc_send(^NS.MenuItem, main_menu, "itemAtIndex:", NS.Integer(0))
	app_menu := intrinsics.objc_send(^NS.Menu, app_item, "submenu")
	if app_menu == nil do return

	sel := NS.sel_registerName("agenticShowWhatsNew:")
	NS.class_addMethod(cls, sel, auto_cast menu_whats_new, "v@:@")
	item := NS.MenuItem.alloc()->initWithTitle(ns_string(WHATS_NEW_MENU_TITLE), sel, ns_string(""))
	item->autorelease()
	intrinsics.objc_send(nil, item, "setTarget:", delegate)
	// after "About Agentic Design" (index 0), when GLFW put it first
	at := NS.Integer(1) if intrinsics.objc_send(NS.Integer, app_menu, "numberOfItems") > 0 else NS.Integer(0)
	app_menu->insertItem(item, at)
}

WHATS_NEW_MENU_TITLE :: "What's New in " + APP_NAME + "…"

// Tests: finds the item in the application menu and performs it as a click would. False
// when it is not there.
app_menu_click_whats_new :: proc() -> bool {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	main_menu := intrinsics.objc_send(^NS.Menu, NS.Application.sharedApplication(), "mainMenu")
	if main_menu == nil || intrinsics.objc_send(NS.Integer, main_menu, "numberOfItems") < 1 do return false
	app_item := intrinsics.objc_send(^NS.MenuItem, main_menu, "itemAtIndex:", NS.Integer(0))
	app_menu := intrinsics.objc_send(^NS.Menu, app_item, "submenu")
	if app_menu == nil do return false
	i := intrinsics.objc_send(NS.Integer, app_menu, "indexOfItemWithTitle:", ns_string(WHATS_NEW_MENU_TITLE))
	if i < 0 do return false
	intrinsics.objc_send(nil, app_menu, "performActionForItemAtIndex:", i)
	return true
}

@(private = "file")
menu_whats_new :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	context = app_context()
	whats_new_show()
}

// Opens a web address in the default browser. Test windows open nothing.
open_url :: proc(url: string) {
	if pf.quiet {
		set_status("Test window: not opening %s", url)
		return
	}
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	u := intrinsics.objc_send(^NS.URL, NS.URL, "URLWithString:", ns_string(url))
	if u == nil do return
	ws := intrinsics.objc_send(^Workspace, Workspace, "sharedWorkspace")
	_ = intrinsics.objc_send(NS.BOOL, ws, "openURL:", u)
}

// The Mac's first preferred language ("ru-RU", "en"), or "".
preferred_language :: proc() -> string {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	langs := intrinsics.objc_send(^NS.Array, Locale, "preferredLanguages")
	if langs == nil || langs->count() == 0 do return ""
	first := langs->objectAs(0, ^NS.String)
	if first == nil do return ""
	return strings.clone(first->odinString(), context.temp_allocator)
}

@(objc_class = "NSLocale")
Locale :: struct {
	using _: NS.Object,
}
