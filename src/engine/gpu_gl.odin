#+build !js
package engine

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import nvg "../nanovg"
import nvgl "../nanovg/gl"

// The OpenGL 3.2 backend (see gpu.odin), on a desktop only. The host makes the GL
// context current on its window (GLFW does it here) before gpu_create.

when RENDERER == "gl" {

	Gpu_Surface :: struct {
		// loads GL functions by name (glfw.gl_set_proc_address)
		set_proc_address: gl.Set_Proc_Address_Type,
	}

	Target :: struct {
		image: int,
		w, h:  int,
		fb:    nvgl.framebuffer,
	}

	gpu_create :: proc(surface: Gpu_Surface) -> ^nvg.Context {
		gl.load_up_to(3, 2, surface.set_proc_address)
		return nvgl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	}

	gpu_destroy :: proc() {
		if renderer != nil do nvgl.Destroy(renderer)
	}

	@(private = "file")
	window_h: int // the window framebuffer's height (GL counts rows from the bottom)

	gpu_window_begin :: proc(w, h: i32, clear: nvg.Color) {
		window_h = int(h)
		nvgl.BindFramebuffer(nil)
		gl.Viewport(0, 0, w, h)
		gl.ClearColor(clear.r, clear.g, clear.b, clear.a)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	}

	gpu_present :: proc() {} // (the host swaps the GL buffers)

	target_make :: proc(w, h: int) -> Target {
		fb := nvgl.CreateFramebuffer(renderer, w, h, {})
		return {image = fb.image, w = w, h = h, fb = fb}
	}

	target_free :: proc(t: ^Target) {
		if t.w > 0 do nvgl.DeleteFramebuffer(&t.fb)
		t^ = {}
	}

	target_begin :: proc(t: ^Target, clear: nvg.Color) {
		nvgl.BindFramebuffer(&t.fb)
		gl.Viewport(0, 0, i32(t.w), i32(t.h))
		gl.ClearColor(clear.r, clear.g, clear.b, clear.a)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	}

	gpu_max_side :: proc() -> int {
		max_side: i32
		gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &max_side)
		return int(max_side)
	}

	gpu_allocated :: proc() -> int {
		return -1 // (OpenGL does not say)
	}

	gpu_trim :: proc() {
		if renderer != nil do nvgl.RecycleBuffers(renderer)
	}

	gpu_finish :: proc() {
		gl.Flush()
	}

	// Read in strips of 128 rows through one small pixel buffer. Read straight into
	// memory, the driver kept a 32 MB staging buffer after the first screenshot; through
	// a pixel buffer as large as the image, it kept that one (20 MB for a window-sized
	// shot) in its pool after deletion. GL's rows run bottom-up: each strip is copied
	// into the rows it is from the top.
	gpu_read :: proc(t: ^Target, x, y, w, h: int) -> []u8 {
		STRIP :: 128
		nvgl.BindFramebuffer(&t.fb if t != nil else nil)
		height := t.h if t != nil else window_h
		pixels := make([]u8, w * h * 4, context.temp_allocator)
		row := w * 4
		pbo: u32
		gl.GenBuffers(1, &pbo)
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, pbo)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		// a whole number of megabytes: the driver keeps a block per size it was asked
		// for, and image widths vary (one block per width came to 23 MB of shared memory
		// in a session)
		pbo_size := (STRIP * row + (1 << 20) - 1) / (1 << 20) * (1 << 20)
		gl_y := height - y - h // the rectangle's bottom row, in GL's rows
		for r0 := 0; r0 < h; r0 += STRIP {
			rows := min(STRIP, h - r0)
			gl.BufferData(gl.PIXEL_PACK_BUFFER, pbo_size, nil, gl.STREAM_READ)
			gl.ReadPixels(i32(x), i32(gl_y + r0), i32(w), i32(rows), gl.RGBA, gl.UNSIGNED_BYTE, nil)
			if src := gl.MapBuffer(gl.PIXEL_PACK_BUFFER, gl.READ_ONLY); src != nil {
				strip := ([^]u8)(src)[:rows * row]
				// GL row r0 + k counts from the bottom: it is row h - 1 - r0 - k from the top
				for k in 0 ..< rows do copy(pixels[(h - 1 - r0 - k) * row:][:row], strip[k * row:][:row])
				gl.UnmapBuffer(gl.PIXEL_PACK_BUFFER)
			}
		}
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
		gl.DeleteBuffers(1, &pbo)
		return pixels
	}

	gpu_blur :: proc(src, dst: ^Target, dir: [2]f32, sigma: f32) {
		g := &blur_gl
		if !blur_shader() do return
		gl.BindFramebuffer(gl.FRAMEBUFFER, dst.fb.fbo)
		gl.Viewport(0, 0, i32(dst.w), i32(dst.h))
		gl.Disable(gl.BLEND)
		gl.Disable(gl.STENCIL_TEST)
		gl.Disable(gl.SCISSOR_TEST)
		gl.Disable(gl.CULL_FACE)
		gl.UseProgram(g.prog)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, src.fb.texture)
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

	@(private = "file")
	blur_gl: struct {
		prog:                    u32,
		vao, vbo:                u32,
		tex, dir, sigma, radius: i32,
		failed:                  bool,
	}

	@(private = "file")
	BLUR_VERT :: `#version 150 core
in vec2 pos;
out vec2 uv;
void main() {
	uv = pos * 0.5 + 0.5;
	gl_Position = vec4(pos, 0.0, 1.0);
}
`

	@(private = "file")
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
	gpu_blur_ready :: proc() -> bool {
		return blur_shader()
	}

	@(private = "file")
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
}
