# NanoVG and fontstash (vendored)

Copies of Odin's `vendor:nanovg` and `vendor:fontstash` (Odin-native ports of
[nanovg](https://github.com/memononen/nanovg) and
[fontstash](https://github.com/memononen/fontstash), zlib licence), taken from Odin
dev-2026-10. Kept in the repository so that `wgpu/`, a WebGPU backend written here after
`gl/` (the same calls, the same shader in WGSL, the same stencil passes, fans turned into
index lists), sits next to the GL one, and so that the following fixes can be applied:

- fontstash: glyph advances and positions are no longer rounded to whole pixels of the
  rendered size, so text keeps its width and position at every zoom level.
- nanovg: the font atlas resize callback creates an empty texture of the new size instead
  of uploading the old, smaller buffer (a crash in `glTexImage2D`).
- nanovg: `__flattenPaths` skips paths without points instead of indexing `pts[-1]`.
- fontstash/nanovg: `__flattenPaths` aside, the stroker skips open paths that collapse to a
  single point (a zero-length segment such as lucide's `M12 8h.01`) instead of reading
  `pts[1]`.
- nanovg: glyphs are rasterised at most `MAX_GLYPH_PIXELS` (256) high (`__textScale`); larger
  text is drawn scaled up. At high zoom, glyphs of several hundred pixels used to fill the
  atlas and the rest of the frame's text vanished. Text that big on screen is drawn from
  its glyph outlines instead (`src/engine/text_outline.odin`), so it stays sharp.
- nanovg: `QuadTo` placed its control points with `2 / 3`, an integer division that is 0
  in Odin, so every quadratic curve was a straight line (glyph outlines, SVG `Q`/`T`).
  Now `2.0 / 3.0`.
- fontstash: the font size maps to the em square (`ScaleForMappingEmToPixels`), as in CSS,
  Figma and pen.dev; ascender, descender and line height are relative to the em. Upstream
  used `ScaleForPixelHeight`, which drew every font smaller by (ascent − descent) / em.
- nanovg: `TextBreakLines` also breaks a line after a hyphen between letters
  ("Sample-|specific"), as Skia's ICU line breaker does in pen.dev; not before a digit
  ("-5" stays whole).
- nanovg/gl: `RecycleBuffers` gives back what the per-frame arrays grew to and gives the
  buffer objects fresh storage, between frames (the app calls it when it goes quiet).
- nanovg/gl: the per-frame arrays (`paths`, `verts`, `uniforms`) grow by half again when
  they run out (`__grow`), as upstream's C code does. `resize` alone reserved exactly what
  was asked, so after `RecycleBuffers` a big frame regrew them in thousands of steps, each
  a full copy once past 256 KB.
- nanovg: `CreateImagePath` and `CreateImageMem` ask stb_image for 4 channels but cut the
  pixel slice to the file's own channel count (3 for an RGB PNG such as a dashboard
  thumbnail). The GL backend read past the slice through its raw pointer and never
  noticed; the WebGPU backend copies the slice and trapped. The slice is now 4 channels.
- nanovg: builds for `js` too (upstream lists only Windows, Linux and macOS), for the
  browser viewer; `CreateImagePath` returns 0 there, as stb_image has no file access in
  WebAssembly (the engine reads an image's bytes and calls `CreateImageMem`).
- fontstash/nanovg: small text is drawn as Skia draws it in Chrome: each glyph rasterised
  at the pen's subpixel offset (4 bins across a pixel, `MakeGlyphBitmapSubpixel`, the bin
  part of the glyph's cache key) and its quad placed on whole device pixels, with the
  baseline on a whole pixel row. It applies when a unit of fontstash's space is a device
  pixel (an axis-aligned transform at the scale `__textScale` uses: screenshots at whole
  scales, the canvas at 100 % and 200 %); elsewhere glyphs keep their fractional positions.
  Before, every glyph bitmap was drawn at a fractional position and blurred by the
  texture's bilinear sampling. Advances stay unrounded, so text keeps its width.
- fontstash: GPOS pair kerning of a variable font's instance adds the deltas its
  `XAdvDevice` tables point to in GDEF's item variation store, at the instance's axis
  coordinates (a private `ADvc` table that the engine's `varfont_instance` writes).
  Without them every instance kerned as the default one: Inter at 500 and 600 came out
  with Regular's kerning, wider or tighter than in Chrome by up to a pixel per pair.
