# Shared Safety Policies

Policies in this directory describe safety requirements that apply regardless of
which AI agent is active.

Agent-specific hooks and integrations may enforce these policies differently, but
they must not silently weaken them.

Operating-system permissions, read-only mounts, constrained Windows identities,
and narrowly scoped bridge commands are preferred over model-side promises.

The canonical machine-readable policy is `core.toml`.
