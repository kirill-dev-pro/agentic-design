#+build !js
package engine

import "base:runtime"
import "core:fmt"
import nvg "../nanovg"
import nvgw "../nanovg/wgpu"
import wgpu "../wgpu"

// The WebGPU backend on a desktop, through wgpu-native (gpu_wgpu.odin): the window's
// surface, creating the device (waiting for it), reading pixels back and the driver's
// memory.

when RENDERER == "wgpu" {

	// The window to draw into, one kind per system.
	Gpu_Surface :: struct {
		metal_layer:     rawptr, // macOS: the CAMetalLayer of the window's content view
		hwnd, hinstance: rawptr, // Windows
		x11_display:     rawptr, // Linux on X11 (or XWayland)
		x11_window:      u64,
		wayland_display: rawptr, // Linux on Wayland
		wayland_surface: rawptr,
	}

	@(private = "file")
	create_surface :: proc(s: Gpu_Surface) -> wgpu.Surface {
		if s.metal_layer != nil {
			return wgpu.InstanceCreateSurface(G.instance, &{nextInChain = &wgpu.SurfaceSourceMetalLayer{chain = {sType = .SurfaceSourceMetalLayer}, layer = s.metal_layer}})
		}
		if s.hwnd != nil {
			return wgpu.InstanceCreateSurface(G.instance, &{nextInChain = &wgpu.SurfaceSourceWindowsHWND{chain = {sType = .SurfaceSourceWindowsHWND}, hinstance = s.hinstance, hwnd = s.hwnd}})
		}
		if s.wayland_surface != nil {
			return wgpu.InstanceCreateSurface(G.instance, &{nextInChain = &wgpu.SurfaceSourceWaylandSurface{chain = {sType = .SurfaceSourceWaylandSurface}, display = s.wayland_display, surface = s.wayland_surface}})
		}
		return wgpu.InstanceCreateSurface(G.instance, &{nextInChain = &wgpu.SurfaceSourceXlibWindow{chain = {sType = .SurfaceSourceXlibWindow}, display = s.x11_display, window = s.x11_window}})
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
		G.surface = create_surface(surface)
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
		return device_ready(limits.maxTextureDimension2D)
	}

	@(private)
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
