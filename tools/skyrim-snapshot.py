#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import shutil
import sys
import tomllib
from datetime import datetime, timezone
from pathlib import Path

TOOLKIT_ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = TOOLKIT_ROOT / "projects"

# Standard layout:
# ~/skyrim-dev/tooling/skyrim-agent-toolkit
#              ↑
#         workspace root
WORKSPACE_ROOT = Path(
    os.environ.get(
        "SKYRIM_DEV_ROOT",
        TOOLKIT_ROOT.parent.parent,
    )
).resolve()

ARTIFACTS_ROOT = Path(
    os.environ.get(
        "SKYRIM_AGENT_ARTIFACTS",
        WORKSPACE_ROOT / "artifacts",
    )
).resolve()


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def load_projects() -> dict[str, dict]:
    projects = {}

    for config in sorted(PROJECTS_DIR.glob("*.toml")):
        data = load_toml(config)

        project_id = data.get("id")
        if not project_id:
            raise ValueError(f"{config}: missing project id")

        if project_id in projects:
            raise ValueError(f"duplicate project id: {project_id}")

        data["_config"] = str(config)
        projects[project_id] = data

    return projects


def project_repo(project: dict) -> Path:
    value = project.get("repo")
    if not value:
        raise ValueError(
            f"project '{project.get('id', 'unknown')}' has no repository"
        )

    return Path(value).resolve()


def path_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def resolve_source(
    source_value: str,
    requested_project: str | None,
) -> tuple[str, dict, Path, Path]:
    projects = load_projects()

    source = Path(source_value).expanduser()

    if not source.is_absolute():
        source = (Path.cwd() / source).resolve()
    else:
        source = source.resolve()

    if requested_project:
        if requested_project not in projects:
            raise ValueError(f"unknown project: {requested_project}")

        project = projects[requested_project]

        if project.get("status") != "active":
            raise ValueError(
                f"project '{requested_project}' is not active"
            )

        repo = project_repo(project)

        if not path_within(source, repo):
            raise ValueError(
                f"source is outside project '{requested_project}' repository: "
                f"{source}"
            )

        return requested_project, project, repo, source

    matches = []

    for project_id, project in projects.items():
        if project.get("status") != "active":
            continue

        repo = project_repo(project)

        if path_within(source, repo):
            matches.append((len(repo.parts), project_id, project, repo))

    if not matches:
        raise ValueError(
            f"source does not belong to any active registered project: {source}"
        )

    # If repositories are ever nested, the deepest matching repository wins.
    matches.sort(reverse=True, key=lambda item: item[0])
    _, project_id, project, repo = matches[0]

    return project_id, project, repo, source


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)

    return digest.hexdigest()


def snapshot_file(
    source_value: str,
    requested_project: str | None,
    reason: str,
    if_registered: bool = False,
) -> dict:
    try:
        project_id, project, repo, source = resolve_source(
            source_value,
            requested_project,
        )
    except ValueError as exc:
        if (
            if_registered
            and requested_project is None
            and "does not belong to any active registered project" in str(exc)
        ):
            source = Path(source_value).expanduser().resolve()
            return {
                "status": "skipped",
                "reason": "source-not-in-registered-project",
                "source": str(source),
            }
        raise

    if not source.exists():
        return {
            "status": "skipped",
            "reason": "source-does-not-exist",
            "project": project_id,
            "source": str(source),
        }

    if not source.is_file():
        raise ValueError(f"source is not a regular file: {source}")

    relative = source.relative_to(repo)

    timestamp = datetime.now(timezone.utc).strftime(
        "%Y%m%dT%H%M%S.%fZ"
    )

    snapshot_root = (
        ARTIFACTS_ROOT
        / project_id
        / "snapshots"
    )

    destination = (
        snapshot_root
        / "files"
        / timestamp
        / relative
    )

    destination.parent.mkdir(parents=True, exist_ok=True)

    shutil.copy2(source, destination)

    source_hash = sha256(source)
    snapshot_hash = sha256(destination)

    if source_hash != snapshot_hash:
        destination.unlink(missing_ok=True)
        raise RuntimeError(
            f"snapshot verification failed for {source}"
        )

    record = {
        "timestamp": timestamp,
        "project": project_id,
        "project_name": project.get("name", project_id),
        "reason": reason,
        "source": str(source),
        "snapshot": str(destination),
        "sha256": source_hash,
    }

    audit_log = snapshot_root / "audit.jsonl"
    audit_log.parent.mkdir(parents=True, exist_ok=True)

    with audit_log.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")

    return {
        "status": "snapshotted",
        **record,
    }


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Create verified snapshots of files belonging to registered "
            "Skyrim agent projects."
        )
    )

    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )

    file_parser = subparsers.add_parser(
        "file",
        help="snapshot one existing project file",
    )

    file_parser.add_argument("path")

    file_parser.add_argument(
        "--project",
        help=(
            "registered project id; normally omitted because the project "
            "can be inferred from the source path"
        ),
    )

    file_parser.add_argument(
        "--reason",
        default="manual",
        help="short reason recorded in the audit log",
    )

    file_parser.add_argument(
        "--if-registered",
        action="store_true",
        help=(
            "snapshot only when the file belongs to an active registered "
            "project; otherwise return a skipped result"
        ),
    )

    args = parser.parse_args()

    try:
        if args.command == "file":
            result = snapshot_file(
                args.path,
                args.project,
                args.reason,
                args.if_registered,
            )
            print(json.dumps(result, indent=2))

    except (
        ValueError,
        RuntimeError,
        tomllib.TOMLDecodeError,
        OSError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
