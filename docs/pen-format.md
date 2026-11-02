# The `.pen` format in Agentic Design

[pencil.design](https://pencil.design) defines the format; this app does not change it. This
page covers what the app reads, what it adds and where versions differ.

The reference is the TypeScript schema at the end of
[the-pen-format](https://docs.pencil.dev/for-developers/the-pen-format) (document version
`2.21` as of October 2026). Sample files and a community schema for version 2.8 are at
[de-novo/pencil-skill](https://github.com/de-novo/pencil-skill) (`assets/*.pen`). They are
the round-trip test fixtures.

## Shape of a file

```json
{
  "version": "2.21",
  "themes": { "mode": ["light", "dark"] },
  "variables": { "color-surface": { "type": "color", "value": [
    { "value": "#FFFFFF" },
    { "value": "#1A1A1B", "theme": { "mode": "dark" } }
  ] } },
  "pages": [ { "name": "Page 1", "nodes": ["home", "settings"] } ],
  "children": [ { "type": "frame", "id": "home", "x": 0, "y": 0, "children": [] } ]
}
```

- **Header.** Every key except `children` is kept as raw JSON and written back in this
  order: `version`, `themes`, `variables`, then the other keys alphabetically. A file with
  no `version` gets `2.21`.
- **Nodes.** Each node's properties are written back in the order they were read. Positions
  are relative to the parent.

## What is understood

| Area | Properties |
| --- | --- |
| Node types | `frame`, `group`, `rectangle`, `ellipse`, `path`, `text`, `ref`, `icon` (`library: "lucide"`, `icon`), and 2.8's `icon_font` (`iconFontFamily`, `iconFontName`). Other types are kept and drawn as placeholders. |
| Size | `width` / `height`: number, `fit_content`, `fill_container`, also with a fallback as in `fit_content(120)` |
| Flex | `layout` (`none`, `horizontal`, `vertical`), `gap`, `padding` (n, [v,h], [t,r,b,l]), `justifyContent`, `alignItems`, `layoutPosition: absolute`, `clip` |
| Paint | `fill` (color, `$variable`, image fill, linear / radial / angular gradients, or a list of them), `stroke`, `strokeWidth` (one number or `{top, right, bottom, left}`), `strokeAlignment`, `strokeLinecap`, `strokeLinejoin`, `cornerRadius` (n or 4 corners), `opacity` (number or `%`), `enabled` |
| Effects | `effect`: one or a list of outer and inner shadows, `blur` and `background_blur` |
| Transform | `rotation` (degrees counter-clockwise), `flipX`, `flipY`, all around the top-left corner |
| Text | `content` (a string; styled runs are not supported), `fontFamily`, `fontSize`, `fontWeight`, `fontStyle`, `letterSpacing`, `underline`, `strikethrough`, `textAlign` (with `justify`), `textAlignVertical`, `textGrowth`, `lineHeight` |
| Paths | `geometry` (SVG path data, arcs included), view box |
| Components | `reusable`, `ref`, overrides of any property on the `ref` itself (the component root) and in `descendants`, slot frames |
| Variables | `$name` references in any property, themed values, variables pointing to variables |
| Themes | header `themes`, node `theme` for its subtree |

Defaults that matter:

- Frames default to `layout: horizontal` and fit their content; groups default to `none`.
- The schema gives no default for `strokeAlignment`. pen.dev centres the stroke on the
  outline (checked pixel by pixel), and so does the app. Strokes added in the inspector are
  written as `"inner"`, as pen.dev's own files are.
- Font size is the em size, as in CSS. Without `lineHeight`, the font's own line spacing
  applies: (ascender − descender + line gap) / em, 1.21 for Inter. Lines sit in their line
  box with half leading. `letterSpacing` follows every character, including the last.
- `rotation` and the flips pivot on the node's top-left corner, so a node with `flipX`
  is drawn to the left of its `x` (pen.dev renders and exports it so). A shadow's `blur`
  fades over twice its value, as in CSS; a blur effect's `radius` is twice the CSS value.
- pen.dev does not draw `underline` or `strikethrough`; the app does.
- `imports` (alias → relative path of another `.pen` file) are read: its components are
  `ref`ed as "alias:id", its variables used as "$alias:name", and overrides inside them
  use descendant keys "alias:childId". These names were taken from pen.dev's own renders.
- The pen tool writes a `path` whose `geometry` is relative to its box, with `width` and
  `height` equal to the outline's bounds; editing keeps the outline where it is.
- `fonts` (header) lists font files the document brings, as pen.dev's "Add custom fonts"
  writes it: `[{"name": "Scto Grotesk A", "url": "./fonts/SctoGroteskA-Light.ttf",
  "weight": 300, "style": "normal"}]`. `weight` may be a range `[100, 900]` for a variable
  font, and `axes` (`[{"tag", "start", "end"}]`) may follow. Urls are relative to the file.
  An entry is a face of `name`, whatever the file calls itself. The lists of imported
  libraries apply to the files importing them. pen.dev reads no installed fonts, so this
  list is the only way a font reaches it.
- A `fontFamily` that is not available is drawn with Noto Sans at the asked weight, as
  pen.dev draws it (its first fallback font). Text without a `fontFamily` uses Arial.
- A bold (600+) asked of a family whose closest face is lighter is thickened (Skia's
  FreeType embolden: size / 24, same advances). 500 from a Light face stays Light.
- Without `lineHeight`, a line is the font's ascender to descender, without its line gap.
- A frame fitting its content ignores `fill_container` children on that axis; they get
  what the other children give it (pen.dev's "Collapsed size" when nothing does).
- The app also reads installed fonts and a `fonts` folder next to the `.pen` file (its own
  convention). Any `fontWeight` of a TrueType variable font is drawn by instancing it.

## Version differences

| | 2.8 | 2.21 |
| --- | --- | --- |
| Stroke | `"stroke": {"align", "thickness", "fill"}` | `stroke: <fill>`, `strokeWidth`, `strokeAlignment` |
| Slot | the component lists slot frames by name in its own `slot` array | the slot frame itself carries `slot` |

The reader accepts both. Edits keep the form the node already uses (`Node.stroke_old`).

## What the app adds

- **`pages`** in the header: `[{"name": string, "nodes": [top-level ids]}]`.
  - Top-level nodes listed under no page belong to the first page.
  - The key is not written when the document has a single default page with no ids.
  - Other tools are expected to keep or ignore it.
- **`fonts`** in the header, when fonts are added to the document (`add_fonts`).
- **`metadata.strokeDashPattern`**: a dashed stroke's pattern (#67). pen.dev keeps
  `metadata` and drops unknown keys, so the app's own data goes there; a node-level
  `strokeDashPattern` is read and moved into `metadata`.
- **Image files.** Images placed through the app are copied into `images/` next to the
  document and referenced as `./images/<name>`.

- **Connectors, labels and shapes with text** (decision #67) are plain nodes that pen.dev
  draws as last saved, with their live part in `metadata`, the only place pen.dev 1.2.21
  keeps data it does not know:
  - a connector: a stroked `path` with `layoutPosition: "absolute"` and `metadata
    {"type": "connector", "source": {"path", "anchor"}, "target": {"path", "anchor"},
    "routing", "startMarker", "endMarker", "waypoints"?}`. `path` is an id path (through
    instances: `"card/title"`), `anchor` is `center`, `top`, `right`, `bottom` or `left`,
    as in the schema's ConnectionEndpoint. The app rewrites `geometry`, `x`, `y`,
    `width`, `height` and `viewBox` with the current route.
  - its label: a frame with a text and `metadata {"type": "connection-label",
    "connection": <connector id>, "at": 0..1}`.
  - a shape with text: a frame with `metadata {"type": "shape", "shape": "diamond" |
    "ellipse" | "capsule", "inset"?}`, whose `padding` (and a capsule's `cornerRadius`)
    the app writes, and an outline child with `metadata {"type": "shape-outline"}`.
  - The schema's own `connection` nodes are read as connectors' ends would be, but never
    written: pen.dev 1.2.21 drops them.

Nothing else is added. Computed boxes (`bounds`) appear only in socket and MCP answers,
never in the file.

## Instances and overrides

```json
{ "type": "ref", "id": "post-1", "ref": "post-card",
  "descendants": { "post-title": { "content": "Hello" },
                   "vote/count": { "content": "42" },
                   "badge":      { "enabled": false } },
  "children": [ { "type": "text", "id": "post-1-body", "content": "Slot content" } ] }
```

- `descendants` keys are ids inside the component, or `/` paths through nested instances.
  The app matches an entry by the last segment of its path, so ids must be unique inside a
  component.
- The inspector's Parameters section edits these entries through `override_set`. It updates
  an existing entry if there is one, and drops entries that become empty.
- An override that carries a `type` replaces the whole node. Such entries are kept but not
  applied.
- **Slot content, 2.21.** pen.dev writes it as
  `descendants: {"<slot frame id>": {"children": [...]}}`. The slot frame is an empty frame
  marked `slot: []`. These children load as real child nodes of the instance, render in
  that frame instead of its default children, and are written back to the same place.
- **Slot content, 2.8.** The instance's own `children` render inside the component's slot
  frame: the one named in the component's `slot` list, else the first frame marked as a
  slot, else the root.
- **Where pen.dev differs.** pen.dev reads `children` on a `ref` as an override of the
  root's children. A 2.8 file like reddit-ui therefore shows only the slot content there,
  without the card's header and actions.
- Properties set on the `ref` itself override the component root: `fill`, `width`,
  `cornerRadius`, `padding`, and so on. Identity, position, `enabled`, `opacity` and
  `theme` stay with the instance. An instance can therefore fill its container while the
  component has a fixed width.
- Any property can be overridden. Content, name, colors, visibility, opacity, font size and
  weight have a fast path. Other properties (`icon`, `padding`, `cornerRadius`, ...) are
  written into a copy of the component node, which is then parsed again.

## Themed variables

A variable's `value` is either a literal or an array of `{value, theme}` entries.

**Resolving a node.** For each node the app works out the theme in effect: the axis values
shown in the Theme tab, overridden by the nearest `theme` properties above the node. It then
picks the entry that:

- has no axis value contradicting that theme, and
- matches the most axes.

An entry without `theme` is the default. A `"$other"` value is resolved through that
variable under the same theme.

**Editing a variable** in the Theme tab writes the entry whose theme equals the current
choice on every axis, and adds that entry if it does not exist. Under the default theme it
writes the untagged entry.
