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

