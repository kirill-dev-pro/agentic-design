package agentic_design

import "base:intrinsics"
import "base:runtime"
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

// An image on the system clipboard as PNG bytes (a screenshot, an image copied from a page
// or Preview): PNG as it is, TIFF converted. nil when there is none.
clipboard_image_png :: proc(allocator := context.allocator) -> []u8 {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil do return nil
	bytes_of :: proc(d: ^NS.Data, allocator: runtime.Allocator) -> []u8 {
		n := int(intrinsics.objc_send(NS.UInteger, d, "length"))
		p := intrinsics.objc_send(rawptr, d, "bytes")
		if n <= 0 || p == nil do return nil
		out := make([]u8, n, allocator)
		copy(out, ([^]u8)(p)[:n])
		return out
	}
	if d := intrinsics.objc_send(^NS.Data, pb, "dataForType:", NS.AT("public.png")); d != nil do return bytes_of(d, allocator)
	if d := intrinsics.objc_send(^NS.Data, pb, "dataForType:", NS.AT("public.tiff")); d != nil {
		rep := intrinsics.objc_send(^Bitmap_Image_Rep, Bitmap_Image_Rep, "imageRepWithData:", d)
		if rep == nil do return nil
		png := intrinsics.objc_send(^NS.Data, rep, "representationUsingType:properties:", NS.UInteger(4), NS.id(nil)) // NSBitmapImageFileTypePNG
		if png != nil do return bytes_of(png, allocator)
	}
	return nil
}

// A file copied in Finder: its path ("" when the clipboard holds none).
clipboard_file_path :: proc() -> string {
	pb := intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
	if pb == nil do return ""
	s := intrinsics.objc_send(^NS.String, pb, "stringForType:", NS.AT("public.file-url"))
	if s == nil do return ""
	u := intrinsics.objc_send(^NS.URL, NS.URL, "URLWithString:", s)
	if u == nil do return ""
	path := intrinsics.objc_send(^NS.String, u, "path")
	if path == nil do return ""
	return path->odinString()
}

@(objc_class = "NSBitmapImageRep")
Bitmap_Image_Rep :: struct {
	using _: NS.Object,
}
