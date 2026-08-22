# Environments

An environment represents a Skyrim test/deployment installation such as an MO2,
Wabbajack, Vortex, or stock setup.

Environments are independent of source projects. Multiple projects may use the
same environment.

Linux-side agents should prefer read-only evidence views of environments.
Write access to a live Skyrim or MO2 environment must be provided only through
an explicitly authorized, narrowly scoped bridge capability.

Build workers are not runtime/deployment workers.
