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

`provision.ps1` is the owner/admin initial-provisioning entry point. It creates a
random-password non-admin `SkyrimDeploy` identity, denies that identity inherited
write/delete rights across the ASSOS tree, explicitly grants Modify only on the
registered `Hoarfrost - Development` target, protects service/config state from
unprivileged writes, registers the S4U task, proves listener ownership, and runs a
one-shot effective-permission smoke. That smoke must write/hash/remove a temporary
file under the real registered `SKSE\Plugins` destination, refuse temporary writes
across every unrelated ASSOS mod root, and refuse write-open access to the protected
config and bridge files. Provisioning leaves Tailscale unchanged until those local
checks pass; the owner then adds the path-scoped Serve route as a separate observable
step and verifies that the existing read route is unchanged.

`batch-right.ps1` grants only `SeBatchLogonRight` to an exact expected
`SkyrimDeploy` SID and verifies readback. This right is required by the local-account
S4U pattern; the established `SkyrimInspect` S4U identity has the same right.

`acl-smoke.ps1` is an internal fixed-operation helper run only through a temporary
S4U task by `provision.ps1`; it is not a general command runner.

`resume-task.ps1` is a one-time, SID-pinned recovery for the diagnosed ASSOS partial
provisioning state. It preserves existing ACLs/files, grants the missing batch-logon
right, registers or validates only the exact service task, starts the loopback bridge,
and runs the fixed ACL smoke. It does not configure Tailscale or deploy artifacts.

### Diagnosed ASSOS partial state (2026-08-25)

The first task-registration attempt stopped with `0x80070005` after creating SID
`S-1-5-21-3046562540-2879210194-691397096-1014`, applying the ASSOS deny and isolated
Hoarfrost target allow, and protecting/copying bridge configuration. Read-only
inspection established: no deployment task, no port 7347 listener, no Tailscale
change, no candidate deployment, and no account rights for `SkyrimDeploy`; the
working local `SkyrimInspect` S4U identity has `SeBatchLogonRight`. Recovery must not
rerun the ASSOS ACL provisioning.

`deploy.ps1` updates only an already-provisioned protected bridge/config. It requires
pinned source/config hashes and the exact single Hoarfrost/ASSOS allowlist, then
verifies deployed hashes, exact S4U task identity, loopback binding, post-start
process owner, and health. Initial provisioning and future updates remain owner/admin actions; they
are intentionally not exposed through an agent or general remote-shell command.

## Client behavior

Dry-run does not contact this write bridge. It hashes sources locally and inspects the
registered read-only environment evidence path for the current destination. Apply
always uses the bridge's authoritative two-phase check; the read-only mount is never
a write route.
