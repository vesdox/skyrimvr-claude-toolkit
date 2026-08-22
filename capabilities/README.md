# Capability Catalog

This directory describes reusable Skyrim development capabilities independently of
projects, environments, and AI agents.

A catalog entry describes:

- what an operation does;
- where it must execute;
- whether it requires an MO2 virtual filesystem or running game;
- its write/risk boundary;
- whether an implementation is currently available.

Catalog presence does not grant a project permission to use a capability.

Projects opt into capabilities separately. A capability may also remain
`unconfigured` until its executable, bridge, or runtime integration has been
validated.

Execution classes:

- `linux` — runs directly in the authoritative Linux workspace.
- `windows` — requires Windows, but not necessarily MO2.
- `windows-mo2` — requires Windows and an MO2 virtual filesystem.
- `windows-runtime` — requires a running Skyrim environment.

Risk classes:

- `read` — inspection only.
- `source-write` — may create or modify authoritative project source/artifacts.
- `environment-write` — may alter a test/runtime environment.
- `runtime` — interacts with a running game.

Environment-write and runtime capabilities require explicit authorization beyond
ordinary project source access.
