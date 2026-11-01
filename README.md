# Agentic Design

**agentic-design.kcrz.dev**

A free, open, native macOS design canvas built for agents that work on your computer.
The agent is a first-class user: it reads the document, draws into it and screenshots the
result through a built-in MCP server, while you watch and edit the same canvas live.

Documents are [pencil.design](https://pencil.design) `.pen` files. The app reads and writes
the format directly, keeps every property it does not understand, and the MCP tools speak
`.pen` too: an agent creates nodes with the same JSON it would write into the file.

Written in [Odin](https://odin-lang.org). GLFW opens the window; NanoVG (a patched copy
lives in the repository) draws everything: antialiased vectors, Bézier paths, text that keeps
its exact width at any zoom. No other dependencies.

The agent talks to the app directly: `agentic-design mcp` is a stdio MCP server that forwards
tool calls to the running window over `127.0.0.1:4410` and starts the window itself
if it is not open. No browser, plugin or extra server to keep alive.

## Status

Prototype. What works in `.pen` files today:

- `frame`, `group`, `rectangle`, `ellipse`, `path`, `text`, `ref`, and `icon` /
  `icon_font` from Lucide (the icon set is built in); other node types (scripts,
  browsers, ...) are kept and shown as placeholders
- flex layout: `layout`, `gap`, `padding`, `justifyContent`, `alignItems`,
  `fit_content` / `fill_container`, `layoutPosition: absolute`
- variables (`$name`), theme axes, themed values and per-subtree `theme`; components and
  instances (`reusable`, `ref`), with any property overridden on the instance itself (the
  component root) or through `descendants`, and slot content
- solid, gradient and image fills, strokes with per-side widths, caps and joins, corner
  radii, opacity; text font family, size, weight, style, letter spacing, underline,
  alignment, vertical alignment and growth, with GPOS kerning

- linear, radial and angular gradients with any number of stops, several fills and
  shadows per layer (inner and drop), rotation and flips

Not yet: rich text runs, blur effects, mesh and shader fills, icon libraries other than
Lucide. [docs/pen-dev-comparison.md](docs/pen-dev-comparison.md) lists what pen.dev has and
this app does not.

Design notes, decisions and the test recipe are in [`docs/`](docs/README.md); what broke
while using the app for real work is logged in [`docs/dogfooding.md`](docs/dogfooding.md).
`designs/sample.lib.pen` is a full design system built that way (tokens, foundations,
28 components), and `designs/sample-screens.pen` holds the product's screens, importing it
as a library.

## Build and run

```sh
brew install odin
./build.sh                      # debug build -> build/agentic-design
./build/agentic-design          # opens designs/untitled.pen
./build/agentic-design file.pen
```

Connect it to Claude Code for every project:

```sh
claude mcp add --scope user agentic-design -- /path/to/agentic-design/build/agentic-design mcp
```

## Editor

Tabs hold open files; the Dashboard tab lists recent files with previews. The sidebar shows
the document's pages (stored in the file header as `pages`; `+` adds one, double-click
renames, right-click duplicates or deletes), the layer tree (double-click renames, the eye
hides) and, on the Theme tab, the document's variables, which can be added, renamed and
edited there. Double-click the file name to rename the file. Drop images onto the canvas or
use the image tool to place them; they are copied into `images/` next to the document.

| Key | Action |
| --- | --- |
| V H F R E T | move, hand, frame, rectangle, ellipse, text |
| Two-finger scroll, Space + drag, middle drag | pan |
| Pinch, Cmd + scroll, Cmd = / Cmd − | zoom |
| Two-finger double tap | zoom to what is under the pointer / fit all |
| Shift 1 / Cmd 0 | fit all / 100% |
| Hold Z / hold Option | zoom tool (click, Option-click, drag) / measure distances |
| P | pen tool (double click or Enter on a path edits its points) |
| Shift Cmd C / Option Cmd C | copy as PNG / copy as HTML |
| Cmd F, ?, Cmd , | find layers, shortcut sheet, settings |
| Cmd ' | pixel grid |
| Shift + drag | keep proportions |
| Double click text, Enter | edit text (Esc to finish) |
| Cmd D, Backspace, arrows | duplicate, delete, nudge |
| Cmd C / Cmd X / Cmd V | copy / cut / paste (also as `.pen` JSON on the clipboard) |
| Option A D W S H V | align left, right, top, bottom, centre, middle |
| Shift H / Shift V, Shift 1 / Shift 2 | flip; zoom to fit / to selection |
| Enter / Shift Enter | select children / parent (Enter on text edits it) |
| Click / double click / Cmd click | layer at the working level / one level in / deepest layer |
| Cmd Option K / Cmd Option X | create component / detach instance |
| Cmd G / Shift Cmd G / Option Cmd G / Shift A | group / ungroup / frame selection / auto layout |
| Cmd R | rename |
| Cmd ] / Cmd [, ] / [ | one step forward / back, to the front / back (arrows reorder inside flex) |
| Cmd Z / Shift Cmd Z | undo / redo |
| Cmd N, Cmd W, Shift Cmd E | new file, close tab, export PNG |
| Right click | context menu |

Dragging snaps to the edges and centres of neighbours (hold Ctrl to disable).
Set `AGENTIC_QUIET=1` to open a window behind the others without taking focus (tests);
`AGENTIC_NO_FOCUS=1` opens it in front but leaves the keyboard focus alone (the MCP server
uses this).

Shapes dropped onto a frame become its children. Children of a frame with a flex layout
are positioned by the frame. Documents autosave a second after each change.

The window follows the layout of [Paper](https://paper.design): a tab bar, a sidebar with
pages and layers, a tool strip, the canvas and an inspector. The inspector edits position and
size, flex layout (alignment grid, direction, gap, padding, absolute position, clip), corner
radius, visibility and opacity, fill, stroke, shadow and text, and lists the colors used by
the selection; variables show as chips. The inspector's "Connect more agents" button copies
the `claude mcp add` command.

## Components, themes and code

An instance (`ref`) shows which component it uses, with Go to component, Detach and a
Parameters section: every text and part of the component can be overridden per instance
(written as `descendants` in the file). Double-click an instance to jump to its component.
Slot content inside an instance stays selectable and editable.

The Theme tab lists the document's theme axes (`themes` in the header), lets you switch the
shown value, add values and rename them; variable edits apply to the shown theme. Frames
can pin a theme for their subtree (the Theme row in the inspector), and instances rendered
under another theme re-resolve their variables.

Export (inspector, top right, or the `export_code` tool): PNG, HTML + CSS (one element per
node, variables as custom properties, `[data-theme-mode="dark"]` blocks; every fill and
gradient, shadow, blur, rotation and flip, written as pen.dev writes them) or React +
Tailwind (a function per component with props from the overrides, shadcn/ui primitives for
components named Button, Card, Input, …, `Page.tsx` for the current page).

## MCP tools

`get_guide` (what the document holds and how its parts are named; the place to start),
`batch` (several edits as one undo step, all or nothing), `find_nodes`, `rename_references`
(repoint variables and refs; with `library`, move a file onto an imported library), `lint` (`metadata.lintIgnore` on a layer or `ignore` per call skips rules; hard-coded
colours, missing fonts, text that does not fit, layers cut off, broken refs, off-pixel values),
`get_document` (with `ids` for subtrees and `depth` for big files), `get_selection`,
`get_variables`, `get_styles` (the CSS code export writes for given nodes), `create_nodes`
(`.pen` nodes, nested `children`; an instance as `parent_id` takes slot content; an image paint's `url` may be any local file, copied into `images/`), `update_nodes`, `delete_nodes`, `reorder`, `select`,
`zoom_to_fit`, `screenshot` (a node, the canvas, or the whole window with `view: true`),
`undo`, `redo`, `save`, `open` (`create: true` starts a new file), `add_fonts` (font files or installed families into the document), `set_variables` (variables, theme axes and the shown theme),
`set_pages`, `set_libraries` (import other .pen files as libraries; they are re-read when their files
change), `export_code` (`html` or `react`; `ids` for one frame; a `viewport` theme axis
becomes media queries). `screenshot` also writes JPEG, WEBP or PDF files (`format`, `path`) and renders
in a given theme (`theme`) whatever the window shows.

The first time the app opens, an onboarding walks through the app and connects agents.
It detects Claude Code, Codex, Claude Desktop, Cursor, Gemini CLI, OpenCode, Windsurf,
VS Code and Kiro, and registers the MCP server with each one in a click. It is also behind
**Connect agents** on the dashboard and in the inspector.

`get_document` returns the tree as stored in the file plus `bounds` — the absolute box of
every node after layout — so the agent can see where things ended up.

## Agents on the canvas

Each agent working through MCP has a cursor with its name on the canvas, as in pen.dev
(Claude in clay, Codex in green, and so on; the proxy names it from the client's
`clientInfo`). The cursor glides to each layer a request creates, changes or deletes, in
turn, and the layer flashes in the agent's colour as it gets there. New layers get a sweep
of colour, and deleted ones fold away where they were. A capture flashes too. Frames marked
`placeholder` glow while an agent works on them. A cursor outside the view waits at the
edge, pointing the way, and fades 15 s after the agent's last call. Settings → Agent cursors
turns all of it off.

The control socket's `presence` request sets a cursor for anyone else, for a future
multiplayer link: `{"id", "name", "color", "x", "y", "kind": "person"}`, or `"leave": true`.
A socket request with an `"agent": {"id", "client"}` field next to `method` acts as that
agent. Tests use it to drive the cursors.

## Testing without a mouse

The control socket (`127.0.0.1:4410`, newline-delimited JSON) has an `input` method that
injects synthetic pointer and keyboard events, so the interface itself can be driven from a
script. `tools/uidrive.py script` walks through every panel; `tools/uidrive.py fuzz <seed> <n>`
sends random clicks, drags and keys. Run the app under `lldb --batch -o run -k bt` to get a
backtrace if it crashes. The full recipe is in [docs/testing.md](docs/testing.md).

## Layout

| File | |
| --- | --- |
| `src/main.odin` | entry: editor or `mcp` mode |
| `src/platform.odin` | GLFW window and per-frame input state |
| `src/doc.odin` | node model: raw `.pen` properties plus parsed fields, colors |
| `src/pen.odin` | `.pen` reading and writing, variables |
| `src/layout.odin` | flex layout, text measurement, instances |
| `src/svgpath.odin` | SVG path parser |
| `src/app.odin` | main loop, rendering, undo |
| `src/input.odin` | tools, selection, drag, shortcuts, text editing |
| `src/widgets.odin` | the widget library: buttons, fields, menus, color picker, dialogs, tooltips |
| `src/ui.odin` | tab bar, sidebar, tool strip and inspector built from the widgets |
| `src/server.odin` | local control socket (requests run on the main thread) |
| `src/presence.odin` | agents' and other people's cursors, flashes on what agents touch, placeholder glow |
| `src/api.odin` | control API and screenshots |
| `src/mcp.odin` | stdio MCP server |
| `src/tabs.odin` | tabs, recent files, thumbnails |
| `src/dashboard.odin` | the dashboard view |
| `src/edit.odin` | grouping, alignment, clipboard, context menu |
| `src/fonts.odin`, `assets/fonts` | fonts by family and weight: the document's `fonts` list, installed fonts, built-in Noto Sans for missing families (OFL) |
| `src/inspector.odin`, `src/paint.odin` | inspector sections modelled on pen.dev; fills, gradients and effects drawing |
| `src/components_panel.odin`, `src/variables_table.odin` | the Components tab; the variables table |
| `src/onboarding.odin`, `src/agents.odin` | the onboarding sheet; agent client detection and MCP registration |
| `src/icons.odin`, `assets/lucide.txt` | the built-in Lucide icon set (generated by `tools/lucide_assets.py`) |
| `src/images.odin` | image fills, drag-and-drop and the place-image dialog |
| `src/pages.odin`, `src/themes.odin` | pages inside a file; theme axes and themed variables |
| `src/codegen.odin` | HTML/CSS and React export |
| `src/gestures_darwin.odin` | trackpad gestures via Cocoa |
| `src/nanovg`, `src/fontstash` | vendored NanoVG/fontstash ports with text rendering fixes (see `src/nanovg/README.md`) |
| `tools/uidrive.py` | drives the interface through the socket for tests |
| `tools/font_instances.py` | static instances of variable fonts for the app's font folder |
| `tools/dogfood/` | a Chrome DevTools client for reading live pages, and the generator of the Sample Search design system |
