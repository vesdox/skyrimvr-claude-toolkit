# Bounded project deployment forced command

This directory implements the Windows write boundary behind `skyrim-agent deploy`.
It is not a remote shell, SFTP endpoint, daemon, or general command runner. A dedicated
SSH key authenticates only as the non-admin local `SkyrimDeploy` identity; an OpenSSH
`Match User skyrimdeploy` block forces `invoke-ssh.ps1` and disables passwords, PTY,
user RC files, tunneling, and all forwarding.

The wrapper accepts only the literal SSH original command `project-deploy-v1`, verifies
its own protected worker/config hashes and exact Windows SID, refuses requests while
Skyrim is running, and launches `bridge.js --stdio`. The worker requires pinned protocol magic and
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
`Hoarfrost - Development` target and protected backup tree. Worker, wrapper,
configuration, and authorized-key files are read-only to that identity and writable
only by Administrators/SYSTEM. These filesystem ACLs remain the backstop even if a
request is malformed.

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

- worker: `C:\ProgramData\SkyrimToolBridge\project-deploy\bridge\bridge.js`
- wrapper: `C:\ProgramData\SkyrimToolBridge\project-deploy\invoke-ssh.ps1`
- allowlist: `C:\ProgramData\SkyrimToolBridge\project-deploy\config.json`
- backups/audit: registry-configured protected backup root
- public key: `C:\ProgramData\SkyrimToolBridge\openssh\authorized_keys`
- transport: existing Windows OpenSSH 9.5p2 service on pinned port 22 and host key

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
   protected parent/runtime ACLs, and a pinned-path Node.js 20+ runtime;
2. builds a candidate `sshd_config` with a dedicated Match block;
3. runs `sshd.exe -t` and non-empty `sshd.exe -T -C` checks;
4. proves effective settings for every existing local user, including
   `HoarfrostTransfer` and `HoarfrostBuild`, are unchanged;
5. proves every required `SkyrimDeploy` restriction is effective;
6. backs up runtime files and `sshd_config`, installs exact ACLs, and restarts sshd;
7. restores compare-and-swap-validated original state, waits for sshd transitions,
   and revalidates the restored port-22 service if activation/health checks fail.

A remote smoke with the dedicated key is still required after local provisioning. It
must prove valid protocol access, shell/SFTP/PTY/forwarding refusal, unrelated-mod
refusal, protected-file refusal, target probe and smoke-backup cleanup,
backup/replace/rollback, audit evidence, and unchanged existing build/transfer access. Smoke must not deploy a
registered candidate artifact.

## Client behavior

Dry-run never writes: it verifies source/build provenance and reads registered
read-only destination evidence. Apply opens one dedicated forced-command SSH process,
performs plan and apply as two messages in that process, and validates all returned
paths and hashes. There is no direct SFTP or unrestricted SSH fallback.
