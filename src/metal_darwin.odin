package agentic_design

import "vendor:glfw"

// The window's content view hosting a CAMetalLayer, for the WebGPU renderer: wgpu draws
// into the layer, and its contents scale is the window's, so a Retina window shows the
// drawable pixel for pixel. objc_msgSend is called as plain C functions of the right
// types: Odin's Objective-C class lookup (`objc_find_class`) fails to link in this
// compiler build for classes outside its Foundation bindings.

foreign import objc "system:objc"

@(default_calling_convention = "c")
foreign objc {
	objc_getClass :: proc(name: cstring) -> rawptr ---
	sel_getUid :: proc(name: cstring) -> rawptr ---
	dlsym :: proc(handle: rawptr, name: cstring) -> rawptr ---
}

foreign import coregraphics "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign coregraphics {
	CGColorSpaceCreateWithName :: proc(name: rawptr) -> rawptr ---
	CGColorSpaceRelease :: proc(space: rawptr) ---
}

@(private = "file")
RTLD_DEFAULT :: rawptr(~uintptr(1)) // (void *)-2

platform_metal_layer :: proc(window: glfw.WindowHandle) -> rawptr {
	objc_msgSend := dlsym(RTLD_DEFAULT, "objc_msgSend") // (QuartzCore is linked with wgpu)
	send_id := cast(proc "c" (self, op: rawptr) -> rawptr)objc_msgSend
	send_ptr := cast(proc "c" (self, op: rawptr, v: rawptr))objc_msgSend
	send_bool := cast(proc "c" (self, op: rawptr, v: bool))objc_msgSend
	send_f64 := cast(proc "c" (self, op: rawptr, v: f64))objc_msgSend
	get_f64 := cast(proc "c" (self, op: rawptr) -> f64)objc_msgSend
	ns_window := rawptr(glfw.GetCocoaWindow(window))
	view := send_id(ns_window, sel_getUid("contentView"))
	layer := send_id(objc_getClass("CAMetalLayer"), sel_getUid("layer"))
	if view == nil || layer == nil do return nil
	send_f64(layer, sel_getUid("setContentsScale:"), get_f64(ns_window, sel_getUid("backingScaleFactor")))
	// the document's colours are sRGB (as in CSS and pen.dev): macOS converts them for the
	// display (a P3 laptop screen shows them as authored, not more saturated)
	if name := (^rawptr)(dlsym(RTLD_DEFAULT, "kCGColorSpaceSRGB")); name != nil {
		if cs := CGColorSpaceCreateWithName(name^); cs != nil {
			send_ptr(layer, sel_getUid("setColorspace:"), cs)
			CGColorSpaceRelease(cs)
		}
	}
	// a layer-hosting view: the layer first, then wantsLayer
	send_ptr(view, sel_getUid("setLayer:"), layer)
	send_bool(view, sel_getUid("setWantsLayer:"), true)
	return layer
}
