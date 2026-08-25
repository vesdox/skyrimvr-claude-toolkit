# Bounded project deployment bridge

This bridge is the Windows write boundary behind `skyrim-agent deploy`. It is not a
remote shell and exposes only:

- `GET /health`
- `POST /plan`
- `POST /apply`

`plan` accepts registered logical IDs and hashes, resolves them through a generated
allowlist, hashes every current destination, and returns a five-minute one-use token.
`apply` requires that token, the exact planned bytes, and unchanged destination
hashes. The protected generated allowlist also pins every permitted source SHA256, so
a caller cannot substitute arbitrary bytes for a registered artifact ID. The bridge
backs up replaced files, stages and hashes each source, replaces only the registered
destination, verifies the resulting SHA256, and rolls back completed replacements if
the transaction fails.

## Trust boundary

The bridge binds only to `127.0.0.1:7347` and is intended to be exposed as the
`/project-deploy` path through Tailscale Serve. The dedicated Windows identity is
`SkyrimDeploy`; it must have modify permission only on the registered deployment
mod directory and its protected backup tree. It must not have permission to edit MO2
profiles, `plugins.txt`, `loadorder.txt`, saves, game/runtime configuration, or other
mods. Do not run this service as the native-build or read-only `SkyrimInspect`
identity.

The bridge never accepts an arbitrary filesystem path. Its protected `config.json`
is generated from the shared project/environment registries:

```bash
python3 tools/export_deployment_bridge_config.py \
  --environment assos \
  --output /tmp/assos-project-deploy.json
```

The ASSOS MO2 root lives in `environments/assos.toml`; the Hoarfrost target, allowed
sets, exact source ownership, and destination-relative paths live in
`projects/hoarfrost.toml`. The full destination is therefore not hardcoded in either
the Linux client or bridge source.

## Protected runtime layout

- bridge: `C:\ProgramData\SkyrimToolBridge\project-deploy\bridge\bridge.js`
- generated allowlist: `C:\ProgramData\SkyrimToolBridge\project-deploy\config.json`
- backups: registry-configured protected backup root
- scheduled task: `SkyrimToolBridge-Project-Deploy` (S4U, `SkyrimDeploy`)

`deploy.ps1` updates only an already-provisioned protected bridge/config and verifies
source/deployed hashes, task identity, loopback binding, and health. Initial account,
ACL, scheduled-task, and Tailscale Serve provisioning remains an owner/admin action;
it is intentionally not exposed through an agent command.

## Client behavior

Dry-run does not contact this write bridge. It hashes sources locally and inspects the
registered read-only environment evidence path for the current destination. Apply
always uses the bridge's authoritative two-phase check; the read-only mount is never
a write route.
