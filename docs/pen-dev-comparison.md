# Agentic Design vs pen.dev: interface and features

Compared on 2026-10-31 against pen.dev's desktop app (Pen.app) and its web editor
(app.pen.dev), using the same files (reddit-ui, the Sample Search design system, text and
gradient test files), its documentation (docs.pen.dev) and its MCP server. Rendering parity
was found while using the app for real work (the dogfooding log, kept with the tests).

## How to read the tables

- **pen.dev** is the reference behaviour.
- **Before** and **Now** describe Agentic Design at the start and at the end of this session.
- **Status** values:
  - **done**: on par.
  - **partial**: works, with the gap named.
  - **missing**: not there yet.

## Canvas and navigation

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Pan and zoom | space-drag, two fingers, pinch, ⌘-scroll | same, plus smart zoom on two-finger double tap | same | done |
| Zoom shortcuts | ⌘0 100%, ⇧1 fit all, ⇧2 selection, ⌘± | ⌘0 fit, ⌘1 100%, ⌘± | ⇧1, ⇧2; ⌘0 is 100% | done |
| Zoom tool | hold Z: click to zoom, drag a region | — | hold Z: click in, ⌥-click out, drag a region | done |
| Selection colours | blue; magenta for a component origin, violet for an instance | blue | blue / magenta / violet | done |
| Smart guides | edge and centre snapping | yes | yes | done |
| Measurements | distances to the hovered element | — | hold ⌥: gaps to the layer under the pointer, or insets within the parent | done |
| Pixel grid and snap toggles | Settings, ⌘' | — | pixel grid from 800% (⌘'), snap to pixels, smart guides on/off | done |
| Settings: nudge amounts, scroll-to-zoom | Settings → General | — | Settings sheet (⌘,): nudge and big nudge, the toggles above, onboarding again | partial (scroll always pans) |
| Performance | "120 fps" | 2–5 ms per frame on reddit-ui; off-screen culling | same | done |

## Tools

| Tool | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Move, hand, frame, rectangle, ellipse, text | V H A/F R O T | V H F R E T | adds O for ellipse | done |
| Image | primitives menu | image tool, drop, place dialog | same | done |
| Pen tool and path editing | P, point editing, cut | — | P: corner and smooth points, close on the first point; double click a path to drag points and handles (⌥ breaks the mirror), add a point on a segment, ⌫ removes one | partial (no cut, no boolean operations) |
| Polygon, icon picker | primitives menu | icons via the format and MCP only | same | partial (no icon picker UI) |
| Scale tool | K, scales text, strokes, effects | — | — | missing |
| Sticky note | N | — | — | missing |

## Selection

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Click, shift-click, marquee | yes | yes | yes | done |
| ⌘A select all | yes | yes (all pages) | yes | done |
| Enter / ⇧Enter | children / parent | Enter edits text | Enter: children (text: edit); ⇧Enter: parent | done |
| Click levels, ⌘-click deep select, ⌘-drag nested marquee | yes | click took the deepest layer | click picks the layer at the working level, double click goes one level in, ⌘-click the deepest; a marquee started in a frame picks its layers, ⌘ the innermost | done |
| Esc | clears the selection | yes | yes | done |

## Layers panel

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Tree with type icons, instance and component colour | yes | icons, component names | same | done |
| Rename (double click), hide (eye) | yes | yes | yes | done |
| Drag to reorder or move into a container | yes | — | yes: drop above, below, or into a frame or group | done |
| Find layers (search) | toolbar | — | search field over the tree (⌘F): name, text or type, with the parent shown | done |
| Instance internals in the tree | shown in violet | slot content only | same | partial |
| Lock | — | — | — | — (pen.dev has none either) |

## Properties panel

| Section | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Header | name and type icon, **Create Component** | name; "Component (reusable)" checkbox | name, **Create component ⌘⌥K** or "Component origin · Make plain layer" | done |
| Alignment | 6 buttons, single or multiple | multi-selection only | 6 buttons; one layer aligns inside its parent; ⌥A/D/W/S/H/V | done |
| Position | X, Y, rotation, rotate 90°, flip H/V, Absolute Position | X, Y; absolute under Flex | X, Y, **rotation**, rotate 90°, **flip H/V** (⇧H/⇧V), absolute when the parent has flex; turning and flipping keep the layer in place; clicks, outlines and marquee follow the drawn shape | partial (no resize handles on a turned layer) |
| Flex layout | none/vertical/horizontal, 3×3 alignment, gap or space-between/around, padding (2 or 4) | same controls | same, named "Layout" | done |
| Dimensions | W, H, Fill Width/Height, Hug Width/Height checkboxes | W/H fields taking "fit_content" / "fill_container" text | W, H, **Fill** (in flex parents) and **Hug** checkboxes | done |
| Text resizing | auto width, auto height, fixed size | dropdown | **3-button segmented control** | done |
| Appearance | opacity, corner radius with per-corner toggle, eye, Clip Content | radius slider, opacity, eye, "Normal" blend label | opacity, radius with **per-corner** fields, eye, clip | done (no blend mode) |
| Fill | list with +, eye, −; colour, gradient (linear, radial, angular, mesh), image, shader; blend mode | one fill (colour, variable or image) | **list** with +, eye, −, type menu (solid / linear / radial / angular), first and last stop colours, rotation, size | partial (no stop editing beyond the ends, mesh, shader, blend mode) |
| Stroke | +, width, inside/center/outside | width, alignment, colour | same; new strokes are written "inner" | done (one stroke) |
| Effects | drop shadow, inner shadow, layer blur, background blur, shader; list | one shadow | **list**: drop and inner shadows, layer blur and background blur, all drawn as pen.dev draws them | done (no shader effects) |
| Typography | font, weight, size (variable binding), line height, letter spacing, align ×4, vertical ×3 | font, size, weight, align ×3, growth | adds **line height**, **letter spacing**, **justify**, **vertical align**, underline, strikethrough | done (no variable binding UI for size) |
| Theme | per frame, add/remove | per frame | same | done |
| Instance | Go to component, Detach | Go to component, Detach, Parameters | same | done (Parameters goes beyond pen.dev's UI) |
| Context | notes for the agent | — | **Context** field (`context` property) | done |
| Code | HTML + Tailwind, copy, export | Export ▾ menu (HTML + CSS, React + Tailwind); one fill, first shadow | every fill and gradient, all shadows, blurs, rotation and flips, justify and vertical align, written as pen.dev writes them | done |
| Export | per layer, scale and format (PNG, JPEG, WEBP, PDF) | PNG of the selection at 2× | per layer, 1×–4×, **PNG, JPEG, WEBP, PDF**; `screenshot` writes any of them | partial (WEBP is lossless and uncompressed, PDF holds a raster) |

## Colour picker

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| HSV, hex, alpha | yes | yes | yes | done |
| Document colours | variables | named list with search | same | done |
| Fill type tabs (colour / gradient / image) | in the picker | — | type menu on the fill row | partial |
| Gradient stops | bar with stops, drag handles on the canvas | — | stop bar (drag a stop, click to add), a row per stop (position, colour, remove), canvas handles for the ends of a linear gradient and the centre and radii of radial and angular ones | done |
| Eyedropper | — | — | — | — |

## Fonts

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Font picker | search, previews | search, previews in their own face | same | done |
| Font metrics | CSS-like | 17% too small, line height 1.2 | em size, font line height, half leading | done |
| Kerning | yes | `kern` table only | **GPOS pair kerning** (Extension lookups included; a variable font's kerning at its weight) | done |
| Variable fonts | all weights | default instance only | any weight on demand: TrueType variable fonts are instanced in the app (matches fontTools within 1.2 units) | done (CFF2 variable fonts keep their default) |
| Custom fonts per document | import ttf/otf/woff/woff2 | — | a `fonts` folder next to the document, filled by the import button or by dropping font files; also `.ttc` collections and `.woff` | partial (no woff2) |
| Missing font warning | Typography reports it | "(missing)" in the menu | same | done |

## Variables and themes

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Variables panel | table: rows × theme columns, add by type, row menu | list in the sidebar (shown theme only) | **variables table**: axis tabs, a column per value, editable cells with aliases, search, add (colour, number, string, boolean), delete, add axis or value | done |
| Themes per frame | Theme → add theme | yes | yes | done |
| Apply variable beside a property | yes | fill/stroke via the picker | same | partial |

## Components

| Feature | pen.dev | Before | Now | Status |
| --- | --- | --- | --- | --- |
| Create / undo component | ⌘⌥K | checkbox, context menu | **⌘⌥K** and header button | done |
| Detach | ⌘⌥X | inspector | adds **⌘⌥X** | done |
| Components panel | search, click or drag onto the canvas | — | **Components tab**: previews, search, click inserts in the view, drag drops into the frame under the pointer, double click goes to the origin | done |
| Overrides | any property | any property (this session) | same | done |
| Slots | `descendants[slot].children` | yes (this session) | same | done |
| Libraries | import components across files | — | `imports` read under their alias ("ui:btn", "$ui:brand", overrides "ui:label"), listed in the Components tab, import and remove there or with `set_libraries` | done |

## Editing shortcuts

| Shortcut | pen.dev | Now |
| --- | --- | --- |
| ⌘X cut | yes | added |
| ⌘[ / ⌘] one step, [ / ] back / front | yes | added (⌘[ / ⌘] used to go all the way) |
| Arrows reorder inside flex | yes | added |
| ⇧⌥A remove flex | yes | added |
| ⌘⇧C copy as PNG, ⌥⌘C copy as HTML | yes | added |
| ⌘⇧R paste to replace | yes | missing |
| ? shortcut sheet | yes | added |

## Agents

| Feature | pen.dev | Now |
| --- | --- | --- |
| Connect agents | silently, 6 clients | onboarding, 9 clients, one click each |
| Built-in chat | yes | no (the user's own agent works through MCP) |
| MCP tools | `execute` (JS API), `get_app_state`, `browser`, `get_style`, `read_skill` | `.pen` JSON tools: get (with `ids` and `depth`) / create / update / delete, screenshot, `get_variables`, `get_styles` (a node's CSS), variables, pages, export |

## Still missing, by value

1. ~~Pen tool and path editing.~~ Done; cutting paths and boolean operations remain.
2. ~~Measurements and a zoom tool.~~ Done.
3. ~~Per-document custom fonts and on-demand variable fonts.~~ Done, except woff2.
4. ~~Gradient stop editing and on-canvas handles.~~ Done. Mesh gradients and blend modes remain.
5. ~~Blur effects.~~ Done.
6. ~~More export formats.~~ Done; WEBP is uncompressed and PDF is a raster page.
7. ~~Find layers, ⌘-click deep select, a shortcut sheet, settings.~~ Done.
8. ~~Libraries.~~ Done.
9. **Resize handles on turned layers.** Clicks, outlines and the marquee follow rotation and flips; resizing a turned layer works from the inspector only.
10. **Smaller gaps.** Mesh and shader fills, blend modes, woff2, the scale tool, sticky notes, an icon picker, scroll-to-zoom as a setting, compressed WEBP and vector PDF.

Styled runs inside one text are not on the list: the 2.21 format has none (`content` is a
string), so pen.dev has none either. 2.8 files that use them still lose the styles.

## Found while comparing code export (2026-10-31)

- pen.dev turns **and mirrors** a layer around its top-left corner; a flipped layer is drawn
  to the left of (or above) its x/y. Its HTML export says the same
  (`transform-origin: top left; transform: scaleX(-1)`). Agentic Design flipped around the
  centre; it now draws as pen.dev does, and its flip commands move x/y so the layer stays in
  place.
- pen.dev exports a blur of radius r as `blur(r/2)` and shadows as CSS `box-shadow` with the
  same numbers, and its canvas matches that. Our canvas faded shadows over half the
  distance; it now matches both.
- pen.dev does not draw `underline` or `strikethrough`, though the schema has them. We draw
  them.

