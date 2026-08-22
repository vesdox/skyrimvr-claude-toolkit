# Projects

A project is a source repository or logical mod-development project.

Projects do not own Skyrim installations or Mod Organizer instances. They reference
one or more environments defined separately under `environments/`.

The toolkit must support an arbitrary number of projects. It must not assume:
- one repository per installation;
- one plugin per repository;
- one project per plugin;
- one Skyrim runtime;
- one Mod Organizer instance.

Project source repositories are authoritative for development once a project has
been migrated into this workspace.

A project may be marked pending before its repository exists.
