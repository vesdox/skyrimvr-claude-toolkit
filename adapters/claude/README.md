# Claude Code Adapter

Claude Code follows the shared contract in the repository root `AGENTS.md`.

`CLAUDE.md` remains the detailed Claude-facing/tool reference while the original
toolkit is being separated into agent-neutral and agent-specific layers.

Claude-specific functionality remains under `.claude/`, including hooks and skills.

Those hooks are supplemental protections. Shared workflows must not depend on them
for correctness or security because Pi and future agents do not receive them.

When extending a workflow:
- put agent-neutral tools and policy in the shared toolkit;
- put Claude-specific hooks, skills, or invocation behavior in this adapter or
  `.claude/`;
- do not hardcode a single project or Skyrim environment.

Use the shared project resolver for project-specific operations:

    ./tools/skyrim-agent.py show <project-id>
    ./tools/skyrim-agent.py evidence <project-id>
    ./tools/skyrim-agent.py build <project-id>
