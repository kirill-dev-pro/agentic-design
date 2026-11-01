package engine

import "core:fmt"
import "core:strings"
import nvg "../nanovg"

// Image fills: files referenced relative to the .pen document, loaded into NanoVG on demand.

images: map[string]int // absolute path -> nanovg image (0 = failed)

image_resolve :: proc(url: string) -> string {
	if path_is_abs(url) do return url
	u := url
	if strings.has_prefix(u, "./") do u = u[2:]
	return fmt.tprintf("%s/%s", path_dir(current.path), u)
}

image_for :: proc(url: string) -> (img: int, w, h: int) {
	path := image_resolve(url)
	if cached, has := images[path]; has {
		img = cached
	} else {
		if data, ok := read_file(path, context.temp_allocator); ok do img = nvg.CreateImageMem(renderer, data, {})
		if img < 0 do img = 0
		images[strings.clone(path)] = img
	}
	if img > 0 do w, h = nvg.ImageSize(renderer, img)
	return
}

// Draws an image into the current path with cover/contain/stretch fitting.
image_fill :: proc(vg: ^nvg.Context, n: ^Node) -> bool {
	img, iw, ih := image_for(n.image_url)
	if img == 0 || iw == 0 || ih == 0 do return false
	w, h := f32(iw), f32(ih)
	dw, dh := n.w, n.h
	switch n.image_mode {
	case .Cover:
		s := max(n.w / w, n.h / h)
		dw, dh = w * s, h * s
	case .Contain:
		s := min(n.w / w, n.h / h)
		dw, dh = w * s, h * s
	case .Stretch:
	}
	dx, dy := n.x + (n.w - dw) / 2, n.y + (n.h - dh) / 2
	nvg.FillPaint(vg, nvg.ImagePattern(dx, dy, dw, dh, 0, img, 1))
	nvg.Fill(vg)
	return true
}

IMAGE_EXTS := [?]string{".png", ".jpg", ".jpeg", ".gif", ".bmp", ".psd", ".tga"}

is_image_file :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for e in IMAGE_EXTS do if strings.has_suffix(lower, e) do return true
	return false
}

