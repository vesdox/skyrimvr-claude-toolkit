# Environments

An environment represents a Skyrim test/deployment installation such as an MO2,
Wabbajack, Vortex, or stock setup.

Environments are independent of source projects. Multiple projects may use the
same environment.

Linux-side agents should prefer read-only evidence views of environments.
Write access to a live Skyrim or MO2 environment must be provided only through
an explicitly authorized, narrowly scoped bridge capability.

Build workers are not runtime/deployment workers.

An authorized MO2 deployment environment may register its Windows mods root, the
matching read-only evidence root used only for dry-run inspection, and a constrained
project-deployment bridge. The environment root and project-owned mod target remain
separate registry facts so shared environments do not grant cross-project writes.
