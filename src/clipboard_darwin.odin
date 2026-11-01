package agentic_design

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// Puts data of one type (a UTI such as "public.png" or "public.html") on the system
// clipboard; `text` adds a plain-text version beside it.
clipboard_set :: proc(data: []u8, uti: string, text := "") {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil do return
	_ = intrinsics.objc_send(NS.Integer, pb, "clearContents")
	d := NS.Data.alloc()->initWithBytes(data)
	t := NS.String.alloc()->initWithOdinString(uti)
	_ = intrinsics.objc_send(NS.BOOL, pb, "setData:forType:", d, t)
	if text != "" {
		s := NS.String.alloc()->initWithOdinString(text)
		_ = intrinsics.objc_send(NS.BOOL, pb, "setString:forType:", s, NS.AT("public.utf8-plain-text"))
	}
}
