#+build darwin
package agentic_design

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import "vendor:glfw"

// Trackpad gestures. GLFW only reports scrolling, and it scales trackpad deltas down,
// so the Cocoa view's scroll, magnify and smart-magnify handlers are replaced with
// ours. They run inside glfw.PollEvents on the main thread and accumulate into `gest`,
// which platform_poll hands to the frame state.

Gesture :: struct {
	scroll:  [2]f32, // precise (trackpad) delta in points, natural direction applied
	lines:   [2]f32, // mouse wheel notches
	magnify: f32, // pinch: relative change of scale this frame
	smart:   bool, // two-finger double tap
}

gest: Gesture

gestures_install :: proc() {
	view := glfw.GetCocoaView(pf.window)
	if view == nil do return
	cls := NS.object_getClass(NS.id(view))
	NS.class_replaceMethod(cls, intrinsics.objc_find_selector("scrollWheel:"), auto_cast gesture_scroll, "v@:@")
	NS.class_addMethod(cls, intrinsics.objc_find_selector("magnifyWithEvent:"), auto_cast gesture_magnify, "v@:@")
	NS.class_addMethod(cls, intrinsics.objc_find_selector("smartMagnifyWithEvent:"), auto_cast gesture_smart_magnify, "v@:@")
}

gesture_scroll :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = app_context()
	dx, dy := event->scrollingDelta()
	if event->hasPreciseScrollingDeltas() do gest.scroll += {f32(dx), f32(dy)}
	else do gest.lines += {f32(dx), f32(dy)}
}

gesture_magnify :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	gest.magnify += f32(intrinsics.objc_send(NS.Float, event, "magnification"))
}

gesture_smart_magnify :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	gest.smart = true
}

// Moves the gestures gathered during PollEvents into the per-frame input state.
gestures_collect :: proc() {
	pf.wheel += gest.lines
	pf.scroll += gest.scroll
	pf.magnify += gest.magnify
	pf.smart ||= gest.smart
	gest = {}
}

// Puts the window behind the others (used for test instances).
platform_order_back :: proc() {
	win := glfw.GetCocoaWindow(pf.window)
	if win != nil do intrinsics.objc_send(nil, win, "orderBack:", NS.id(nil))
}
