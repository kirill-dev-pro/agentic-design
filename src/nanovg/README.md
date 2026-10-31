# NanoVG and fontstash (vendored)

Copies of Odin's `vendor:nanovg` and `vendor:fontstash` (Odin-native ports of
[nanovg](https://github.com/memononen/nanovg) and
[fontstash](https://github.com/memononen/fontstash), zlib licence), taken from Odin
dev-2026-10. Kept in the repository so the following fixes can be applied:

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
  atlas and the rest of the frame's text vanished.
- fontstash: the font size maps to the em square (`ScaleForMappingEmToPixels`), as in CSS,
  Figma and pen.dev; ascender, descender and line height are relative to the em. Upstream
  used `ScaleForPixelHeight`, which drew every font smaller by (ascent − descent) / em.
