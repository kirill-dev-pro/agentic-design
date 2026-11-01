#+build js
package engine

import "base:runtime"
import "core:fmt"
import nvg "../nanovg"
import wgpu "../wgpu"

// The WebGPU backend in a browser (gpu_wgpu.odin), through Odin's wgpu.js: the page's
// <canvas> is the window. The browser hands out the adapter and the device through
// promises, so creating the context takes a callback (gpu_create_async), and a pixel
// readback cannot be waited for: gpu_read gives blank pixels.

when RENDERER == "wgpu" {

	Gpu_Surface :: struct {
		canvas: string, // a CSS selector of the canvas ("#canvas")
	}

	@(private = "file")
	creating: struct {
		done: proc(vg: ^nvg.Context),
		ctx:  runtime.Context,
	}

	// Starts creating the NanoVG context on the canvas; `done` gets it (nil: no WebGPU
	// here) once the browser has given an adapter and a device, after this returns.
	gpu_create_async :: proc(surface: Gpu_Surface, done: proc(vg: ^nvg.Context)) {
		creating = {done, context}
		G.instance = wgpu.CreateInstance(nil)
		if G.instance == nil {
			fmt.eprintln("WebGPU: not in this browser")
			done(nil)
			return
		}
		G.surface = wgpu.InstanceCreateSurface(G.instance, &{
			nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{chain = {sType = .SurfaceSourceCanvasHTMLSelector}, selector = surface.canvas},
		})
		wgpu.InstanceRequestAdapter(G.instance, &{compatibleSurface = G.surface}, {callback = on_adapter})
	}

	@(private = "file")
	on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, _, _: rawptr) {
		context = creating.ctx
		if status != .Success || adapter == nil {
			fmt.eprintln("WebGPU: no adapter:", message)
			creating.done(nil)
			return
		}
		G.adapter = adapter
		// the browser's default limits (8192 pixel textures, 256-byte uniform offsets)
		// are what the renderer needs
		wgpu.AdapterRequestDevice(adapter, &{
			label = "agentic-design",
			uncapturedErrorCallbackInfo = {callback = proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, _, _: rawptr) {
				context = creating.ctx
				fmt.eprintln("WebGPU error:", type, message)
			}},
		}, {callback = on_device})
	}

	@(private = "file")
	on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, _, _: rawptr) {
		context = creating.ctx
		if status != .Success || device == nil {
			fmt.eprintln("WebGPU: no device:", message)
			creating.done(nil)
			return
		}
		G.device = device
		limits, _ := wgpu.DeviceGetLimits(device)
		creating.done(device_ready(limits.maxTextureDimension2D))
	}

	// (The canvas's pixel size follows: the glue sets its width and height.)
	@(private)
	configure :: proc(w, h: int) {
		wgpu.SurfaceConfigure(G.surface, &{
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

	gpu_allocated :: proc() -> int {
		return -1 // (the browser does not say)
	}

	gpu_finish :: proc() {}

	gpu_read :: proc(t: ^Target, x, y, w, h: int) -> []u8 {
		return make([]u8, max(w * h * 4, 0), context.temp_allocator)
	}
}
