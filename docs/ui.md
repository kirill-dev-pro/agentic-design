# Interface design

This page describes how the window looks, which conventions the panels follow, and how to
add to them. The keyboard shortcuts are listed in the [README](../README.md#editor).

## Reference

The visual reference is [Paper](https://paper.design); the feature references are Paper and
[Pencil](https://pencil.dev). When it is unclear how something should behave, check what
those two do first.

## Regions

```
┌──────────────────────────── tab bar (TAB_H 44) ───────────────────────────────┐
│ Dashboard │ file.pen × │ other.pen × │ +                                       │
├──────────────┬────┬──────────────────────────────────────────┬────────────────┤
│ sidebar      │tool│ canvas                                   │ inspector      │
│ (LEFT_W 260) │(44)│                                          │ (RIGHT_W 300)  │
│ file name    │ V  │   frame titles, selection, smart guides, │ zoom ▾ Export ▾│
│ Design│Comp… │ H  │   size badge "Fill 1440 × Fit 296"       │ sections …     │
│ Pages        │ F  │                                          │                │
│ Layers       │ …  │                                          │                │
└──────────────┴────┴──────────────────────────────────────────┴────────────────┘
```

| Region | Contents |
| --- | --- |
| Tab bar | The Dashboard, one tab per open file (tabs are files, never pages), and `+` for a new file. |
| Sidebar | File name (double-click renames the file); Design, Components and Theme tabs; Pages (`+`, double-click renames, right-click for Rename, Duplicate or Delete…); layer tree. |
| Layer tree | Eye toggle, inline rename, context menu, and icons for the node kind and flex direction. Instances show their component's name. Rows drag to reorder or into another frame or group. |
| Components tab | Every component of the file with a preview and search. Click inserts an instance in the view; drag drops it into the frame under the pointer; double click goes to the origin. |
| Theme tab | Theme axis dropdowns (`+` adds a value, right-click renames one), the variable list and **Open variables table**: a sheet with a column per axis value, editable cells, search and add or delete. |
| Tool strip | Move, Hand, Frame, Rectangle, Ellipse, Text and Image, each with a tooltip. |
| Share | The inspector's Share button opens a sheet: signed out, "Sign in with browser" (then "Waiting for the browser…", Open again, Cancel); signed in, the account and Sign out, then "Create link", or the link with Copy link, Allow download, Allow embedding, Upload changes, Open in browser and Turn off link, and the files the document refers to that were not found. Progress and errors on the last line. `src/share_ui.odin`. |
| What's new | A sheet on the first launch after an update (not on a fresh install, in test windows or windows an agent opened): the app icon, "Updated from X to Y · date", then New, Improved and Fixed with a count each, every skipped version merged; "All changes ↗" opens the GitHub release, Got it, ×, Esc and Enter close it. The app menu and Settings → Updates open it again. `src/whats_new.odin`. |
| Inspector | pen.dev's order: header (Create component), instance, Alignment, Position (rotation, flips), Layout, Dimensions (Fill and Hug), Appearance (per-corner radius), Theme, Fill (list, gradients), Stroke, Effects (list), Typography, Context, Export, Selection colors. With nothing selected it shows page and document settings and the MCP connect button. |

## Style

All colors and sizes are constants in `src/app.odin` and `src/widgets.odin`. Use them rather
than new literals.

| Token | Value | Use |
| --- | --- | --- |
| `TAB_BG` | `#1A1A1A` | tab bar |
| `PANEL_BG` | `#1E1E1E` | sidebar, inspector, dashboard |
| `CANVAS_BG` | `#282828` | canvas |
| `FIELD_BG` | `#2A2A2A` | fields, dropdowns |
| `PANEL_LINE` | `#2E2E2E` | dividers |
| `HOVER_BG` / `ACTIVE_BG` | white at 6% / 12% | hover and pressed rows |
| `TEXT_FG` / `TEXT_DIM` | `#E8E8E8` / `#8F8F8F` | text, secondary text |
| `ACCENT` | `#0D99FF` | selection, focus, primary buttons |
| `GUIDE` | `#FF4D73` | smart guides |

- **Type.** The interface font is the system font (`SFNS.ttf`, falling back to Arial) at
  12 px. Only the regular weight is used, because NanoVG cannot pick a weight from the
  system variable font.
- **Metrics.** Inspector rows are 30 px (`ROW_H`). Menu rows are 26 px, and menu
  separators 9 px.

## Behaviour rules

1. **Choices are dropdowns.**
   - Font family, weight, alignment, theme value, zoom and export each open a menu.
   - Fonts use a searchable menu that previews every family in its own face.
   - Colors use a row with a swatch and a chevron. It opens the HSV picker with hex and
     alpha fields and a list of the document's color variables. Each row shows a swatch,
     the variable's name and its hex value in the shown theme. Typing filters the list;
     the bound variable is highlighted and scrolled into view. The inspector does not
     repeat the palette as a swatch grid.
2. **Numbers can be typed, scrubbed and stepped.**
   - Number fields accept typing.
   - Dragging the field's icon or prefix scrubs the value.
   - ↑ and ↓ step it.
   - Tab moves to the next field.
3. **Edits commit on leave.** Enter, Tab or a click elsewhere commits a field. Esc
   cancels.
4. **Overlays are modal.** While a menu, picker or dialog is open, nothing else on screen
   reacts. A click outside closes the overlay without passing the click through.
5. **Scrolling goes to the list under the pointer.** Only the topmost scrollable area
   under the pointer scrolls (`wheel_over`), and nothing below an open overlay does.
6. **Show where things come from.**
   - Variables show as chips.
   - Instances show their component's name and offer Go to component. Double-clicking an
     instance on the canvas does the same.
   - The size badge names the size mode (Fill, Fit or a number).
7. **No focus stealing.** Windows started by agents or tests do not take the keyboard (see
   [decisions.md](decisions.md#5-agents-and-tests-never-steal-focus)).
8. **Nothing account-related.** There are no accounts, so there is no avatar and no
   sharing UI.

## Adding to the interface

- **Use the widgets.** Build controls from `src/widgets.odin`: `button`, `icon_button`,
  `checkbox`, `dropdown` / `dropdown_menu`, `slider`, `field`, `menu_open`, `picker_open`,
  `dialog_open`, `tooltip_request`, `section`, `section_toggle`, `scrollbar`. If a control
  is missing, add it there rather than drawing it inline in a panel.
- **Menu results.** Give each menu, picker or dialog a unique key. Read the result with
  `menu_take(key)`, `picker_take(key)` or `dialog_take(key)` in the code that draws the
  control. The result arrives on a later frame.
- **Field keys.** A field is identified by `(uid, key)`. `uid` is the node it edits; 0 means
  an app or document setting. Keys follow a `kind:detail` pattern (`var.value:color:name`,
  `ov.content:<id>`, `page.name:<i>`). Handle a new kind in `field_apply` in `src/ui.odin`.
- **Icons.** Icons are SVG path strings in `ICON_PATHS`, drawn with `draw_icon`. Add a
  constant to the `Icon` enum and give it a path.
- **Commands.** Anything a shortcut, the context menu and the inspector all offer belongs in
  `src/edit.odin`, so the three stay the same.
