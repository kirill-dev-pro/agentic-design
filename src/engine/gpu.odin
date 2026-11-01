package engine

// The GPU under the engine. Paths, images and text are drawn through NanoVG, whose
// backend turns them into GPU work. This is the rest, which NanoVG has no call for:
// creating the context on a backend, drawing into offscreen targets, the blur pass,
// reading pixels back, limits and giving memory back. Nothing outside the backend files
// (gpu_<backend>.odin and src/nanovg/<backend>) calls the GPU API itself.
//
// One backend is compiled in, chosen with -define:RENDERER=...:
//   gl    OpenGL 3.2 core (gpu_gl.odin, src/nanovg/gl), the default
//
// Every backend provides:
//
//   Gpu_Surface             what the host gives to create the context on its window
//   Target                  an offscreen colour buffer with a stencil; `image` is the
//                           NanoVG image to draw it with, `w`, `h` its size in pixels
//   gpu_create(surface) -> ^nvg.Context
//                           creates the NanoVG context (antialiased, stencil strokes)
//   gpu_destroy()
//   gpu_window_begin(w, h, clear)
//                           the next frame draws into the window's framebuffer of w × h
//                           pixels, cleared to `clear`
//   target_make(w, h) -> Target, target_free(^Target)
//   target_begin(^Target, clear)
//                           the next frame draws into the target, cleared to `clear`
//   gpu_blur_ready() -> bool
//                           whether gpu_blur works (its shader compiled); blurs are
//                           skipped otherwise
//   gpu_blur(src, dst: ^Target, dir, sigma)
//                           one direction of a Gaussian: src drawn into dst, each pixel
//                           the weighted sum along `dir` (in texture coordinates per
//                           tap) out to 3σ
//   gpu_read(t: ^Target, x, y, w, h) -> []u8
//                           the pixels of a rectangle of t (nil: the window's framebuffer,
//                           as last drawn) as RGBA rows, top row first, origin at the
//                           top left (temp allocator)
//   gpu_max_side() -> int   the largest texture side the GPU takes
//   gpu_trim()              gives back what per-frame buffers grew to (between frames)
//   gpu_finish()            hands deleted resources back to the driver now
//
// The calls happen between NanoVG frames: begin a window or a target, nvg.BeginFrame,
// draw, nvg.EndFrame (which runs the GPU work), then read or blur.

RENDERER :: #config(RENDERER, "gl")

#assert(RENDERER == "gl", "RENDERER must be gl")
