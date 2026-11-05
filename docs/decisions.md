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
- **Delivery.** The Export menu writes the files to `~/Downloads/<title>-html|react` (since
  #64 to a folder named in the save panel). The
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
- A scripted run walks every panel; a fuzzer sends random clicks, drags and keys (both are
  kept with the tests, in a private repository).
- Run the window under `lldb --batch -o run -k bt` in quiet mode to get a backtrace for any
  crash.

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
  and diffing bounds and pixels (a comparison harness kept with the tests).
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
the layout still runs over the whole document, which is what remains of it. Anything cached by the version must not depend on the positions of
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
The latency fix is #47. The controlled comparison (kept with the
performance notes in the tests repository) covers three builds of the same tree, the window started as the
MCP proxy starts it. `TCP_NODELAY` alone changes nothing measurable; App Nap accounts for
the whole ~170 ms, and #47 removes it.

**Consequences.** Latency tests start the window as an agent does and let it idle before
timing, and compare builds on the same kind of window.

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
  text pixels. Those pixels change with where the binary is run from, not with the code:
  the same binary copied to a longer path gives them too (probably the window's own
  text, which includes the binary's path, puts glyphs into the atlas in another order).
  Comparisons of two builds therefore run both from paths of the same length. Undo, the
  session and presence scripts, the scripted run and two fuzz passes under lldb pass.
  Idle CPU and memory at start (273 MB) are unchanged.
- The engine is still single-threaded and keeps its state in globals: one engine per
  process. A C API for other languages, if phones need it, goes on top of this package.
- The next step puts a renderer interface between `draw.odin` and NanoVG's GL backend, so
  that a WebGPU backend can replace it.

## 52. The GPU work besides NanoVG goes through one interface, one backend compiled in

**Problem.** Moving to WebGPU (and to the browser, where WebGPU is the only modern API)
means replacing every OpenGL call. NanoVG already reaches the GPU only through its
backend callbacks (`nvg.Params`), but the app and the engine also called GL directly:
the window's clear, offscreen framebuffers for screenshot tiles and blurs, the blur
shader, `glReadPixels` through a pixel buffer, the texture size limit and NanoVG's
buffer recycling. GL's pixel rows run bottom-up, and the PNG, JPEG, WEBP and PDF
encoders flipped them.

**Decision.** `src/engine/gpu.odin` lists what a backend provides: `Gpu_Surface`,
`Target` (an offscreen colour buffer with a stencil and the NanoVG image to draw it
with), `gpu_create`, `gpu_window_begin`, `target_make`, `target_begin`, `target_free`,
`gpu_blur`, `gpu_read`, `gpu_max_side`, `gpu_trim` and `gpu_finish`. The backend is
chosen when building (`-define:RENDERER=gl`, the default); each backend's file wraps its
declarations in `when RENDERER == ...`, so a call costs nothing and the compiler checks
that every backend has every call. `src/engine/gpu_gl.odin` holds the OpenGL code that
was in `blur.odin`, `api.odin` and `app.odin`, unchanged. `gpu_read` returns rows top
first, as WebGPU, Metal and image files have them; the GL backend copies each strip it
reads into its rows from the top, and the encoders no longer flip. The pasteboard code,
the engine's last Cocoa call, moved to the app (`src/clipboard_darwin.odin`).

**Consequences.**

- A build of this step and one of the previous step, run from paths of the same length
  (#51), give byte-identical results on 35 outputs: documents, lint, exports, every
  screenshot of the Sample files, a test file with layer blur, background blur and
  shadows at three scales, view screenshots, a canvas larger than one tile, and the
  PNG, JPEG, WEBP and PDF files. The scripted run, a fuzz pass and the memory session
  under lldb pass.
- A WebGPU backend is a NanoVG backend (`src/nanovg/wgpu`) plus `gpu_wgpu.odin` with
  the same calls. The host part that differs is the surface: GL needs a current
  context from GLFW, WebGPU a surface made from the window (a `CAMetalLayer` on macOS,
  a canvas in the browser).
- A choice at build time means one binary has one backend: a machine without WebGPU
  cannot fall back to GL at run time. If that is ever needed, the same calls can become
  a table of procedures.

## 53. A WebGPU backend next to OpenGL; OpenGL stays the default until it is seen on screen

**Problem.** OpenGL is deprecated on macOS and absent from the browser and from phones.
WebGPU runs on Metal, Vulkan and D3D12 through wgpu-native, and in the browser natively,
which is what the shared engine needs (#51). It costs about 11 MB of binary.

**Decision.**

- `src/nanovg/wgpu` is a NanoVG backend written after the GL3 one: the same calls, the
  same fragment shader in WGSL, the same stencil passes for fills and strokes. Each GL
  state the GL backend switches to is one pipeline. WebGPU has no triangle fans: each
  path's fan becomes an indexed triangle list with the same triangles. Texture lookups use
  level 0 (`textureSampleLevel`), so they may sit under the shader's branches.
- `src/engine/gpu_wgpu.odin` implements the calls of `gpu.odin` on wgpu-native v29.0.1.1.
  Every target, the window's included, has the surface's format (`BGRA8Unorm`, not its
  sRGB variant, so that blending works on the same values as OpenGL) and a `Stencil8`
  buffer. The blur is the same shader in WGSL. Readback copies up to 2048 rows at a time
  into a mapped buffer: 128-row strips, each waiting for the GPU, made screenshots 3–4
  times slower than with OpenGL.
- The window: GLFW opens it without a GL context, `src/metal_darwin.odin` gives its
  content view a `CAMetalLayer` (through `objc_msgSend`, see the file), `gpu_present`
  presents. Without a drawable (a locked screen; `Occluded`), the frame is drawn into an
  offscreen target of the window's size, and a view screenshot reads that.
- The wgpu bindings are vendored in `src/wgpu` with one change: the library is linked,
  and must exist, only when `RENDERER == "wgpu"`. The 34 MB static library is not in the
  repository; `tools/fetch_wgpu.sh` downloads the pinned release and checks its SHA-256,
  and `build.sh` runs it for a WebGPU build. An OpenGL build needs none of it and is
  byte for byte the size it was.
- The default stays OpenGL until the WebGPU window has been looked at on an unlocked
  screen: presentation, live resize, Retina scale and colours. All the checks below ran
  with the screen locked. (Done the same day; WebGPU became the default, #54.)

**Consequences.**

- Pictures (35 outputs as in #52, both builds run from paths of the same length): 21
  identical, 12 within 1–2 of 255 on under 0.01 % of pixels, and two that differ more.
  The window screenshot with a fading toast differs in time, not in drawing. The canvas
  of sample.lib at scale 0.5 differs on 0.18 % of pixels: one-unit dividers there are
  half a pixel thick with edges through pixel centres. NanoVG's antialiasing fringe of a
  fill thinner than a pixel overlaps itself. OpenGL (rows counted upwards) leaves the
  overlap's edge row out and shows about half the line's colour, the correct coverage.
  Metal (rows counted downwards) takes it in and shows the full colour. Off such exact
  ties both overdraw the same way. Fills under a device pixel should be drawn as NanoVG
  draws thin strokes (one pixel wide, alpha scaled); that would fix both.
- Measured with the benchmark kept with the tests (OpenGL → WebGPU final build, a
  component-heavy document and a stress file): frames while panning 0.41 → 0.31 / 1.89 → 1.79 ms, zooming
  0.29 → 0.17 / 0.55 → 0.43 ms, dragging the same within the noise; idle CPU 0.9 → 0.5 /
  3.0 → 2.1 %; screenshots 10–25 % slower (stress10 canvas at 2× 222 → 278 ms).
  `phys_footprint` at start 276 → 244 / 293 → 271 MB, after the screenshots 394 → 287 /
  486 → 321 MB. The comparison of memory is not final: with the screen locked the Metal
  layer holds no drawables, while OpenGL's 99 MB of window surfaces count either way.
  Unlocked, the layer adds two or three drawables of the window's size (about 21 MB each
  on a Retina 1440 × 900 window).
- The fuzzer found a bug the GL backend had hidden: Odin's NanoVG cut the pixels of an
  RGB image file to 3 channels after asking stb_image for 4 (`src/nanovg/README.md`).
- Under lldb on a debug build: the scripted run, fuzz seeds 71, 13 and 29, undo and redo of
  102 steps, the memory session (flat at 266–275 MB through 20 screenshots) and the
  presence script pass, with no WebGPU validation errors.

## 54. WebGPU is the default renderer; Metal's fixed cost and sRGB colours

**Problem.** #53 left OpenGL the default until the WebGPU window had been seen on an
unlocked screen, and until its memory had been measured with the window's drawables,
which a locked screen does not give.

**Decision.** WebGPU is the default; `-define:RENDERER=gl` builds the OpenGL renderer,
kept as a fallback. The window's `CAMetalLayer` is tagged sRGB, and the surface has two
drawables instead of wgpu's three (`desiredMaximumFrameLatency = 1`). The `memory`
request reports `gpu_allocated_bytes` (`MTLDevice.currentAllocatedSize`; -1 with OpenGL).

**Consequences.**

- Looked at side by side with OpenGL on the same file, the user saw no difference, and
  live resizing was smoother. Their two screen captures (Display P3) differ only in
  saturated colours: a purple of sRGB (57, 8, 158) shows as P3 (52, 12, 152) in the WebGPU
  window, exactly its sRGB-to-P3 conversion, and as P3 (57, 8, 158) in the OpenGL one. The
  OpenGL window passed the document's sRGB values to the display unconverted, so on a P3
  screen saturated colours were too saturated; WebGPU shows them as pen.dev and browsers
  do. Greys are identical.
- Memory, both windows visible, same file: at 850 × 620 points WebGPU takes 227 MB and
  OpenGL 196 MB; at 1440 × 900, 258 against 276 MB (after ten 2× screenshots each, 266
  against 284 MB). Window surfaces: OpenGL 41 / 99 MB, WebGPU 16 / 40 MB (two drawables).
  The rest of the difference is the GPU driver's own memory: 165–171 MB for WebGPU
  against 102–119 MB for OpenGL, of which only 17–22 MB are our textures and buffers
  (`gpu_allocated_bytes`). Plain Metal shows where the rest comes from: a test program
  (no wgpu) that only clears a texture each frame holds 86 MB of driver memory, and 142 MB
  once a frame also copies a buffer or uploads a texture, whatever the size of the copy
  or the queue. wgpu itself adds nothing (a wgpu window that only clears holds 0 MB until
  it draws), and texture uploads cannot be avoided, so this is the floor of a Metal app on
  this system. It is larger than OpenGL's, and OpenGL's window surfaces are larger than
  WebGPU's: WebGPU wins from about 1440 × 900 up, and by 100–165 MB after screenshots of
  big files (#53).
- A window that macOS reports as not visible (`occlusionState`: behind other windows, or
  opened without focus behind the active app) gets no drawable from wgpu, and draws
  offscreen until shown; the log says when it switches.
- A build now downloads wgpu-native once (`tools/fetch_wgpu.sh`, run by `build.sh`).


## 55. A browser viewer on the same engine; the engine's files go through one layer

**Problem.** Step 4 of the WebGPU plan (#51–#54): show `.pen` files in a web page with the
engine of the app, not a second renderer. Odin's `core:os` does not compile for
`js_wasm32` at all, and the engine used it, `core:path/filepath` and POSIX `mmap` for
fonts, images, libraries and code export. A page has no files, no installed fonts and no
synchronous GPU readback, and the browser hands out its WebGPU adapter and device through
promises.

**Decision.**

- Everything the engine asks of the system goes through `src/engine/files.odin`:
  `read_file`, `map_file`, `file_exists`, `file_mtime`, `dir_names` and path procs, with a
  desktop half on `core:os` (as before, call for call) and a browser half on a table of
  files the host hands over. Font headers are now parsed from the mapped file instead of
  `read_at` calls, and an image file is read and decoded from memory instead of by path
  (`stbi.load` has no file access in WebAssembly).
- In the browser, a read of a file that is not in the table fails and queues its path;
  the viewer has the page fetch the queue from its server and reads the document again
  when the files arrive. The engine asks for exactly what it reads: the document, then
  the libraries it imports, then the fonts they declare and the images it draws, each
  round in parallel. A file the server does not have is handed over empty and listed as
  missing. No manifest of a document's files, no second parser in JavaScript.
- The WebGPU backend splits into a shared file and a desktop and a browser half
  (`gpu_wgpu_native.odin`, `gpu_wgpu_js.odin`). In the browser the context is created
  through callbacks (`gpu_create_async`), with the browser's default limits (8192-pixel
  textures, 256-byte uniform offsets: what the renderer uses; the glue's conversion of
  required limits reads the wrong offset), and `gpu_read` gives blank pixels. PNG
  encoding uses stb_image_write there (no system zlib). OpenGL is desktop-only.
- The page owns the input (Odin's glue passes no modifier keys or position with a wheel
  event, and a trackpad pinch is a wheel with `ctrlKey`) and calls exported procs. The
  module draws only when something changed. Text without a family and families that are
  not available are drawn with the built-in Noto Sans, as pen.dev does.

**Consequences.**

- The same About screen of sample-screens drawn at 1× in headless Chrome (Dawn on Metal)
  and by the app (wgpu-native on Metal) differs by at most 1/255 per channel. At 2×,
  0.05 % of the pixels differ, on the edges of curves (icons, a circle's stroke): the
  curve tessellation is finer at 2× and WebAssembly's floating point does not round
  exactly as arm64's.
- In headless Chrome at 1440 × 900 and 2×, a frame's layout and drawing take a median
  of 1–5 ms while panning or zooming sample-screens, a product design (eight pages, images, a
  library), the site design and the stress file, 9 ms at most (zooming a product design); the
  module's heap is 49–79 MB. The WebAssembly file is 5.4 MB, 4.3 MB of it the two Noto
  Sans fonts.
- On the desktop nothing changed: the 35 outputs of the build comparison and the product design's
  screenshots (with image fills) are byte-identical to the build before.
- Building it needs LLVM's `wasm-ld` (Homebrew's `lld`), which `tools/build_web.sh`
  looks for. Fonts in a `fonts` folder next to a document are only found when the document
  lists them (a web server lists no folders), as in pen.dev.

## 56. A Mac app bundle for Apple Silicon and macOS 14; one version in the code

**Problem.** The app was a bare binary in a build folder that opened files next to the
repository. Releasing it needs an installable `.app`, a version shown to users and compared
by updates, and a known oldest macOS.

**Decision.**

- `VERSION` in `src/version.odin` is the only place the version is written. `--version`
  prints it, Settings shows it, `tools/release/bundle.sh` writes it into Info.plist from the
  binary's own `--version`, and the release workflow refuses a tag that differs. A build can
  override it (`-define:VERSION=…`) to make a test update.
- The bundle is `Agentic Design.app`, id `dev.kcrz.agentic-design`, with the icon, the
  sample design system in Resources, and `.pen` as a document type. The binary inside works
  in every mode (`Contents/MacOS/agentic-design mcp`), and agent registration points at it.
  Installed, the default document is a scratch file in Application Support and the sample
  is copied there, since the bundle is read-only and replaced by updates.
- arm64 only. The pinned Odin release has no Intel macOS build, wgpu-native is pinned for
  arm64, and a universal binary would double the build for few users. macOS 14: the Odin
  release's GLFW is built for 14.0 (`-minimum-os-version:14.0`; without it the binary
  required the build machine's macOS). Release builds use the official Odin release, not
  Homebrew's, whose GLFW is built for the newest macOS.

**Consequences.** Intel Macs and macOS 13 are not supported. A copy run from its download
folder is translocated by macOS: it refuses to update or register with agents and asks to
be moved to Applications.

## 57. Updates: a built-in updater over a signed manifest on GitHub Releases

**Problem.** Users should get new versions without reinstalling, safely, without an update
cutting off an agent mid-call, and test windows must never update.

**Decision.** A small updater in the app (`src/update.odin`) rather than Sparkle 2. Sparkle
is an Objective-C framework with XPC helpers and its own windows, to be embedded, signed
and driven through delegates from Odin, for a flow the app can do in a few hundred lines
with tools macOS already has. The app's way of doing it:

- At launch (after 8 s) and every 24 h, and from Settings ("Check now"), a worker thread
  fetches `latest.json` and `latest.json.sig` from the latest GitHub release with
  `/usr/bin/curl`. The Ed25519 signature over the manifest's exact bytes is checked against
  the public key compiled into the app (`core:crypto/ed25519`) before any field is used;
  HTTPS alone is never trusted.
- A newer version's zip is downloaded to `~/Library/Caches/dev.kcrz.agentic-design`, must
  match the manifest's size and SHA-256, is unpacked with `ditto`, and must have the same
  bundle id, the manifest's version and a valid code signature (`codesign --verify --deep
  --strict`). Only then is it offered.
- Nothing installs without the user's click ("Restart to update"). Then the app waits until
  no agent request is queued, no capture is pending and none came in for 5 s, copies the
  new bundle beside the old one, swaps them atomically (`renamex_np(RENAME_SWAP)`; on a
  volume without it, two renames with a rollback), deletes the old one, saves documents by
  the normal quit path and relaunches with the open document through a helper that waits
  for this process to exit.
- Settings → Updates: the version, "Check for updates automatically" (on by default),
  "Check now", the state, and the restart button.
- Test windows (`AGENTIC_QUIET`) never check or install. `AGENTIC_UPDATE_TEST=1` and
  `AGENTIC_UPDATE_URL` make a test window that does, against a local feed; only such a window
  accepts the socket's `update` install action.
- The signing tool (`tools/release/updatesign`) uses the same Odin crypto as the app.

**Consequences.** The private key is the root of trust: it lives outside the repository (a
GitHub secret for the workflow) and losing it strands installed copies. Found on the way:
the control socket was inherited by the relaunch helper, so the new window found its port
taken and ran without a control server; both sockets are now close-on-exec.

## 58. Releases are built by a workflow on tags; signing is optional, the update key is not

**Problem.** Releases should be reproducible and need no maintainer's machine, but code
signing needs a paid Apple certificate the project may not have yet.

**Decision.** `.github/workflows/release.yml` runs on `v*` tags on an Apple Silicon runner:
the pinned Odin release (version and SHA-256), the tag checked against `VERSION`, the
release build and bundle, Developer ID signing with the hardened runtime and notarization
with stapling when those secrets exist (ad hoc otherwise), the signed `latest.json` checked
against the app's public key, and a GitHub Release with the dmg, zip, manifest, signature,
checksums and the notes from `docs/releases/v<version>.md`. The update signing key
(`UPDATE_SIGNING_KEY`) is required; the Apple secrets are not.

**Consequences.** Until there is a Developer ID certificate, a downloaded first install is
blocked by Gatekeeper and must be opened by hand once; updates through the app are not
quarantined and start normally.

## 59. Open source code, private tests; the sample is our own

**Problem.** The repository was about to become public. It held the test harnesses,
benchmarks and the dogfooding log next to the code, and its sample design system was
distilled from another company's website.

**Decision.** The code is MIT. The tests (the scripted interface runs, fuzzing, benchmarks,
pen.dev comparisons, the update end-to-end checks), their fixtures and the QA logs live in a
private repository that works against a checkout of this one, as SQLite keeps its tests;
issues are welcome, pull requests are not accepted. Everything a user or contributor needs
to build and run the app stays here. The bundled sample is this app's own landing page
(`designs/sample/`), designed through the MCP tools, with its OFL fonts. The history was
rewritten to remove the moved files and the old sample.

**Consequences.** Docs and comments that pointed at the moved files now say the material is
kept with the tests.

## 60. Dashed strokes, scaled copies and drawn bounds

**Problem.** Rebuilding a marketing site, an agent faked dashed borders with rows of small
rectangles, rebuilt each illustration by hand at 64% for mobile, and could not tell where
a tilted layer landed: `bounds` is the unrotated layout box.

**Decision.**

- Dashes are `strokeDashPattern: [dash, gap, ...]`, next to `strokeWidth`, as the 2.21
  schema names stroke properties (since #67 kept in `metadata`, the only place pen.dev
  keeps it); older files with the dashes in the stroke object
  (`dashPattern`) are read too. The schema has no dash property: pen.dev keeps the stroke
  and draws it solid (checked in pen.dev 1.2.21), so dashes are this app's extension. The
  vendored NanoVG gained `StrokeDash`: `Stroke` splits the flattened outline into open
  dashes (scaled with the transform), so every shape and path gets them with its caps and
  joins. Export writes `stroke-dasharray` for SVG paths and `border-style: dashed` for
  boxes; CSS borders take no dash length.
- Scaling is a tool, not a property: `scale_nodes` rewrites a subtree's numbers in one
  undo step. A `scale` property would be lost on pen.dev, which has none; rewritten numbers
  are plain `.pen` everywhere. Variables and instances' inner sizes are left alone and
  reported.
- `bounds` stays the layout box (what `x`, `y` and sizes mean). A rotated or flipped layer,
  or one inside such a layer, also reports `visual_bounds`, the box as drawn; lint's
  `clipped` rule uses the rotated corners.

**Consequences.** Per-side strokes stay solid. A dashed line is a one-segment path, since a
zero-height rectangle's outline runs out and back over itself.

## 61. A rotated layer in a flex frame takes the room of its rotated box, as in pen.dev

**Problem.** A layer turned by `rotation` inside a frame with a flex layout was laid out by
its unrotated box and then turned around its top-left corner. pen.dev lays out the box
around the rotated layer: a 160 × 100 card at 30° in a horizontal frame took 160 of the row
here and 188.6 there, and stuck out above the frame instead of starting at its top. Every
later sibling, the frame's fit_content size and the cross-axis alignment differed with it
(D53).

**Decision.** Measured in pen.dev 1.2.21 (its MCP `Get` with resolved bounds, then
`layout: "none"` to read the positions it gives): in a flex frame a rotated child counts
with the axis-aligned box around it, for the flow, the gaps, `justifyContent`,
`alignItems` and the frame's fit_content size, and its top-left corner (the point it turns
around) sits inside that box where the rotation puts it. A `fill_container` child gets its
share of the free room as its own, unrotated, size and then takes the room of that size
rotated, as pen.dev does. In `layout: "none"` frames nothing changes: `x` and `y` are the
corner it turns around, as the schema says ("Degrees CCW around top-left corner"; the
format has no other origin). `rotated_extent` in `layout.odin` gives the box and the
corner's offset.

**Consequences.** On a minimal file (horizontal and vertical frames, each alignment,
justify centre, a rotated frame with a text inside, rotations of −20° to 90°) every
layer's box now equals pen.dev's to 0.01; before, up to 217 units off
(`tools/perf/rotcmp.py`). Files without rotated children in flex frames are unchanged:
canvas screenshots and `get_document` of sample.lib, sample-screens, reddit-ui and
stress10 are identical. A product landing page we compare places all its tilted cards in
`layout: "none"` frames, so it is unchanged too; its hero and "Built for this job" frames
match pen.dev's bounds to 1.94 units, all of it text widths.

## 62. Paths fill by their fill rule and align an outer stroke; text can be outlined into a path

**Problem.** pen.dev drops a stroke on a text layer (an update with `stroke` leaves no key
on the node, and stroked text draws its fill only), so the outlined `+` and `=` of the HR
Breakers site cannot be text. A path keeps a stroke, but the app filled every subpath of a
path as solid: holes vanished (a ring, the counter of an `A`), whatever the path's
`fillRule`. pen.dev draws both rules.

**Decision.**

- Paths fill by `fillRule` (`nonzero` by default, `evenodd`), read from the file. NanoVG
  fills with a stencil that counts front faces up and back faces down, which is the
  nonzero rule as long as each subpath keeps its direction; it used to force them all to
  one. Each subpath now keeps the direction it was written in, all turned so that the
  biggest runs counter-clockwise (NanoVG puts the antialiasing fringe outside such a
  contour; turning every subpath keeps nonzero's result). For `evenodd` a subpath inside
  an odd number of others becomes a hole: exact for nested contours, overlapping ones
  are joined. HTML and React export write `fill-rule` for `evenodd` (browsers apply the
  winding themselves).
- A path's stroke with `strokeAlignment: "outer"` over a solid opaque fill is drawn as a
  stroke of twice the width under the fill (CSS `paint-order: stroke`, which export writes),
  as pen.dev draws it. An inner stroke, or an outer one over a fill that does not cover
  (none, translucent, a gradient, an image), still follows the outline's centre: drawing
  those needs clipping to the path, which NanoVG does not have.
- `outline_text` (an MCP tool and "Outline text" in the context menu) turns text layers
  into paths, one undo step. The geometry is written by the code that draws the text: a
  sink in `text_outline.odin` takes the glyph outlines, kerning, letter spacing, fallback
  fonts, line breaks, alignment, justification and underlines that `draw_text` produces,
  in the text's own box. The path keeps the text's id, position, box (`width`, `height`
  and `viewBox [0, 0, w, h]`, so a flex parent lays it out the same), rotation, opacity,
  fill and effects; text without a fill gets black, which is what it drew. A bold the
  family lacks, drawn by thickening a lighter face, keeps that look as a stroke of its
  fill colour. Text inside an instance is refused: outline it in the component.

**Consequences.** A ring with a nonzero and one with an evenodd hole, and an outer stroke
around a filled +, match pen.dev's export pixel for pixel; a lettermark logo now has the
counter of its R cut out, as in pen.dev (it was filled). Outlined text fills the same
shapes as the text: at 16× (where the canvas draws text as outlines too) 0.024 % of pixels
differ, by at most 38 of 255, where glyphs' antialiasing overlaps (the path is one fill,
the text one per line); at 1× the canvas draws small text from its glyph atlas, which
antialiases differently from any vector fill (6 % of pixels). Undo gives back the document
byte for byte. pen.dev opens the outlined file, keeps the stroke added to it and draws the
same picture (2 % of pixels at 2×, on edges). An outlined layer is no longer editable as
text.

## 63. Small text on whole pixels, from glyphs rasterised at their subpixel offset

**Problem.** Small text was the largest difference left between a product design and
its live site in Chrome (D44): every paragraph and label came out softer and slightly
heavier. A 14 px bullet line differed from Chrome's by a mean of 3.2 per channel, with 7.5 %
of its pixels more than 16 off. fontstash placed each glyph's bitmap at the pen's exact
fractional position (decision #10 removed its rounding so that text keeps its width at any
zoom), and the texture's bilinear sampling then spread every glyph over a pixel more.
Skia, which Chrome and pen.dev use, rasterises a glyph at the pen's subpixel offset and
draws it on whole pixels, with the baseline on a pixel row.

**Decision.** fontstash rasterises a glyph at one of four subpixel offsets across a pixel
(`MakeGlyphBitmapSubpixel`; the offset is part of the glyph's cache key) and places its quad
on whole device pixels, the baseline rounded to a pixel row. nanovg turns this on for a
`Text` call when a unit of fontstash's space is a device pixel: an axis-aligned transform
with the same scale both ways that `__textScale` neither capped nor rounded. That covers
screenshots and exports at whole scales and the canvas at 100 % and 200 %; at other zooms
glyphs keep their fractional positions. Pen positions and advances are unchanged, so line
breaks, widths and layout are exactly as before.

Also tried, and not kept: a coverage curve fitted to headless Chrome (whose text is
darker than the user's Chrome, which follows macOS's font smoothing setting: on the live
captures our glyphs already carry about 5 % more ink than Chrome's), and curves that thin
or thicken the coverage. On the live site's captures each was worse than raw coverage.

**Consequences.**

- On the dogfooder's live captures of the landing (`secdiff`, 12 sections × desktop and
  mobile × light and dark): the share of pixels more than 16 off fell from 2.46 % to 1.83 %
  (desktop light), 4.55 % to 3.32 % (mobile light), 2.47 % to 1.88 % and 4.46 % to 3.31 %
  (dark); the mean difference by 13–15 %; pixels more than 48 off by 3–7 %. The 14 px
  bullet line: mean 3.23 → 1.57, more than 16 off 7.47 % → 3.47 %.
- Against pen.dev's export of the same lines (12–20 px and two headings): mean 6.25 →
  4.59 at 1×, 3.51 → 2.56 at 2×; headings 2.22 → 1.90.
- `get_document` and the saved file are byte-identical before and after on that product design.
- Up to four bitmaps per glyph and size: at 100 % the atlas of sample-screens grows from
  1024 to 2048 pixels square while panning (the trim budget; the whole product landing page
  pans at 100 % without a reset), and a frame takes 0.33 ms instead of 0.27.
- Remaining: Blink rounds a font's ascent and descent to whole pixels before centring a
  line, so some sizes (13 px) sit a pixel row away from Chrome's; and the app's instances
  of a variable font at in-between weights (500, 600) are a little thinner than Chrome's.

## 64. Exports from the window ask where to save; agents' and test windows' do not

**Problem.** Every export from the window went to `~/Downloads` under a made-up name
("<file> - <layer>.png"), with only a toast saying so. Users expect the Mac's save panel,
to choose the name and folder; several layers came out as one image of their bounds.

**Decision.** User-initiated exports (Shift Cmd E, the Export menu, the context menu, the
inspector's Export section) open the system panel, between frames so no frame is half
drawn:

- One layer, or the page with nothing selected: `NSSavePanel` with the layer's name (the
  file's title for the page) plus `@2x` at another scale than 1, and the format's
  extension. The panel allows the four image extensions with the chosen one first: typing
  another of them (`.jpg`, `.pdf`) exports in that format, so no format popup is needed.
- Several selected layers: an open panel choosing a folder (it can create one); each layer
  is written as `<name>.<ext>`, a repeated name as `<name> 2.<ext>`.
- HTML + CSS and React + Tailwind: the save panel names the folder the files go into
  (`<title>-html`).
- The panel opens in the folder of the last export (`exportFolder` in settings.json), at
  first the document's folder. Cancel does nothing. After writing, the toast says what was
  exported and has "Show in Finder" (6 s, kept while the pointer is on it; the canvas does
  not take its clicks).

Agents' exports (`screenshot` with `path`, `export_code` with `dir`) do not go through
this and write where they are told. A quiet window never opens a panel: it writes to its
default folder in `$TMPDIR` (#49), so tests and the fuzzer cannot wait on a modal.
Copy as PNG and as HTML (Shift Cmd C, Option Cmd C) stay on the clipboard.

**Consequences.**

- In a quiet window, Shift Cmd E with one, several or no layers selected and the Export
  menu's HTML write their files to `$TMPDIR/agentic-design-downloads` (`<layer>@2x.png`, a
  file per layer, `agentic-design-html/`) and the socket keeps answering. In a normal
  window the panel opens and the window waits for it, like the open panels before.
- While the panel is open the main loop is inside `runModal`: agent requests wait until
  the user answers it, as with the other system panels, and a quit signal is handled after.

## 65. Small text kerns at its variable weight and keeps Chrome's baseline at fractional positions

**Problem.** Two differences from Chrome remained after #63 (D44). Text at weights 500
and 600 of a variable font (Inter) looked thinner and spaced differently from Chrome's.
The instance itself was right: its outlines and advances equal fontTools' instancer's. But
GPOS kerning came from the default instance, because the deltas that `XAdvDevice` tables
point to in GDEF's item variation store were never read. Then some lines sat a device pixel
row off Chrome's. Blink rounds a font's ascent and descent to whole pixels and puts the
baseline the rounded ascent below the line box's pixel-snapped top. The app put it at the
exact ascent and rounded the sum, which differs whenever a text layer sits at a fractional
`y`, as flex layouts often place it.

**Decision.**

- fontstash adds the variation deltas to GPOS pair kerning at the instance's axis
  coordinates: the normalised coordinates after `avar`, which `varfont_instance` writes
  into a private `ADvc` table of the instance.
- When glyphs go on whole device pixels (#63), text with "normal" line height (no
  `lineHeight`) starts its first line at the ascent rounded to device pixels
  (`blink_baseline_top` in `draw.odin`).
- Text with an explicit `lineHeight` keeps the exact half leading. Blink would floor the
  half leading too, but pen.dev, the reference (#25), places such text by the exact
  value, and so does the dogfooder's importer when it reads positions from the live
  page. On the landing, the Blink rule for those layers moved mobile text a row low
  (more than 16 off: 3.21 → 3.63 % on mobile light); with only "normal" text it gains
  everywhere.

**Consequences.**

- Inter at 600 draws pixel for pixel as the static Inter SemiBold does. A 14 px 600 line
  against Chrome: mean 9.2 → 4.1.
- The baseline rule matches headless Chrome on a harness with fractional positions to a
  mean of 0.15 px at 1× (0.49 before) and 0.09 at 2× (0.16). pen.dev places such text
  unsnapped, a fraction of a pixel from either rule.
- Landing sections against the dogfooder's live captures (`secdiff`, 12 sections), from
  #63 to now, share of pixels more than 16 off: desktop light 1.83 → 1.51 %, mobile light
  3.32 → 2.82 %, desktop dark 1.88 → 1.56 %, mobile dark 3.31 → 2.82 %. More than 48 off:
  0.82 → 0.57, 1.43 → 1.03, 0.83 → 0.57, 1.39 → 1.01 %. Mean: 1.47 → 1.16, 2.57 → 2.08,
  1.35 → 1.07, 2.29 → 1.85. Before #63 the share of pixels more than 16 off was 2.46,
  4.55, 2.47 and 4.46 %.
- Text widths at weights 500 and 600 change by up to 1.5 units (kerning), so
  `get_document` bounds move with them. Saved files are byte-identical.

## 66. Bring to front says when a layer cannot go further inside its parent

**Problem.** A user selected the "+" of an imported page's hero, drawn partly under the
card next to it, and Bring to front did nothing. The two are not siblings: the import
wraps the "+" in a frame of its own (two outline paths in it), and that frame comes
before the card in their common parent. Bring to front orders a layer among its
siblings, as Figma and pen.dev do, and the "+" was already in front inside its wrapper,
so nothing moved and the editor said nothing.

**Decision.** The behaviour stays; the editor says why (chosen by the user among a hint,
moving the parent instead, and fixing the import).

- When none of the selected layers can go further, Bring to front, forward, backward
  and Send to back (], ⌘], ⌘[, [ and the context menu) show a toast instead: "Already
  in front inside '<parent>' — Shift+Enter selects it", or "Already at the back
  inside ...". A top-level layer is "Already in front on the page". No undo step is
  made and the document is not marked edited.
- MCP `reorder`, and `batch` `move` with `position`, answer `moved: false` with a note
  naming the parent and its id, and change nothing; otherwise `moved: true`.
- `get_selection` includes the toast showing at the moment (`status`), so agents that
  drive the interface can read such hints.

**Consequences.** Shift+Enter then ] brings the wrapper, and the "+" with it, over the
card. `tools/zorder.py` in the tests repository checks the keys, the hint texts, the
MCP replies, undo and the pixels at the overlap on a minimal file with a turned wrapper
and a turned, shadowed card. The import's order (the live page puts the "+" over the
card with CSS stacking) is a separate fix in the importer.

## 67. Extension data lives in metadata: the dash pattern moves there (updates #60)

**Problem.** pen.dev 1.2.21 drops every property it does not know when it loads a file; of
our own data only `metadata` (`{type: string, ...any}` in the 2.21 schema) comes back
(checked by hand in pen.dev with a probe file). The node-level `strokeDashPattern` of #60
was therefore lost as soon as a file was opened and saved there.

**Decision.**

- The dash pattern is `metadata.strokeDashPattern`. The stroke itself stays standard
  (`stroke`, `strokeWidth`, caps, joins, alignment), so pen.dev draws it solid and keeps the
  pattern for this app.
- Reading accepts all three forms: `metadata.strokeDashPattern`, a node-level
  `strokeDashPattern` (files written before, and what agents send) and the old stroke
  object's `dashPattern`. Writing produces only the first: before every refresh
  (`migrate_extension_props`) a node-level key is moved into `metadata`, also inside instance
  overrides (`descendants`). Metadata of another type (a connector's) gains the key next to
  its own; a node without metadata gets `{"type": "agentic-design", ...}`, as the schema
  requires a type. `null` removes the pattern, and metadata that holds nothing else goes
  with it.
- `scale_nodes` scales the pattern in `metadata`; `outline_text` keeps `metadata`.
- Audit of what else the app writes outside the schema: no node keys. `outline_text` writes
  a standard `path` (`geometry`, `viewBox`, `fillRule` are in the schema), `scale_nodes`
  rewrites existing numbers. The header keys `pages` and `fonts` and metadata without a
  `type` (the lint tool's `{"lintIgnore": true}`) are not in the published schema; whether
  pen.dev keeps them waits for one batched pen.dev check (the probe is ready:
  every extension form in one file).

**Consequences.** Agents still send `strokeDashPattern` on the node and read it back in
`metadata`. In a quiet window: a file with the old key saves it in `metadata`; an update on
a connector's metadata keeps `type` and `foo`; `null` removes it; `scale_nodes` ×2 turns
[6, 3] into [12, 6]; an outlined text keeps it; an override `{"strokeDashPattern": [4, 4]}`
becomes `{"metadata": {...}}`; strokes from metadata draw dashed (22 dash edges along a
200-unit side), and a stroke without a pattern stays solid. The sample saves to the same
JSON.

## 68. The website and the viewer at /view: static files on Bunderhost, the viewer exports through the canvas

*The hosting part (Caddy in a container on a server) is superseded by #78.*

**Problem.** The app needs a website, and the browser viewer (#55) needs to be a product:
opening files without a server of one's own, layer info, PNG export, notices for what is
missing. Bunderhost, where the site is hosted, deploys Bunderstack and Workerstack apps and
has no static mode. In the browser `gpu_read` gives blank pixels (no synchronous readback),
so the engine's PNG path cannot export.

**Decision.**

- `site/` holds a hand-written static page after the landing design in
  `designs/sample/agentic-design.pen` (its HTML export was the starting point): its tokens,
  light and dark, desktop and phone layouts, self-hosted woff2 subsets, an Open Graph image
  rendered by the app. `site/build.mjs` adds the viewer under `/view` with the sample, hashes
  asset names, inlines the stylesheet and writes `.br` and `.gz` copies; Caddy serves them
  with immutable caching. Lighthouse: 100 in all four categories, mobile and desktop.
- Bunderhost builds `Dockerfile.bunderhost` (repository root; the project's root directory
  is `site/`): the viewer on the pinned Odin release with `lld`, the pages, Caddy on :3000.
  Its contract asks for a blueprint, a `bunderstack` dependency, build and start scripts and
  a migration journal; the site carries minimal ones and leaves the database and bucket
  Bunderhost provisions unused. A push to `main` deploys.
- The viewer's export draws the layer or page into the page's canvas at the picture's size
  (`viewer_export`) and the page copies the canvas in the same task, before the browser
  presents it; the next frame draws the view again. It draws twice: Safari drew the first
  pass at a new size without its glyphs. The size is capped at the GPU's texture side
  (8192), so tall frames export at a lower scale.
- Selection follows the app's click rules (`viewer_pick`). Files the user gives stay in the
  page under `/local/<n>/`; each drop starts a new `<n>`, because the engine keeps the first
  copy of a path it was handed (a file handed over empty when missing cannot be filled in
  later). A file not found where the document says is matched by name among the dropped
  ones. A URL is read as `/~url/<scheme>/<host>/<path>`, so relative paths resolve as on its
  server.

**Consequences.**

- Every frame of the sample (light and dark), of a product design with a library, images and
  fonts, and of a five-screen design at 1× and 2× exports from Chrome 156 and Safari 27 within
  1/255 of the app's `screenshot`, except one glyph: "✓", which no font of that document
  has. The app finds it in the system's symbol fonts; a page has no system fonts and draws
  a missing glyph.
- The wasm is 5.4 MB (2.1 MB with brotli), 4.3 MB of it the built-in Noto Sans; loading those
  fonts as files of their own would let them stay cached across engine releases.
- No WebGL fallback: the GL backend is desktop OpenGL. Without WebGPU the page says which
  browsers work and links the app.

## 69. Connectors, markers and shapes with text, as plain .pen that pen.dev draws

**Problem.** Agents draw flowcharts (D54–D57 of the dogfooding log: a chat bot's flows,
seven pages, 120 arrows). An arrow was a free path that stayed behind when a box moved or
its text grew, every arrowhead a separate triangle turned by hand, and a decision diamond
a frame with a path and a text laid over it that did not wrap to it. The .pen 2.21 schema
has a `connection` type (`source`/`target`: an id path and an anchor), but pen.dev 1.2.21
drops connections when it loads a file ("Unknown node type: connection" from its API) and
drops every property it does not know; a probe saved by pen.dev kept only `metadata`.

**Decision.** Everything is plain .pen that pen.dev draws as last saved; what makes it live
is in `metadata`, which pen.dev keeps.

- A connector is a stroked `path` (`layoutPosition: absolute`) with `metadata {"type":
  "connector", "source": {"path", "anchor"}, "target": {...}, "routing", "startMarker",
  "endMarker", "waypoints"?}`; the endpoints use the schema's ConnectionEndpoint (id paths
  through instances; center, top, right, bottom, left). After every layout the routing
  pass (`engine/connector.odin`) works out the route between the two layers' boxes as
  drawn and writes it into the path's geometry, position and size when it changed: a
  connector follows its shapes, and the saved file shows the current picture.
  - `center` leaves from the side that faces the other layer. Orthogonal routes (the
    default) run 16 px straight out of a side and bend at most three times; facing boxes
    that overlap across the flow get a straight line where they overlap (a diamond or an
    ellipse only at its tips). Straight and curved routes too. Going around third boxes
    is not done; crossings will be a lint rule (D60).
  - Markers (arrow, open arrow, circle, diamond, bar) are drawn into the geometry as
    outlines, the route trimmed under filled ones; the app fills the closed ones in the
    stroke colour, pen.dev shows their outlines. HTML and React export draw the filled
    heads as a second SVG path.
  - A label is a small frame with a text and `metadata {"type": "connection-label",
    "connection": id, "at": 0.5}`, kept centred on the route; pen.dev shows it where it
    was saved. Its fill is the nearest solid container fill.
  - Native `connection` nodes are not written (pen.dev would drop them).
  - A dashed connector keeps its `strokeDashPattern` in the same metadata (#67): `connect`
    takes one, and rewriting the connector's ends, routing or markers keeps it.
- A shape with text is a frame with `metadata {"type": "shape", "shape": "diamond" |
  "ellipse" | "capsule"}`: layout gives it the padding that puts its content in the
  shape's inscribed box (a diamond's middle half, an ellipse's 71 %, a capsule between its
  round ends) and a frame that fits its content grows to hold it. Its outline is a child
  with `metadata {"type": "shape-outline"}` (a path or an ellipse) kept at the frame's
  size; a capsule is the frame's own fill and a radius of half its height. Padding,
  outline and radius are written into the file.
- MCP: `connect {from, to, fromSide, toSide, routing, startMarker, endMarker, label,
  stroke, strokeWidth, parent_id, id}` (also a `batch` op); `update_nodes` on a connector
  takes `source`, `target`, sides, routing, markers and `label`; `get_document` gives a
  connector's `route`; `create_nodes` takes `{"type": "frame", "shape", "content", ...}`
  and expands it. Deleting a layer deletes the connectors attached to it and their labels,
  in the same undo step.
- Canvas: the connector tool (C) drags from one layer to another (from a side dot for a
  fixed side); a selected connector shows its ends, which drag onto other layers or
  sides; double-click edits its label; connectors are picked by their line, not their box;
  the inspector has routing, start and end markers and the label. `get_selection` also
  gives the view (`zoom`, `origin`) for tools that drive the pointer.
- Layers created without an id get it where the loader puts it (after `type`), so a file
  saved right after an edit reads back and saves to the same bytes.

**Consequences.** `tools/connectors.py` in the tests repository checks routes against the
boxes, re-routing, markers in pixels, labels, `update_nodes`, `batch`, errors, the delete
cascade and undo, a diamond's text inside its middle half and growing with it, the
capsule's radius, HTML export, the connector tool, dragging an end, label editing, and a
saved file that is stable across a reload and has no `connection` node or unknown key
(32 checks). pen.dev 1.2.21 opens such a file and draws the same diagram, arrowheads as
outlines. Files without connectors or shapes are unchanged (`get_document`, the saved
file and a screenshot of a product design are byte-identical); the D43 batch takes as
long as before. A connector inside a turned frame is routed in page space; routes do not
avoid other boxes.

## 70. create_nodes, update_nodes and batch answer with the layers' bounds

**Problem.** Placing the next box of a diagram needs the size the last one got after
layout (its text wrapped, a shape grew), so an agent's script did create, `get_document`,
move, `get_document` again: two extra round trips per page (D58).

**Decision.** `create_nodes` and `update_nodes` (and the `create` and `update` operations of
`batch`) answer, after layout, with `nodes: [{"id", "bounds": [x, y, w, h]}]` in page
coordinates for each layer they created (the top-level ones of the request) or changed,
plus `visual_bounds` for a turned layer and `route` for a connector, as `get_document`
gives them. `created` (the ids) stays as it was.

**Consequences.** The `get_document` after each step is gone. `tools/connectors.py` checks
the answers against `get_document`. A request that changes a layer can move others (its
siblings in a flex frame); those still need a read.

## 71. PDF is vector, with real text, and exports pages into one file

**Problem.** `screenshot {format: "pdf"}` wrapped a JPEG: a seven-page diagram came out as
seven pictures, 10.6 MB, with no text to select, search or copy, and one layer per call
(D59).

**Decision.** PDF is drawn by the canvas's own code into a recording NanoVG context
(`nanovg.Recorder`): `Fill`, `Stroke` and `Text` hand their path, paint, scissor and stroke
style, or their glyphs and origins, to `engine/pdf.odin` instead of drawing.

- Paths keep their curves, fill rule (each subpath turned as NanoVG fills it), clip, and
  stroke width, caps, joins and dashes. Opacity is an ExtGState.
- Text is text: each font is embedded once per file as a subset (TrueType: only the glyphs
  used and their components, ids unchanged, no hinting or cmap; CFF fonts under 4 MB
  whole), as a CIDFontType2 or CIDFontType0 with Identity-H and a ToUnicode map. Glyphs
  sit where fontstash puts them (kerning, GPOS variation deltas, fallbacks); letter
  spacing is the text's character spacing, so words stay whole when copied. Fonts that
  cannot be embedded (collections, bitmap glyphs) draw their glyphs as outlines.
- Image fills are the image, placed as on the canvas. Gradients and shadows (which PDF
  has no operator for in NanoVG's terms) are images at 2 px per unit over the shape,
  sampled as the canvas's shader samples them. Layer and background blurs are drawn
  without the blur.
- Colours are in an ICC-based sRGB space (the system's sRGB profile), as the canvas draws
  them; DeviceRGB would be shown through a generic profile.
- `export_pages {path, ids? | page?}` writes one PDF, a page per top-level layer (all
  pages' layers in order by default, or a page by name or index, or ids in their order);
  `screenshot` with format pdf writes a layer (or the shown page) the same way.

**Consequences.** The seven-page diagram: 223 KB instead of 10.6 MB, its text extracts
(also Cyrillic), written in 0.05 s. A landing page drawn from the PDF by CoreGraphics
differs from the canvas by a mean of 1.5–2.2 per channel at 1× (glyph antialiasing and
baseline snapping). `tools/pdfexport.py` checks pages, sizes, text, subset fonts, sRGB,
`export_pages` by page and ids, and both pages against the canvas (17 checks). Canvas,
saved files and screenshots of files are unchanged.

## 72. Lint for diagrams

**Problem.** In a hand-built diagram an arrow that runs through a box, a label on another
label or an arrow whose end touches nothing was found by eye on every page (D60).

**Decision.** `lint` has diagram rules:

- `connector-crosses`: a connector's route runs through a box other than its ends (and
  the boxes around or inside them). A box is a shape, or a rectangle, ellipse or frame
  that draws something and holds nothing but its text; lanes and pages hold boxes and are
  crossed by design.
- `connectors-overlap`: two connectors run along the same line for more than 24 px
  (leaving the same side together, for up to three stubs, is not counted).
- `label-overlap`: a connector's label sits on another label or on a box.
- `connector-end-missing`: an end's layer is gone (the connector keeps its last route).
- `arrow-unattached` / `arrow-free`: a stroked path named like an arrow, with an end on
  no box or between two boxes: `connect` them instead.

The messages say what to change (sides, waypoints, the label's `at`). `fractional` no
longer reports connectors, labels and shape outlines, whose positions the app computes.

**Consequences.** On a product design without connectors lint answers exactly as before.
`tools/connectors.py` checks each rule and that rerouting clears them.

## 73. Text metrics at fractional sizes

**Problem.** Three step headings of the product design (Inter Variable 21.6 px, weight
500) sat a pixel above Chrome after #65 (D69). fontstash's `VerticalMetrics`, behind
`nvg.TextMetrics`, scaled the font's ascender by `f32(isize / 10)`, an integer division:
a 21.6 px font got the ascender of a 21 px one (20.34 instead of 20.93), which #65 rounded
down to 20 where Blink rounds to 21. The half leading used the same wrong value.

**Decision.** `f32(isize) / 10`. Text at whole-pixel sizes is unchanged.

**Consequences.** The headings match Chrome again. Landing sections against the live
captures (`secdiff`, share of pixels more than 16 off): desktop light 1.51 → 1.43 %,
desktop dark 1.56 → 1.49 %, mobile light and dark 2.82 → 2.80 %; desktop "how" 1.06 →
0.73 %; mobile "keywords" 3.94 → 4.01 %, the only section a little worse. Text with an
explicit line height at a fractional size moves by up to a third of a pixel, to where
pen.dev puts it.

## 74. Connectors go around boxes, spread along sides and sit under the boxes

**Problem.** The dogfooder rebuilt a page of the chat-bot diagram with connectors (D72–D84
of its log): routes ran straight through other boxes, two boxes closer than two stubs got
a loop with the arrowhead buried in it, connectors leaving one side shared a line (and
their colours merged), labels sat on crossing lines or, on curves, off the curve, a shape
held one plain text, and lint counted the swimlanes behind everything as obstacles (25
false crossings, 22 false label hits).

**Decision.**

- One set of obstacles for the router and lint, worked out once per document change: the
  drawn boxes of a page (filled or stroked frames and rectangles, ellipses, shapes,
  instances, filled paths) without backgrounds (a box with another box inside it that is
  not its own, such as a lane) and without boxes inside one that counts (a card stands
  for its button row). A connector's own ends and the boxes around or inside them are not
  its obstacles; `metadata.lintIgnore` also takes a layer out of lint's.
- An orthogonal route that would cross an obstacle is found again on the grid of lines 12
  px outside the obstacles' edges (and halfway between them): the shortest path, a bend
  costing 24 px. Only boxes near the two ends are considered.
- Facing sides closer than two stubs get a shorter stub, not a loop.
- Connectors that leave (or reach) one flat side of a box with an automatic side spread
  along it, in the order of their other ends.
- A new connector goes into its frame just under the first layer that holds one of its
  ends: above what is behind the boxes, under the boxes.
- Labels: a curve's route is sampled, so its label sits on it; a label at a spot on
  another connector's line or on a box moves along its own line to the nearest free spot.
  `connect` takes `labelFill` (default: the connector's colour) and `labelFontSize`; a
  label's id is the connector's with `-label`.
- Shapes: `caption` (with `captionFontSize`, `captionFontFamily`, `captionFill`) adds a
  smaller second line; any `children` go inside the shape too.
- Lint names obstacles with their ids and reports a label on another connector's line
  (`label-on-line`).
- PDF text on an unscaled, unrotated line has its baseline on a whole unit, as the canvas
  puts it on a whole pixel.

**Consequences.** On the rebuilt page lint went from 25 crossings, 7 overlaps and 23
label hits to 0, 2 and 1 (the two overlaps and the label are real). Layout with routing
takes 2.8 ms on it. `tools/connectors.py` checks routing around a box, the z-order, the
label id and colour, the close boxes, spread ports, captions and the lint rules (47
checks). Files without connectors are unchanged.

## 75. Agents' edits name their document; the window refuses them for another one

**Problem.** After a window restart the window reopens `untitled.pen` (or the last file),
and an agent's next edit through the MCP server landed there: in the user's scratch file,
silently (D52). The same happened when the user switched tabs while an agent worked.

**Decision.**

- The MCP server keeps the document of its session: the path `open` answered with, or the
  `document` argument of a call (which also binds the session). Every request then names it
  (`"file"` next to `"method"`), and the window refuses any request about the document
  (reads too) when it shows another one, with both paths and "Call open with … to work on
  it again". Nothing is changed.
- An edit (`batch`, `create_nodes`, `update_nodes`, `delete_nodes`, `reorder`, `connect`,
  `set_variables`, `set_pages`, `set_libraries`, `rename_references`, `scale_nodes`,
  `outline_text`, `add_fonts`, `undo`, `redo`, `save`) in a session without a document is
  refused by the MCP server itself, naming the document the window shows (new method
  `window`), so the agent opens it on purpose. Reads without a document still work.
- Every successful answer carries `"file"`, the document it read or changed (written after
  the method ran, so `open` and `save` under another name report the new one); the MCP
  server adds it to the result it returns.
- Socket clients that send no `"file"` (tests, the interface driver) work as before.

**Consequences.** An agent's first edit costs one `open` more. A test through the MCP
server: an edit before `open` is refused and names `a.pen`; after `open` it lands in `a.pen`
and says so; with the window restarted on `untitled.pen` the next edit and `save` are
refused and `untitled.pen` is byte-identical afterwards; `open` again and the edit lands in
`a.pen`; a fresh session can pass `document`, and a `document` the window does not show is
refused.

## 76. The window's PDF export is vector too

**Problem.** #71 made PDF vector for agents (`screenshot` with format pdf, `export_pages`),
but the Export panel's PDF (inspector, and a `.pdf` name typed in the save panel, #64)
still wrapped a picture of the layer: large, and no text to select or search.

**Decision.** The window's export writes PDF with the same writer as #71: one layer as one
PDF page, the page with nothing selected as one PDF page per top-level frame (as
`export_pages` writes a page), several selected layers as one PDF file each. The scale
does not apply, so a PDF's name has no `@2x`.

**Consequences.** The sample's Hero frame from the inspector (PDF, "Export layer"): one
1440 × 1164 page, 93 KB, whose text PDFKit reads back. As in #71, blurs are drawn without
the blur, and gradients and shadows are images; the raster PDF had them as pixels.

## 77. Documents opened from Finder go to the app's delegate; .pen is a declared type

**Problem.** Double-clicking a `.pen` file, Open With, a file dropped on the Dock icon and
`open file.pen` showed the system alert "Agentic Design cannot open files in the 'Pen
document' format". macOS hands such documents to the application delegate's
`application:openURLs:`; GLFW's delegate does not implement it, so AppKit fell back to
`NSDocumentController`, which has no document class for the type. The bundle declared the
type by extension only.

**Decision.**

- `application:openURLs:` is added to GLFW's delegate class (`GLFWApplicationDelegate`, by
  the Objective-C runtime) before `glfwInit`, so the files a launch was asked to open,
  which arrive while GLFW finishes launching, are caught as well. Each `.pen` opens in a
  tab, or activates the tab that has it; its libraries resolve next to it as for any open.
  A launch for documents opens those instead of the scratch `untitled.pen`.
- The bundle exports the type `dev.kcrz.agentic-design.pen` (extension `pen`, conforming to
  `public.json`, so Quick Look and Spotlight treat it as JSON text). pen.dev declares
  `.pen` only by extension and exports no type, so nothing conflicts; it keeps opening
  `.pen` files. The document type is that content type, role Editor, rank Default, and has
  no `NSDocumentClass`.
- The socket's `window` method lists the open tabs.

**Consequences.** Checked with a copy of the release bundle under another bundle id (the
user's own copy was running): `open -n -a … reaktor-search.pen` launched it on that file
alone, with its library `reaktor.lib.pen` imported; `open -a` with a second file opened a
second tab in the running app, the first file again activated its tab, the library file
opened in a third. `mdls` reports `.pen` files as `dev.kcrz.agentic-design.pen` under
`public.json`. A double-click in Finder and a drop on the Dock icon send the same event.

## 78. The website is a Workerstack app on Cloudflare Workers (supersedes the hosting of #68)

**Problem.** #68 served the site as static files from a Caddy container on a Bunderhost
server, with stub Bunderstack files to satisfy the deploy contract. The site will not stay
static: sharing, accounts and an API for the web editor are coming.

**Decision.**

- `site/` is a Workerstack 0.2.4 app (`render: spa`) on Bunderhost's Cloudflare target. The
  pages and the viewer are the Worker's static assets, `site/dist/client`, written by
  `site/build.mjs` as plain files after the Worker's Vite build; the Worker answers `/api/*`,
  empty except `GET /api/version`. The pages moved from `site/src` to `site/pages`; `src/` is
  the Worker's. The schema has only Workerstack's own tables; the database Bunderhost
  provisions is unused for now.
- Bunderhost installs dependencies from the repository root, so the root has a
  `package.json` naming `site` as its only workspace, and the `bun.lock`.
- The build runs in Bunderhost's Bun image, which has no Odin or `wasm-ld`:
  `site/scripts/viewer.sh` fetches the pinned Odin release (checked by SHA-256, as the
  release workflow pins it) and installs `lld`, then runs `tools/build_web.sh`.
- Cloudflare compresses at its edge and serves `.wasm` as `application/wasm`; the build
  writes no `.br` or `.gz` copies (`COMPRESS=1` still does, for other hosts). `_headers` marks
  names with a content hash immutable. The domain is a Workers custom domain that Bunderhost
  manages; the CNAME of #68 is gone.

**Consequences.**

- Lighthouse on the live site: 99–100 for performance, 100 for the rest, mobile and
  desktop. The viewer runs from the Worker in Chrome 156 and Safari 27.
- Cloudflare's edge brotli sends the viewer's wasm as 2.76 MB, against 2.08 MB at brotli 11.
  Serving the precompressed file would need the Worker in front of `/view`.
- In `spa` mode an unknown path answers with the landing page and status 200, not the 404 page.
- `Dockerfile.bunderhost`, the Caddyfile and the Bunderstack blueprint are gone. The build
  output stays a plain folder, so moving to another static host is a copy.

## 79. The website answers unknown paths with a 404 (updates #78)

**Problem.** In Workerstack's `spa` mode every path without a file got the landing page
with status 200. Search engines treat that as a soft 404, and the site's search ranking
matters.

**Decision.** The blueprint says `render: ssr`, whose asset handling is `none`: Cloudflare
serves every file of `site/dist/client` itself, and a path no file matches reaches the
Worker. `site/src/server.ts` is the Worker's entry: `/api/*` goes to the Workerstack
backend (created with `createWorker`, whose Durable Object classes it re-exports), and
anything else is answered with `404.html` and status 404. `site/vite.config.ts` builds it
with the Cloudflare Vite plugin directly, because `workerstack()`'s plugin expects TanStack
Start in `ssr` mode. `/view` and, later, `/edit` are folders of their own with an
`index.html`, so they stay entry points.

**Consequences.** `/nope` answers 404 with the site's 404 page; `/`, `/view/`, its
files and `/api/version` are unchanged. A future TanStack Start or Workerstack upgrade has
to keep this entry (or a 404-page mode, if Workerstack gains one).

## 80. "What's new" after an update, from the release notes compiled into the app

**Problem.** Updates install silently on the user's consent and relaunch the app; nothing
told the user what changed, and the release notes lived only on GitHub.

**Decision.** `docs/releases/v<version>.md` has a fixed shape (a `released` date comment,
then `## New`, `## Improved`, `## Fixed` with a headline per entry and an optional detail
line) and is compiled into the binary with `#load_directory`; `src/whats_new.odin` parses
it once. On launch the app compares `VERSION` with `lastSeenVersion` in `settings.json`: if
newer, a sheet lists the entries of every version after the last one seen, merged per
section, newest first, and the version is recorded at once (so it shows once, also after the
updater's relaunch). A fresh install (no `settings.json` and no `app.log`) records the
version without showing anything. Versions before 0.1.4 did not write the key: the last
`update: A -> B` line of `app.log` gives the previous version, else the release before this
one. Test windows (`AGENTIC_QUIET`) and windows an agent opened (`AGENTIC_NO_FOCUS`)
neither show nor record it, so the user still gets it next time; the MCP server never sees
it. The app menu (an item GLFW's menu did not have, added to its application delegate) and
Settings → Updates open the current version's notes.

**Consequences.** Release notes are now user interface: one sentence per headline, written
for users, no internal names. A tester can run the launch decision in a quiet window with
`AGENTIC_WHATS_NEW_TEST=1` and `HOME` set to a sandbox (refused with the real home, so the
user's settings stay untouched); the socket's `whats_new` method reports the sheet, opens
it, presses the menu item or closes it. The app has one, dark, theme; the sheet follows it.

## 81. The Mac app shares through the cloud with a browser sign-in and a device token

**Problem.** Cloud M1 shares files by link (docs/cloud-design.md). The Mac app needs the
same, without its own password form and without keeping the user's password.

**Decision.** Sign-in is PKCE (S256) through the system browser and a loopback port
(RFC 8252): the app listens on 127.0.0.1, opens `/auth/app` with the challenge, the
signed-in user approves this Mac, the browser returns to `/callback` with a one-time code,
and the app trades it with its verifier for a device session (30 days, renewed while used),
kept in the login Keychain per site and sent as `Authorization: Bearer`. HTTP goes through
`/usr/bin/curl` with its options on stdin, so the token never appears in a command line.
Sharing uploads the saved `.pen` and the files it refers to: every relative `url` (image
fills, fonts) and every `imports` library, recursively, as paths from the document's
folder, each by SHA-256; the server asks only for the blobs it lacks, which are PUT to
presigned URLs before the version is committed. Each file's share (file id, link) is kept in
`shared.json` next to the settings, so sharing again uploads a new version behind the same
link. Previews are not rendered by the app yet (the site falls back to the viewer).

**Consequences.** Test windows keep the token and shares in memory and never open a
browser; the socket's `cloud` method reports the sign-in URL, so a test plays the browser
(tests/cloud/share.py in the tests repository, against the local dev server). A file deleted
on the site is shared as a new file the next time. `AGENTIC_CLOUD_URL` points a window at
another site (local development).

## 82. The dashboard lists every .pen file on the Mac

**Problem.** The dashboard showed only files opened in the app (Recents, at most 40) and the
files of one folder, most without a preview. Agents create and edit files the app never
opened.

**Decision.** All files (the default view) is every `.pen` under the home folder, from two
sources merged with the recents: Spotlight (`mdfind -onlyin ~`, 0.14 s), and a background
walk of the home folder, because Spotlight skips folders the user excluded (here `~/Temp`).
The walk skips `~/Library`, hidden folders, `node_modules`, `build`, `dist`, `target`,
`vendor`, `Pods`, `DerivedData`, `tmp`, `Caches` and bundles, follows no symlinks and sleeps
2 ms every 48 folders: on this Mac 15 600 folders and 53 files in 1.9 s, 1.0 s of CPU, once
per 10 minutes at most while the dashboard is shown. Sort (Last modified by default, Last
opened, Name, Created) is kept in `settings.json`. Recents stays as the second view, the
files opened in the app by last opened: one list with two orders would bury what the user
just had open under files agents touched. Previews are drawn for the cards in view only,
one every 250 ms, and again when a file changed after its preview (by modification time).
Remove from list and Hide this folder keep files and folders off the list
(`dashboardHidden`); Move to Trash uses NSFileManager `trashItemAtURL`, after a
confirmation, never deletes, and refuses a file open in a tab.

**Consequences.** Copies of designs in other tools' working folders (repository clones,
agents' workspaces) show up too, until hidden with one click. Test windows index nothing
unless `AGENTIC_FILES_ROOT` names a folder (the socket's `dashboard` method drives the
view); a test that moves a file to the Trash keeps it on a disk image so the user's Trash
is not touched.


## 83. A property added by an edit goes to its canonical place

**Problem.** Loading a `.pen` puts each node's properties in a fixed order (`type`, `id`, `name`, then alphabetical) and
the header's keys too (`version`, `themes`, `variables`, then alphabetical), but a property added by an edit was
appended at the end. A file edited and saved changed its bytes the next time it was opened and saved, and cloud
documents (cloud-ops.md §1) need every client and the server to write the same bytes for the same state.

**Decision.** `node_set_raw` inserts a new key where the loader would put it, and new header entries go through
`header_insert` (`canonical_index` in `src/engine/pen.odin`).

**Consequences.** What the app writes after an edit is what it writes after reopening the file. A file saved by an
older version after edits is put in order once, on its next save (same JSON, keys moved).

## 84. The editor's panels float and hide; the interface has a size

**Problem.** The docked sidebar, tool strip and inspector took 604 of 1440 points from the
canvas whether or not they were in use, and on a large screen or with weaker eyes the 12-13 pt
interface could not be made larger.

**Decision.**

- The layers panel and the inspector float over a canvas that fills the window
  (`src/panels.odin`). Each hides with the button in its header, ⌘\ hides or shows both, and a
  hidden panel leaves a button in its corner that outlines where the panel opens. The tools
  are a bar at the bottom centre; zoom, Export and Share moved to the tab bar. A panel's
  height follows its content. Double click a tab to rename its file.
- The panels' contents are drawn where they were when docked: `panel_begin` moves the drawing
  and the pointer by the panel's offset (`ui.origin`), and the widgets that keep a rect for
  later (menus, the colour picker, tooltips, the focused field) add it back. Canvas input goes
  through `canvas_hit`, which leaves out the floating chrome; zoom to fit and the view's
  centre use the part of the canvas the panels leave open.
- The dashboard has one header (All files | Recents, search, sort; Connect agents, New file,
  Settings, the account) and cards that fill the width. A preview of a page much taller or
  wider than the card shows its top left at least half the size that fills the card.
- Settings has sections (Account, General, Canvas, Agents, Updates). The interface size
  (90, 100, 115, 130%; ⌘⌥+ ⌘⌥- ⌘⌥0) divides the window into larger units, so panels and text
  grow; the canvas keeps its zoom in real pixels (`view_zoom`), and changing the size keeps the
  view's centre and zoom.

**Consequences.** Coordinates in tests that click the interface changed (tools/uidrive.py maps
them). The designs are in app-ui.pen; the agent input at the bottom is not built yet.

## 85. Agents work on documents the window does not show

**Problem.** Decision 75 refused every request for a document the window did not show, so an
agent could not look at or change another file while the user kept theirs open, and its
first edit always cost an `open` that took over the user's view.

**Decision.**

- A request that names another document (`"file"`) runs on it in place
  (`src/background_docs.odin`): the document of another tab, or one read from disk and kept
  for three minutes, is swapped into `app` for that request alone, saved if it changed, and
  swapped back. Requests run between frames, so nothing of it is drawn; the user's view,
  selection and undo stay as they were. A screenshot of it is drawn at once; a `view`
  screenshot (the window) is refused. Opening that file later keeps its undo history.
- An MCP session without a document takes the one the window shows at its first edit; with
  only the dashboard shown, the edit is refused. `open` still shows a document.
- After a restart onto another file, a session's edits keep going to its own document,
  in the background, instead of being refused.

**Consequences.** tests/mcp/document_binding.py checks the new rules; the edits it once
expected to be refused now land in their own file while the window shows another.

## 86. Ask an agent from the window

**Problem.** Agents could change a design only from outside the app: a terminal or another
editor with our MCP server. The user had to switch windows to ask for a change, and an
agent's work came back as many undo steps.

**Decision.**

- A rounded input at the bottom centre of the canvas and of the dashboard (app-ui.pen,
  "Agent input"; `src/agent_input.odin`) runs the user's own Claude Code or Codex headless,
  signed in as the user already is (`src/agent_run.odin`): `claude -p --output-format
  stream-json` or `codex exec --json`, with only our MCP server (`--strict-mcp-config`,
  built-in tools off; Codex read-only with only our server, its tools approved). Nothing is
  bundled and no key is stored. The guide sent with the prompt names the document shown and
  the selection; on the dashboard it says no file is open and where to create a new design
  (~/Documents/Agentic Design unless the user names another folder); a run that opens a file
  goes on in that file's thread.
- Each run has a token the MCP server passes with every request (`AGENTIC_RUN` → `"run"`).
  The window refuses requests of a stopped run. A run's changes to a document are one undo
  step until the user edits it by hand; the thread's Undo takes back the last run, and the
  next request tells the agent it was undone.
- The thread panel above the input shows the requests, what the agent says, its tool calls
  folded by tool, and how the run ended (time, tool calls, cost). Send becomes Stop (⌘.):
  SIGINT, then SIGKILL after 3 s. ⌘L focuses the input. Follow-ups resume the CLI's session.
  Threads are kept per file in Application Support (never in the .pen); Settings → Agents
  clears them. Quitting stops running agents.

**Consequences.** tests/agent/input.py drives it with a stand-in CLI (fake_claude.py) that
starts our MCP server from the config, as Claude Code does. Test windows show the input only
with AGENTIC_AGENT_INPUT=1. The web editor has no input yet (it cannot start processes).

## 87. Agents put files in the cloud, private unless the user allows a link

**Problem.** An agent could design a file but not share it: only the Share button in the
inspector could upload, and it always made a link.

**Decision.**

- MCP tools `share` and `unshare` (`src/agent_share.odin`) upload the session's document
  (or `document`) to the account signed in on this Mac, as the Share button does (a new
  version behind the same file when it was shared before).
- `access`: `private` by default (only the owner, in their cloud files; any link of the file
  is turned off), `link` (anyone with the link) or `public`. A link needs the user's yes in
  the window ("Share" / "Don't allow"), because a document's text could ask an agent to
  publish it; private uploads to the user's own account do not ask. `allow_download` and
  `allow_embed` set what the link allows. `unshare` turns the link off; the file stays,
  private.
- With nobody signed in the call is refused and says where to sign in; the agent never
  signs in for the user.
- People (contract §10): `invite` (email, role `viewer` or `editor`) asks the user in the window,
  puts the file in the cloud privately if it is not there, and returns the invitation link
  for the agent to give the user (no mail is sent; the person opens it signed in with that
  email). Inviting a member again changes their role. `people` lists the owner, members and
  open invitations; `remove_access` takes a member out or cancels an invitation. Teams are
  not part of it.

**Consequences.** tests/cloud/agent_share.py runs the tools through `agentic-design mcp`
against a backend with a throwaway account.

## 88. Context, sessions and marks for the agent

**Problem.** The agent in the window saw only the design: not the code or notes it is
for, not what the user meant by "this" beyond the selection. Each file had one thread, so
an earlier conversation could not be picked up again.

**Decision** (agent-context.pen, drawn by the Dogfooder; Kirill chose: marks clear on send,
titles by the agent).

- Context: a paperclip in the input attaches folders and files to the document (kept per
  document in Application Support, never in the .pen). Claude Code gets them as `--add-dir`
  and may read only them (`Read(//path/**)`, Read, Grep and Glob; nothing else of the
  Mac); Codex reads them in its read-only sandbox; Gemini CLI gets `--include-directories`.
  The guide sent with the prompt lists them.
- Sessions: each document keeps every conversation (threads/<hash>/index.json and one file
  per session); the thread panel's header lists them, resumes one (the CLI's session id) or
  starts a new one. After a session's first answer its agent names it in a few words (a
  short run with no tools, in the background). 0.3 thread files become the first session.
- Marks (`src/annotations.odin`): comment, pen, arrow, area and numbered tag, drawn over
  the canvas in page coordinates. The next request takes them: a list naming the layers each
  mark is on, and a picture of the view with the marks (`render_overlay` in render_region),
  readable by the agent (Claude: a read rule for it; Codex: `-i`; Gemini: `@path`). Then they
  leave the canvas.
- Gemini CLI joins Claude Code and Codex: `--output-format stream-json`, our server from
  settings for this run (GEMINI_CLI_SYSTEM_SETTINGS_PATH, trusted), only it allowed.
- A request is started at the next frame's start: the picture is drawn offscreen, which
  cannot happen inside the window's frame. The CLIs' options that take several values come
  before the others, so none of them takes the prompt.

**Consequences.** tests/agent/input.py covers context, sessions, titles, marks, Gemini's
stream and the 0.3 migration with stand-in CLIs. Gemini CLI itself has not been run here.

## 89. Rich text and one responsive page

**Problem.** A text node had one style, so a sentence with a bold word, a coloured word or
a link took several layers placed by hand (Dogfooder D39, D98). `export_code` of a desktop
and a mobile frame wrote two pages one under the other (D103): 10,838 px tall at 1440 px
for a 4,829 px page.

**Decision.**

- Text nodes take `spans`: runs `{"text", …style}` whose texts join up to `content`, each
  overriding the node's fontFamily, fontWeight, fontStyle, fontSize, fill, underline,
  strikethrough, letterSpacing, or adding href. `content` stays the whole plain text, so
  pen.dev (which has no runs) and older versions show the words in the node's style.
  Lines wrap at spaces across runs (a word wider than the box between characters); a row
  is as tall as its biggest run and the runs share a baseline. Setting `spans` alone sets
  `content`. A content change (update_nodes, the inspector, typing) keeps the runs: the
  changed part goes into the run where the change starts. Runs that no longer join up to
  the content (changed in another editor) are ignored and lint reports `spans-mismatch`.
  `export_code` writes `<span style>` and `<a href>`; PDF and outline text draw the runs.
- `export_code` of frames pinned to two or more `viewport` values makes one page: each
  version sits in a `vp-<value>` wrapper shown only in its own width range, split at the
  breakpoints the variables use (the middle between the widths). A value's width comes from
  the frames pinned to it; an unpinned frame counts only for a value no frame is pinned to
  (0.5.1: a wide components board had moved the breakpoint to 2376 px, D108).

**Consequences.** tests/render/rich_text.py and tests/render/responsive_export.py. Justify
is not applied to rich text. A responsive page carries each version's markup once per
version; merging matching layers into one tree is left for later.

## 90. The canvas is cached

**Problem.** Every frame drew the whole document, about 8 ms for a 5,800-layer file. A frame
is drawn for anything that moves on screen: the pointer over a panel, a list scrolled,
hover, an agent's cursor, a caret. On a 120 Hz display that was most of the frame's time:
lists stuttered and an agent's run kept a core busy. The layers list was also clamped only
after it was drawn, so a fling past its end drew it beyond its last row for a frame,
which looked like a spring over the list.

**Decision.** The document (grid included) is drawn into a texture of the window's size
before the frame and the frame shows that texture. It is drawn again only when its key
changes: the document and its version, the layout epoch, zoom, camera, canvas rect,
framebuffer size, scale, background, grid, the pages hidden, and every 2 s while an image
failed to load (D106). Everything over the document (frame titles, hover, selection,
agents' cursors and flashes, marks, guides) is drawn on top every frame, as before.
Blurs are prepared only when the document is drawn. `AGENTIC_NO_CANVAS_CACHE=1` turns the
cache off; `perf` reports `canvas_renders`. The layers list is clamped before it is drawn,
by the last frame's height, and draws only the rows in view; children come from the
document's index.

**Consequences.** tests/ui/canvas_cache.py runs the same steps with and without the cache
and compares the window pictures byte for byte. A change that alters drawing without
bumping the document version or the layout epoch would leave a stale canvas until the next
change: such state must join the key.
