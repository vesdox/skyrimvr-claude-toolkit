# houseCARL Read Bridge

This directory contains the authoritative source for the constrained Windows
houseCARL inspection bridge.

## Allowed operations

The bridge currently exposes only:

- `GET /health`
- `POST /read-record`
- `POST /diff-record`
- `POST /query-records`

It does not expose arbitrary MCP tool names or the raw houseCARL MCP endpoint.

## Runtime path

Linux `skyrim-agent`
-> HTTPS over Tailscale Serve
-> constrained Windows bridge
-> localhost houseCARL MCP
-> Mutagen / registered MO2 instance

Raw houseCARL remains bound to:

`127.0.0.1:7345`

The constrained bridge remains bound to:

`127.0.0.1:7346`

Only the constrained bridge is exposed through Tailscale Serve.

## Windows identity

houseCARL and the constrained bridge run as:

`Ellfone\SkyrimInspect`

That identity can read the registered ASSOS environment but is denied creation,
modification, rename, and deletion there by Windows filesystem ACLs.

## Source and deployment

Authoritative source:

`bridges/windows/housecarl-read/bridge.js`

Protected deployed copy:

`C:\ProgramData\SkyrimToolBridge\housecarl-read\bridge\bridge.js`

The protected runtime tree is writable only by Administrators and SYSTEM.
`SkyrimInspect` receives read/execute access only.

Changes are made in the Linux repository first and then explicitly deployed to
Windows. The Windows ProgramData copy is a deployed artifact, not source.

The houseCARL inspection bridge is a separate trust boundary from the hardened
Windows native-build bridge.

## Tested houseCARL runtime

The constrained bridge is currently validated against upstream houseCARL commit:

    fad208d4d7bca736d4190fca36ec921be9ac7ea6

This revision was built from the upstream `main` branch on Windows with .NET 9
and promoted into the protected SkyrimInspect runtime.

The `query-records` facade relies on the `housecarl_cross_plugin_query` surface
available at that revision, including JSON output and the `offset` parameter.

Do not assume a newer or older houseCARL build is API-compatible. After changing
the upstream revision, rerun the bridge smoke tests before promoting it into the
protected runtime.

The public `query-records` facade intentionally exposes only:

- record type
- EditorID substring
- one plugin scope
- conflicts-only filtering
- a bounded result limit

It does not expose arbitrary predicates, file-backed inputs, output paths,
expanded fields, conflict trees, grouping, or arbitrary MCP tool names.
