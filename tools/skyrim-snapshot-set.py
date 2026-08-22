#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import time
import tomllib
from pathlib import Path

TOOLKIT_ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = TOOLKIT_ROOT / "projects"
SNAPSHOT_TOOL = TOOLKIT_ROOT / "tools" / "skyrim-snapshot.py"

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


def resolve_project_from_path(path_value: str):
    path = Path(path_value).expanduser().resolve()
    projects = load_projects()

    matches = []

    for project_id, project in projects.items():
        if project.get("status") != "active":
            continue

        repo = project_repo(project)

        if path_within(path, repo):
            matches.append(
                (len(repo.parts), project_id, project, repo)
            )

    if not matches:
        return None

    matches.sort(reverse=True, key=lambda item: item[0])

    _, project_id, project, repo = matches[0]

    return project_id, project, repo


def snapshot_sets(project: dict) -> dict[str, dict]:
    result = {}

    for item in project.get("snapshot_sets", []):
        set_id = item.get("id")

        if not set_id:
            raise ValueError(
                f"project '{project.get('id')}' has snapshot set without id"
            )

        if set_id in result:
            raise ValueError(
                f"duplicate snapshot set '{set_id}'"
            )

        result[set_id] = item

    return result


def rate_limit_file(project_id: str, set_id: str) -> Path:
    return (
        ARTIFACTS_ROOT
        / project_id
        / "snapshots"
        / "set-state"
        / f"{set_id}.last"
    )


def rate_limited(
    project_id: str,
    set_id: str,
    seconds: int,
) -> bool:
    if seconds <= 0:
        return False

    state = rate_limit_file(project_id, set_id)

    if not state.exists():
        return False

    try:
        last = float(state.read_text().strip())
    except (ValueError, OSError):
        return False

    return (time.time() - last) < seconds


def update_rate_limit(project_id: str, set_id: str):
    state = rate_limit_file(project_id, set_id)
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(str(time.time()))


def collect_files(repo: Path, config: dict) -> list[Path]:
    patterns = config.get("patterns", [])

    if not patterns:
        raise ValueError(
            f"snapshot set '{config.get('id')}' has no patterns"
        )

    cutoff_days = config.get("modified_within_days")
    cutoff = None

    if cutoff_days is not None:
        cutoff = time.time() - (float(cutoff_days) * 86400)

    found = set()

    for pattern in patterns:
        for path in repo.glob(pattern):
            if not path.is_file():
                continue

            if cutoff is not None:
                try:
                    if path.stat().st_mtime < cutoff:
                        continue
                except OSError:
                    continue

            found.add(path.resolve())

    return sorted(found)


def snapshot_one(
    project_id: str,
    path: Path,
    reason: str,
):
    process = subprocess.run(
        [
            str(SNAPSHOT_TOOL),
            "file",
            str(path),
            "--project",
            project_id,
            "--reason",
            reason,
        ],
        text=True,
        capture_output=True,
    )

    if process.returncode != 0:
        raise RuntimeError(
            process.stderr.strip()
            or f"snapshot failed: {path}"
        )

    return json.loads(process.stdout)


def run_set(project_id: str, project: dict, set_id: str, reason: str):
    sets = snapshot_sets(project)

    if set_id not in sets:
        raise ValueError(
            f"unknown snapshot set '{set_id}' for project '{project_id}'"
        )

    config = sets[set_id]
    repo = project_repo(project)

    rate_seconds = int(
        config.get("rate_limit_seconds", 0)
    )

    if rate_limited(project_id, set_id, rate_seconds):
        return {
            "status": "skipped",
            "reason": "rate-limited",
            "project": project_id,
            "set": set_id,
        }

    files = collect_files(repo, config)

    if not files:
        return {
            "status": "skipped",
            "reason": "no-matching-files",
            "project": project_id,
            "set": set_id,
        }

    results = []

    for path in files:
        results.append(
            snapshot_one(
                project_id,
                path,
                f"{reason}:set:{set_id}",
            )
        )

    update_rate_limit(project_id, set_id)

    return {
        "status": "snapshotted",
        "project": project_id,
        "set": set_id,
        "files": len(results),
    }


def trigger_before_command(context_path: str, reason: str):
    resolved = resolve_project_from_path(context_path)

    if resolved is None:
        return {
            "status": "skipped",
            "reason": "context-not-in-registered-project",
            "context": str(
                Path(context_path).expanduser().resolve()
            ),
        }

    project_id, project, _repo = resolved

    configured = (
        project
        .get("snapshots", {})
        .get("before_command", [])
    )

    if not configured:
        return {
            "status": "skipped",
            "reason": "no-before-command-snapshot-sets",
            "project": project_id,
        }

    results = []

    for set_id in configured:
        results.append(
            run_set(
                project_id,
                project,
                set_id,
                reason,
            )
        )

    return {
        "status": "processed",
        "project": project_id,
        "sets": results,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Run project-declared snapshot sets."
    )

    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )

    trigger = subparsers.add_parser(
        "before-command",
        help="run snapshot sets configured for pre-command protection",
    )
    trigger.add_argument(
        "--context",
        required=True,
        help="path used to determine the active registered project",
    )
    trigger.add_argument(
        "--reason",
        default="before-command",
    )

    run = subparsers.add_parser(
        "run",
        help="run one named snapshot set",
    )
    run.add_argument("project")
    run.add_argument("set")
    run.add_argument(
        "--reason",
        default="manual",
    )

    args = parser.parse_args()

    try:
        if args.command == "before-command":
            result = trigger_before_command(
                args.context,
                args.reason,
            )

        elif args.command == "run":
            projects = load_projects()

            if args.project not in projects:
                raise ValueError(
                    f"unknown project: {args.project}"
                )

            project = projects[args.project]

            result = run_set(
                args.project,
                project,
                args.set,
                args.reason,
            )

        else:
            raise ValueError(
                f"unsupported command: {args.command}"
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
