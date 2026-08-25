#!/usr/bin/env python3
"""Export the constrained Windows deployment allowlist from shared registries."""

import argparse
import hashlib
import json
import re
import tomllib
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parent.parent
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict:
    with path.open("rb") as stream:
        return tomllib.load(stream)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--environment", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()

    env_path = ROOT / "environments" / f"{args.environment}.toml"
    environment = load(env_path)
    if environment.get("id") != args.environment or environment.get("status") != "active":
        raise SystemExit(f"error: environment {args.environment!r} is unknown or inactive")

    deployment = environment.get("deployment", {})
    mods_root = deployment.get("mo2_mods_root_windows")
    bridge = environment.get("bridges", {}).get("project_deploy", {})
    backup_root = bridge.get("backup_root_windows")
    if not isinstance(mods_root, str) or not isinstance(backup_root, str):
        raise SystemExit("error: environment deployment roots are not fully configured")

    targets = {}
    physical_targets = {}
    for project_path in sorted((ROOT / "projects").glob("*.toml")):
        project = load(project_path)
        project_id = project.get("id")
        if project.get("status") != "active" or not project.get("capabilities", {}).get("runtime_deployment"):
            continue
        if "project-deploy" not in project.get("capability_grants", {}).get("allow", []):
            continue
        registered_envs = {
            item.get("id") for item in project.get("environments", [])
            if isinstance(item, dict)
        }
        if args.environment not in registered_envs:
            continue

        sets = {}
        for file_set in project.get("deployment", {}).get("sets", []):
            set_id = file_set.get("id")
            if not isinstance(set_id, str) or set_id in sets:
                raise SystemExit(f"error: invalid or duplicate deployment set in {project_path}")
            sets[set_id] = file_set

        for target in project.get("deployment", {}).get("targets", []):
            if target.get("environment") != args.environment:
                continue
            target_id = target.get("id")
            mod = target.get("mod")
            allowed_sets = target.get("sets")
            if (
                not isinstance(target_id, str)
                or not isinstance(mod, str)
                or not mod
                or mod in (".", "..")
                or any(character in mod for character in "/\\:\r\n")
                or not isinstance(allowed_sets, list)
                or not allowed_sets
            ):
                raise SystemExit(f"error: invalid deployment target in {project_path}")
            artifact_map = {}
            for set_id in allowed_sets:
                if set_id not in sets:
                    raise SystemExit(f"error: target references unknown set {set_id!r} in {project_path}")
                file_set = sets[set_id]
                provenance = file_set.get("provenance")
                for item in file_set.get("files", []):
                    artifact_id = item.get("id")
                    destination = item.get("destination")
                    source = item.get("source")
                    if not all(isinstance(value, str) for value in (artifact_id, destination, source)):
                        raise SystemExit(f"error: invalid deployment file metadata in {project_path}")
                    if artifact_id in artifact_map:
                        raise SystemExit(f"error: duplicate artifact id {artifact_id!r} in target")
                    if provenance == "repository":
                        repo = Path(project.get("repo", "")).resolve()
                        source_path = (repo / source).resolve()
                        try:
                            source_path.relative_to(repo)
                        except ValueError:
                            raise SystemExit(f"error: repository source escapes project: {source}")
                        if not source_path.is_file():
                            raise SystemExit(f"error: repository source does not exist: {source_path}")
                        expected_hash = sha256_file(source_path)
                    elif provenance == "windows-native-build":
                        expected_hash = item.get("expected_sha256")
                        if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
                            raise SystemExit(f"error: native artifact {artifact_id!r} has no pinned SHA256")
                        expected_hash = expected_hash.lower()
                    else:
                        raise SystemExit(f"error: invalid deployment provenance for {set_id!r}")
                    artifact_map[artifact_id] = {
                        "destination": destination.replace("/", "\\"),
                        "sha256": expected_hash,
                    }
            key = f"{project_id}:{target_id}"
            if key in targets:
                raise SystemExit(f"error: duplicate deployment target {key}")
            target_root = PureWindowsPath(mods_root) / mod
            physical_key = str(target_root).casefold()
            if physical_key in physical_targets:
                raise SystemExit(
                    f"error: physical deployment target {target_root} is also registered by "
                    f"{physical_targets[physical_key]}"
                )
            physical_targets[physical_key] = key
            targets[key] = {
                "project": project_id,
                "environment": args.environment,
                "target": target_id,
                "root": str(target_root),
                "artifacts": artifact_map,
            }

    result = {
        "schema": 1,
        "environment": args.environment,
        "backup_root": backup_root,
        "targets": targets,
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(text)
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
