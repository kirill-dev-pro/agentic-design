# Documentation

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Processes, the frame loop, document model, layout, rendering, the interface, persistence, export and the module map |
| [decisions.md](decisions.md) | Design decisions with the problem, the decision and its consequences, numbered (#1–#80) |
| [pen-format.md](pen-format.md) | What the app reads from and adds to `.pen` files: version differences, instances, themed variables |
| [ui.md](ui.md) | The interface: regions, style tokens, behaviour rules, how to add panels and widgets |
| [releasing.md](releasing.md) | Versions, the app bundle, update signing, the release workflow, secrets, Gatekeeper; testing an update locally |
| [pen-dev-comparison.md](pen-dev-comparison.md) | Feature-by-feature comparison of the interface with pen.dev: what is on par, partial or missing |
| [cloud-design.md](cloud-design.md) | The cloud (approved; M1 in progress): accounts, cloud documents and their sync model, share links, mobile viewing, multiplayer; backend on Workerstack, milestones and costs |

Usage, shortcuts and the MCP tools are listed in the [top-level README](../README.md).

When a change alters behaviour or reverses a decision:

- update the matching page;
- add an entry to `decisions.md` rather than rewriting an old one.

The test recipes (quiet test windows, the interface driver and fuzzer, lldb), the
performance notes and the dogfooding log are kept with the tests, in a private repository.
