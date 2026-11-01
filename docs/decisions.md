# Design decisions

This log records decisions taken while building the app (October 2026), with the reasons
and what each one costs. Each entry follows the same pattern: the problem, what was
decided, and the consequences. Add new entries at the end. When a decision is reversed,
mark the old entry *superseded* and link the new one.

---

## 1. Native Odin app on GLFW + NanoVG, no raylib

**Problem.** The first version drew with raylib. A design canvas needs:

- antialiased vector paths and Bézier curves,
- rounded rectangles with per-corner radii,
- strokes with alignment,
- text that measures exactly.

raylib is a game library and handles none of these well.

**Decision.** GLFW only opens the window and delivers input. NanoVG on OpenGL 3.2 draws
the canvas and the interface. The program has no other dependencies.

**Consequences.**

- One small native binary with fast startup.
- We write the widget library ourselves (#12).
- We patch the renderer when it is wrong (#11).
- macOS-only pieces stay in `*_darwin.odin` files (gestures, window ordering).

## 2. `.pen` is the native format, kept losslessly

**Problem.** The app should open and save pencil.design files without damaging what it does
not understand: icon fonts, scripts, gradients, newer schema fields.

**Decision.**

- Each node keeps its authored properties as raw JSON, in file order (`Node.props`). The
  document header does the same.
- Typed fields are only a cache, rebuilt by `node_refresh`.
- Edits rewrite one prop through `node_set*`. Saving writes the props back as they were.
- Formatting is canonical (`write_json_value`: compact values, sorted object keys).
  Re-saving an unchanged document therefore produces the same file.

**Consequences.**

- Unknown node types survive a round trip and are drawn as placeholders.
- Every new feature has to read and write real `.pen` properties instead of private
  state.
- The test for format work: open the samples from `de-novo/pencil-skill`, save them, and
  compare with the originals.

## 3. Flat node array with versioned indexes

**Problem.** Trees of pointers make undo, reparenting and the socket API awkward in Odin.
Linear lookups made reddit-ui pan at 240 ms per frame.

**Decision.**

- Nodes live in one `[dynamic]Node`. A node points to its parent's uid, and array order is
  the z-order.
- `doc.version` goes up on structural changes. The `by_uid`, `by_id` and `kids` indexes, the
  ghosts, pages and theme axes rebuild lazily when it differs.
- The socket `perf` method reports per-phase frame timings and counters. Check it before
  guessing why something is slow.

**Consequences.**

- Undo snapshots are a plain copy of the array (#14).
- Index entries are validated on use, so a stale index costs a rebuild, not a crash.
- Code that changes structure must call `doc_bump`. `node_refresh` does it unless ghosts are
  being built.

## 4. The agent talks to the window, not to the file

**Problem.**

- The agent and the user should edit the *same* live canvas and see each other's changes.
- Nothing extra should have to be installed or kept running: no browser, plugin or server.

**Decision.**

- `agentic-design mcp` is a stdio MCP server inside the same binary. It forwards each tool
  call to the window over `127.0.0.1:4410` and starts the window when needed.
- Requests run on the main thread between frames.
- Tool arguments and results are `.pen` JSON, the same objects an agent would write into the
  file. `get_document` adds the computed `bounds` so the agent sees where layout put things.

**Consequences.**

- One registration: `claude mcp add --scope user agentic-design -- …/agentic-design mcp`.
- After a rebuild, kill the running window. The next tool call starts the new binary.
- The socket only listens on localhost and has no authentication.

## 5. Agents and tests never steal focus

**Problem.** A window popping up in front of the user while they work, or a test run that
grabs the keyboard, is disruptive. A modal file dialog in a test hangs the run.

**Decision.** Two modes, both set by environment variables:

- `AGENTIC_NO_FOCUS=1` opens the window without taking key focus. The MCP launcher sets it.
- `AGENTIC_QUIET=1` also orders the window behind the others and disables every system
  dialog. The place-image dialog, for example, just shows a status message. Tests use this
  mode.

**Consequences.** Quiet mode must never open anything modal. Check for `pf.quiet` before
calling any system UI.

## 6. Instances expand into ghost nodes

**Problem.** Instances used to re-lay out and redraw their component in place for every
measure and draw call. That cost about 240 ms per frame on reddit-ui.

**Decision.**

- When the document changes, each `ref` is expanded once into a tree of ghost copies of its
  component, with the instance's overrides applied (`ghosts_sync`).
- Ghosts are laid out and drawn like real nodes. They are never saved, selected or edited.
- The instance's real children are its slot content. They are laid out inside the
  component's slot frame and stay selectable and editable.
- When an instance sits under a different theme than its component, its ghosts are re-parsed
  under the instance's theme.

**Consequences.**

- A frame takes 2–5 ms.
- `node_clone` and `ghost_clone` must clone *every* owned string. Forgetting one has already
  caused a startup double free (`theme_set`, `theme_key`, `ghost_of`).
- Nesting is capped at `MAX_INSTANCE_DEPTH`, and an instance inside its own component is
  refused.
- An instance takes its size spec from the component unless it sets its own `width` or
  `height` (see #23).

## 7. Component parameters are `.pen` overrides

**Problem.** Users want to pass text and on/off values into a component instead of drawing
text on top of instances.

**Decision.** The format already has per-instance overrides: `descendants: {<id path>:
{props}}`. The inspector's Parameters section exposes the common ones:

- every text in the component becomes a field;
- every part becomes a visibility checkbox, including parts of nested instances.

`override_set` writes and removes the entries. Clearing a field returns to the component's
value. There is no separate props schema.

**Consequences.**

- Files stay readable by pencil.design.
- Code export derives React props from the overrides any instance uses (#16).
- Overrides that replace a node (`descendants` entries with a `type`) are kept but not
  applied.
- Since #23, any property can be overridden, not only text and visibility.

## 8. Themes resolve per node

**Problem.**

- reddit-ui contains a dark showcase next to a light one. Resolving variables once, with the
  first value of each, drew both light.
- Users want theme variants that swap color values.

**Decision.**

- **Axes.** Theme axes and their values come from the header (`themes`).
- **Values.** Variables keep every themed value (`var_defs`).
- **Theme in effect.** Each node works out its own theme: the global choice (`app.theme`),
  overridden by the `theme` property of each ancestor from the root down.
- **Lookup.** `var_get` skips entries that contradict that theme and picks the most specific
  match. Variables may point to other variables.
- **Theme tab.** It switches the shown value, adds values (or creates a `mode` axis with
  light and dark), and renames values everywhere they are used.
- **Edits.** A variable edit goes to the entry for the theme being shown; other themes keep
  theirs.

**Consequences.**

- Switching the theme re-parses every node (`doc_retheme`).
- Frames can pin a theme for their subtree (the Theme row in the inspector).
- Export writes non-default themes as `[data-theme-<axis>="…"]` CSS blocks.

## 9. Tabs are files, pages live inside a file

**Problem.**

- At first, "pages" were the `.pen` files in the document's folder, and they opened as
  tabs.
- Kirill: tabs are files; pages belong inside a file.
- The `.pen` format has no pages.

**Decision.**

- Pages are stored in the header as `"pages": [{"name", "nodes": [top-level ids]}]`.
  pencil.design keeps or ignores unknown header keys.
- Top-level nodes listed under no page belong to the first page.
- A new top-level node joins the page being shown.
- A document with a single default page writes no `pages` key at all.
- Each tab holds one file with its own camera, selection, undo stacks and page. The
  dashboard lists recent files with thumbnails.

**Consequences.**

- Saving prunes ids of deleted nodes from the page lists (`pages_prune`).
- Deleting a page deletes its layers.

## 10. Text keeps its width at every zoom

**Problem.** When zooming, text lines changed width and wrapped differently, so they
"walked". Kirill rated this critical. Two causes:

- lines were broken at the current zoom;
- fontstash rounds glyph advances and positions to whole pixels of the rendered size.

**Decision.**

- Layout measures and breaks text at document scale, with the transform reset. It caches
  the size and line ranges (`Text_Metrics`, keyed by content, face, size, line height and
  wrap width).
- Drawing replays the cached lines one by one.
- Our fontstash copy keeps advances and positions unrounded.

**Consequences.**

- Text looks the same at every zoom and in screenshots.
- The text cache is cleared wholesale when it passes 20 000 entries.

## 11. NanoVG and fontstash are vendored and patched

**Problem.** The Odin vendor ports had three bugs:

- integer rounding of glyph advances (#10);
- a crash in `glTexImage2D` when the glyph atlas grows, because the old, smaller buffer was
  uploaded into the new texture;
- a trap on `pts[-1]` for empty paths.

**Decision.** Copy both packages into `src/nanovg` and `src/fontstash` and fix them there.
The patches are listed in `src/nanovg/README.md`. The app also trims the font atlas between
frames, once it has outgrown its budget.

**Consequences.** Upgrading Odin does not update the renderer. Re-apply the patches when
syncing with upstream.

## 12. Our own immediate-mode widget library

**Problem.** The interface needs real dropdowns, searchable menus, checkboxes, a color
picker, dialogs and tooltips in the app's dark style. These have to draw with the same
NanoVG context as the canvas. No existing Odin library fits that style and renderer.

**Decision.** `src/widgets.odin` is a small immediate-mode library, and `src/ui.odin` builds
the panels from it. Conventions:

- **Modal overlays.** Menus, the picker and dialogs are drawn last. While one is open,
  nothing else gets pointer or key input (`ui_modal`, `ui.overlay_pass`).
- **Results by key.** `menu_open(key, …)` returns its pick on a later frame through
  `menu_take(key)`. The picker and dialogs work the same way.
- **Fields.** A field is identified by `(uid, key)` and commits on Enter, Tab or a click
  elsewhere. A single dispatcher, `field_apply`, maps the key to the property, variable,
  page name or override it edits.
- **Key ownership.** Keys are often built with `tprintf`, so `field_focus` clones them
  (`ui.focus_owned`). A key left in temp memory is freed at the next frame and corrupts the
  commit.

**Consequences.**

- Adding a panel means calling widgets, not building a widget tree.
- New field kinds need a case in `field_apply`.

## 13. Fonts and colors are real dropdowns

**Problem.** Typing a font family or a hex code into a plain field is not how design tools
work. Kirill called real pickers a must-have.

**Decision.**

- **Fonts.** The family is chosen from a searchable menu that previews each family in its
  own face. Prefix matches rank first, and script-only Noto families are filtered out. Fonts
  are found by file name in the standard macOS font folders; NanoVG cannot read `.ttc`
  collections. Faces load on first use and are memoised.
- **Colors.** A color row opens an HSV picker with hex and alpha fields. The picker offers
  the document's color variables, or a default palette when there are none. A row can also
  bind to a `$variable`.

## 14. Undo stores whole node snapshots

**Problem.** Undo must be reliable across every kind of edit: inspector fields, drags,
socket requests, instance overrides.

**Decision.** `push_undo` copies the whole node array before a change. The stack is capped
at 200 steps, and redo works the same way.

**Consequences.**

- Undo is simple and hard to break, but memory use grows with document size × steps.
- Only nodes are snapshotted. Header changes are **not** undone: pages, theme axes and
  variables. Known gap; extend the snapshot to the header if it matters.

## 15. Autosave, no save command needed

**Decision.**

- A dirty document is written a second after the last change, and when its tab is closed or
  the app quits.
- `save` exists for agents and accepts an optional new path.
- The window title shows `•` while unsaved changes exist.

## 16. Code export comes from the model

**Problem.** Designs should become code: HTML/CSS and React with shadcn/ui.

**Decision.** `src/codegen.odin` walks the parsed model of the current page, with
everything already resolved: layout modes, sizes, variables, instances.

- **HTML + CSS** mirrors the document one to one:
  - one element and one class per node;
  - flex or absolute positioning as authored;
  - variables as custom properties and themes as attribute blocks.
- **React**:
  - one function per component;
  - props from the overrides instances use, and slot content as `children`;
  - shadcn/ui primitives for components named Button, Card, Input, Badge, …;
  - Tailwind arbitrary values for styles;
  - `Page.tsx` composes the page from instances.
- **Delivery.** The Export menu writes the files to `~/Downloads/<title>-html|react`. The
  `export_code` tool returns their contents and can also write them to a folder.

**Consequences.**

- The output follows the design's geometry, not semantic HTML.
- A shadcn mapping is a naming convention, not a binding.

## 17. Test through the real interface

**Problem.**

- Crashes came from UI paths that unit tests would not reach.
- Test windows must not disturb the user.

**Decision.**

- The control socket's `input` method injects pointer and key events into the same
  per-frame state real events use.
- `tools/uidrive.py script` walks every panel. `tools/uidrive.py fuzz <seed> <n>` sends
  random clicks, drags and keys.
- Run the window under `lldb --batch -o run -k bt` in quiet mode to get a backtrace for any
  crash.
- See [testing.md](testing.md).

**Consequences.** Fuzz runs edit and save whatever file is open, so run them on a copy or
restore the fixtures afterwards.

## 18. Trackpad gestures through Cocoa

**Problem.** Kirill wanted pinch-to-zoom and two-finger panning. GLFW does not report pinch
and scales trackpad scroll deltas down.

**Decision.**

- `src/gestures_darwin.odin` replaces the GLFW view's `scrollWheel:` and adds
  `magnifyWithEvent:` and `smartMagnifyWithEvent:`. The handlers use the objc runtime and
  accumulate precise deltas.
- Pinch zooms, two-finger scroll pans, and Cmd + scroll zooms.
- A two-finger double tap zooms to the node under the pointer, or fits all.

## 19. Images live next to the document

**Decision.** A dropped or placed image is copied into `images/` next to the `.pen` file and
used as an image fill with the relative URL `./images/<name>`. The folder can be moved
together with the file.

## 20. The clipboard holds `.pen` JSON

**Decision.** Copy puts the selection on the system clipboard as a JSON array of `.pen`
nodes. Paste accepts it back, even from another document, an agent or a text editor.

## 21. The interface follows Paper; the features come from Paper and Pencil

**Problem.** Kirill gave Paper (paper.design) as the visual reference and Paper plus Pencil
as the feature reference.

**Decision.**

- **Layout:** a tab bar with the Dashboard and the open files, a sidebar (file name, Design
  and Theme tabs, Pages, layer tree), a vertical tool strip, the canvas and an inspector.
- **Style:** dark, with `#1E1E1E` panels and a `#282828` canvas, using the system font.
- **Features:**
  - smart guides and a size badge;
  - grouping, frames and auto layout (Shift A);
  - alignment, context menus and in-place rename;
  - components with Go to component and Detach;
  - export menus.
- **Left out:** no account avatar, since there are no accounts.

See [ui.md](ui.md).

## 22. Lucide is built in

**Problem.** `.pen` 2.21 references icons by name: `{type: "icon", library: "lucide",
icon: "house"}`; 2.8 used `icon_font`. The app drew placeholders, so any design system or
real screen was full of grey boxes. Lucide's icons are written with SVG arcs and round
caps, which the path renderer did not support either.

**Decision.**

- `tools/lucide_assets.py` turns lucide-static's `icon-nodes.json` into
  `assets/lucide.txt`: one line of path data per icon, with circles, rects and lines
  converted. The file is embedded in the binary (`#load`), about 310 KB for 2015 icons.
  The ISC licence is in `assets/LICENSE-lucide.txt`.
- Icons are stroked 2 units wide in a 24-unit box with round caps and joins, scaled
  uniformly to the node. The node's `fill` is the color.
- The SVG parser converts arcs to cubic Béziers. Paths honour `strokeLinecap` and
  `strokeLinejoin`.
- Export: inline SVG in HTML, `lucide-react` components in React.

**Consequences.**

- No network access and no font files are needed.
- Other libraries (Material Symbols, phosphor, feather) still draw placeholders.
- Lucide renames icons between versions; there is no alias table yet.

## 23. Overrides re-parse a copy

**Problem.** Instances could override only a fixed list of fields (text, colors,
visibility, opacity, font size and weight). A navigation item could not swap its icon. An
instance could not change its size or radius, though the spec allows any property on the
`ref` and in `descendants`.

**Decision.** When an override sets anything outside that list, or the instance sets
properties on itself, the ghost copy of that component node is made from its props:

1. the instance's own properties are written into the root copy (except identity,
   position, visibility, opacity and structure);
2. the `descendants` entries are written into the matching copies;
3. the copy is parsed again with `node_refresh`.

The fixed list keeps its fast path.

**Consequences.**

- Any property can be overridden, at the same cost as a themed instance.
- Nested instances work: an override of a nested `ref` reaches that instance's root.
- React export turns root overrides into classes merged with `cn()`.

## 24. Tokens and pages have an agent API

**Problem.** An agent could create nodes but not variables, theme axes or pages, so it
could not build a design system on its own.

**Decision.**

- `set_variables` merges `.pen` variable definitions (`null` deletes one), replaces the
  theme axes, and picks the theme shown in the window.
- `set_pages` replaces the page list and switches the shown page.
- Both exist as socket methods and MCP tools, and take the same JSON as the file header.

**Consequences.** The Claude Code MCP process keeps the tool list it started with. New
tools appear only after it restarts; until then, call them on the socket directly.

## 25. pen.dev is the reference renderer

**Problem.** The `.pen` schema leaves much unsaid: font size units, default line height
and stroke alignment, the meaning of `children` on a `ref`. Guessing gave text 17% too
small and strokes in the wrong place.

**Decision.**

- When the spec is silent, behave like pen.dev. Check by rendering the same file in both
  and diffing bounds and pixels (`tools/dogfood/pen-compare/`).
- Deviate only where pen.dev loses information, such as 2.8 slot content. Note each
  deviation in pen-format.md.

**Consequences.**

- Font size is the em; the line height comes from the font metrics; strokes are centred.
- Designs made before this change render larger text; they were drawn too small before.

## 26. Agents are connected from the onboarding, one click each

**Problem.** pen.dev registers itself silently with every agent it finds. The app offered
only a `claude mcp add` command to copy.

**Decision.**

- The onboarding's second step lists nine clients with their state: connected, not
  connected, outdated path, or not found.
- **Connect** writes one entry, by the client's own CLI when there is one (Claude Code) or
  by inserting a single member into its config (JSON/JSONC or TOML). Comments and key order
  are kept; the result must parse before it is written.
- Nothing is written without a click. Test windows cannot write at all, unless
  `AGENTIC_HOME` points them at a sandbox.

**Consequences.** Running agent sessions need a restart to see the server. Zed (JSONC
`context_servers`) is not covered yet.


## 27. The inspector follows pen.dev; gradients are textures

**Problem.** The inspector had one fill, one shadow and W/H fields that took
`fit_content` typed as text. pen.dev users expect its sections and shortcuts. NanoVG
paints two-colour linear, radial and box gradients only, while `.pen` files use any
number of stops and angular gradients too.

**Decision.**

- The inspector has the same sections, in the same order, as pen.dev's. Each section
  writes the same properties pen.dev writes. Examples: Fill and Hug checkboxes write
  `fill_container` and `fit_content`; a single solid fill stays a string, not a
  one-item array.
- Fills and effects are lists stored as written. A file that has one fill is written back
  with one fill.
- A gradient is drawn from a generated texture, cached by its stops: 256×1 for linear,
  256×256 for radial and angular. The texture is mapped onto the node with an image
  pattern. The geometry was matched against pen.dev renders of the same file.
- pen.dev's shortcuts win where ours differed. For example, ⌘[ and ⌘] now move one step.

**Consequences.**

- Any number of stops, at the cost of one small texture per distinct gradient. The
  cache holds up to 128 textures and is then cleared.
- Layer blur and background blur are kept in the file but not drawn; they need render
  targets.
- Hit-testing and the selection box ignore rotation.

## 28. Code export and the canvas follow pen.dev's CSS

**Problem.** Code export lagged behind the renderer, and both guessed at details the schema
leaves open: where a flip pivots, what a blur radius means in CSS, how far a shadow fades.

**Decision.**

- pen.dev's own `html-css` export of the same file is the reference for every CSS value:
  - gradient angles and stop positions,
  - `blur(r/2)` for a blur of radius r,
  - `box-shadow` with the file's numbers,
  - `transform-origin: top left`.
- The canvas draws to match: flips pivot on the top-left corner like rotation, and shadows
  fade over twice their blur.
- Editing commands keep a layer where it is on screen. Turning or flipping it moves its x/y.
- Variables stay `var(--name)` in the CSS. pen.dev inlines them; we keep themes working.

**Consequences.**

- Files made earlier with flipped layers now draw where pen.dev draws them, which may be
  shifted from where they used to be.
- `get_styles` gives agents the exact CSS of any node without exporting the page.

## 29. Libraries are read into the document under their alias

**Problem.** pen.dev's `imports` maps an alias to another `.pen` file. Inside that file's
components, pen.dev names everything after the alias: the component is "ui:btn", its
variables are "$ui:brand", a descendant override key is "ui:label". This was found by
rendering such files in pen.dev. The app resolves refs, overrides and variables by name
within one document.

**Decision.**

- When a document opens, each library's layers and variables are added to it, renamed with
  the alias, and the layers are flagged `imported`.
- Imported layers are never saved, shown on a page, listed in the layer tree or returned as
  document children to agents. Agents see them in `get_document`'s `libraries`.
- Refs, overrides, variables and code export then work unchanged.

**Consequences.**

- A library changed on disk shows when the document is opened again, as in pen.dev.
- A component edited in the document cannot be pushed back to its library; it is edited in
  the library file.

## 30. Fonts travel with the document; variable fonts are instanced in the app

**Problem.** stb_truetype draws only a variable font's default instance, and the schema
has no list of fonts.

**Decision.**

- A `fonts` folder next to the `.pen` file is scanned when the document opens. The import
  button and dropping font files fill it.
- `.ttc` collections and `.woff` files are read as well.
- A TrueType variable font is instanced at the weight asked for (`varfont.odin`): gvar
  deltas with IUP and avar, giving a static font in memory. The result matches fontTools
  within about one unit.

**Consequences.**

- `tools/font_instances.py` is no longer needed.
- CFF2 variable fonts and woff2 are not covered.
- pen.dev reads neither folder; see #32 for the document's `fonts` list.

## 31. Agents get a guide, batches and a linter

**Problem.** Agents rebuilt their picture of a document from `get_document`. On big files
that is a lot of JSON. Several related edits became many calls and many undo steps. Nothing
told an agent which conventions the file follows, or what a reviewer would flag.

**Decision.**

- `get_guide` is markdown written for the open document: pages, theme axes, variables
  grouped by prefix, components, libraries, fonts (missing ones flagged) and how to work
  with the tools.
- `batch` applies create, update, delete, move and set_variables operations as one step.
  The first failure restores the document as it was.
- An undo step now snapshots the header as well as the layers, so variables, themes, pages
  and imports undo too. They did not before.
- `find_nodes` searches by name, type, text, component, variable or subtree.
- `lint` reports hard-coded colours (naming the variable with that value), missing fonts
  (once per family), text taller than its box, layers cut off by clipping frames, broken
  refs, values off whole pixels and empty text.

## 32. Fonts come from the document, and stand-ins follow pen.dev's renderer

**Problem.** The Sample font (Scto Grotesk A) was installed on the Mac. The app picked it
up, pen.dev did not even after a restart. pen.dev draws text with Skia compiled to
WebAssembly and reads no installed fonts. It loads Google Fonts from its own index, plus
the fonts a document lists (its "Add custom fonts" copies the file next to the `.pen` and
adds an entry). Decision #30's `fonts` folder and the SF Pro stand-in (C11) were guesses.
SF Pro had matched one badge's width by coincidence.

**Decision.**

- A document's `fonts` list is read: `[{"name", "url", "weight": n or [min, max],
  "style": "normal" | "italic"}]`, with urls relative to the file. Each entry is a face of
  `name`, whatever the file calls itself. The lists of imported libraries count too, so a
  design system declares its fonts once. Importing a font in the app copies it into
  `fonts/` and writes the entry, as pen.dev does.
- A missing family is drawn with Noto Sans, the first of pen.dev's fallback fonts. The
  same Noto Sans 2.015 files pen.dev fetches are built in (OFL, `assets/fonts`) and
  instanced at the weight asked for. They also supply glyphs a font lacks. Measured on six
  Larken headings: Noto Sans matches pen.dev's widths to its rounding, SF Pro is off by up
  to 4 px.
- A bold (600+) asked of a family whose closest face is lighter than 600 is thickened as
  Skia's FreeType backend does: outlines grow by size / 24, advances stay. Scto Grotesk A
  700 drawn from its Light file matches pen.dev's width (209 px) and weight; 500 stays
  Light, as in pen.dev.
- The default line height is the font's ascender to descender, without its line gap.
  Measured: Scto Grotesk A gives 1.0 (its 0.244 gap ignored), Inter 1.21, Roboto 1.17 and
  Merriweather 1.26, all as pen.dev.
- Installed fonts and `fonts/` folders still work, and folders are watched while the app
  runs. `lint` and `get_guide` say when a family is installed but not in the document,
  since pen.dev and other machines will not have it.

**Consequences.** Commercial font files stay out of the repository (`designs/fonts/` is
ignored). The binary grows by 4 MB of Noto Sans.

## 33. fit_content ignores children that fill it, as pen.dev does

**Problem.** A frame fitting its content, with a `fill_container` child on the same axis,
took all the space offered to it in the app. In pen.dev the child adds nothing. The frame
is as big as its other children, and the child gets that size, or nothing along the flow.
pen.dev warns about this as "Collapsed size". The Sample About screen had two such
sections, which pen.dev drew 85 and 310 px wide and the app 360.

**Decision.**

- Layout follows pen.dev, measured on six probe frames: the child takes the width or height
  the other children give the frame across the flow, nothing along it. `fit_content(n)`
  still falls back to `n` when nothing else gives a size.
- `lint` reports it as `collapsed-size`.
- Lines also break after a hyphen between letters, as ICU does in Skia.

**Consequences.** Every library page and screen of the Sample files now has pen.dev's
size; pixel differences are antialiasing, under 1%.

## 34. The main loop sleeps when nothing happens

**Problem.** The loop drew frames back to back and relied on vsync to pace it. macOS stops
syncing a window that is covered by others, so an idle window behind other apps used a
whole core: about 9 s of CPU in 10 s.

**Decision.**

- Frames run at full rate for half a second after any input or agent request, and while a
  screenshot, export or thumbnail waits for one.
- Otherwise the loop waits for events. Requests wake it from the server thread
  (`glfwPostEmptyEvent`). It also wakes every half second, in step with the caret blink,
  for timers.

**Consequences.** An idle window uses about 1% of a core. A request is answered within a
few milliseconds.

## 35. Agents have cursors on the canvas, as in pen.dev

**Problem.** An agent's changes appeared out of nowhere. Nothing showed who was working,
or where. Other people on the canvas will need the same.

**Decision.**

- The MCP proxy sends the client's `clientInfo` with each request. The window keeps a
  cursor per agent session, named and coloured after the client.
- The layers a request touches are found by comparing the document before and after it
  (a hash of each layer's properties and parent). Methods need no bookkeeping of their own.
  The cursor visits up to six of them in turn, 0.45 s apart. Each flashes as the cursor
  gets there.
- Motion, flash and glow follow pen.dev's code (AgentCursorMotion, addFlash,
  renderGeneratingEffects):
  - exponential approach and a slow sway at rest;
  - a ring closing in for 0.2 s, holding 0.4 s and fading for 0.3 s, with a sweep of colour
    on new layers;
  - two soft lights circling in `placeholder` frames.
  It differs in four ways:
  - the approach is a little quicker;
  - the cursor stays 15 s rather than 5, since agents think between calls;
  - deleted layers fold away;
  - a cursor out of view waits at the canvas edge.
- `presence` on the control socket places anyone else's cursor, for a multiplayer link
  later.
- None of it is drawn into screenshots, exports or thumbnails.

**Consequences.**

- Animation costs frames. They are drawn only while something moves: at the display rate
  for travel and flashes, 20 fps for a resting cursor, none once it has faded. The frame
  rate is capped at the display's refresh even for input, since a covered window gets no
  vsync.
- Only pointer moves that macOS sends to the window count as input. The pointer position
  read each frame changes when the mouse moves over other apps. Before this, that kept an
  open window drawing at full rate whenever the mouse moved anywhere.

## 36. Memory: measured, then cut where it went

**Problem.** The window took 700 MB at start on a Retina screen, and grew by hundreds of
megabytes in a session. Most of it was not the document.

**Decision.** Measure first: the `memory` request reports what the app holds (layers,
instance copies, undo, caches, fonts, and every block of 256 KB or more by where it was
allocated); `footprint`, `vmmap` and `malloc_history` give the rest. Then:

- The window has no multisampling and no depth buffer. NanoVG antialiases edges itself
  and needs only the stencil buffer, and frames came out identical without either.
  Saved 240 MB of video memory.
- An undo step shares every layer that did not change with the steps around it
  (decision in `doc.odin`): 100 edits cost 5 MB, not 195.
- Blocks of 256 KB and more come from the system and go straight back when freed
  (`memory.odin`). macOS's malloc kept freed large blocks: 20 screenshots left 77 MB
  that no pressure relief returned. The per-frame arena, screenshots and responses go
  through it; so does code called from C.
- Screenshots render in 2048-pixel tiles through one buffer of that fixed size, and read
  back in strips of 128 rows through a small pixel buffer. The driver keeps the storage
  of what was deleted:
  - read straight from the window, it kept a 32 MB staging buffer;
  - read through a pixel buffer as large as the image, it kept that buffer (20 MB for a
    window-sized shot);
  - drawn into a buffer as large as the image, it kept 60–70 MB after a big shot.
  Screenshots are no longer limited to the window's size. Tiled and single-pass images
  are identical, a 14840 × 3850 canvas included.
- PNGs are written with the system's zlib and the app's allocator (`png.odin`), not with
  stb_image_write, whose C allocations stayed with malloc (a session of agent
  screenshots reached 400 MB). Opaque images are RGB; files are a quarter smaller.
- Font files are mapped, not read into memory (the system UI font alone is 9 MB).
- Closing a tab or rendering a thumbnail frees the whole document. Instance copies,
  lookup tables and theme data used to stay behind each time, and every change of the
  variables left a copy of their names.

**Consequences.**

- A 1440 × 900 Retina window starts at about 270 MB. About 220 MB of that is the OpenGL
  stack's own: a bare GLFW window that only clears takes 234 MB. Below that needs a Metal
  renderer.
- Returning freed blocks to the system made two old reads of freed memory crash.
  Expanding nested instances kept pointers into the copies array while it grew; it now
  keeps the overrides themselves.

## 37. Frames: lay out only after a change; draw what can be seen

**Problem.** Every frame laid the whole document out up to three times and drew every
detail, however small on screen. On a file with 40 screens (4,000 layers with instance
copies), a frame at zoom-to-fit took 10 ms of CPU.

**Decision.**

- Layout runs only when the document's version or the fonts change, or code asks for it
  (`layout_epoch`). Every change to a layer, the header or the tree moves the version.
- On the live canvas, details too small to see are simplified:
  - text under 2 points becomes a bar per line;
  - icons under 6 points become a dot of their colour;
  - corners under a third of a point are drawn square;
  - leaves under half a point are skipped.
  Screenshots, exports and thumbnails draw everything as before.

**Consequences.** On that file a frame costs 4.6 ms instead of 9.6, and layout 0.03 ms
instead of 1.4–2 ms.

## 38. Agent API: say what was done to the input, and follow CSS where the format is silent

**Problem.** Dogfooding the landing page (dogfooding Session 9, D1–D12) found the agent
API quietly doing something other than what was asked: a missing file could not be
created, a too-large corner radius made an ellipse, indentation vanished from code blocks,
three-value padding and unknown icon names were dropped without a word, a screenshot scale
above 4 was capped silently, and lint suggested variables that change with the theme.

**Decision.**

- Geometry and text follow CSS (and Skia, so pen.dev) where `.pen` does not say:
  - corner radii too big for the box shrink together by one factor and stay circular (the
    vendored NanoVG clamped x and y separately);
  - leading spaces of a paragraph (the start of the text and after a newline) are drawn,
    as `white-space: pre-wrap`; after a soft wrap they are still dropped;
  - `padding` with three values is read as top, sides, bottom.
- Input the app had to interpret is reported back: `create_nodes` and `update_nodes`
  return `warnings` (unknown Lucide icons with close names; three-value padding, which is
  rewritten to the four values it means, since the schema has no three-value form), and
  `lint` has an `unknown-icon` rule.
- `open` takes `create: true` and makes an empty document; its errors name the path.
  `add_fonts` copies font files or installed families into `fonts/` and declares them.
  Families installed only as `.ttc` are refused: pen.dev reads no collections.
- `screenshot` goes up to 16 pixels per unit and reports the scale it used, with a note
  when it had to reduce it.
- `get_document` lists libraries only for the whole document (or `libraries: true`);
  a library component asked for by id comes with its children and their `alias:id`
  override keys. `get_guide` summarises library variables after the document's own.
- `lint` suggests a colour variable for a hard-coded colour only if the variable has that
  value in every theme; otherwise it says in which theme it matches.
- The MCP proxy names its agent by its process id. A new proxy takes over the cursor of an
  ended proxy from the same client, so an agent that runs one process per call keeps one
  cursor. Proxies running side by side keep theirs.

**Consequences.** Files written by older builds with a three-value padding now show it;
pen.dev ignores such padding, so agents get it rewritten on the way in. `os.make_directory_all`
fails on an existing folder: font import and `export_code` into an existing folder failed
on their second use, and now check for the folder instead.

## 39. Code export reads instance copies as the file would state them

**Problem.** The HTML export of the landing page lost the fills and text colours inside
instances, wrote an instance's overrides twice (on its element and on the component root
inside it), drew path strokes as a box border and wrote 261 library variables into every
theme block. The React export put all of a library's components next to the local ones,
with clashing names.

**Decision.**

- Instance copies keep only parsed fields, for speed. Export reads raw properties (to
  write `var(--name)` and every paint layer), so it builds a view of each copy: the
  component node's properties with the overrides of every instance around it written over
  them, outer first. Every override keeps its JSON for this; a separate flag still marks
  the overrides that need the copy re-parsed.
- An instance's element only places and sizes; the component root inside carries the look.
- Paths are SVG paint (`fill`, `stroke` in CSS, inherited by the `<path>`).
- The page is generated before the variables. A library's variables, and its components
  in React, are written only when the generated code uses them. Library components are
  named after the alias (`LibBadge`).
- React: a style override of a part becomes a `<part>ClassName` prop merged with `cn`,
  the way root overrides already travel as classes.

**Consequences.** Export output now matches the canvas for instances (checked by rendering
the HTML in headless Chrome next to the app's screenshot). Each override's JSON is kept in
memory once more.

## 40. Libraries bring their theme axes; images and screenshots need no extra steps

**Problem.** After importing a themed library the document had no theme axes, so no frame
could pin `{"mode": "dark"}`; an agent could not place an image without copying it into
`images/` itself; a screenshot of a section without its own fill was drawn on white
whatever the theme.

**Decision.**

- `set_libraries` add merges the library's axes and values into the document's `themes`,
  in the same undo step (pen.dev reads axes from the document's own header).
- An image paint's `url` may be any local path; create and update copy the file into
  `images/` and rewrite the url, as a dropped image is. A missing file is a warning.
- A node screenshot is drawn on its nearest ancestor's opaque fill, in the screenshot's
  theme; white only when no ancestor has one.
- `lint` `missing-font` counts text inside instances and points at the instance.

## 41. A viewport theme axis exports as media queries

**Problem.** A landing page designed as a desktop and a mobile frame, with number tokens
themed on a `viewport` axis, exported as two fixed-width frames one after the other, the
tokens inlined as px and the viewport blocks unused.

**Decision.** A theme axis named `viewport`, `breakpoint`, `screen` or `device` is
responsive. Each of its values gets a width (the widest top-level frame pinned to it; the
first value: the widest unpinned frame) and, except the widest, a media query below the
middle between its width and the next wider one. Number properties bound to variables are
written as `calc(var(--name) * 1px)` (line height as `var()`), so the media queries
change them. Exported top-level frames are fluid up to their width. `export_code` takes
`ids` to export one frame. The window's choice on that axis is not pinned on `<html>`.

**Consequences.** Spacing and type follow the breakpoints. Structure does not: a layout
built from fixed widths still overflows on a phone, and two frames with different
structures are not merged into one page.

## 42. The outermost override wins; libraries follow their files

**Problem.** A card component that set its button's label could not be relabelled where
the card was used: the inner override was applied last. An override keyed by a nested
instance's own id was ignored. A library saved from another tab or by an agent was not
picked up by the documents importing it until they were reopened.

**Decision.**

- Overrides are applied innermost first, so the outermost one wins, as in pen.dev and
  Figma (decision text in `expand_instance` reversed). The root of a nested instance also
  takes overrides aimed at that instance's id. Code export follows the same order.
- The open document's libraries are re-read within about 2 s of a change to their files
  (modification times, checked like font folders). This is not an edit: no undo step and
  nothing to save. `set_libraries` `reload: true` does it at once.
- Lint can be told a colour is intentional: `metadata.lintIgnore` on a layer (a `.pen`
  field), or `ignore` for one call.
- Web fonts without a typographic family name drop a trailing weight word that matches
  their weight, outside the system font folders.
- Symbols fall back to Apple Symbols and Arial Unicode after Noto Sans. Colour emoji are
  not drawn yet.

**Consequences.** A document that relied on an inner override beating an outer one now
shows the outer value; that matches pen.dev.

## 43. The control socket turns off Nagle's algorithm

**Problem.** Every control request took about 170 ms on an idle window, so a scripted UI
run or an agent's calls spent most of their time waiting. The window answers with two
writes (the JSON, then the newline), and the MCP proxy sends requests the same way. With
Nagle's algorithm the second write waited for the peer's delayed ACK.

**Decision.** Both ends set `TCP_NODELAY` on the connection.

**Consequences.** A request on an idle window takes about 18 ms (waking the loop and one
frame), measured with 10 sequential `perf`, `get_selection` and `input` calls.

## 44. Exported code ships the document's fonts and images

**Problem.** Exported pages named the brand fonts but did not load them, so a browser
fell back to Helvetica, and image fills pointed at `./images/…` next to the document,
not next to the code.

**Decision.** Export writes `@font-face` for each font the document and its libraries
declare under `fonts` (the declaration pen.dev writes), and with `dir` copies those font
files to `fonts/` and the images the code uses to `images/` beside the code. The
`export_code` response lists them under `assets`. Fonts that are only installed on the
Mac are not copied: whether they may be shipped is the user's call, and `add_fonts`
declares them.

## 45. Test windows never open the repository's sample

**Problem.** During dogfooding Session 9 a fuzz run in a quiet test window clicked the
onboarding's "Sample design system" card. When the test folder has no
`sample-screens.pen`, the card opens the one in `designs/` next to the build, so the fuzzer
edited the real sample and autosave wrote it (the `s-home` screen and its page entry were
lost). The quiet-mode guards covered recent files and file dialogs, not this path.

**Decision.** In a quiet window the card copies the sample and its library into
`$TMPDIR/agentic-design-sample-<pid>/` and opens the copy.

**Consequences.** Fuzzing can still exercise the sample. Anything else that opens a fixed
path must follow the same rule; the only other one is the default `designs/untitled.pen`
when no file is given, which tests never rely on.

## 46. Moving a layer outside a component keeps the instance copies

**Problem.** Every frame of a drag rebuilt every instance in the document: `doc_move` wrote
`x` and `y` through `node_refresh`, which moves the document's version, and `ghosts_sync`
rebuilds all ghosts on a new version. On a file with 1,500 layers and 3,000 instance copies
the input phase of a drag frame took 7.7 ms of the 8.3 ms a 120 Hz frame has.

**Decision.** `doc_move` writes the position without moving the version when the layer is
not a ghost and neither it nor an ancestor is `reusable`, and asks for a layout
(`layout_invalidate`) instead. No instance copies such a position: an instance's own `x`
and `y` are not applied to its copy (`root_override_skipped`), and copies are made of
components only. Inside a component the version moves as before. This is the one
exception to decision #37's rule that every change to a layer moves the version.

**Consequences.** Drag input on that file takes 2.5 ms instead of 7.7 (no ghost rebuilds);
the layout still runs over the whole document, which is what remains of it
(docs/performance.md). Anything cached by the version must not depend on the positions of
layers outside components; nothing does today (pages, theme axes, child lists, ghosts).

## 47. Agent work is latency-critical: no App Nap while requests come in

**Problem.** A window launched by an agent's MCP call ran at background priority (App
Nap: it is behind other windows, or the display sleeps). macOS stretched the frame-pacing
sleep (`1 / refresh`) to about 130 ms, so each request waited about 170 ms and a screenshot
took seconds. Test windows started from a shell were never throttled, so tests missed it.

**Decision.**

- Each request begins (or extends) an `NSProcessInfo` activity, user-initiated and
  latency-critical, which ends 10 s after the last request (`activity_darwin.odin`). A
  window nobody uses can still nap.
- The pacing sleep waits on a semaphore the server posts, so a request cuts it short.
- Frames a screenshot, export or copy waits for are not paced.

**Consequences.** Agents get the same latency in the background as in front. The
activity allows idle system sleep, so a long agent session does not keep the Mac awake.
Odin's `ActivityOptions` bit_set takes log2 of multi-bit masks, so the raw value is
passed.

## 48. Exports ship only openly licensed fonts

**Problem.** Export with `dir` copied every declared font next to the code, commercial
ones included: the landing page bundle carried Scto Grotesk A, licensed per user (the
reason `designs/fonts/` is not in git).

**Decision.** Amends #44. A font is copied only when its name table names an open
license (SIL OFL, Apache, Ubuntu Font Licence), as Google Fonts and fontsource files do.
Other declared fonts keep their `@font-face` rule, pointing at `fonts/<file>`, and the
`export_code` result has a warning naming the file to supply. `copy_all_fonts: true`
copies them anyway, for a user whose license allows web embedding. The export button in
the window follows the default.

## 49. The big allocator's own maps live on the heap; test windows stay out of Downloads

**Problem.** Two freezes. (1) Rarely, the window stopped for good: the bookkeeping maps
of the big allocator (#36) took their allocator from the first caller's context, which was
the big allocator itself. Growing a map under `big_mutex` freed its old storage through
the big allocator; a page-aligned block went to `big_size`, which locked `big_mutex` again
on the same thread. (2) A fuzzed quiet window pressed Export, which writes to
`~/Downloads`; the first write from a process without access waits in `open()` for a
system consent prompt.

**Decision.** The maps are made with `runtime.heap_allocator()` before first use, so no
allocation under `big_mutex` comes back into the big allocator. Quiet windows export to
`$TMPDIR/agentic-design-downloads` (`downloads_dir`).

**Consequences.** The user's window still exports to `~/Downloads` and may show the
consent prompt once, as any app does.

## 50. Correction to #43: the 170 ms per request was App Nap, not Nagle

**Problem.** #43 credited `TCP_NODELAY` with cutting a request from about 170 ms to 18 ms.
The two measurements were taken on different test windows: the slow one had been idle
behind other windows with the display asleep (napping, as found later for D35), the fast
one had just started. The comparison mixed the two effects.

**Decision.** #43 stays: setting `TCP_NODELAY` on a request/response socket costs nothing.
The latency fix is #47. The controlled comparison is in
[performance.md](performance.md#windows-started-by-an-agent-d35-decisions-43-and-47)
("Windows started by an agent"): three builds of the same tree, the window started as the
MCP proxy starts it. `TCP_NODELAY` alone changes nothing measurable; App Nap accounts for
the whole ~170 ms, and #47 removes it.

**Consequences.** Latency tests start the window as an agent does and let it idle before
timing (`tools/perf/agentlat.py`), and compare builds on the same kind of window.

## 51. The engine is a package of its own, set up by its host through a few globals

**Problem.** The app is to run on WebGPU, in the browser and later on other platforms,
and native apps for phones should share its rendering. The code that reads, lays out and
draws a `.pen` document lived in the same package as the window, the interface and the
socket, and reached into `app` for the NanoVG context, the open document, its path, the
theme, the hidden pages and the flag that asks for a layout. Nothing of it could be built
without the rest.

**Decision.** Seventeen files moved to `src/engine/` (package `engine`), and the drawing
and transform code moved out of `app.odin` into `src/engine/draw.odin`. The engine
imports nothing from the app. What it used to read from `app` is now set by the host in
`src/engine/engine.odin`: `renderer`, `current`, `hidden`, `theme` and `allocator`. A
`Document` carries its `path`. A layout request is `layout_invalidate()` (the
`layout_epoch` that layout already compared). The draw order of top-level layers is
passed to blur in `Blur_View.order`. The app's side of pages, libraries, fonts, file
dialogs and export, which needs the window or the tabs, stayed in the app in
`*_ui.odin` files. The app names engine symbols with the `engine.` prefix (Odin has
no `using` for imports).

Map iteration order changes between runs, and two outputs depended on it: the order of
a component's props in the React export (the `descendants` of an instance were read in
map order) and the font list in the guide. Both now go through `sorted_keys`, so the same
document gives the same output every time. When two override paths of one instance name
the same part, the later one in key order wins (before, it was whichever the map gave).

**Consequences.**

- Before the move and after it, documents, lint, HTML export and every screenshot of the
  two Sample files were compared: identical, except up to 1 in 255 on about 0.01 % of
  text pixels after the sorting change (glyphs reach the atlas in another order). Undo,
  the session and presence scripts, the scripted run and two fuzz passes under lldb
  pass. Idle CPU and memory at start (273 MB) are unchanged.
- The engine is still single-threaded and keeps its state in globals: one engine per
  process. A C API for other languages, if phones need it, goes on top of this package.
- The next step puts a renderer interface between `draw.odin` and NanoVG's GL backend, so
  that a WebGPU backend can replace it.

