# Architecture

How the app is put together. The reasons behind each choice are in
[decisions.md](decisions.md).

## Processes

```
Claude Code ──stdio──▶ agentic-design mcp ──TCP 127.0.0.1:4410──▶ agentic-design (window)
                         (src/mcp.odin)        newline-delimited JSON   (src/server.odin, src/api.odin)
```

- **The window** (`agentic-design [file.pen]`) owns the documents, draws them and serves
  the control socket on `127.0.0.1:4410`.
- **The MCP server** (`agentic-design mcp`) is the same binary in another mode. It speaks MCP
  over stdio, turns each tool call into one socket request and relays the answer. When the
  window is not running, it starts the window with `AGENTIC_NO_FOCUS=1`. The window's stderr
  goes to `$TMPDIR/agentic-design.log`.
- The socket also serves tests and scripts. Besides the MCP tools it has `input` (synthetic
  pointer and key events), `perf` (frame phase timings and counters) and `export_code`.

Network threads only queue requests. The main thread runs them between frames
(`process_requests`), so the document is never touched from two threads.

## Engine and app

The source is two Odin packages:

- **`src/engine`** (package `engine`) works on `.pen` documents without a window. It holds
  the document model and the file format, variables, themes, pages and libraries, layout,
  fonts and text, drawing a node tree with NanoVG, blur, images, PNG encoding and code
  export.
- **`src/`** (package `agentic_design`) is the app built around it: the window and its
  input, the interface, tabs, undo, the control socket, the MCP server and agent presence.
  It refers to engine names with the `engine.` prefix.

The engine imports nothing from the app. It can be compiled alone:
`odin check src/engine -no-entry-point`. What it needs from its host is set in a few
globals in `src/engine/engine.odin`:

| Global | Set by the app to |
| --- | --- |
| `renderer` | the NanoVG context the engine draws and measures text with |
| `current` | the document that drawing, lookups and labels work on (`&app.doc`; tabs swap into it) |
| `hidden` | the set of top-level layers on pages that are not shown |
| `theme` | the theme shown: axis -> value |
| `allocator` | the allocator for code called from C (zlib), so that frees match |

The engine tells the app that layout must run again by bumping `layout_epoch`
(`layout_invalidate`). The draw order of top-level layers is built by the app and passed
in where it is needed (`Blur_View.order`). A document carries its own `path`, so
relative image and library paths resolve without app state. One engine serves one
process and one thread: fonts and the glyph atlas live in the NanoVG context.

The split exists for other hosts: a WebGPU renderer behind the same drawing calls, a
viewer in the browser, and native apps on other platforms (decision #51).

## The frame

`app_main` in `src/app.odin` runs one loop per frame:

1. Free the temp allocator and trim the font atlas if it has grown too large.
2. Poll GLFW and the Cocoa gesture hooks into per-frame input state (`platform_poll`).
3. Lay out the document, run queued socket requests, and lay out again if a request changed
   anything.
4. Sync pages (which top-level nodes are hidden) and build the draw order.
5. Handle dropped files and canvas input (tools, drag, shortcuts). Lay out again if needed.
6. Autosave if the document has been dirty for more than a second.
7. Render pending offscreen work: screenshots, dashboard thumbnails, PNG export.
8. Draw the canvas, then the interface (`draw_ui`). Widgets handle their own clicks while
   they draw. Overlays such as menus, the color picker, dialogs and tooltips are drawn last.
9. Swap buffers and store phase timings in `app.perf`.

Layout runs only when something changed (`app.needs_layout`, `mark_dirty`). The text and
instance caches keep a layout pass cheap. On the reddit-ui sample a frame takes 2–5 ms.

## Document model (`src/engine/doc.odin`)

A document is a **flat array of nodes**:

- `parent` holds the container's uid, with 0 meaning the canvas.
- Array order is the stacking order among siblings; later nodes are on top.
- `uid` is an internal handle that is never saved. `id` is the `.pen` id.

Each node keeps its **authored `.pen` properties as raw JSON** (`props`, in file order). That
list is the source of truth and the only thing written back to disk. The typed fields
(`kind`, `width`, `fill`, `font_size`, …) are a parsed cache rebuilt by `node_refresh`.

Every edit goes through `node_set*` / `node_unset`. These rewrite one prop and call
`node_refresh`. Code never writes a parsed field without the prop behind it.

The document header holds every top-level key except `children` (`version`, `themes`,
`variables`, `pages`, and anything unknown) as raw JSON too.

`x, y, w, h` on a node are its absolute box, computed by layout. `pos` is the authored
position relative to the parent, as in the file.

**Indexes and versions.** `doc.version` goes up on every structural change (`doc_bump`).
These derived structures compare against it and rebuild lazily:

| Structure | Contents |
| --- | --- |
| `by_uid`, `by_id` | node index, validated on use |
| `kids` | child uid lists per parent |
| `ghosts` | instance expansions, see below |
| `pages` | the parsed header `pages` |
| `theme_axes` | the parsed header `themes` |

**Instances as ghosts.** A `ref` node (an instance of a `reusable` component) is expanded
into a tree of *ghost* nodes:

- The ghosts are copies of the component's parsed nodes. Overrides from the instance's
  `descendants` are applied, outer instances last so they win. The instance's own
  properties override the component root. Overrides outside the common fields are
  written into a copy of the node's props, which is parsed again (decision #23).
- Ghosts live in `doc.ghosts`. They are laid out and drawn like real nodes, but never saved,
  selected or edited.
- The instance's real children are slot content. Layout and drawing put them inside the
  component's slot frame (`children_for_layout`).
- Nesting is capped at `MAX_INSTANCE_DEPTH`, and an instance inside its own component is
  refused.

**Themes** (`src/engine/themes.odin`):

- **Axes.** The header declares axes and their values: `"themes": {"mode": ["light", "dark"]}`.
- **Themed values.** A variable can carry one value per theme:
  `value: [{value, theme: {mode: "dark"}}, …]`. Every variant is parsed into `var_defs`.
- **Subtree themes.** A node's `theme` property switches the theme for its subtree.
- **Resolution.** `node_refresh` works out the theme in effect at the node: the global
  choice in `app.theme`, overridden by each ancestor's `theme` from the root down. Variables
  are then resolved against that theme. `var_get` skips entries that contradict it and picks
  the most specific match.
- **Instances under another theme.** When an instance sits under a different theme than its
  component, its ghosts are re-parsed under the instance's theme.

**Pages** (`src/engine/pages.odin`) live in the header as
`"pages": [{"name", "nodes": [top-level ids]}]`. `pages_sync` turns the shown page into a set
of hidden top-level uids every frame.

## Layout (`src/engine/layout.odin`)

Each top-level subtree gets two passes:

- **`measure`** works bottom-up. It finds intrinsic sizes from text metrics, path view boxes
  and `fit_content` (children plus gap and padding). As in pen.dev, `fill_container`
  children add nothing to a fit-content container on that axis. They get the size its other
  children give it across the flow, and nothing along it. In a flex container, children
  with their own size along the flow are measured first. The `fill_container` ones are
  then measured with their share of what is left, so text inside them wraps at the width
  it will get.
- **`arrange`** works top-down. It hands out final boxes: it distributes `fill_container`
  space along the flow, applies `justifyContent` and `alignItems`, and keeps
  `layoutPosition: absolute` children at their authored position. A node whose final size
  differs from its measurement is measured again, and a fit-content height follows the new
  measurement.

**Text** is measured at document scale, with the NanoVG transform reset, and cached in
`text_cache`. The cache key is the content, face, size, line height and wrap width. The
cached value holds the size and the line breaks as byte ranges. Drawing replays those lines
one by one, so wrapping does not change with zoom.

## Rendering (`src/engine/draw.odin`, `src/engine/gpu.odin`, `src/app.odin`)

NanoVG draws everything:

- the canvas under a camera transform (`app.cam`, `app.zoom`), including Lucide icons
  from the built-in set (`src/engine/icons.odin`, decision #22). Nodes outside the visible part
  of the page are skipped (`cull_rect`): leaves and clipping frames by their box,
  unclipped containers still visit their children.
- the interface in screen space on top.

`draw_node_tree` draws boxes (fill, stroke with alignment, corner radii, image fills, outer
shadow), ellipses, SVG paths parsed by `src/engine/svgpath.odin`, text, and placeholders for node
types the app does not render.

NanoVG turns paths, images and text into GPU work through its backend: `src/nanovg/gl`
(OpenGL 3.2) or `src/nanovg/wgpu` (WebGPU, decision #53). The rest of the GPU work goes
through `src/engine/gpu.odin` (decision #52):

- `gpu_window_begin` and `target_begin` choose where the next NanoVG frame draws (the
  window or an offscreen `Target`) and clear it;
- `gpu_blur` runs one direction of the Gaussian for layer and background blur
  (`src/engine/blur.odin`);
- `gpu_read` reads pixels back, top row first: screenshots, thumbnails, copy as PNG and
  export render the region in tiles of 2048 px through one target (`render_region` in
  `src/api.odin`), a view screenshot reads the window;
- `gpu_max_side`, `gpu_trim` and `gpu_finish` give the texture limit and hand memory back.

One backend is compiled in: WebGPU by default (`src/engine/gpu_wgpu.odin`, on
wgpu-native, which runs on Metal here and Vulkan or D3D12 elsewhere; decision #54),
OpenGL with `-define:RENDERER=gl` (`src/engine/gpu_gl.odin`). No other file calls the GPU
API. With WebGPU the GLFW window has no GL context; `src/metal_darwin.odin` gives its
content view a `CAMetalLayer` tagged sRGB, the frame is drawn into one of the layer's two
drawables and `gpu_present` shows it. When the window is not visible (behind other
windows, a locked screen), wgpu gives no drawable and the frame goes to an offscreen
target of the window's size, so view screenshots keep working.

Patched copies of NanoVG and fontstash live in `src/nanovg` and `src/fontstash`. The
patches are listed in `src/nanovg/README.md`.

## Interface (`src/widgets.odin`, `src/ui.odin`)

The interface is **immediate mode**. Widgets are procedures called every frame, and each
returns what happened (`button` → clicked, `field` → edits the buffer). The little state they
need lives in the global `ui`:

- the focused field key and its buffer,
- the open menu, picker or dialog,
- drags, scrubbing and tooltips.

`src/widgets.odin` is the library: buttons, icon buttons, checkboxes, dropdowns, sliders,
text and number fields, searchable menus, the HSV color picker, dialogs, tooltips,
scrollbars and sections. `src/ui.odin` builds the panels from it: tab bar, sidebar (pages,
layers, Theme tab), tool strip and inspector. The inspector's sections live in
`src/inspector.odin`, the Components tab in `src/components_panel.odin`, the variables
table in `src/variables_table.odin`. `src/engine/paint.odin` draws fills, gradients and shadows
for the renderer.

Rules the widgets follow:

- **Overlays are modal.** While a menu, picker or dialog is open, `hovered` and `clicked`
  return false everywhere except inside the overlay (`ui.overlay_pass`). `handle_input`
  leaves the canvas alone.
- **Results come back by key.** A menu opened with a key returns its pick on a later frame
  through `menu_take(key)`. The picker and dialogs work the same way (`picker_take`,
  `dialog_take`).
- **Fields commit through one place.** A field is identified by `(uid, key)`. Enter, Tab or
  a click elsewhere commits it through `field_commit` → `field_apply`. That function decides
  from the key what to write: a node property, a page name, a variable, a theme value, an
  instance override, and so on. Tab moves to the next field drawn in the frame.

## Input (`src/input.odin`, `src/platform.odin`, `src/gestures_darwin.odin`)

`platform.odin` turns GLFW callbacks into per-frame state (`key_pressed`, `mouse_pressed`,
`pf.wheel`, typed characters). The socket's `input` method feeds the same state, so a
synthetic event cannot be told apart from a real one.

GLFW does not report pinch, and it scales trackpad scrolling down. The Cocoa view's
`scrollWheel:`, `magnifyWithEvent:` and `smartMagnifyWithEvent:` are therefore replaced with
our own handlers, which accumulate into `gest`.

`handle_input` covers the canvas:

- tools and selection,
- move and resize with smart guides (`snap_box`),
- marquee selection and text editing,
- the context menu and shortcuts.

Shared editing commands live in `src/edit.odin`: group, wrap in frame or auto layout,
align, clipboard and z-order.

## Tabs, files and persistence

- **Tabs** (`src/tabs.odin`). Each open file is a tab. The active tab's state lives in `app`:
  document, path, selection, undo stacks, camera and page. `tab_activate` swaps it in and
  out of `app.tabs[i]`. `app.tab == -1` shows the dashboard (`src/dashboard.odin`).
- **Saving.** Every change marks the document dirty. Autosave writes it a second after the
  last change, and closing a tab or quitting saves too. `doc_serialize` writes the header
  props, then each node's props in their original order. The `children` key is regenerated
  from the tree.
- **Undo** (`push_undo`). Each step stores a snapshot of the whole node array, capped at 200
  steps.
- **Recent files** are kept in `~/Library/Application Support/Agentic Design/recents.json`.
  Thumbnails are rendered into `thumbs/` next to it: the open document's from memory
  right after it is saved, other files from the saved file (docs/performance.md).
- **Images** dropped or placed on the canvas are copied into `images/` next to the document
  and referenced as `./images/<name>`.
- **The clipboard** holds a JSON array of `.pen` nodes, also put on the system clipboard as
  text.

## Code export (`src/engine/codegen.odin`)

Export generates code for the current page from the parsed model:

- **HTML + CSS** (`index.html`, `styles.css`): one element and one class per node, using
  flex or absolute positioning as in the document. Variables become CSS custom properties,
  and each non-default theme value becomes a `[data-theme-<axis>="<value>"]` block. Instances
  are expanded.
- **React** (`components.tsx`, `Page.tsx`, `globals.css`):
  - one function per component, with props for every descendant any instance overrides;
  - slot content as `children`;
  - shadcn/ui primitives for components named Button, Card, Input, Badge, and so on;
  - Tailwind arbitrary values for styles;
  - `Page.tsx` builds the page from component instances with their props.

## Modules

Engine (`src/engine/`):

| File | Role |
| --- | --- |
| `engine.odin` | the globals the host sets, `sorted_keys` |
| `gpu.odin`, `gpu_gl.odin`, `gpu_wgpu.odin` | the GPU interface besides NanoVG: offscreen targets, blur pass, pixel readback; its OpenGL and WebGPU backends |
| `doc.odin` | node model, props, parsing, indexes, instances, overrides, undo snapshots |
| `pen.odin` | `.pen` reading and writing, variable resolution |
| `themes.odin`, `pages.odin`, `libraries.odin` | theme axes and themed variables; pages in the header; imported libraries |
| `layout.odin` | measure/arrange, text metrics cache |
| `fonts.odin`, `varfont.odin`, `text_outline.odin` | fonts by family and weight; variable font instances; text drawn as outlines |
| `draw.odin` | transforms and drawing a node tree: boxes, paths, text, placeholders, culling, level of detail |
| `paint.odin`, `blur.odin` | fills, gradients and shadows; blur effects |
| `images.odin`, `image_formats.odin`, `png.odin` | image fills and decoding; PNG encoding |
| `svgpath.odin`, `icons.odin` | SVG path parser; the embedded Lucide icon set (`assets/lucide.txt`) |
| `codegen.odin` | HTML/CSS and React export |
| `files.odin` | absolute paths, file titles, mapped files |

App (`src/`):

| File | Role |
| --- | --- |
| `main.odin` | entry: editor or `mcp` mode |
| `platform.odin`, `gestures_darwin.odin` | window, input state, focus modes, Cocoa gestures |
| `app.odin` | main loop, draw order, offscreen renders, undo, saving |
| `input.odin`, `edit.odin`, `pen_tool.odin`, `gradient_edit.odin` | canvas interaction, shortcuts, editing commands |
| `widgets.odin`, `ui.odin`, `inspector.odin` | widget library; panels built from it |
| `components_panel.odin`, `variables_table.odin` | the Components tab; the variables table |
| `tabs.odin`, `dashboard.odin`, `onboarding.odin` | tabs, recents, thumbnails, dashboard, onboarding |
| `pages_ui.odin`, `libraries_ui.odin`, `fonts_ui.odin`, `files_ui.odin`, `export_ui.odin` | the app's side of pages, libraries, font import, file dialogs and drops, export to a folder |
| `server.odin`, `api.odin`, `mcp.odin`, `agent_tools.odin` | control socket, its methods, stdio MCP server, the guide |
| `presence.odin`, `agents.odin` | agent cursors and flashes; agent client detection and MCP registration |
| `memory.odin` | the big allocator, memory trim and the `memory` report |
| `clipboard_darwin.odin` | putting data on the system clipboard |
| `activity_darwin.odin`, `applog.odin`, `settings.odin` | no App Nap while agents work; the start/exit log; app settings |
| `metal_darwin.odin` | the window's `CAMetalLayer` (WebGPU builds) |
| `nanovg/`, `fontstash/` | patched vendored renderer (with `gl/` and `wgpu/` backends) and font rasteriser |
| `wgpu/` | the wgpu-native bindings; the library itself is fetched by `tools/fetch_wgpu.sh` |
