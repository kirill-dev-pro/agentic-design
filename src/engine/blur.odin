package engine

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import nvg "../nanovg"
import nvgl "../nanovg/gl"

// Layer blur and background blur. NanoVG draws a frame when it ends, so a blur is made
// before the frame that shows it: the layer (or everything painted before it) is drawn
// into an offscreen buffer, blurred there by a two-pass Gaussian shader, and the frame
// then draws that image in place of the layer, or under the layer's fill. A blur of
// radius r is a Gaussian with σ = r / 2, as pen.dev renders and exports it (CSS blur(r/2)).

Blur_View :: struct {
	xf:   nvg.Matrix, // page → frame coordinates (those of the frame's BeginFrame)
	dpr:  f32, // frame coordinates → framebuffer pixels
	clip: [4]f32, // the visible part, frame coordinates
	fb:   [2]i32, // framebuffer size
	bg:   nvg.Color, // behind everything: the canvas or the export background
	order: []int, // layers in paint order (a blur behind another is made first)
}

Blur_Result :: struct {
	image: int,
	rect:  [4]f32, // frame coordinates
}

Blur_Buffer :: struct {
	a, b: nvgl.framebuffer,
	w, h: int,
}

blur_buffers: [dynamic]Blur_Buffer
blur_layer: map[int]Blur_Result // layer blur, drawn instead of the layer
blur_backdrop: map[int]Blur_Result // background blur, drawn under the layer's fill
blur_active: bool // draw_node_tree uses the results (canvas and screenshots only)
blur_self: int // the layer being drawn into its own buffer
blur_stop: int // capturing a backdrop: drawing stops at this layer
blur_stopped: bool

blur_gl: struct {
	prog:                     u32,
	vao, vbo:                 u32,
	tex, dir, sigma, radius:  i32,
	failed:                   bool,
}

// Prepares every blur visible in `view`, in paint order (a blur behind another one is
// ready by the time the one in front captures it).
blur_prepare :: proc(view: Blur_View) {
	clear(&blur_layer)
	clear(&blur_backdrop)
	count := 0
	for uid in view.order {
		n, _ := doc_find_uid(current, uid)
		if n == nil do continue
		for e in n.effects[:n.neffects] {
			if !e.enabled || e.blur <= 0 || (e.kind != .Blur && e.kind != .Background_Blur) do continue
			back := e.kind == .Background_Blur
			if r, ok := blur_render(view, n, back, e.blur, count); ok {
				if back do blur_backdrop[uid] = r
				else do blur_layer[uid] = r
				count += 1
			}
		}
	}
	if count > 0 do nvgl.BindFramebuffer(nil)
}

blur_buffer :: proc(i, w, h: int) -> ^Blur_Buffer {
	for len(blur_buffers) <= i do append(&blur_buffers, Blur_Buffer{})
	b := &blur_buffers[i]
	if b.w != w || b.h != h {
		if b.w > 0 {
			nvgl.DeleteFramebuffer(&b.a)
			nvgl.DeleteFramebuffer(&b.b)
		}
		b.a = nvgl.CreateFramebuffer(renderer, w, h, {})
		b.b = nvgl.CreateFramebuffer(renderer, w, h, {})
		b.w, b.h = w, h
	}
	return b
}

blur_render :: proc(view: Blur_View, n: ^Node, back: bool, radius: f32, index: int) -> (res: Blur_Result, ok: bool) {
	if !blur_shader() do return
	xf := view.xf
	scale := math.sqrt(abs(xf[0] * xf[3] - xf[1] * xf[2])) * view.dpr
	sigma := radius / 2 * scale // in framebuffer pixels
	if sigma < 0.3 do return
	// the layer's box as drawn, in framebuffer pixels, with room for the blur
	corners, _ := node_corners(n)
	lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
	for c in corners {
		q := [2]f32{xf[0] * c.x + xf[2] * c.y + xf[4], xf[1] * c.x + xf[3] * c.y + xf[5]} * view.dpr
		lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
	}
	margin := math.ceil(3 * sigma)
	lo, hi = lo - margin, hi + margin
	// only what can be seen (and the margin the blur reaches in from outside it)
	cl := view.clip
	lo.x, lo.y = max(lo.x, cl[0] * view.dpr - margin, 0), max(lo.y, cl[1] * view.dpr - margin, 0)
	hi.x = min(hi.x, (cl[0] + cl[2]) * view.dpr + margin, f32(view.fb.x))
	hi.y = min(hi.y, (cl[1] + cl[3]) * view.dpr + margin, f32(view.fb.y))
	lo, hi = {math.floor(lo.x), math.floor(lo.y)}, {math.ceil(hi.x), math.ceil(hi.y)}
	if hi.x - lo.x < 1 || hi.y - lo.y < 1 do return
	// wide blurs work at a lower resolution: σ stays within 6 buffer pixels
	down := max(1, sigma / 6)
	w := min(int(math.ceil((hi.x - lo.x) / down)), 2048)
	h := min(int(math.ceil((hi.y - lo.y) / down)), 2048)
	buf := blur_buffer(index, w, h)

	vg := renderer
	nvgl.BindFramebuffer(&buf.a)
	gl.Viewport(0, 0, i32(w), i32(h))
	if back do gl.ClearColor(view.bg.r, view.bg.g, view.bg.b, 1)
	else do gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, f32(w), f32(h), 1)
	nvg.Scale(vg, f32(w) / (hi.x - lo.x), f32(h) / (hi.y - lo.y))
	nvg.Translate(vg, -lo.x, -lo.y)
	nvg.Scale(vg, view.dpr, view.dpr)
	nvg.Transform(vg, xf[0], xf[1], xf[2], xf[3], xf[4], xf[5])
	// cull to the buffer's part of the page
	inv: nvg.Matrix
	nvg.TransformInverse(&inv, xf)
	a := xform_point(Xform(inv), lo / view.dpr)
	b := xform_point(Xform(inv), hi / view.dpr)
	saved_cull, saved_active := cull_rect, blur_active
	cull_rect = {min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
	blur_active = true // blurs made earlier show in this one
	defer blur_active = saved_active
	if back {
		// everything painted before the layer
		blur_stop, blur_stopped = n.uid, false
		for cu in children_of(current, 0) {
			if is_hidden(cu) do continue
			if c, _ := doc_find_uid(current, cu); c != nil do draw_node_tree(vg, c, 1, 0)
		}
		blur_stop, blur_stopped = 0, false
	} else {
		// the layer alone, turned and mirrored as the layers around it are
		if m, tr := node_transform_of_parent(n); tr do nvg.Transform(vg, m[0], m[1], m[2], m[3], m[4], m[5])
		blur_self = n.uid
		draw_node_tree(vg, n, 1, 0)
		blur_self = 0
	}
	cull_rect = saved_cull
	nvg.EndFrame(vg)

	s := sigma * f32(w) / (hi.x - lo.x)
	blur_pass(buf.a.texture, buf.b.fbo, w, h, {1 / f32(w), 0}, s)
	blur_pass(buf.b.texture, buf.a.fbo, w, h, {0, 1 / f32(h)}, s)
	return {image = buf.a.image, rect = {lo.x / view.dpr, lo.y / view.dpr, (hi.x - lo.x) / view.dpr, (hi.y - lo.y) / view.dpr}}, true
}

// The turns and flips of the layers around n (not its own).
node_transform_of_parent :: proc(n: ^Node) -> (Xform, bool) {
	p, _ := doc_find_uid(current, n.parent)
	if p == nil do return XFORM_IDENTITY, false
	return node_transform(p)
}

// One direction of the Gaussian: src texture → dst framebuffer.
blur_pass :: proc(src: u32, dst: u32, w, h: int, dir: [2]f32, sigma: f32) {
	g := &blur_gl
	gl.BindFramebuffer(gl.FRAMEBUFFER, dst)
	gl.Viewport(0, 0, i32(w), i32(h))
	gl.Disable(gl.BLEND)
	gl.Disable(gl.STENCIL_TEST)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.UseProgram(g.prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, src)
	gl.Uniform1i(g.tex, 0)
	gl.Uniform2f(g.dir, dir.x, dir.y)
	gl.Uniform1f(g.sigma, sigma)
	gl.Uniform1i(g.radius, i32(math.ceil(3 * sigma)))
	gl.BindVertexArray(g.vao)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
	gl.BindVertexArray(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	gl.Enable(gl.BLEND)
}

BLUR_VERT :: `#version 150 core
in vec2 pos;
out vec2 uv;
void main() {
	uv = pos * 0.5 + 0.5;
	gl_Position = vec4(pos, 0.0, 1.0);
}
`

BLUR_FRAG :: `#version 150 core
uniform sampler2D tex;
uniform vec2 dir;
uniform float sigma;
uniform int radius;
in vec2 uv;
out vec4 color;
void main() {
	vec4 sum = vec4(0.0);
	float total = 0.0;
	for (int i = -radius; i <= radius; i++) {
		float w = exp(-float(i * i) / (2.0 * sigma * sigma));
		sum += texture(tex, uv + dir * float(i)) * w;
		total += w;
	}
	color = sum / total;
}
`

// Compiles the blur shader once; false (and blurs are skipped) if the driver refuses it.
blur_shader :: proc() -> bool {
	g := &blur_gl
	if g.prog != 0 do return true
	if g.failed do return false
	prog, ok := gl.load_shaders_source(BLUR_VERT, BLUR_FRAG)
	if !ok {
		fmt.eprintln("blur shader failed to compile")
		g.failed = true
		return false
	}
	g.prog = prog
	g.tex = gl.GetUniformLocation(prog, "tex")
	g.dir = gl.GetUniformLocation(prog, "dir")
	g.sigma = gl.GetUniformLocation(prog, "sigma")
	g.radius = gl.GetUniformLocation(prog, "radius")
	quad := [8]f32{-1, -1, 1, -1, -1, 1, 1, 1}
	gl.GenVertexArrays(1, &g.vao)
	gl.BindVertexArray(g.vao)
	gl.GenBuffers(1, &g.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad), &quad, gl.STATIC_DRAW)
	loc := u32(gl.GetAttribLocation(prog, "pos"))
	gl.EnableVertexAttribArray(loc)
	gl.VertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0)
	gl.BindVertexArray(0)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
	return true
}

// The blurred layer, in place of the layer (frame coordinates, so the transform is reset).
draw_blurred_layer :: proc(vg: ^nvg.Context, r: Blur_Result, alpha: f32) {
	nvg.Save(vg)
	defer nvg.Restore(vg)
	nvg.ResetTransform(vg)
	nvg.GlobalAlpha(vg, alpha)
	nvg.BeginPath(vg)
	nvg.Rect(vg, r.rect[0], r.rect[1], r.rect[2], r.rect[3])
	nvg.FillPaint(vg, nvg.ImagePattern(r.rect[0], r.rect[1], r.rect[2], r.rect[3], 0, r.image, 1))
	nvg.Fill(vg)
}

// Fills the current path with the blurred backdrop, fixed in frame coordinates whatever
// the current transform.
fill_backdrop :: proc(vg: ^nvg.Context, n: ^Node) {
	if !blur_active do return
	r, ok := blur_backdrop[n.uid]
	if !ok do return
	p := nvg.ImagePattern(r.rect[0], r.rect[1], r.rect[2], r.rect[3], 0, r.image, 1)
	cur, inv: nvg.Matrix
	nvg.CurrentTransform(vg, &cur)
	nvg.TransformInverse(&inv, cur)
	nvg.TransformMultiply(&p.xform, inv)
	nvg.FillPaint(vg, p)
	nvg.Fill(vg)
}
