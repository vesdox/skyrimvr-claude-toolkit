#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = ROOT / "projects"
ENVIRONMENTS_DIR = ROOT / "environments"
CAPABILITIES_DIR = ROOT / "capabilities"

WORKSPACE_ROOT = Path(
    os.environ.get(
        "SKYRIM_DEV_ROOT",
        ROOT.parent.parent,
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


def path_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def load_project(project_id: str) -> dict:
    path = PROJECTS_DIR / f"{project_id}.toml"

    if not path.is_file():
        raise ValueError(f"unknown project: {project_id}")

    project = load_toml(path)

    if project.get("id") != project_id:
        raise ValueError(
            f"{path}: project id does not match filename"
        )

    if project.get("status") != "active":
        raise ValueError(
            f"project '{project_id}' is not active"
        )

    return project


def load_spriggit() -> dict:
    path = CAPABILITIES_DIR / "spriggit.toml"

    if not path.is_file():
        raise ValueError("Spriggit capability definition is missing")

    capability = load_toml(path)

    if capability.get("status") != "available":
        raise ValueError(
            "Spriggit inspection capability is not available"
        )

    return capability


def require_grant(project: dict):
    granted = (
        project
        .get("capability_grants", {})
        .get("allow", [])
    )

    if "spriggit" not in granted:
        raise ValueError(
            f"project '{project.get('id')}' is not granted Spriggit inspection"
        )


def authorized_roots(project: dict) -> list[tuple[str, Path]]:
    roots = []

    repo = project.get("repo")

    if repo:
        roots.append(
            ("project-source", Path(repo).resolve())
        )

    for reference in project.get("environments", []):
        environment_id = reference.get("id")

        if not environment_id:
            continue

        config = ENVIRONMENTS_DIR / f"{environment_id}.toml"

        if not config.is_file():
            continue

        environment = load_toml(config)

        for name, value in environment.get("evidence", {}).items():
            if isinstance(value, str) and value:
                roots.append(
                    (
                        f"environment-evidence:{environment_id}:{name}",
                        Path(value).resolve(),
                    )
                )

    return roots


def authorize_input(plugin: Path, project: dict) -> str:
    matches = []

    for label, root in authorized_roots(project):
        if path_within(plugin, root):
            matches.append((len(root.parts), label))

    if not matches:
        raise ValueError(
            "plugin is outside the project repository and its registered "
            f"environment evidence: {plugin}"
        )

    matches.sort(reverse=True)

    return matches[0][1]


def summarize_yaml(root: Path) -> dict[str, int]:
    groups = {}

    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue

        count = sum(
            1
            for path in child.rglob("*.yaml")
            if path.is_file()
        )

        if count:
            groups[child.name] = count

    return groups


def inspect_plugin(project_id: str, plugin_value: str) -> dict:
    project = load_project(project_id)
    capability = load_spriggit()
    require_grant(project)

    plugin = Path(plugin_value).expanduser().resolve()

    if not plugin.is_file():
        raise ValueError(f"plugin does not exist: {plugin}")

    if plugin.suffix.lower() not in {".esp", ".esm", ".esl"}:
        raise ValueError(
            f"not a Skyrim plugin: {plugin}"
        )

    source_kind = authorize_input(plugin, project)

    implementation = capability.get("implementation", {})

    package_version = implementation.get("package_version")
    game_release = implementation.get("game_release")
    format_package = implementation.get("format_package")

    if not all(
        (
            package_version,
            game_release,
            format_package,
        )
    ):
        raise ValueError(
            "Spriggit implementation metadata is incomplete"
        )

    timestamp = datetime.now(timezone.utc).strftime(
        "%Y%m%dT%H%M%S.%fZ"
    )

    final_dir = (
        ARTIFACTS_ROOT
        / project_id
        / "spriggit"
        / f"{timestamp}__{plugin.stem}"
    )

    final_dir.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with tempfile.TemporaryDirectory(
        prefix="spriggit-",
        dir=final_dir.parent,
    ) as temp_value:
        temp_dir = Path(temp_value)

        command = [
            "dotnet",
            "tool",
            "run",
            "spriggit",
            "serialize",
            "--InputPath",
            str(plugin),
            "--OutputPath",
            str(temp_dir),
            "--GameRelease",
            game_release,
            "--PackageName",
            format_package,
            "--PackageVersion",
            package_version,
        ]

        process = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        if process.returncode != 0:
            stderr = process.stderr.strip()
            stdout = process.stdout.strip()

            detail = stderr or stdout or "no diagnostic output"

            raise RuntimeError(
                "Spriggit serialization failed. "
                "If this is a localized plugin, the Linux limitation may "
                f"apply.\n\n{detail}"
            )

        groups = summarize_yaml(temp_dir)

        shutil.copytree(
            temp_dir,
            final_dir,
        )

    record = {
        "project": project_id,
        "plugin": str(plugin),
        "source_kind": source_kind,
        "artifact": str(final_dir),
        "record_groups": groups,
        "record_count": sum(groups.values()),
        "spriggit_package_version": package_version,
    }

    metadata = final_dir / "_inspection.json"

    metadata.write_text(
        json.dumps(
            record,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )

    return record


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Inspect a registered project's Skyrim plugin with "
            "the shared Spriggit capability."
        )
    )

    parser.add_argument("project")
    parser.add_argument("plugin")

    args = parser.parse_args()

    try:
        result = inspect_plugin(
            args.project,
            args.plugin,
        )

        print(
            json.dumps(
                result,
                indent=2,
            )
        )

    except (
        ValueError,
        RuntimeError,
        OSError,
        tomllib.TOMLDecodeError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
