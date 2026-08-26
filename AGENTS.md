# Skyrim Agent Toolkit — Shared Agent Contract

This file is the canonical agent-neutral instruction entry point for this toolkit.

It applies to Pi, Claude Code, and other coding agents unless an adapter explicitly
adds stricter behavior. Agent-specific adapters may extend this contract but must
not silently weaken it.

## Architecture

The toolkit is multi-project and multi-environment.

- `projects/` defines source projects and their capabilities.
- `environments/` defines Skyrim/MO2 test environments and read-only evidence.
- `policies/` contains shared safety policy.
- `bridges/` contains narrowly scoped Linux ↔ Windows capabilities.
- `adapters/` contains agent-specific integration.
- `tools/skyrim-agent.py` is the shared project/environment resolver.

Do not assume:
- there is only one source repository;
- one repository produces only one plugin;
- one plugin has only one repository;
- one project uses only one Skyrim environment;
- one Skyrim environment belongs to only one project.

Resolve project-specific information through the project registry rather than
hardcoding Hoarfrost, ASSOS, MO2VR, or any future project/environment name.

## Source and environment boundaries

A project source repository is authoritative for development once that project is
marked active and migrated into this workspace.

A Skyrim/MO2 environment is a test/deployment environment, not a source workspace.

Linux-visible environment evidence must be treated as read-only. Never use an
environment evidence path as an authoritative project source tree.

Do not deploy to, alter, or manage a live Skyrim/MO2 environment unless an explicit
runtime/deployment capability has been authorized for that operation.

Build permission does not imply deployment permission.

Authorized deployment must use `skyrim-agent deploy` with a registered project,
environment, target, and file set. Native artifacts require registered Windows-build
evidence. Dry-run may inspect destination hashes through read-only evidence, but
actual copying must use the constrained deployment bridge and must report pre-copy
and resulting hashes. Deployment does not authorize load-order/profile mutation,
mod enablement, game launch, save changes, or runtime configuration changes.

## Project-aware commands

Before acting on a project, resolve it through the shared registry.

Examples:

    ./tools/skyrim-agent.py show hoarfrost
    ./tools/skyrim-agent.py evidence hoarfrost
    ./tools/skyrim-agent.py build hoarfrost --dry-run
    skyrim-agent deploy hoarfrost --environment assos --target development --set <registered-set> --dry-run
    skyrim-agent inspect-plugin <project-id> --environment <environment-id> --mod "<mod-name>"

Use the project ID supplied by the user or task. Do not substitute another project
because it appears similar or shares an environment.

For reusable toolkit capabilities, prefer the project-aware capability interface:

    skyrim-agent run <project-id> <capability-id> <action> ...

Treat capability implementation scripts as toolkit internals unless explicitly
debugging the toolkit itself.

When locating plugins manually or debugging capability resolution, use the
project-aware `plugins` and `inspect-plugin` commands instead of hardcoded filesystem
paths. If a mod contains multiple plugins, identify the intended plugin explicitly
rather than guessing.

## Windows boundaries

Prefer Linux for work that does not genuinely require Windows.

Windows operations must use narrowly scoped bridge capabilities rather than general
remote shell access when a bridge exists.

Native Windows builds must be invoked through the shared project-aware entry
point:

    skyrim-agent build <project-id>

The repository-local build command registered in a project definition is an
implementation detail used by the toolkit. Agents should not invoke that underlying
command directly unless explicitly debugging the toolkit itself.

Do not substitute a Linux-native build when Windows validation is required.

Build workers are not runtime/deployment workers.

Live Skyrim installations, MO2 instances, saves, runtime configuration, and deployed
mods are outside the build-worker trust boundary.

## Skyrim tooling principles

Consult `KNOWLEDGEBASE.md` before relying on assumptions about Skyrim engine behavior,
runtime differences, file formats, or modding tools.

Never assume Skyrim SE/AE behavior is identical to Skyrim VR behavior. Validate the
runtime relevant to the project.

Prefer structured tooling over direct binary edits.

Never directly hand-edit `.esp`, `.esm`, `.esl`, `.bsa`, or `.ba2` binary files.
Use the appropriate toolkit workflow such as Spriggit, xelib, or another validated
format-aware tool.

Treat load-order-dependent results as environment-dependent evidence. Under MO2,
tools that require the merged virtual filesystem must run through an authorized
Windows/MO2 capability.

## Safety

Agent-specific hooks are supplemental safety mechanisms, not the universal security
boundary.

Prefer protections enforced below the model:
- filesystem permissions;
- read-only mounts;
- constrained bridge identities;
- validated project capabilities;
- dry-run and structured tool wrappers.

Do not bypass an operating-system permission boundary or weaken one merely to make an
agent workflow more convenient.

When a requested capability is unavailable, report the missing capability instead of
silently using a broader or less-safe mechanism.

## Agent adapters

Read the relevant adapter documentation when using an agent-specific integration:

- Pi: `adapters/pi/README.md`
- Claude Code: `adapters/claude/README.md`

Claude-specific hooks and skills under `.claude/` remain useful when Claude Code is
the active agent, but other agents must not assume those hooks are present.

## Existing detailed reference

`CLAUDE.md` currently contains substantial historical tool usage and workflow
documentation from the original Claude-oriented toolkit.

Treat applicable technical material there as reference, but where it conflicts with
this file on architecture, project resolution, environment ownership, or safety
boundaries, this `AGENTS.md` is authoritative.

The long-term direction is to move genuinely shared material out of `CLAUDE.md` and
leave only Claude-specific integration there.

## Filesystem search safety

- Do not recursively search `/home/wodox/skyrim-dev` as a whole by default.
- `/home/wodox/skyrim-dev/windows-ro` contains remote CIFS/SMB evidence mounts over Tailscale. Broad `find`, `rg`, `grep`, `xargs`, or similar recursive searches across that tree can cause heavy network I/O and CPU I/O wait.
- Prefer the narrowest relevant local scope first, such as the current repository, `/home/wodox/skyrim-dev/reference/mod-sources`, or a named artifact/source directory.
- Search `/home/wodox/skyrim-dev/windows-ro` only when Windows-side evidence is specifically required, and then search only the named mount/subdirectory needed for the task.
- Never use an unbounded command such as `find /home/wodox/skyrim-dev -type f ...` merely to locate likely project/reference evidence.
