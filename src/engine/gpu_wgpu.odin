package engine

import "base:runtime"
import "core:fmt"
import "core:math"
import nvg "../nanovg"
import nvgw "../nanovg/wgpu"
import wgpu "../wgpu"

// The WebGPU backend (see gpu.odin), on wgpu-native: Metal on macOS (Vulkan and D3D12
// elsewhere), the browser's WebGPU in a page. The default renderer; build.sh fetches
// the library (tools/fetch_wgpu.sh).
//
// Every target, the window's included, has the surface's colour format (BGRA8Unorm on
// macOS, not its sRGB variant: blending and colours then work on the same values as
// OpenGL) and a Stencil8 buffer. When macOS gives the window no drawable (the screen is
// locked or the window is fully covered), the frame is drawn into an offscreen target of
// the window's size instead, so that a view screenshot still works. wgpu asks macOS
// whether the window is visible at all (`occlusionState`): a window behind others, or
// opened without focus behind the active app, draws offscreen until it is shown.

when RENDERER == "wgpu" {

	Gpu_Surface :: struct {
		metal_layer: rawptr, // macOS: the CAMetalLayer of the window's content view
	}

	Target :: struct {
		image:        int,
		w, h:         int,
		tex:          wgpu.Texture,
		view:         wgpu.TextureView,
		stencil:      wgpu.Texture,
		stencil_view: wgpu.TextureView,
	}

	@(private = "file")
	G: struct {
		instance:      wgpu.Instance,
		surface:       wgpu.Surface,
		adapter:       wgpu.Adapter,
		device:        wgpu.Device,
		queue:         wgpu.Queue,
		format:        wgpu.TextureFormat,
		bgra:          bool, // the format's bytes are B, G, R, A: swapped on readback
		surface_usage: wgpu.TextureUsageFlags,
		max_side:      int,
		failed:        string, // why gpu_create failed

		// the window
		win_w, win_h:  int, // the surface's size as configured
		frame:         wgpu.Texture, // this frame's drawable (nil: drawn into `offscreen`)
		frame_view:    wgpu.TextureView,
		win_stencil:   Target, // its stencil (and, when there is no drawable, its colour)
		offscreen:     Target,
		last_status:   wgpu.SurfaceGetCurrentTextureStatus,

		// blur
		blur_shader:   wgpu.ShaderModule,
		blur_layout:   wgpu.BindGroupLayout,
		blur_pipeline: wgpu.RenderPipeline,
		blur_sampler:  wgpu.Sampler,
		blur_uniform:  wgpu.Buffer,
		blur_failed:   bool,
	}

	@(private = "file")
	wait :: proc(done: ^bool) {
		for !done^ {
			if G.device != nil do wgpu.DevicePoll(G.device, true)
			wgpu.InstanceProcessEvents(G.instance)
		}
	}

	gpu_create :: proc(surface: Gpu_Surface) -> ^nvg.Context {
		G.instance = wgpu.CreateInstance(nil)
		if G.instance == nil {
			fmt.eprintln("WebGPU: no instance")
			return nil
		}
		G.surface = wgpu.InstanceCreateSurface(G.instance, &{
			nextInChain = &wgpu.SurfaceSourceMetalLayer{chain = {sType = .SurfaceSourceMetalLayer}, layer = surface.metal_layer},
		})
		done := false
		wgpu.InstanceRequestAdapter(G.instance, &{compatibleSurface = G.surface, powerPreference = .LowPower}, {
			mode = .AllowProcessEvents,
			callback = proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, done, _: rawptr) {
				if status == .Success do G.adapter = adapter
				else {
					context = runtime.default_context()
					fmt.eprintln("WebGPU: no adapter:", message)
				}
				(^bool)(done)^ = true
			},
			userdata1 = &done,
		})
		wait(&done)
		if G.adapter == nil do return nil
		limits, _ := wgpu.AdapterGetLimits(G.adapter)
		done = false
		wgpu.AdapterRequestDevice(G.adapter, &{
			label = "agentic-design",
			requiredLimits = &limits,
			uncapturedErrorCallbackInfo = {callback = proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, _, _: rawptr) {
				context = runtime.default_context()
				fmt.eprintln("WebGPU error:", type, message)
			}},
			deviceLostCallbackInfo = {mode = .AllowProcessEvents, callback = proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: string, _, _: rawptr) {
				if reason == .Destroyed || reason == .CallbackCancelled do return
				context = runtime.default_context()
				fmt.eprintln("WebGPU device lost:", reason, message)
			}},
		}, {
			mode = .AllowProcessEvents,
			callback = proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, done, _: rawptr) {
				if status == .Success do G.device = device
				else {
					context = runtime.default_context()
					fmt.eprintln("WebGPU: no device:", message)
				}
				(^bool)(done)^ = true
			},
			userdata1 = &done,
		})
		wait(&done)
		if G.device == nil do return nil
		G.queue = wgpu.DeviceGetQueue(G.device)
		G.max_side = int(limits.maxTextureDimension2D)

		caps, _ := wgpu.SurfaceGetCapabilities(G.surface, G.adapter)
		defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
		G.format = .Undefined
		for f in caps.formats[:caps.formatCount] do if f == .BGRA8Unorm || f == .RGBA8Unorm {
			G.format = f
			break
		}
		if G.format == .Undefined {
			fmt.eprintln("WebGPU: the window takes no BGRA8Unorm or RGBA8Unorm")
			return nil
		}
		G.bgra = G.format == .BGRA8Unorm
		G.surface_usage = {.RenderAttachment}
		if .CopySrc in caps.usages do G.surface_usage += {.CopySrc}
		return nvgw.Create(G.device, G.queue, G.format, {.ANTI_ALIAS, .STENCIL_STROKES})
	}

	gpu_destroy :: proc() {
		if renderer != nil do nvgw.Destroy(renderer)
		target_free(&G.offscreen)
		target_free(&G.win_stencil)
		if G.device != nil {
			wgpu.DeviceDestroy(G.device)
			wgpu.DeviceRelease(G.device)
		}
		G = {}
	}

	@(private = "file")
	release_frame :: proc() {
		if G.frame_view != nil do wgpu.TextureViewRelease(G.frame_view)
		if G.frame != nil do wgpu.TextureRelease(G.frame)
		G.frame, G.frame_view = nil, nil
	}

	@(private = "file")
	configure :: proc(w, h: int) {
		// two drawables instead of wgpu's three: the window keeps one less frame of its
		// size (8-30 MB); the app draws far below the display rate anyway
		extras := wgpu.SurfaceConfigurationExtras{chain = {sType = .SurfaceConfigurationExtras}, desiredMaximumFrameLatency = 1}
		wgpu.SurfaceConfigure(G.surface, &{
			nextInChain = &extras,
			device = G.device,
			format = G.format,
			usage = G.surface_usage,
			width = u32(w),
			height = u32(h),
			alphaMode = .Opaque,
			presentMode = .Fifo,
		})
		G.win_w, G.win_h = w, h
	}

	gpu_window_begin :: proc(w, h: i32, clear: nvg.Color) {
		release_frame()
		w, h := max(int(w), 1), max(int(h), 1)
		if w != G.win_w || h != G.win_h do configure(w, h)
		if G.win_stencil.w != w || G.win_stencil.h != h {
			target_free(&G.win_stencil)
			G.win_stencil = make_target(w, h, false)
		}
		st := wgpu.SurfaceGetCurrentTexture(G.surface)
		if st.status == .Outdated || st.status == .Lost {
			if st.texture != nil do wgpu.TextureRelease(st.texture)
			configure(w, h)
			st = wgpu.SurfaceGetCurrentTexture(G.surface)
		}
		color: wgpu.TextureView
		if st.status == .SuccessOptimal || st.status == .SuccessSuboptimal {
			if G.last_status != .SuccessOptimal && G.last_status != .SuccessSuboptimal && G.last_status != {} {
				fmt.eprintln("WebGPU: drawing into the window again")
			}
			G.frame = st.texture
			G.frame_view = wgpu.TextureCreateView(G.frame)
			color = G.frame_view
		} else {
			if st.texture != nil do wgpu.TextureRelease(st.texture)
			if st.status != G.last_status do fmt.eprintln("WebGPU: the window has no drawable (", st.status, "): drawing offscreen")
			if G.offscreen.w != w || G.offscreen.h != h {
				target_free(&G.offscreen)
				G.offscreen = target_make(w, h)
			}
			color = G.offscreen.view
		}
		G.last_status = st.status
		nvgw.SetTarget(renderer, color, G.win_stencil.stencil_view, true, clear)
	}

	// Shows the frame drawn since gpu_window_begin.
	gpu_present :: proc() {
		if G.frame != nil do wgpu.SurfacePresent(G.surface)
		release_frame()
	}

	@(private = "file")
	make_target :: proc(w, h: int, with_color: bool) -> (t: Target) {
		t.w, t.h = w, h
		if with_color {
			t.tex = wgpu.DeviceCreateTexture(G.device, &{
				label = "target",
				usage = {.RenderAttachment, .TextureBinding, .CopySrc},
				dimension = ._2D,
				size = {u32(w), u32(h), 1},
				format = G.format,
				mipLevelCount = 1,
				sampleCount = 1,
			})
			t.view = wgpu.TextureCreateView(t.tex)
			t.image = nvgw.CreateImageFromTexture(renderer, t.tex, t.view, w, h, {.PREMULTIPLIED})
		}
		t.stencil = wgpu.DeviceCreateTexture(G.device, &{
			label = "stencil",
			usage = {.RenderAttachment},
			dimension = ._2D,
			size = {u32(w), u32(h), 1},
			format = nvgw.STENCIL_FORMAT,
			mipLevelCount = 1,
			sampleCount = 1,
		})
		t.stencil_view = wgpu.TextureCreateView(t.stencil)
		return
	}

	target_make :: proc(w, h: int) -> Target {
		return make_target(w, h, true)
	}

	target_free :: proc(t: ^Target) {
		if t.image != 0 do nvg.DeleteImage(renderer, t.image)
		for v in ([2]wgpu.TextureView{t.view, t.stencil_view}) do if v != nil do wgpu.TextureViewRelease(v)
		for x in ([2]wgpu.Texture{t.tex, t.stencil}) do if x != nil {
			wgpu.TextureDestroy(x)
			wgpu.TextureRelease(x)
		}
		t^ = {}
	}

	target_begin :: proc(t: ^Target, clear: nvg.Color) {
		nvgw.SetTarget(renderer, t.view, t.stencil_view, true, clear)
	}

	gpu_max_side :: proc() -> int {
		return G.max_side
	}

	// MTLDevice.currentAllocatedSize on macOS.
	gpu_allocated :: proc() -> int {
		when ODIN_OS == .Darwin {
			if G.device == nil do return -1
			mtl := wgpu.DeviceGetNativeMetalDevice(G.device)
			msg := dlsym(RTLD_DEFAULT, "objc_msgSend")
			if mtl == nil || msg == nil do return -1
			send := cast(proc "c" (self, op: rawptr) -> uint)msg
			return int(send(mtl, sel_getUid("currentAllocatedSize")))
		} else {
			return -1
		}
	}

	gpu_trim :: proc() {
		if renderer != nil do nvgw.RecycleBuffers(renderer)
	}

	gpu_finish :: proc() {
		if G.device != nil do wgpu.DevicePoll(G.device, false)
	}

	// Copied into a buffer (rows padded to 256 bytes, as a copy needs them) up to 2048
	// rows at a time, mapped and read once the copy is done. Each strip waits for the
	// GPU: strips of 128 rows made a screenshot 3-4 times slower than with OpenGL, whole
	// tiles 10-25 % slower. The buffer (16 MB for a 2048 tile) is gone after the read;
	// memory after many screenshots stayed where it was.
	gpu_read :: proc(t: ^Target, x, y, w, h: int) -> []u8 {
		STRIP :: 2048
		nvgw.FlushClear(renderer)
		src := t.tex if t != nil else (G.frame if G.frame != nil else G.offscreen.tex)
		pixels := make([]u8, w * h * 4, context.temp_allocator)
		if src == nil || w <= 0 || h <= 0 do return pixels
		row := w * 4
		stride := (row + 255) / 256 * 256
		size := stride * min(STRIP, h)
		buf := wgpu.DeviceCreateBuffer(G.device, &{label = "readback", usage = {.MapRead, .CopyDst}, size = u64(size)})
		defer {
			wgpu.BufferDestroy(buf)
			wgpu.BufferRelease(buf)
		}
		for r0 := 0; r0 < h; r0 += STRIP {
			rows := min(STRIP, h - r0)
			enc := wgpu.DeviceCreateCommandEncoder(G.device)
			wgpu.CommandEncoderCopyTextureToBuffer(
				enc,
				&{texture = src, mipLevel = 0, origin = {u32(x), u32(y + r0), 0}, aspect = .All},
				&{layout = {offset = 0, bytesPerRow = u32(stride), rowsPerImage = u32(rows)}, buffer = buf},
				&{u32(w), u32(rows), 1},
			)
			cmd := wgpu.CommandEncoderFinish(enc)
			wgpu.QueueSubmit(G.queue, {cmd})
			wgpu.CommandBufferRelease(cmd)
			wgpu.CommandEncoderRelease(enc)
			Mapped :: struct {
				done, ok: bool,
			}
			m: Mapped
			wgpu.BufferMapAsync(buf, {.Read}, 0, uint(stride * rows), {
				mode = .AllowProcessEvents,
				callback = proc "c" (status: wgpu.MapAsyncStatus, message: string, m, _: rawptr) {
					(^Mapped)(m).ok = status == .Success
					(^Mapped)(m).done = true
				},
				userdata1 = &m,
			})
			wait(&m.done)
			if !m.ok do continue
			data := wgpu.BufferGetConstMappedRange(buf, 0, uint(stride * rows))
			for k in 0 ..< rows {
				out := pixels[(r0 + k) * row:][:row]
				copy(out, data[k * stride:][:row])
				if G.bgra do for i := 0; i < row; i += 4 do out[i], out[i + 2] = out[i + 2], out[i]
			}
			wgpu.BufferUnmap(buf)
		}
		return pixels
	}

	@(private = "file")
	BLUR_SHADER :: `
struct Blur {
	dir: vec2<f32>,
	sigma: f32,
	radius: i32,
}
@group(0) @binding(0) var<uniform> b: Blur;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;

struct VOut {
	@builtin(position) pos: vec4<f32>,
	@location(0) uv: vec2<f32>,
}

// a quad over the target as a strip: (-1,-1) (1,-1) (-1,1) (1,1)
@vertex
fn vs(@builtin(vertex_index) i: u32) -> VOut {
	let p = vec2<f32>(f32(i & 1u) * 2.0 - 1.0, f32(i >> 1u) * 2.0 - 1.0);
	var o: VOut;
	o.pos = vec4<f32>(p, 0.0, 1.0);
	o.uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); // texture rows run top-down
	return o;
}

@fragment
fn fs(in: VOut) -> @location(0) vec4<f32> {
	var sum = vec4<f32>(0.0);
	var total = 0.0;
	for (var i = -b.radius; i <= b.radius; i++) {
		let w = exp(-f32(i * i) / (2.0 * b.sigma * b.sigma));
		sum += textureSampleLevel(src, samp, in.uv + b.dir * f32(i), 0.0) * w;
		total += w;
	}
	return sum / total;
}
`

	gpu_blur_ready :: proc() -> bool {
		if G.blur_pipeline != nil do return true
		if G.blur_failed || G.device == nil do return false
		G.blur_shader = wgpu.DeviceCreateShaderModule(G.device, &{
			label = "blur",
			nextInChain = &wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = BLUR_SHADER},
		})
		entries := [3]wgpu.BindGroupLayoutEntry {
			{binding = 0, visibility = {.Fragment}, buffer = {type = .Uniform, minBindingSize = 16}},
			{binding = 1, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
			{binding = 2, visibility = {.Fragment}, sampler = {type = .Filtering}},
		}
		G.blur_layout = wgpu.DeviceCreateBindGroupLayout(G.device, &{label = "blur", entryCount = 3, entries = &entries[0]})
		layout := wgpu.DeviceCreatePipelineLayout(G.device, &{label = "blur", bindGroupLayoutCount = 1, bindGroupLayouts = &G.blur_layout})
		defer wgpu.PipelineLayoutRelease(layout)
		color := wgpu.ColorTargetState{format = G.format, writeMask = wgpu.ColorWriteMaskFlags_All}
		frag := wgpu.FragmentState{module = G.blur_shader, entryPoint = "fs", targetCount = 1, targets = &color}
		G.blur_pipeline = wgpu.DeviceCreateRenderPipeline(G.device, &{
			label = "blur",
			layout = layout,
			vertex = {module = G.blur_shader, entryPoint = "vs"},
			primitive = {topology = .TriangleStrip, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = 0xffffffff},
			fragment = &frag,
		})
		if G.blur_pipeline == nil {
			fmt.eprintln("blur shader failed to compile")
			G.blur_failed = true
			return false
		}
		G.blur_sampler = wgpu.DeviceCreateSampler(G.device, &{
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = .Linear,
			minFilter = .Linear,
			mipmapFilter = .Nearest,
			lodMaxClamp = 32,
			maxAnisotropy = 1,
		})
		G.blur_uniform = wgpu.DeviceCreateBuffer(G.device, &{label = "blur", usage = {.Uniform, .CopyDst}, size = 16})
		return true
	}

	gpu_blur :: proc(src, dst: ^Target, dir: [2]f32, sigma: f32) {
		if !gpu_blur_ready() do return
		nvgw.FlushClear(renderer)
		Blur :: struct {
			dir:    [2]f32,
			sigma:  f32,
			radius: i32,
		}
		u := Blur{dir, sigma, i32(math.ceil(3 * sigma))}
		wgpu.QueueWriteBuffer(G.queue, G.blur_uniform, 0, &u, size_of(u))
		entries := [3]wgpu.BindGroupEntry {
			{binding = 0, buffer = G.blur_uniform, size = 16},
			{binding = 1, textureView = src.view},
			{binding = 2, sampler = G.blur_sampler},
		}
		bind := wgpu.DeviceCreateBindGroup(G.device, &{label = "blur", layout = G.blur_layout, entryCount = 3, entries = &entries[0]})
		defer wgpu.BindGroupRelease(bind)
		color := wgpu.RenderPassColorAttachment {
			view       = dst.view,
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Clear,
			storeOp    = .Store,
		}
		enc := wgpu.DeviceCreateCommandEncoder(G.device)
		pass := wgpu.CommandEncoderBeginRenderPass(enc, &{colorAttachmentCount = 1, colorAttachments = &color})
		wgpu.RenderPassEncoderSetPipeline(pass, G.blur_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, bind)
		wgpu.RenderPassEncoderDraw(pass, 4, 1, 0, 0)
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
		cmd := wgpu.CommandEncoderFinish(enc)
		wgpu.QueueSubmit(G.queue, {cmd})
		wgpu.CommandBufferRelease(cmd)
		wgpu.CommandEncoderRelease(enc)
	}
}

when RENDERER == "wgpu" && ODIN_OS == .Darwin {
	foreign import objc_runtime "system:objc"

	@(private = "file", default_calling_convention = "c")
	foreign objc_runtime {
		sel_getUid :: proc(name: cstring) -> rawptr ---
		dlsym :: proc(handle: rawptr, name: cstring) -> rawptr ---
	}

	@(private = "file")
	RTLD_DEFAULT :: rawptr(~uintptr(1)) // (void *)-2
}

