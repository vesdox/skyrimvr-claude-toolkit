#!/usr/bin/env python3
"""Provisioning-only smoke for the dedicated SkyrimDeploy forced command."""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import tomllib
from pathlib import Path

import project_deploy as deploy

ROOT = Path(__file__).resolve().parent.parent


def run_refusal(label: str, argv: list[str], input_bytes: bytes = b"", timeout: int = 25) -> None:
    result = subprocess.run(argv, input=input_bytes, capture_output=True, timeout=timeout, check=False)
    if result.returncode == 0:
        raise deploy.DeployError(f"{label} unexpectedly succeeded")
    stdout = result.stdout.decode("utf-8", errors="replace")
    if "ELLFONE\\SkyrimDeploy" in stdout or "Microsoft Windows" in stdout:
        raise deploy.DeployError(f"{label} exposed command output: {stdout[:500]}")
    print(f"{label}: refused (status {result.returncode})")


def port_closed(port: int) -> bool:
    with socket.socket() as stream:
        stream.settimeout(0.5)
        return stream.connect_ex(("127.0.0.1", port)) != 0


def main() -> int:
    with (ROOT / "environments" / "assos.toml").open("rb") as stream:
        environment = tomllib.load(stream)
    bridge = deploy.ssh_bridge_config(environment)

    with deploy.SshBridgeSession(bridge, timeout=30) as session:
        health = session.request(deploy.protocol_request("health", {}), timeout=30)
    if health.get("service") != "project-deploy-ssh-worker":
        raise deploy.DeployError("forced-command health returned an unexpected service")
    print(json.dumps(health, indent=2))

    with deploy.SshBridgeSession(bridge, timeout=180) as session:
        smoke = session.request(deploy.protocol_request("smoke", {}), timeout=180)
    required = (
        "target_write_backup_replace_rollback_remove",
        "unrelated_refused",
        "config_write_open_refused",
        "worker_write_open_refused",
        "wrapper_write_open_refused",
    )
    if smoke.get("sid") != "S-1-5-21-3046562540-2879210194-691397096-1014":
        raise deploy.DeployError("smoke ran under an unexpected SID")
    if smoke.get("unrelated_count", 0) < 1 or not all(smoke.get(name) is True for name in required):
        raise deploy.DeployError(f"fixed ACL smoke failed: {smoke}")
    print(json.dumps(smoke, indent=2))

    base = [
        "ssh", "-oBatchMode=yes", "-oIdentitiesOnly=yes",
        "-oStrictHostKeyChecking=yes", f'-oUserKnownHostsFile={bridge["known_hosts"]}',
        "-oHostKeyAlgorithms=ssh-ed25519", "-oPasswordAuthentication=no",
        "-oKbdInteractiveAuthentication=no", "-oPreferredAuthentications=publickey",
        "-oConnectTimeout=15", "-p", str(bridge["port"]),
        "-i", str(bridge["identity"]),
        f'{bridge["user"]}@{bridge["host"]}',
    ]
    run_refusal("arbitrary command", base[:1] + ["-T"] + base[1:] + ["whoami"])
    run_refusal("empty shell", base[:1] + ["-T"] + base[1:])
    run_refusal("PTY", base[:1] + ["-tt"] + base[1:] + [bridge["command"]])
    run_refusal(
        "SFTP",
        [
            "sftp", "-b", "-", "-oBatchMode=yes", "-oIdentitiesOnly=yes",
            "-oStrictHostKeyChecking=yes", f'-oUserKnownHostsFile={bridge["known_hosts"]}',
            "-oHostKeyAlgorithms=ssh-ed25519", "-oPasswordAuthentication=no",
            "-oKbdInteractiveAuthentication=no", "-P", str(bridge["port"]),
            "-i", str(bridge["identity"]),
            f'{bridge["user"]}@{bridge["host"]}',
        ],
        b"pwd\n",
    )

    forwarding = (
        ("local forwarding", ["-L", "127.0.0.1:45891:127.0.0.1:22"], 45891),
        ("remote forwarding", ["-R", "45892:127.0.0.1:22"], None),
        ("dynamic forwarding", ["-D", "127.0.0.1:45893"], 45893),
        ("stdio forwarding", ["-W", "127.0.0.1:22"], None),
    )
    for label, options, local_port in forwarding:
        run_refusal(
            label,
            base[:1] + ["-T", "-oExitOnForwardFailure=yes"] + options + base[1:],
        )
        if local_port is not None and not port_closed(local_port):
            raise deploy.DeployError(f"{label} left local port {local_port} listening")

    print("Forced-command SSH smoke passed; no registered artifact was sent or deployed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (deploy.DeployError, OSError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
