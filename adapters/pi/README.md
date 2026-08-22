# Pi Adapter

Pi follows the shared contract in the repository root `AGENTS.md`.

Pi does not receive Claude Code's `.claude/hooks/` safety layer.

Therefore Pi workflows must rely on the shared project registry, operating-system
permissions, read-only evidence mounts, and narrowly scoped bridge commands rather
than assuming a model-side confirmation hook will intercept unsafe operations.

Before project-specific work, resolve the project with:

    ./tools/skyrim-agent.py show <project-id>

For Windows native build work, use:

    ./tools/skyrim-agent.py build <project-id>

For environment evidence inspection, use:

    ./tools/skyrim-agent.py evidence <project-id>

Do not replace these project-aware entry points with hardcoded Hoarfrost or Windows
paths when extending the toolkit.
