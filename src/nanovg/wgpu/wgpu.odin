// A WebGPU backend for NanoVG, after the GL3 backend in ../gl: the same calls, the same
// shader (in WGSL), the same stencil passes for fills and strokes. Written for Agentic
// Design; see README.md one folder up.
//
// What WebGPU does differently, and how it is met here:
// - No triangle fans. A path's fill is a fan; each is turned into an indexed triangle
//   list with the same triangles in the same order.
// - State lives in pipelines. Each combination of topology, culling, colour writes and
//   stencil test that the GL backend switches to is one pipeline (`Pipe`).
// - The frame is recorded and submitted at `renderFlush` (EndFrame), into the colour and
//   stencil views the host set with `SetTarget`. A clear asked for there is the pass's
//   load operation.
// - Texture rows run top-down, so render targets need no FLIP_Y.
package nanovg_wgpu

import "base:intrinsics"
import "core:math"
import nvg "../../nanovg"
import wgpu "../../wgpu"

CreateFlag :: enum {
	// geometry based anti-aliasing (the fringes); the app always uses it
	ANTI_ALIAS,
	// strokes drawn through the stencil, so that overlaps are drawn once
	STENCIL_STROKES,
}
CreateFlags :: bit_set[CreateFlag]

// The stencil format of every target this backend draws into.
STENCIL_FORMAT :: wgpu.TextureFormat.Stencil8

ShaderType :: enum i32 {
	FILL_GRAD,
	FILL_IMG,
	SIMPLE,
	IMG,
}

// As the GL3 backend's uniform block (std140), and the WGSL struct `Frag` below.
FragUniforms :: struct #packed {
	scissorMat:   [12]f32, // 3 columns of vec3, each padded to 4
	paintMat:     [12]f32,
	innerColor:   nvg.Color,
	outerColor:   nvg.Color,
	scissorExt:   [2]f32,
	scissorScale: [2]f32,
	extent:       [2]f32,
	radius:       f32,
	feather:      f32,
	strokeMult:   f32,
	strokeThr:    f32,
	texType:      i32,
	type:         ShaderType,
}
#assert(size_of(FragUniforms) == 176)

Texture :: struct {
	id:            int,
	tex:           wgpu.Texture,
	view:          wgpu.TextureView,
	bind:          wgpu.BindGroup,
	width, height: int,
	type:          nvg.Texture,
	flags:         nvg.ImageFlags,
	borrowed:      bool, // the host's texture (a render target): not destroyed here
}

CallType :: enum {
	NONE,
	FILL,
	CONVEX_FILL,
	STROKE,
	TRIANGLES,
}

Call :: struct {
	type:           CallType,
	image:          int,
	pathOffset:     int,
	pathCount:      int,
	triangleOffset: int,
	triangleCount:  int,
	uniformOffset:  int,
}

Path :: struct {
	fillOffset:   int, // into indices: the fan as a triangle list
	fillCount:    int,
	strokeOffset: int, // into verts: a triangle strip
	strokeCount:  int,
}

// The GPU states the GL backend switches between, one pipeline each.
Pipe :: enum {
	LIST, // triangles, back faces culled, no stencil: convex fills, text, triangles
	STRIP, // the same for strips: fringes of convex fills, strokes without stencil
	FILL_STENCIL, // the fill's winding into the stencil: no colour, no culling
	FILL_FRINGE, // where the stencil is 0 (the fill's and the stroke's antialiased edge)
	FILL_COVER, // where the stencil is not 0, which it sets back to 0
	STROKE_BASE, // where the stencil is 0, which it then increments: overlaps once
	STROKE_CLEAR, // stencil back to 0 under the stroke, no colour
}

Context :: struct {
	device:         wgpu.Device,
	queue:          wgpu.Queue,
	format:         wgpu.TextureFormat,
	flags:          CreateFlags,
	textures:       [dynamic]Texture,
	textureId:      int,
	view:           [2]f32,
	fragSize:       int,
	dummyTex:       int,

	// per frame
	calls:          [dynamic]Call,
	paths:          [dynamic]Path,
	verts:          [dynamic]nvg.Vertex,
	indices:        [dynamic]u32,
	uniforms:       [dynamic]byte,

	// GPU objects
	shader:         wgpu.ShaderModule,
	frag_layout:    wgpu.BindGroupLayout, // group 0: frag (dynamic offset) and view
	tex_layout:     wgpu.BindGroupLayout, // group 1: texture and sampler
	layout:         wgpu.PipelineLayout,
	pipes:          [Pipe]wgpu.RenderPipeline,
	samplers:       [8]wgpu.Sampler, // by NEAREST, REPEAT_X, REPEAT_Y
	vert_buf:       wgpu.Buffer,
	vert_cap:       int,
	index_buf:      wgpu.Buffer,
	index_cap:      int,
	frag_buf:       wgpu.Buffer,
	frag_cap:       int,
	view_buf:       wgpu.Buffer,
	frag_bind:      wgpu.BindGroup,

	// where the next flush draws
	target_color:   wgpu.TextureView,
	target_stencil: wgpu.TextureView,
	clear_pending:  bool,
	clear_color:    nvg.Color,
}

// Creates a NanoVG context drawing with `device` into targets of `format` (and
// STENCIL_FORMAT).
Create :: proc(device: wgpu.Device, queue: wgpu.Queue, format: wgpu.TextureFormat, flags: CreateFlags) -> ^nvg.Context {
	ctx := new(Context)
	ctx.device, ctx.queue, ctx.format, ctx.flags = device, queue, format, flags
	params: nvg.Params
	params.renderCreate = __renderCreate
	params.renderCreateTexture = __renderCreateTexture
	params.renderDeleteTexture = __renderDeleteTexture
	params.renderUpdateTexture = __renderUpdateTexture
	params.renderGetTextureSize = __renderGetTextureSize
	params.renderViewport = __renderViewport
	params.renderCancel = __renderCancel
	params.renderFlush = __renderFlush
	params.renderFill = __renderFill
	params.renderStroke = __renderStroke
	params.renderTriangles = __renderTriangles
	params.renderDelete = __renderDelete
	params.userPtr = ctx
	params.edgeAntiAlias = .ANTI_ALIAS in flags
	return nvg.CreateInternal(params)
}

Destroy :: proc(ctx: ^nvg.Context) {
	nvg.DeleteInternal(ctx)
}

// The next frame draws into `color` (of the context's format) with `stencil` (of
// STENCIL_FORMAT), both of the same size; `clear`: cleared first, to `clear_color` and a
// stencil of 0.
SetTarget :: proc(ctx: ^nvg.Context, color, stencil: wgpu.TextureView, clear: bool, clear_color: nvg.Color = {}) {
	c := cast(^Context)ctx.params.userPtr
	c.target_color, c.target_stencil = color, stencil
	c.clear_pending, c.clear_color = clear, clear_color
}

// Runs a clear asked for in SetTarget that no frame has drawn yet.
FlushClear :: proc(ctx: ^nvg.Context) {
	c := cast(^Context)ctx.params.userPtr
	if c.clear_pending do __renderFlush(c)
}

// A NanoVG image for a texture the host made (a render target). PREMULTIPLIED in
// `flags` for what NanoVG drew.
CreateImageFromTexture :: proc(ctx: ^nvg.Context, texture: wgpu.Texture, view: wgpu.TextureView, w, h: int, flags: nvg.ImageFlags) -> int {
	c := cast(^Context)ctx.params.userPtr
	tex := __allocTexture(c)
	tex.type = .RGBA
	tex.tex, tex.view = texture, view
	tex.width, tex.height = w, h
	tex.flags = flags
	tex.borrowed = true
	tex.bind = __textureBind(c, tex)
	return tex.id
}

// Gives back what the per-frame arrays and buffers grew to (between frames).
RecycleBuffers :: proc(ctx: ^nvg.Context) {
	c := cast(^Context)ctx.params.userPtr
	__releaseBuffer(&c.vert_buf, &c.vert_cap)
	__releaseBuffer(&c.index_buf, &c.index_cap)
	if c.frag_buf != nil {
		__releaseBuffer(&c.frag_buf, &c.frag_cap)
		wgpu.BindGroupRelease(c.frag_bind)
		c.frag_bind = nil
	}
	shrink(&c.verts, 0)
	shrink(&c.indices, 0)
	shrink(&c.uniforms, 0)
	shrink(&c.calls, 0)
	shrink(&c.paths, 0)
	shrink(&ctx.commands, 0)
	shrink(&ctx.cache.points, 0)
	shrink(&ctx.cache.paths, 0)
	shrink(&ctx.cache.verts, 0)
}

SHADER :: `
struct Frag {
	scissorMat: mat3x3<f32>,
	paintMat: mat3x3<f32>,
	innerCol: vec4<f32>,
	outerCol: vec4<f32>,
	scissorExt: vec2<f32>,
	scissorScale: vec2<f32>,
	extent: vec2<f32>,
	radius: f32,
	feather: f32,
	strokeMult: f32,
	strokeThr: f32,
	texType: i32,
	kind: i32,
}

@group(0) @binding(0) var<uniform> frag: Frag;
@group(0) @binding(1) var<uniform> viewSize: vec4<f32>;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct VOut {
	@builtin(position) pos: vec4<f32>,
	@location(0) ftcoord: vec2<f32>,
	@location(1) fpos: vec2<f32>,
}

@vertex
fn vs(@location(0) vertex: vec2<f32>, @location(1) tcoord: vec2<f32>) -> VOut {
	var o: VOut;
	o.ftcoord = tcoord;
	o.fpos = vertex;
	o.pos = vec4<f32>(2.0 * vertex.x / viewSize.x - 1.0, 1.0 - 2.0 * vertex.y / viewSize.y, 0.0, 1.0);
	return o;
}

fn sdroundrect(pt: vec2<f32>, ext: vec2<f32>, rad: f32) -> f32 {
	let ext2 = ext - vec2<f32>(rad, rad);
	let d = abs(pt) - ext2;
	return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0, 0.0))) - rad;
}

// scissoring
fn scissorMask(p: vec2<f32>) -> f32 {
	var sc = abs((frag.scissorMat * vec3<f32>(p, 1.0)).xy) - frag.scissorExt;
	sc = vec2<f32>(0.5, 0.5) - sc * frag.scissorScale;
	return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

// stroke: from [0..1] to a clipped pyramid, where the slope is 1px
fn strokeMask(ftcoord: vec2<f32>) -> f32 {
	return min(1.0, (1.0 - abs(ftcoord.x * 2.0 - 1.0)) * frag.strokeMult) * min(1.0, ftcoord.y);
}

fn texel(pt: vec2<f32>) -> vec4<f32> {
	// level 0 (no mipmaps), so the lookup may sit in any control flow
	var color = textureSampleLevel(tex, samp, pt, 0.0);
	if (frag.texType == 1) { color = vec4<f32>(color.xyz * color.w, color.w); }
	if (frag.texType == 2) { color = vec4<f32>(color.x); }
	return color;
}

@fragment
fn fs(in: VOut) -> @location(0) vec4<f32> {
	let scissor = scissorMask(in.fpos);
	var strokeAlpha = 1.0;
	if (EDGE_AA) {
		strokeAlpha = strokeMask(in.ftcoord);
		if (strokeAlpha < frag.strokeThr) { discard; }
	}
	var result: vec4<f32>;
	if (frag.kind == 0) { // gradient
		let pt = (frag.paintMat * vec3<f32>(in.fpos, 1.0)).xy;
		let d = clamp((sdroundrect(pt, frag.extent, frag.radius) + frag.feather * 0.5) / frag.feather, 0.0, 1.0);
		result = mix(frag.innerCol, frag.outerCol, d) * (strokeAlpha * scissor);
	} else if (frag.kind == 1) { // image
		let pt = (frag.paintMat * vec3<f32>(in.fpos, 1.0)).xy / frag.extent;
		result = texel(pt) * frag.innerCol * (strokeAlpha * scissor);
	} else if (frag.kind == 2) { // stencil fill
		result = vec4<f32>(1.0, 1.0, 1.0, 1.0);
	} else { // textured triangles
		result = texel(in.ftcoord) * scissor * frag.innerCol;
	}
	return result;
}
`

@(private)
__renderCreate :: proc(uptr: rawptr) -> bool {
	ctx := cast(^Context)uptr
	limits, _ := wgpu.DeviceGetLimits(ctx.device)
	align := max(int(limits.minUniformBufferOffsetAlignment), 16)
	ctx.fragSize = (size_of(FragUniforms) + align - 1) / align * align

	source := (SHADER_AA if .ANTI_ALIAS in ctx.flags else SHADER_NO_AA)
	ctx.shader = wgpu.DeviceCreateShaderModule(ctx.device, &{
		label = "nanovg",
		nextInChain = &wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = source},
	})
	if ctx.shader == nil do return false

	frag_entries := [2]wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Vertex, .Fragment}, buffer = {type = .Uniform, hasDynamicOffset = true, minBindingSize = size_of(FragUniforms)}},
		{binding = 1, visibility = {.Vertex, .Fragment}, buffer = {type = .Uniform, minBindingSize = 16}},
	}
	ctx.frag_layout = wgpu.DeviceCreateBindGroupLayout(ctx.device, &{label = "nanovg frag", entryCount = 2, entries = &frag_entries[0]})
	tex_entries := [2]wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	ctx.tex_layout = wgpu.DeviceCreateBindGroupLayout(ctx.device, &{label = "nanovg texture", entryCount = 2, entries = &tex_entries[0]})
	groups := [2]wgpu.BindGroupLayout{ctx.frag_layout, ctx.tex_layout}
	ctx.layout = wgpu.DeviceCreatePipelineLayout(ctx.device, &{label = "nanovg", bindGroupLayoutCount = 2, bindGroupLayouts = &groups[0]})

	for p in Pipe do ctx.pipes[p] = __createPipeline(ctx, p)
	ctx.view_buf = wgpu.DeviceCreateBuffer(ctx.device, &{label = "nanovg view", usage = {.Uniform, .CopyDst}, size = 16})
	ctx.dummyTex = __renderCreateTexture(ctx, .Alpha, 1, 1, {}, nil)
	return true
}

SHADER_AA :: "const EDGE_AA = true;\n" + SHADER
SHADER_NO_AA :: "const EDGE_AA = false;\n" + SHADER

@(private)
__createPipeline :: proc(ctx: ^Context, p: Pipe) -> wgpu.RenderPipeline {
	attrs := [2]wgpu.VertexAttribute {
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x2, offset = 8, shaderLocation = 1},
	}
	vbuf := wgpu.VertexBufferLayout {
		stepMode       = .Vertex,
		arrayStride    = size_of(nvg.Vertex),
		attributeCount = 2,
		attributes     = &attrs[0],
	}
	// premultiplied alpha, source over (NanoVG's default composite; the app uses no other)
	blend := wgpu.BlendState {
		color = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	color := wgpu.ColorTargetState {
		format    = ctx.format,
		blend     = &blend,
		writeMask = wgpu.ColorWriteMaskFlags_All,
	}
	keep := wgpu.StencilFaceState{compare = .Always, failOp = .Keep, depthFailOp = .Keep, passOp = .Keep}
	ds := wgpu.DepthStencilState {
		format            = STENCIL_FORMAT,
		depthWriteEnabled = .False,
		depthCompare      = .Always,
		stencilFront      = keep,
		stencilBack       = keep,
		stencilReadMask   = 0xff,
		stencilWriteMask  = 0,
	}
	prim := wgpu.PrimitiveState {
		topology  = .TriangleStrip,
		frontFace = .CCW,
		cullMode  = .Back,
	}
	switch p {
	case .LIST:
		prim.topology = .TriangleList
	case .STRIP:
	case .FILL_STENCIL:
		prim.topology = .TriangleList
		prim.cullMode = .None
		color.writeMask = {}
		ds.stencilWriteMask = 0xff
		ds.stencilFront = {compare = .Always, failOp = .Keep, depthFailOp = .Keep, passOp = .IncrementWrap}
		ds.stencilBack = {compare = .Always, failOp = .Keep, depthFailOp = .Keep, passOp = .DecrementWrap}
	case .FILL_FRINGE:
		ds.stencilFront = {compare = .Equal, failOp = .Keep, depthFailOp = .Keep, passOp = .Keep}
		ds.stencilBack = ds.stencilFront
	case .FILL_COVER:
		ds.stencilWriteMask = 0xff
		ds.stencilFront = {compare = .NotEqual, failOp = .Zero, depthFailOp = .Zero, passOp = .Zero}
		ds.stencilBack = ds.stencilFront
	case .STROKE_BASE:
		ds.stencilWriteMask = 0xff
		ds.stencilFront = {compare = .Equal, failOp = .Keep, depthFailOp = .Keep, passOp = .IncrementClamp}
		ds.stencilBack = ds.stencilFront
	case .STROKE_CLEAR:
		color.writeMask = {}
		ds.stencilWriteMask = 0xff
		ds.stencilFront = {compare = .Always, failOp = .Zero, depthFailOp = .Zero, passOp = .Zero}
		ds.stencilBack = ds.stencilFront
	}
	frag := wgpu.FragmentState {
		module      = ctx.shader,
		entryPoint  = "fs",
		targetCount = 1,
		targets     = &color,
	}
	return wgpu.DeviceCreateRenderPipeline(ctx.device, &{
		label = "nanovg",
		layout = ctx.layout,
		vertex = {module = ctx.shader, entryPoint = "vs", bufferCount = 1, buffers = &vbuf},
		primitive = prim,
		depthStencil = &ds,
		multisample = {count = 1, mask = 0xffffffff},
		fragment = &frag,
	})
}

@(private)
__allocTexture :: proc(ctx: ^Context) -> (tex: ^Texture) {
	for &texture in ctx.textures {
		if texture.id == 0 {
			tex = &texture
			break
		}
	}
	if tex == nil {
		append(&ctx.textures, Texture{})
		tex = &ctx.textures[len(ctx.textures) - 1]
	}
	tex^ = {}
	ctx.textureId += 1
	tex.id = ctx.textureId
	return
}

@(private)
__findTexture :: proc(ctx: ^Context, id: int) -> ^Texture {
	if id == 0 do return nil
	for &texture in ctx.textures do if texture.id == id do return &texture
	return nil
}

@(private)
__sampler :: proc(ctx: ^Context, flags: nvg.ImageFlags) -> wgpu.Sampler {
	i := (1 if .NEAREST in flags else 0) | (2 if .REPEAT_X in flags else 0) | (4 if .REPEAT_Y in flags else 0)
	if ctx.samplers[i] == nil {
		filter: wgpu.FilterMode = .Nearest if .NEAREST in flags else .Linear
		ctx.samplers[i] = wgpu.DeviceCreateSampler(ctx.device, &{
			addressModeU = .Repeat if .REPEAT_X in flags else .ClampToEdge,
			addressModeV = .Repeat if .REPEAT_Y in flags else .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = filter,
			minFilter = filter,
			mipmapFilter = .Nearest,
			lodMinClamp = 0,
			lodMaxClamp = 32,
			maxAnisotropy = 1,
		})
	}
	return ctx.samplers[i]
}

@(private)
__textureBind :: proc(ctx: ^Context, tex: ^Texture) -> wgpu.BindGroup {
	entries := [2]wgpu.BindGroupEntry {
		{binding = 0, textureView = tex.view},
		{binding = 1, sampler = __sampler(ctx, tex.flags)},
	}
	return wgpu.DeviceCreateBindGroup(ctx.device, &{label = "nanovg texture", layout = ctx.tex_layout, entryCount = 2, entries = &entries[0]})
}

@(private)
__bytesPerPixel :: proc(type: nvg.Texture) -> int {
	return 4 if type == .RGBA else 1
}

@(private)
__renderCreateTexture :: proc(uptr: rawptr, type: nvg.Texture, w, h: int, imageFlags: nvg.ImageFlags, data: []byte) -> int {
	ctx := cast(^Context)uptr
	tex := __allocTexture(ctx)
	tex.width, tex.height = w, h
	tex.type = type
	tex.flags = imageFlags - {.GENERATE_MIPMAPS} // (not used by the app; level 0 only)
	tex.tex = wgpu.DeviceCreateTexture(ctx.device, &{
		label = "nanovg image",
		usage = {.TextureBinding, .CopyDst},
		dimension = ._2D,
		size = {u32(w), u32(h), 1},
		format = .RGBA8Unorm if type == .RGBA else .R8Unorm,
		mipLevelCount = 1,
		sampleCount = 1,
	})
	tex.view = wgpu.TextureCreateView(tex.tex)
	tex.bind = __textureBind(ctx, tex)
	if data != nil do __writeTexture(ctx, tex, 0, h, data)
	return tex.id
}

// Rows y ..< y + h of the texture from `data`, which holds the whole texture.
@(private)
__writeTexture :: proc(ctx: ^Context, tex: ^Texture, y, h: int, data: []byte) {
	if h <= 0 do return
	row := tex.width * __bytesPerPixel(tex.type)
	src := data[y * row:][:h * row]
	wgpu.QueueWriteTexture(
		ctx.queue,
		&{texture = tex.tex, mipLevel = 0, origin = {0, u32(y), 0}, aspect = .All},
		raw_data(src),
		uint(len(src)),
		&{offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(h)},
		&{u32(tex.width), u32(h), 1},
	)
}

@(private)
__deleteTexture :: proc(ctx: ^Context, id: int) -> bool {
	for &texture, i in ctx.textures {
		if texture.id != id do continue
		if texture.bind != nil do wgpu.BindGroupRelease(texture.bind)
		if !texture.borrowed && .NO_DELETE not_in texture.flags {
			if texture.view != nil do wgpu.TextureViewRelease(texture.view)
			if texture.tex != nil {
				wgpu.TextureDestroy(texture.tex)
				wgpu.TextureRelease(texture.tex)
			}
		}
		ctx.textures[i] = {}
		return true
	}
	return false
}

@(private)
__renderDeleteTexture :: proc(uptr: rawptr, image: int) -> bool {
	return __deleteTexture(cast(^Context)uptr, image)
}

@(private)
__renderUpdateTexture :: proc(uptr: rawptr, image: int, x, y: int, w, h: int, data: []byte) -> bool {
	ctx := cast(^Context)uptr
	tex := __findTexture(ctx, image)
	if tex == nil do return false
	// whole rows, as the GL backend updates them
	__writeTexture(ctx, tex, y, h, data)
	return true
}

@(private)
__renderGetTextureSize :: proc(uptr: rawptr, image: int, w, h: ^int) -> bool {
	tex := __findTexture(cast(^Context)uptr, image)
	if tex == nil do return false
	w^, h^ = tex.width, tex.height
	return true
}

@(private)
__xformToMat3x4 :: proc(m3: ^[12]f32, t: [6]f32) {
	m3^ = {t[0], t[1], 0, 0, t[2], t[3], 0, 0, t[4], t[5], 1, 0}
}

@(private)
__premulColor :: proc(c: nvg.Color) -> (res: nvg.Color) {
	res = c
	res.r *= c.a
	res.g *= c.a
	res.b *= c.a
	return
}

@(private)
__convertPaint :: proc(ctx: ^Context, frag: ^FragUniforms, paint: ^nvg.Paint, scissor: ^nvg.ScissorT, width, fringe, strokeThr: f32) -> bool {
	invxform: [6]f32
	frag^ = {}
	frag.innerColor = __premulColor(paint.innerColor)
	frag.outerColor = __premulColor(paint.outerColor)
	if scissor.extent[0] < -0.5 || scissor.extent[1] < -0.5 {
		frag.scissorMat = {}
		frag.scissorExt = {1, 1}
		frag.scissorScale = {1, 1}
	} else {
		nvg.TransformInverse(&invxform, scissor.xform)
		__xformToMat3x4(&frag.scissorMat, invxform)
		frag.scissorExt = scissor.extent
		frag.scissorScale[0] = math.sqrt(scissor.xform[0] * scissor.xform[0] + scissor.xform[2] * scissor.xform[2]) / fringe
		frag.scissorScale[1] = math.sqrt(scissor.xform[1] * scissor.xform[1] + scissor.xform[3] * scissor.xform[3]) / fringe
	}
	frag.extent = paint.extent
	frag.strokeMult = (width * 0.5 + fringe * 0.5) / fringe
	frag.strokeThr = strokeThr
	if paint.image != 0 {
		tex := __findTexture(ctx, paint.image)
		if tex == nil do return false
		if .FLIP_Y in tex.flags {
			m1, m2: [6]f32
			nvg.TransformTranslate(&m1, 0.0, frag.extent[1] * 0.5)
			nvg.TransformMultiply(&m1, paint.xform)
			nvg.TransformScale(&m2, 1.0, -1.0)
			nvg.TransformMultiply(&m2, m1)
			nvg.TransformTranslate(&m1, 0.0, -frag.extent[1] * 0.5)
			nvg.TransformMultiply(&m1, m2)
			nvg.TransformInverse(&invxform, m1)
		} else {
			nvg.TransformInverse(&invxform, paint.xform)
		}
		frag.type = .FILL_IMG
		if tex.type == .RGBA do frag.texType = 0 if .PREMULTIPLIED in tex.flags else 1
		else do frag.texType = 2
	} else {
		frag.type = .FILL_GRAD
		frag.radius = paint.radius
		frag.feather = paint.feather
		nvg.TransformInverse(&invxform, paint.xform)
	}
	__xformToMat3x4(&frag.paintMat, invxform)
	return true
}

@(private)
__renderViewport :: proc(uptr: rawptr, width, height, devicePixelRatio: f32) {
	ctx := cast(^Context)uptr
	ctx.view = {width, height}
}

@(private)
__renderCancel :: proc(uptr: rawptr) {
	ctx := cast(^Context)uptr
	clear(&ctx.verts)
	clear(&ctx.indices)
	clear(&ctx.paths)
	clear(&ctx.calls)
	clear(&ctx.uniforms)
}

@(private)
__releaseBuffer :: proc(buf: ^wgpu.Buffer, cap: ^int) {
	if buf^ != nil {
		wgpu.BufferDestroy(buf^)
		wgpu.BufferRelease(buf^)
	}
	buf^ = nil
	cap^ = 0
}

// A buffer of at least `size` bytes (grown by half again when it runs out).
@(private)
__ensureBuffer :: proc(ctx: ^Context, buf: ^wgpu.Buffer, cap: ^int, size: int, usage: wgpu.BufferUsageFlags, label: string) -> bool {
	if buf^ != nil && cap^ >= size do return false
	__releaseBuffer(buf, cap)
	n := max(size, cap^ + cap^ / 2, 4096)
	n = (n + 255) / 256 * 256
	buf^ = wgpu.DeviceCreateBuffer(ctx.device, &{label = label, usage = usage + {.CopyDst}, size = u64(n)})
	cap^ = n
	return true
}

@(private)
__bind :: proc(ctx: ^Context, pass: wgpu.RenderPassEncoder, uniformOffset: int, image: int) {
	offsets := [1]u32{u32(uniformOffset)}
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, ctx.frag_bind, offsets[:])
	tex := __findTexture(ctx, image)
	if tex == nil do tex = __findTexture(ctx, ctx.dummyTex)
	wgpu.RenderPassEncoderSetBindGroup(pass, 1, tex.bind)
}

@(private)
__drawStrokes :: proc(pass: wgpu.RenderPassEncoder, paths: []Path) {
	for p in paths do if p.strokeCount > 0 do wgpu.RenderPassEncoderDraw(pass, u32(p.strokeCount), 1, u32(p.strokeOffset), 0)
}

@(private)
__drawFans :: proc(pass: wgpu.RenderPassEncoder, paths: []Path) {
	for p in paths do if p.fillCount > 0 do wgpu.RenderPassEncoderDrawIndexed(pass, u32(p.fillCount), 1, u32(p.fillOffset), 0, 0)
}

@(private)
__fill :: proc(ctx: ^Context, pass: wgpu.RenderPassEncoder, call: ^Call) {
	paths := ctx.paths[call.pathOffset:][:call.pathCount]
	// the winding into the stencil
	wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.FILL_STENCIL])
	__bind(ctx, pass, call.uniformOffset, 0)
	__drawFans(pass, paths)
	// antialiased edges, where the stencil is 0
	__bind(ctx, pass, call.uniformOffset + ctx.fragSize, call.image)
	if .ANTI_ALIAS in ctx.flags {
		wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.FILL_FRINGE])
		__drawStrokes(pass, paths)
	}
	// the fill, where the stencil is not 0 (and back to 0)
	wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.FILL_COVER])
	wgpu.RenderPassEncoderDraw(pass, u32(call.triangleCount), 1, u32(call.triangleOffset), 0)
}

@(private)
__convexFill :: proc(ctx: ^Context, pass: wgpu.RenderPassEncoder, call: ^Call) {
	paths := ctx.paths[call.pathOffset:][:call.pathCount]
	__bind(ctx, pass, call.uniformOffset, call.image)
	// (GL draws each fan and then its fringe; a convex fill has one path)
	for p in paths {
		if p.fillCount > 0 {
			wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.LIST])
			wgpu.RenderPassEncoderDrawIndexed(pass, u32(p.fillCount), 1, u32(p.fillOffset), 0, 0)
		}
		if p.strokeCount > 0 {
			wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.STRIP])
			wgpu.RenderPassEncoderDraw(pass, u32(p.strokeCount), 1, u32(p.strokeOffset), 0)
		}
	}
}

@(private)
__stroke :: proc(ctx: ^Context, pass: wgpu.RenderPassEncoder, call: ^Call) {
	paths := ctx.paths[call.pathOffset:][:call.pathCount]
	if .STENCIL_STROKES in ctx.flags {
		// the stroke's body without overlaps
		wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.STROKE_BASE])
		__bind(ctx, pass, call.uniformOffset + ctx.fragSize, call.image)
		__drawStrokes(pass, paths)
		// antialiased pixels
		wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.FILL_FRINGE])
		__bind(ctx, pass, call.uniformOffset, call.image)
		__drawStrokes(pass, paths)
		// the stencil back to 0
		wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.STROKE_CLEAR])
		__drawStrokes(pass, paths)
	} else {
		wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.STRIP])
		__bind(ctx, pass, call.uniformOffset, call.image)
		__drawStrokes(pass, paths)
	}
}

@(private)
__triangles :: proc(ctx: ^Context, pass: wgpu.RenderPassEncoder, call: ^Call) {
	wgpu.RenderPassEncoderSetPipeline(pass, ctx.pipes[.LIST])
	__bind(ctx, pass, call.uniformOffset, call.image)
	wgpu.RenderPassEncoderDraw(pass, u32(call.triangleCount), 1, u32(call.triangleOffset), 0)
}

@(private)
__renderFlush :: proc(uptr: rawptr) {
	ctx := cast(^Context)uptr
	defer __renderCancel(ctx)
	if ctx.target_color == nil do return
	if len(ctx.calls) == 0 && !ctx.clear_pending do return

	if len(ctx.verts) > 0 {
		__ensureBuffer(ctx, &ctx.vert_buf, &ctx.vert_cap, len(ctx.verts) * size_of(nvg.Vertex), {.Vertex}, "nanovg vertices")
		wgpu.QueueWriteBuffer(ctx.queue, ctx.vert_buf, 0, raw_data(ctx.verts), uint(len(ctx.verts) * size_of(nvg.Vertex)))
	}
	if len(ctx.indices) > 0 {
		__ensureBuffer(ctx, &ctx.index_buf, &ctx.index_cap, len(ctx.indices) * size_of(u32), {.Index}, "nanovg indices")
		wgpu.QueueWriteBuffer(ctx.queue, ctx.index_buf, 0, raw_data(ctx.indices), uint(len(ctx.indices) * size_of(u32)))
	}
	if len(ctx.uniforms) > 0 {
		if __ensureBuffer(ctx, &ctx.frag_buf, &ctx.frag_cap, len(ctx.uniforms), {.Uniform}, "nanovg uniforms") || ctx.frag_bind == nil {
			if ctx.frag_bind != nil do wgpu.BindGroupRelease(ctx.frag_bind)
			entries := [2]wgpu.BindGroupEntry {
				{binding = 0, buffer = ctx.frag_buf, offset = 0, size = size_of(FragUniforms)},
				{binding = 1, buffer = ctx.view_buf, offset = 0, size = 16},
			}
			ctx.frag_bind = wgpu.DeviceCreateBindGroup(ctx.device, &{label = "nanovg frag", layout = ctx.frag_layout, entryCount = 2, entries = &entries[0]})
		}
		wgpu.QueueWriteBuffer(ctx.queue, ctx.frag_buf, 0, raw_data(ctx.uniforms), uint(len(ctx.uniforms)))
	}
	view := [4]f32{ctx.view[0], ctx.view[1], 0, 0}
	wgpu.QueueWriteBuffer(ctx.queue, ctx.view_buf, 0, &view, size_of(view))

	cc := ctx.clear_color
	color := wgpu.RenderPassColorAttachment {
		view       = ctx.target_color,
		depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
		loadOp     = .Clear if ctx.clear_pending else .Load,
		storeOp    = .Store,
		clearValue = {f64(cc.r), f64(cc.g), f64(cc.b), f64(cc.a)},
	}
	stencil := wgpu.RenderPassDepthStencilAttachment {
		view              = ctx.target_stencil,
		stencilLoadOp     = .Clear if ctx.clear_pending else .Load,
		stencilStoreOp    = .Store,
		stencilClearValue = 0,
	}
	ctx.clear_pending = false
	enc := wgpu.DeviceCreateCommandEncoder(ctx.device)
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &{
		colorAttachmentCount = 1,
		colorAttachments = &color,
		depthStencilAttachment = &stencil,
	})
	if len(ctx.calls) > 0 {
		wgpu.RenderPassEncoderSetStencilReference(pass, 0)
		if ctx.vert_buf != nil do wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, ctx.vert_buf, 0, u64(ctx.vert_cap))
		if ctx.index_buf != nil do wgpu.RenderPassEncoderSetIndexBuffer(pass, ctx.index_buf, .Uint32, 0, u64(ctx.index_cap))
		for &call in ctx.calls {
			switch call.type {
			case .NONE:
			case .FILL: __fill(ctx, pass, &call)
			case .CONVEX_FILL: __convexFill(ctx, pass, &call)
			case .STROKE: __stroke(ctx, pass, &call)
			case .TRIANGLES: __triangles(ctx, pass, &call)
			}
		}
	}
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	cmd := wgpu.CommandEncoderFinish(enc)
	wgpu.QueueSubmit(ctx.queue, {cmd})
	wgpu.CommandBufferRelease(cmd)
	wgpu.CommandEncoderRelease(enc)
}

@(private)
__maxVertCount :: proc(paths: []nvg.Path) -> (count: int) {
	for i in 0 ..< len(paths) {
		count += len(paths[i].fill)
		count += len(paths[i].stroke)
	}
	return
}

@(private)
__allocCall :: #force_inline proc(ctx: ^Context) -> ^Call {
	append(&ctx.calls, Call{})
	return &ctx.calls[len(ctx.calls) - 1]
}

// The per-frame arrays grow by half again when they run out (see ../gl).
@(private)
__grow :: #force_inline proc(a: ^[dynamic]$T, need: int) {
	if need > cap(a) do reserve(a, max(need, cap(a) + cap(a) / 2))
}

@(private)
__allocPaths :: proc(ctx: ^Context, count: int) -> int {
	old := len(ctx.paths)
	__grow(&ctx.paths, old + count)
	resize(&ctx.paths, old + count)
	return old
}

@(private)
__allocVerts :: proc(ctx: ^Context, count: int) -> int {
	old := len(ctx.verts)
	__grow(&ctx.verts, old + count)
	resize(&ctx.verts, old + count)
	return old
}

@(private)
__allocFragUniforms :: proc(ctx: ^Context, count: int) -> int {
	ret := len(ctx.uniforms)
	__grow(&ctx.uniforms, ret + count * ctx.fragSize)
	resize(&ctx.uniforms, ret + count * ctx.fragSize)
	return ret
}

@(private)
__fragUniformPtr :: proc(ctx: ^Context, offset: int) -> ^FragUniforms {
	return cast(^FragUniforms)&ctx.uniforms[offset]
}

// A fan of `count` vertices from `first` as a triangle list: its offset in indices.
@(private)
__fanIndices :: proc(ctx: ^Context, first, count: int) -> (offset, n: int) {
	offset = len(ctx.indices)
	if count < 3 do return offset, 0
	n = (count - 2) * 3
	__grow(&ctx.indices, offset + n)
	for i in 1 ..< count - 1 {
		append(&ctx.indices, u32(first), u32(first + i), u32(first + i + 1))
	}
	return offset, n
}

@(private)
__copyPaths :: proc(ctx: ^Context, call: ^Call, paths: []nvg.Path, offset: int, fills: bool) -> int {
	offset := offset
	for i in 0 ..< len(paths) {
		copy := &ctx.paths[call.pathOffset + i]
		copy^ = {}
		path := &paths[i]
		if fills && len(path.fill) > 0 {
			copy.fillOffset, copy.fillCount = __fanIndices(ctx, offset, len(path.fill))
			intrinsics.mem_copy_non_overlapping(&ctx.verts[offset], &path.fill[0], size_of(nvg.Vertex) * len(path.fill))
			offset += len(path.fill)
		}
		if len(path.stroke) > 0 {
			copy.strokeOffset = offset
			copy.strokeCount = len(path.stroke)
			intrinsics.mem_copy_non_overlapping(&ctx.verts[offset], &path.stroke[0], size_of(nvg.Vertex) * len(path.stroke))
			offset += len(path.stroke)
		}
	}
	return offset
}

@(private)
__renderFill :: proc(uptr: rawptr, paint: ^nvg.Paint, compositeOperation: nvg.CompositeOperationState, scissor: ^nvg.ScissorT, fringe: f32, bounds: [4]f32, paths: []nvg.Path) {
	ctx := cast(^Context)uptr
	call := __allocCall(ctx)
	call.type = .FILL
	call.triangleCount = 4
	call.pathOffset = __allocPaths(ctx, len(paths))
	call.pathCount = len(paths)
	call.image = paint.image
	if len(paths) == 1 && paths[0].convex {
		call.type = .CONVEX_FILL
		call.triangleCount = 0
	}
	maxverts := __maxVertCount(paths) + call.triangleCount
	offset := __copyPaths(ctx, call, paths, __allocVerts(ctx, maxverts), true)
	if call.type == .FILL {
		// the quad that covers the fill
		call.triangleOffset = offset
		quad := ctx.verts[call.triangleOffset:][:4]
		quad[0] = {bounds[2], bounds[3], 0.5, 1}
		quad[1] = {bounds[2], bounds[1], 0.5, 1}
		quad[2] = {bounds[0], bounds[3], 0.5, 1}
		quad[3] = {bounds[0], bounds[1], 0.5, 1}
		// the stencil pass's shader, then the fill's
		call.uniformOffset = __allocFragUniforms(ctx, 2)
		frag := __fragUniformPtr(ctx, call.uniformOffset)
		frag^ = {}
		frag.strokeThr = -1
		frag.type = .SIMPLE
		__convertPaint(ctx, __fragUniformPtr(ctx, call.uniformOffset + ctx.fragSize), paint, scissor, fringe, fringe, -1)
	} else {
		call.uniformOffset = __allocFragUniforms(ctx, 1)
		__convertPaint(ctx, __fragUniformPtr(ctx, call.uniformOffset), paint, scissor, fringe, fringe, -1)
	}
}

@(private)
__renderStroke :: proc(uptr: rawptr, paint: ^nvg.Paint, compositeOperation: nvg.CompositeOperationState, scissor: ^nvg.ScissorT, fringe: f32, strokeWidth: f32, paths: []nvg.Path) {
	ctx := cast(^Context)uptr
	call := __allocCall(ctx)
	call.type = .STROKE
	call.pathOffset = __allocPaths(ctx, len(paths))
	call.pathCount = len(paths)
	call.image = paint.image
	maxverts := __maxVertCount(paths)
	__copyPaths(ctx, call, paths, __allocVerts(ctx, maxverts), false)
	if .STENCIL_STROKES in ctx.flags {
		call.uniformOffset = __allocFragUniforms(ctx, 2)
		__convertPaint(ctx, __fragUniformPtr(ctx, call.uniformOffset), paint, scissor, strokeWidth, fringe, -1)
		__convertPaint(ctx, __fragUniformPtr(ctx, call.uniformOffset + ctx.fragSize), paint, scissor, strokeWidth, fringe, 1 - 0.5 / 255)
	} else {
		call.uniformOffset = __allocFragUniforms(ctx, 1)
		__convertPaint(ctx, __fragUniformPtr(ctx, call.uniformOffset), paint, scissor, strokeWidth, fringe, -1)
	}
}

@(private)
__renderTriangles :: proc(uptr: rawptr, paint: ^nvg.Paint, compositeOperation: nvg.CompositeOperationState, scissor: ^nvg.ScissorT, verts: []nvg.Vertex, fringe: f32) {
	ctx := cast(^Context)uptr
	call := __allocCall(ctx)
	call.type = .TRIANGLES
	call.image = paint.image
	call.triangleOffset = __allocVerts(ctx, len(verts))
	call.triangleCount = len(verts)
	if len(verts) > 0 do intrinsics.mem_copy_non_overlapping(&ctx.verts[call.triangleOffset], raw_data(verts), size_of(nvg.Vertex) * len(verts))
	call.uniformOffset = __allocFragUniforms(ctx, 1)
	frag := __fragUniformPtr(ctx, call.uniformOffset)
	__convertPaint(ctx, frag, paint, scissor, 1, fringe, -1)
	frag.type = .IMG
}

@(private)
__renderDelete :: proc(uptr: rawptr) {
	ctx := cast(^Context)uptr
	for &texture in ctx.textures do if texture.id != 0 do __deleteTexture(ctx, texture.id)
	__releaseBuffer(&ctx.vert_buf, &ctx.vert_cap)
	__releaseBuffer(&ctx.index_buf, &ctx.index_cap)
	__releaseBuffer(&ctx.frag_buf, &ctx.frag_cap)
	if ctx.view_buf != nil do wgpu.BufferRelease(ctx.view_buf)
	if ctx.frag_bind != nil do wgpu.BindGroupRelease(ctx.frag_bind)
	for p in ctx.pipes do if p != nil do wgpu.RenderPipelineRelease(p)
	for s in ctx.samplers do if s != nil do wgpu.SamplerRelease(s)
	if ctx.layout != nil do wgpu.PipelineLayoutRelease(ctx.layout)
	if ctx.frag_layout != nil do wgpu.BindGroupLayoutRelease(ctx.frag_layout)
	if ctx.tex_layout != nil do wgpu.BindGroupLayoutRelease(ctx.tex_layout)
	if ctx.shader != nil do wgpu.ShaderModuleRelease(ctx.shader)
	delete(ctx.textures)
	delete(ctx.paths)
	delete(ctx.verts)
	delete(ctx.indices)
	delete(ctx.uniforms)
	delete(ctx.calls)
	free(ctx)
}
