# Documentation

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Processes, the frame loop, document model, layout, rendering, the interface, persistence, export and the module map |
| [decisions.md](decisions.md) | Design decisions with the problem, the decision and its consequences, numbered (#1–#50) |
| [pen-format.md](pen-format.md) | What the app reads from and adds to `.pen` files: version differences, instances, themed variables |
| [ui.md](ui.md) | The interface: regions, style tokens, behaviour rules, how to add panels and widgets |
| [testing.md](testing.md) | Quiet test windows, the UI driver and fuzzer, lldb, socket methods, round-trip and performance checks |
| [performance.md](performance.md) | How performance is measured, baseline numbers, hot spots and the changes made for them |
| [dogfooding.md](dogfooding.md) | Problems and improvement ideas found while using the app for real work, with their status |
| [pen-dev-comparison.md](pen-dev-comparison.md) | Feature-by-feature comparison of the interface with pen.dev: what is on par, partial or missing |

Usage, shortcuts and the MCP tools are listed in the [top-level README](../README.md).

When a change alters behaviour or reverses a decision:

- update the matching page;
- add an entry to `decisions.md` rather than rewriting an old one.
