# Bounded project deployment forced command

This directory implements the Windows write boundary behind `skyrim-agent deploy`.
It is not a remote shell, SFTP endpoint, daemon, or general command runner. A dedicated
SSH key authenticates only as the non-admin local `SkyrimDeploy` identity; an OpenSSH
`Match User skyrimdeploy` block forces `invoke-ssh.ps1` and disables passwords, PTY,
user RC files, tunneling, and all forwarding.

The wrapper accepts only the literal SSH original command `project-deploy-v1`, verifies
its own protected worker/config hashes and exact Windows SID, refuses requests while
Skyrim is running, and launches `bridge.js --stdio`. Runtime identity acceptance is pinned to the exact
Windows SID; the case-insensitive `SkyrimDeploy` account component is also checked,
while the environment-reported domain/workgroup label is audit metadata rather than
an identity authority. The worker requires pinned protocol magic and
length-prefixed JSON frames, reads at most two requests, and reserves stdout solely
for framed protocol responses. OpenSSH terminates an idle session after 600 seconds;
a dead apply lock becomes recoverable only after 15 minutes and a dead-PID check:

- `health`: validate the protected runtime and return service identity;
- `smoke`: fixed ACL/backup/rollback checks using disposable probe files;
- `plan`: validate registered artifact IDs/hashes and return destination hashes plus a
  five-minute one-use token;
- `apply`: accept exact planned bytes on the same SSH process, recheck destination
  hashes, back up replacements, stage/hash/replace, verify results, and roll back on
  failure.

Every accepted/rejected operation is appended to a protected NDJSON audit file under
the configured backup root. Apply records include apply-start, commit, and failure or
rollback status; a commit-audit failure triggers transaction rollback. Audit records
omit payload bytes and raw plan tokens.

## Trust boundary

`SkyrimDeploy` has an ASSOS-wide write/delete deny and Modify only on the registered
`Hoarfrost - Development` target and protected backup tree. Worker and configuration files are read-only to that identity; the wrapper and Node
runtime are read/execute only. The authorized-key file is accessible only to
Administrators/SYSTEM. All trusted material lives below a dedicated protected root
whose inheritance is disabled and whose ancestry is checked before execution or SSH
activation. These filesystem ACLs remain the backstop even if a request is malformed.

Never reuse the build (`HoarfrostBuild`/`SkyrimBuildWorkers`), transfer
(`HoarfrostTransfer`), read-only (`SkyrimInspect`), or Administrator identities for
runtime deployment. Build permission does not imply deployment permission.

The worker never accepts arbitrary commands or filesystem paths. Its protected
`config.json` is generated from shared registries:

```bash
python3 tools/export_deployment_bridge_config.py \
  --environment assos \
  --output /tmp/assos-project-deploy.json
```

The ASSOS root and SSH endpoint are registered in `environments/assos.toml`; project
targets, allowed sets, source ownership, expected hashes, and destination-relative
paths are registered in `projects/hoarfrost.toml`.

## Protected runtime layout

- protected root: `C:\Program Files\SkyrimDeployBridge`
- worker: `C:\Program Files\SkyrimDeployBridge\bridge\bridge.js`
- Node runtime: `C:\Program Files\SkyrimDeployBridge\runtime\node.exe`
- wrapper: `C:\Program Files\SkyrimDeployBridge\invoke-ssh.ps1`
- allowlist: `C:\Program Files\SkyrimDeployBridge\config.json`
- public key: `C:\Program Files\SkyrimDeployBridge\openssh\authorized_keys`
- backups/audit: registry-configured writable tree under `C:\ProgramData\SkyrimToolBridge`
- transport: existing Windows OpenSSH 9.5p2 service on pinned port 22 and host key

`C:\ProgramData` and the shared `SkyrimToolBridge` root were rejected for trusted
material because their observed ACLs grant `BUILTIN\Users` write rights. The existing
`C:\Program Files` ACL grants broad identities read/execute only and is used without
changing its ACL. The integrity check distinguishes mutation rights on each trusted
object from delete-child/ACL-control rights on higher ancestors; create-only rights on
a higher ancestor cannot replace an existing protected child. Inherit-only ACEs are
not misclassified as effective rights on the ancestor object.

There is deliberately no deployment Scheduled Task, port 7347 listener, Tailscale
Serve route, deployment SFTP subsystem, or persistent deployment process.

## Provisioning and recovery history

Initial Scheduler-based provisioning on 2026-08-25 partially completed account and
ACL setup, then repeatedly failed task registration with `0x80070005`. Granting
`SeBatchLogonRight` did not change that failure, disproving it as the root cause.
Read-only comparison found no concrete Scheduler authorization cause, and that route
was retired. Do not run historical task recovery scripts or reapply the ASSOS ACL
tree.

The current `provision.ps1` is a SID-pinned continuation for that exact partial state
and the controlled updater for its uniquely marked OpenSSH block. It refuses unmanaged
or ambiguous `SkyrimDeploy` blocks, does not create an account, and does not alter
ASSOS ACLs. Before changing the live service it:

1. verifies source hashes, non-administrator account SID, absent task/listener,
   every privileged path and ancestry boundary, and the exact signed Node.js 24.15.0 runtime;
2. preserves every pre-existing `sshd_config` byte while inserting exactly one
   canonical, structurally validated managed `SkyrimDeploy` Match block;
3. runs `sshd.exe -t -f` against the baseline, candidate, installed, and restored
   configurations without Administrator-side `sshd -T -C user=...` evaluation;
4. verifies the existing `HoarfrostTransfer` and `HoarfrostBuild` local identities
   remain present while leaving their configuration bytes untouched;
5. statically rejects active global `PermitUserEnvironment yes` (and unresolved global
   includes), relying on the pinned OpenSSH 9.5p2 default of `no` when absent; the
   generated Match block contains only directives marked `SSHCFG_ALL` by that pinned
   source and the packaged `sshd.exe -t` remains authoritative;
6. defers effective forced-command and existing-identity semantics to live SSH through
   the actual LocalSystem sshd service;
7. backs up runtime files and `sshd_config`, installs exact ACLs, and restarts sshd;
8. restores compare-and-swap-validated original state, waits for sshd transitions,
   and revalidates the restored port-22 service if activation/health checks fail.

The packaged Node runtime is extracted from the official `node-v24.15.0-win-x64.zip`.
The signed release checksum, archive hash, extracted executable hash, owner-observed
Authenticode signer, and exact file version are recorded in
`node-runtime-v24.15.0.json`. Provisioning verifies the staged hash, size, version
resource, and signer before copying it, then verifies protected destination ancestry,
hash, and ACLs before executing it.

A remote smoke with the dedicated key is still required after local provisioning. It
must prove dedicated-key-only protocol access, shell/SFTP/PTY/forwarding refusal,
unrelated-mod refusal, protected Node/worker/wrapper/config/key refusal, target probe
and smoke-backup cleanup, backup/replace/rollback, read-back-verified and
request-correlated audit evidence, unchanged existing build/transfer authentication
behavior, and unchanged registered destination/backup snapshots. Smoke takes the
existing apply serialization lock around its destination/backup snapshots and probe
work. Smoke must not deploy a registered candidate artifact.

The post-provisioning smoke correction updates only `bridge.js` and its wrapper hash
pin. `update-worker.ps1` is the bounded Administrator maintenance path for that exact
old/new pair: it validates staged and installed hashes, refuses an active deployment
lock, preserves and verifies both file ACLs, backs up both old files, writes in place,
validates the installed scripts, and restores the exact old pair on failure. It does
not rerun provisioning, restart sshd, edit `sshd_config`, alter identities/keys/ACLs,
or touch any deployment target.

## Completed live SSH smoke

The owner-run live smoke passed on 2026-08-26 against toolkit commit
`40024575b1c93eb49cfdd9df44b20daacf5be14e`. Health request
`afb202b1-9585-49ed-a690-2fe97e8df60b` and smoke request
`5526670f-30dd-41ee-9d64-15d9dedc7d4c` each returned a read-back-verified audit
record for the pinned SID. The smoke proved target write/backup/replace/rollback/
remove, refusal across 324 unrelated mod roots, protected Node/worker/wrapper/config/
authorized-key write refusal, and unchanged registered destinations/backups with its
probe and smoke backup removed.

The same run refused wrong deployment keys, arbitrary command, empty shell, PTY,
SFTP, local/remote/dynamic/stdio forwarding, while preserving constrained
`HoarfrostTransfer` SFTP and `HoarfrostBuild` authentication. No registered artifact
was sent or deployed. The capability is available only for its registered bounded
operations; this proof does not authorize load-order, save, launch, or runtime
configuration mutation.

## Client behavior

Dry-run never writes: it verifies source/build provenance and reads registered
read-only destination evidence. Apply opens one dedicated forced-command SSH process,
performs plan and apply as two messages in that process, and validates all returned
paths and hashes. There is no direct SFTP or unrestricted SSH fallback.
