#!/usr/bin/env python3
"""Bounded project-aware deployment planning and execution."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import os
import re
import select
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from pathlib import Path, PurePosixPath, PureWindowsPath

from capability_registry import (
    load_catalog,
    require_capability_action,
    require_project_capability,
)

ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = ROOT / "projects"
ENVIRONMENTS_DIR = ROOT / "environments"
CAPABILITIES_DIR = ROOT / "capabilities"
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
DIRECT_BINARY_MOD_EXTENSIONS = {".esp", ".esm", ".esl", ".bsa", ".ba2"}
PROTOCOL_MAGIC = b"HFDEPLOY1\0"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class DeployError(RuntimeError):
    pass


def load_toml(path: Path) -> dict:
    if not path.is_file():
        raise DeployError(f"configuration file not found: {path}")
    with path.open("rb") as stream:
        return tomllib.load(stream)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value: str, field: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise DeployError(f"{field} must be a non-empty relative path")
    normalized = value.replace("\\", "/")
    path = PurePosixPath(normalized)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise DeployError(f"{field} must not be absolute or contain '.'/'..': {value}")
    if any(not part or ":" in part or "\r" in part or "\n" in part for part in path.parts):
        raise DeployError(f"{field} contains an unsafe path component: {value}")
    if path.suffix.lower() in DIRECT_BINARY_MOD_EXTENSIONS:
        raise DeployError(f"{field} is a direct binary mod-file deployment and is not allowed: {value}")
    return path


def resolve_project_environment(project_id: str, environment_id: str) -> tuple[dict, dict]:
    project = load_toml(PROJECTS_DIR / f"{project_id}.toml")
    if project.get("id") != project_id or project.get("status") != "active":
        raise DeployError(f"project {project_id!r} is unknown or inactive")
    if not project.get("capabilities", {}).get("runtime_deployment", False):
        raise DeployError(f"project {project_id!r} has no runtime deployment authorization")
    try:
        capability = require_project_capability(
            project_id,
            project,
            "project-deploy",
            load_catalog(CAPABILITIES_DIR),
        )
        action = require_capability_action("project-deploy", capability, "deploy")
    except ValueError as exc:
        raise DeployError(str(exc)) from exc
    if action.get("handler") != "project-deploy":
        raise DeployError("project-deploy capability has an unexpected handler")
    registered = {
        item.get("id") for item in project.get("environments", [])
        if isinstance(item, dict)
    }
    if environment_id not in registered:
        raise DeployError(
            f"environment {environment_id!r} is not registered for project {project_id!r}"
        )
    environment = load_toml(ENVIRONMENTS_DIR / f"{environment_id}.toml")
    if environment.get("id") != environment_id or environment.get("status") != "active":
        raise DeployError(f"environment {environment_id!r} is unknown or inactive")
    return project, environment


def deployment_sets(project: dict) -> dict[str, dict]:
    sets = project.get("deployment", {}).get("sets", [])
    if not isinstance(sets, list):
        raise DeployError("deployment.sets must be an array of tables")
    result: dict[str, dict] = {}
    for item in sets:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise DeployError("every deployment set must have an id")
        if item["id"] in result:
            raise DeployError(f"duplicate deployment set id: {item['id']}")
        result[item["id"]] = item
    return result


def parse_hash_manifest(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not SHA256_RE.fullmatch(parts[0]):
            raise DeployError(f"invalid SHA256 manifest line {number}: {path}")
        name = parts[1].lstrip(" *").replace("\\", "/")
        rel = safe_relative(name, f"manifest line {number}")
        key = str(rel)
        if key in result:
            raise DeployError(f"duplicate SHA256 manifest entry {key!r}: {path}")
        result[key] = parts[0].lower()
    return result


def parse_source_proof(path: Path) -> str:
    lines = [line for line in path.read_text(errors="strict").splitlines() if line.strip()]
    if len(lines) != 1:
        raise DeployError(f"source proof must contain exactly one SHA256 entry: {path}")
    parts = lines[0].split(maxsplit=1)
    if len(parts) != 2 or not SHA256_RE.fullmatch(parts[0]):
        raise DeployError(f"source proof has an invalid SHA256 entry: {path}")
    filename = PurePosixPath(parts[1].lstrip(" *").replace("\\", "/")).name
    if filename != "hoarfrost-src.tar.gz":
        raise DeployError(f"source proof names an unexpected archive {filename!r}: {path}")
    return parts[0].lower()


def resolve_build_root(project: dict, requested: str | None) -> Path:
    if requested is None:
        raise DeployError("native deployment sets require --build-evidence")
    configured = project.get("build", {}).get("windows_native", {}).get("evidence_root")
    if not isinstance(configured, str) or not configured:
        raise DeployError("project has no registered Windows build evidence root")
    allowed_root = Path(configured).expanduser().resolve()
    candidate = Path(requested).expanduser().resolve()
    try:
        candidate.relative_to(allowed_root)
    except ValueError as exc:
        raise DeployError(
            f"build evidence must be beneath registered root {allowed_root}: {candidate}"
        ) from exc
    required = ("artifacts.sha256", "source.sha256", "build.log")
    missing = [name for name in required if not (candidate / name).is_file()]
    if missing:
        raise DeployError(
            f"build evidence is incomplete at {candidate}; missing: {', '.join(missing)}"
        )
    build_config = project.get("build", {}).get("windows_native", {})
    expected_source = build_config.get("expected_source_sha256")
    if not isinstance(expected_source, str) or not SHA256_RE.fullmatch(expected_source):
        raise DeployError("project has no pinned Windows-build source archive SHA256")
    actual_source = parse_source_proof(candidate / "source.sha256")
    if actual_source != expected_source.lower():
        raise DeployError(
            f"build source proof does not match pinned registry SHA256 "
            f"{expected_source.lower()}: got {actual_source}"
        )
    log = (candidate / "build.log").read_text(errors="replace")
    if "100% tests passed, 0 tests failed out of" not in log or "native build pipeline passed" not in log:
        raise DeployError(f"build log does not prove a passing native pipeline: {candidate / 'build.log'}")
    return candidate


def resolve_artifacts(
    project: dict,
    selected_sets: list[str],
    build_evidence: str | None,
) -> list[dict]:
    repo_value = project.get("repo")
    if not isinstance(repo_value, str):
        raise DeployError("project repository is not registered")
    repo = Path(repo_value).resolve()
    sets = deployment_sets(project)
    unknown = sorted(set(selected_sets) - set(sets))
    if unknown:
        raise DeployError(
            f"unregistered deployment set(s): {', '.join(unknown)}; "
            f"available: {', '.join(sorted(sets)) or 'none'}"
        )
    if len(selected_sets) != len(set(selected_sets)):
        raise DeployError("deployment sets must not be repeated")

    build_root: Path | None = None
    build_manifest: dict[str, str] | None = None
    artifacts: list[dict] = []
    seen_ids: set[str] = set()
    seen_destinations: set[str] = set()

    for set_id in selected_sets:
        config = sets[set_id]
        provenance = config.get("provenance")
        files = config.get("files", [])
        if provenance not in ("repository", "windows-native-build"):
            raise DeployError(f"deployment set {set_id!r} has invalid provenance")
        if not isinstance(files, list) or not files:
            raise DeployError(f"deployment set {set_id!r} has no registered files")
        if provenance == "windows-native-build" and build_root is None:
            build_root = resolve_build_root(project, build_evidence)
            build_manifest = parse_hash_manifest(build_root / "artifacts.sha256")

        for file_config in files:
            if not isinstance(file_config, dict):
                raise DeployError(f"deployment set {set_id!r} has invalid file metadata")
            artifact_id = file_config.get("id")
            if not isinstance(artifact_id, str) or not artifact_id:
                raise DeployError(f"deployment set {set_id!r} has a file without an id")
            if artifact_id in seen_ids:
                raise DeployError(f"duplicate selected artifact id: {artifact_id}")
            seen_ids.add(artifact_id)
            source_rel = safe_relative(file_config.get("source"), f"source for {artifact_id}")
            destination_rel = safe_relative(
                file_config.get("destination"), f"destination for {artifact_id}"
            )
            destination_key = str(destination_rel).casefold()
            if destination_key in seen_destinations:
                raise DeployError(f"duplicate selected destination: {destination_rel}")
            seen_destinations.add(destination_key)

            if provenance == "repository":
                source = (repo / Path(*source_rel.parts)).resolve()
                try:
                    source.relative_to(repo)
                except ValueError as exc:
                    raise DeployError(f"registered source escapes project repository: {source}") from exc
                expected_hash = None
            else:
                assert build_root is not None and build_manifest is not None
                source = (build_root / Path(*source_rel.parts)).resolve()
                try:
                    source.relative_to(build_root)
                except ValueError as exc:
                    raise DeployError(f"registered build source escapes evidence directory: {source}") from exc
                expected_hash = build_manifest.get(str(source_rel))
                if expected_hash is None:
                    raise DeployError(
                        f"build artifact {source_rel} is not proven by {build_root / 'artifacts.sha256'}"
                    )
            if not source.is_file():
                raise DeployError(f"registered deployment source does not exist: {source}")
            digest = sha256_file(source)
            if expected_hash is not None and digest != expected_hash:
                raise DeployError(
                    f"build artifact hash mismatch for {source}: expected {expected_hash}, got {digest}"
                )
            pinned_hash = file_config.get("expected_sha256")
            if provenance == "windows-native-build":
                if not isinstance(pinned_hash, str) or not SHA256_RE.fullmatch(pinned_hash):
                    raise DeployError(f"native artifact {artifact_id} has no pinned registry SHA256")
                if digest != pinned_hash.lower():
                    raise DeployError(
                        f"build artifact {artifact_id} does not match pinned registry SHA256 "
                        f"{pinned_hash.lower()}: got {digest}"
                    )
            artifacts.append({
                "id": artifact_id,
                "set": set_id,
                "provenance": provenance,
                "source": source,
                "destination": str(destination_rel),
                "sha256": digest,
                "size": source.stat().st_size,
            })
    return artifacts


def target_config(project: dict, environment_id: str, target_id: str) -> dict:
    targets = project.get("deployment", {}).get("targets", [])
    matches = [
        item for item in targets
        if isinstance(item, dict)
        and item.get("id") == target_id
        and item.get("environment") == environment_id
    ]
    if not matches:
        raise DeployError(
            f"target {target_id!r} is not registered for project {project.get('id')!r} "
            f"and environment {environment_id!r}"
        )
    if len(matches) != 1:
        raise DeployError(f"deployment target {target_id!r} is ambiguous")
    mod = matches[0].get("mod")
    if (
        not isinstance(mod, str)
        or not mod
        or mod in (".", "..")
        or any(c in mod for c in "/\\:\r\n")
    ):
        raise DeployError(f"deployment target {target_id!r} has an invalid mod directory")
    allowed_sets = matches[0].get("sets")
    if (
        not isinstance(allowed_sets, list)
        or not allowed_sets
        or not all(isinstance(item, str) for item in allowed_sets)
    ):
        raise DeployError(f"deployment target {target_id!r} has no valid set allowlist")
    return matches[0]


def windows_destination(environment: dict, target: dict, relative: str) -> str:
    mods_root = environment.get("deployment", {}).get("mo2_mods_root_windows")
    if not isinstance(mods_root, str) or not mods_root:
        raise DeployError("environment has no registered Windows MO2 mods root")
    root = PureWindowsPath(mods_root)
    return str(root / target["mod"] / PureWindowsPath(relative.replace("/", "\\")))


def evidence_destination(environment: dict, target: dict, relative: str) -> Path:
    root_value = environment.get("deployment", {}).get("mo2_mods_root_evidence")
    if not isinstance(root_value, str) or not root_value:
        raise DeployError("environment has no registered read-only MO2 mods evidence root")
    root = Path(root_value).resolve()
    destination = (root / target["mod"] / Path(*PurePosixPath(relative).parts)).resolve()
    try:
        destination.relative_to(root)
    except ValueError as exc:
        raise DeployError(f"destination escapes registered evidence root: {destination}") from exc
    return destination


def ssh_bridge_config(environment: dict) -> dict:
    bridge = environment.get("bridges", {}).get("project_deploy", {})
    if bridge.get("protocol") != "project-deploy-ssh-v1":
        raise DeployError("environment deployment bridge protocol is not project-deploy-ssh-v1")
    host = bridge.get("host")
    port = bridge.get("port")
    user = bridge.get("user")
    command = bridge.get("command")
    identity_value = bridge.get("identity_file")
    known_hosts_value = bridge.get("known_hosts_file")
    host_key_sha256 = bridge.get("host_key_sha256")
    if not all(isinstance(value, str) and value for value in (
        host, user, command, identity_value, known_hosts_value, host_key_sha256
    )):
        raise DeployError("environment has an incomplete project deployment SSH bridge registration")
    try:
        ipaddress.ip_address(host)
        valid_host = True
    except ValueError:
        valid_host = host.lower().endswith(".ts.net") and not any(c in host for c in "/\\:@\r\n")
    if not valid_host or port != 22 or user != "SkyrimDeploy" or command != "project-deploy-v1":
        raise DeployError("environment project deployment SSH bridge is not the exact bounded endpoint")
    identity = Path(identity_value).expanduser().resolve()
    known_hosts = Path(known_hosts_value).expanduser().resolve()
    for label, filename in (("identity", identity), ("known-hosts", known_hosts)):
        if not filename.is_file():
            raise DeployError(f"dedicated SkyrimDeploy SSH {label} file is absent: {filename}")
        mode = filename.stat().st_mode & 0o777
        if mode & 0o077:
            raise DeployError(f"dedicated SkyrimDeploy SSH {label} permissions are too broad: {oct(mode)}")
    host_lines = [line for line in known_hosts.read_text(errors="strict").splitlines() if line.strip()]
    if len(host_lines) != 1:
        raise DeployError("dedicated project deployment known-hosts file must contain exactly one key")
    host_fields = host_lines[0].split()
    if (
        len(host_fields) < 3
        or host_fields[0] != host
        or host_fields[1] != "ssh-ed25519"
    ):
        raise DeployError("dedicated project deployment known-hosts key is not bound to the exact endpoint")
    fingerprint = subprocess.run(
        ["ssh-keygen", "-lf", str(known_hosts)],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if fingerprint.returncode != 0 or host_key_sha256 not in fingerprint.stdout.split():
        raise DeployError("dedicated project deployment known-hosts key does not match its registry pin")
    return {
        "host": host, "port": port, "user": user, "command": command, "identity": identity,
        "known_hosts": known_hosts, "host_key_sha256": host_key_sha256,
    }


class SshBridgeSession:
    def __init__(self, bridge: dict, timeout: int = 120):
        self.timeout = timeout
        self._received_magic = False
        self._stderr = tempfile.TemporaryFile(mode="w+b")
        argv = [
            "ssh", "-T", "-oBatchMode=yes", "-oIdentitiesOnly=yes",
            "-oStrictHostKeyChecking=yes", f'-oUserKnownHostsFile={bridge["known_hosts"]}',
            "-oHostKeyAlgorithms=ssh-ed25519", "-oPasswordAuthentication=no",
            "-oKbdInteractiveAuthentication=no", "-oPreferredAuthentications=publickey",
            "-oClearAllForwardings=yes", "-oRequestTTY=no", "-oConnectTimeout=15",
            "-p", str(bridge["port"]), "-i", str(bridge["identity"]),
            f'{bridge["user"]}@{bridge["host"]}',
            bridge["command"],
        ]
        try:
            self.process = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self._stderr,
                shell=False,
                bufsize=0,
            )
        except OSError as exc:
            self._stderr.close()
            raise DeployError(f"could not start dedicated deployment SSH transport: {exc}") from exc
        assert self.process.stdin is not None
        self.process.stdin.write(PROTOCOL_MAGIC)
        self.process.stdin.flush()

    def _read_exact(self, length: int, timeout: int) -> bytes:
        if self.process.stdout is None:
            raise DeployError("deployment SSH stdout is unavailable")
        result = bytearray()
        deadline = time.monotonic() + timeout
        while len(result) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.abort()
                raise DeployError(f"deployment SSH transport timed out after {timeout} seconds")
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self.process.stdout.fileno(), length - len(result))
            if not chunk:
                raise DeployError(self._failure("deployment SSH transport returned truncated output"))
            result.extend(chunk)
        return bytes(result)

    def request(self, body: dict, timeout: int | None = None) -> dict:
        if self.process.stdin is None:
            raise DeployError("deployment SSH stdin is unavailable")
        if self.process.poll() is not None:
            raise DeployError(self._failure("deployment SSH transport exited before request"))
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        if len(payload) > 180 * 1024 * 1024:
            raise DeployError("deployment request frame exceeds 180 MiB")
        self.process.stdin.write(struct.pack(">I", len(payload)))
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        wait = self.timeout if timeout is None else timeout
        if not self._received_magic:
            magic = self._read_exact(len(PROTOCOL_MAGIC), wait)
            if magic != PROTOCOL_MAGIC:
                raise DeployError("deployment SSH stdout was contaminated before protocol magic")
            self._received_magic = True
        length = struct.unpack(">I", self._read_exact(4, wait))[0]
        if length < 2 or length > MAX_RESPONSE_BYTES:
            raise DeployError(f"deployment SSH response frame has invalid length: {length}")
        raw = self._read_exact(length, wait)
        try:
            result = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise DeployError("deployment SSH transport returned invalid framed JSON") from exc
        if not isinstance(result, dict) or result.get("ok") is not True:
            error = result.get("error", "unknown error") if isinstance(result, dict) else "non-object result"
            raise DeployError(f"deployment worker rejected the request: {error}")
        if result.get("operation") != body.get("operation"):
            raise DeployError("deployment SSH response operation does not match its request")
        request_id = result.get("request_id")
        try:
            parsed_request_id = uuid.UUID(request_id)
        except (AttributeError, TypeError, ValueError) as exc:
            raise DeployError("deployment SSH response has no valid request id") from exc
        if str(parsed_request_id) != request_id:
            raise DeployError("deployment SSH response request id is not canonical")
        return result

    def finish(self) -> None:
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            code = self.process.wait(timeout=30)
        except subprocess.TimeoutExpired as exc:
            self.abort()
            raise DeployError("deployment SSH transport did not exit after the fixed request") from exc
        if code != 0:
            raise DeployError(self._failure(f"deployment SSH transport exited with status {code}"))
        self._stderr.close()

    def abort(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        self._stderr.close()

    def _failure(self, prefix: str) -> str:
        self._stderr.flush()
        self._stderr.seek(0)
        detail = self._stderr.read(2000).decode("utf-8", errors="replace").strip()
        return f"{prefix}: {detail}" if detail else prefix

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        if exc_type is None:
            self.finish()
        else:
            self.abort()


def protocol_request(operation: str, body: dict) -> dict:
    return {"protocol": "project-deploy-v1", "operation": operation, **body}


def request_payload(project_id: str, environment_id: str, target_id: str, artifacts: list[dict]) -> dict:
    return {
        "project": project_id,
        "environment": environment_id,
        "target": target_id,
        "artifacts": [
            {
                "id": item["id"],
                "destination": item["destination"],
                "sha256": item["sha256"],
                "size": item["size"],
            }
            for item in artifacts
        ],
    }


def print_source(environment: dict, target: dict, item: dict) -> None:
    print(f"Artifact:             {item['id']}")
    print(f"  provenance:         {item['provenance']}")
    print(f"  source:             {item['source']}")
    print(f"  source SHA256:      {item['sha256']}")
    print(f"  destination:        {windows_destination(environment, target, item['destination'])}")


def dry_run(environment: dict, target: dict, artifacts: list[dict]) -> None:
    for item in artifacts:
        print_source(environment, target, item)
        observed = evidence_destination(environment, target, item["destination"])
        if observed.is_file():
            existing = sha256_file(observed)
            print(f"  existing path:      {observed} (read-only evidence)")
            print(f"  existing SHA256:    {existing}")
        elif observed.exists():
            raise DeployError(f"registered destination is not a file: {observed}")
        else:
            print(f"  existing path:      {observed} (absent in read-only evidence)")
            print("  existing SHA256:    absent")
        print(f"  resulting SHA256:   {item['sha256']} (planned; no copy performed)")
        print()
    print("Dry run only; no ASSOS file was changed.")
    print("The apply bridge will re-read destination hashes immediately before copying.")


def apply_deployment(
    project_id: str,
    environment_id: str,
    target_id: str,
    environment: dict,
    target: dict,
    artifacts: list[dict],
) -> None:
    bridge = ssh_bridge_config(environment)
    with SshBridgeSession(bridge) as session:
        plan = session.request(protocol_request(
            "plan", request_payload(project_id, environment_id, target_id, artifacts)
        ))
        before = plan.get("artifacts")
        if not isinstance(before, list) or len(before) != len(artifacts):
            raise DeployError("deployment bridge returned an incomplete plan")

        before_by_id = {item.get("id"): item for item in before}
        if len(before_by_id) != len(before):
            raise DeployError("deployment bridge returned duplicate artifact ids")
        for artifact in artifacts:
            item = before_by_id.get(artifact["id"])
            if item is None:
                raise DeployError(f"deployment bridge omitted artifact {artifact['id']}")
            if item.get("source_sha256") != artifact["sha256"]:
                raise DeployError(f"deployment bridge source hash mismatch for {artifact['id']}")
            expected_destination = windows_destination(environment, target, artifact["destination"])
            if str(item.get("destination", "")).casefold() != expected_destination.casefold():
                raise DeployError(f"deployment bridge destination mismatch for {artifact['id']}")
            print_source(environment, target, artifact)
            print(f"  bridge existing:    {item.get('destination')}")
            print(f"  existing SHA256:    {item.get('existing_sha256') or 'absent'}")
            print()

        token = plan.get("token")
        if not isinstance(token, str) or not token:
            raise DeployError("deployment bridge returned no plan token")
        body = {
            "token": token,
            "artifacts": [
                {
                    "id": item["id"],
                    "sha256": item["sha256"],
                    "content_base64": base64.b64encode(item["source"].read_bytes()).decode("ascii"),
                }
                for item in artifacts
            ],
        }
        result = session.request(protocol_request("apply", body), timeout=300)
    deployed = result.get("artifacts")
    if not isinstance(deployed, list) or len(deployed) != len(artifacts):
        raise DeployError("deployment bridge returned an incomplete result")
    deployed_by_id = {item.get("id"): item for item in deployed}
    if len(deployed_by_id) != len(deployed):
        raise DeployError("deployment bridge returned duplicate result artifact ids")
    for artifact in artifacts:
        item = deployed_by_id.get(artifact["id"])
        if item is None:
            raise DeployError(f"deployment bridge omitted result for {artifact['id']}")
        expected_destination = windows_destination(environment, target, artifact["destination"])
        if str(item.get("destination", "")).casefold() != expected_destination.casefold():
            raise DeployError(f"deployment bridge result destination mismatch for {artifact['id']}")
        if item.get("resulting_sha256") != artifact["sha256"]:
            raise DeployError(f"deployment bridge resulting hash mismatch for {artifact['id']}")
        print(f"Deployed:             {item['destination']}")
        print(f"  resulting SHA256:   {item['resulting_sha256']}")
        if item.get("backup"):
            print(f"  backup:             {item['backup']}")
        print()


def run(args: argparse.Namespace) -> int:
    project, environment = resolve_project_environment(args.project, args.environment)
    target = target_config(project, args.environment, args.target)
    disallowed_sets = sorted(set(args.sets) - set(target["sets"]))
    if disallowed_sets:
        raise DeployError(
            f"deployment set(s) not allowed for target {args.target!r}: "
            + ", ".join(disallowed_sets)
        )
    artifacts = resolve_artifacts(project, args.sets, args.build_evidence)
    if not artifacts:
        raise DeployError("at least one registered --set is required")

    print(f"Project:              {project.get('name', args.project)} ({args.project})")
    print(f"Environment:          {environment.get('name', args.environment)} ({args.environment})")
    print(f"Target:               {target['mod']} ({args.target})")
    print()
    if args.apply:
        apply_deployment(
            args.project, args.environment, args.target,
            environment, target, artifacts,
        )
    else:
        dry_run(environment, target, artifacts)
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deploy explicitly registered project-owned files")
    parser.add_argument("project", help="registered project id")
    parser.add_argument("--environment", required=True, help="registered project environment")
    parser.add_argument("--target", required=True, help="registered deployment target id")
    parser.add_argument("--set", action="append", dest="sets", required=True, help="registered deployment set; may be repeated")
    parser.add_argument("--build-evidence", help="registered Windows build evidence directory for native sets")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="plan only (the safe default)")
    mode.add_argument("--apply", action="store_true", help="copy through the constrained deployment bridge")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        return run(parse_args(argv))
    except (DeployError, OSError, UnicodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
