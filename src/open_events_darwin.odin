package agentic_design

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// Documents opened from the system: a double-click or Open With in Finder, a file dropped
// on the Dock icon, `open file.pen` (decision 77). macOS sends them to the application
// delegate's application:openURLs:. GLFW's delegate has no such method, so AppKit fell
// back to NSDocumentController, which has no document class for the type and showed
// "Agentic Design cannot open files in the 'Pen document' format". The method is added to
// GLFW's delegate class before glfwInit, so that the files a launch was asked to open
// (delivered while GLFW finishes launching) are caught too.

install_open_handler :: proc() {
	cls := NS.objc_lookUpClass("GLFWApplicationDelegate")
	if cls == nil do return
	NS.class_addMethod(cls, NS.sel_registerName("application:openURLs:"), auto_cast app_open_urls, "v@:@@")
}

@(private = "file")
app_open_urls :: proc "c" (self: NS.id, cmd: NS.SEL, application: NS.id, urls: ^NS.Array) {
	context = app_context()
	if urls == nil do return
	for i in 0 ..< int(urls->count()) {
		url := urls->objectAs(NS.UInteger(i), ^NS.URL)
		if url == nil do continue
		// agentic-design://open?doc=<id>: a cloud document (the site's Open in app)
		if scheme := intrinsics.objc_send(^NS.String, url, "scheme"); scheme != nil && scheme->odinString() == "agentic-design" {
			if abs := intrinsics.objc_send(^NS.String, url, "absoluteString"); abs != nil do append(&pf.open_requests, strings.clone(abs->odinString()))
			continue
		}
		path := intrinsics.objc_send(^NS.String, url, "path")
		if path == nil do continue
		append(&pf.open_requests, strings.clone(path->odinString()))
	}
}

// Opens what the system asked for, each in a tab (or the tab that has it). Runs between
// frames.
handle_open_requests :: proc() {
	if len(pf.open_requests) == 0 do return
	defer {
		for p in pf.open_requests do delete(p)
		clear(&pf.open_requests)
	}
	for p in pf.open_requests {
		if strings.has_prefix(p, "agentic-design:") {
			cloud_open_url(p)
			continue
		}
		if !strings.has_suffix(strings.to_lower(p, context.temp_allocator), ".pen") {
			set_status("Not a .pen document: %s", p)
			continue
		}
		if !open_in_tab(p) do set_status("Could not read %s as a .pen document", p)
	}
}
