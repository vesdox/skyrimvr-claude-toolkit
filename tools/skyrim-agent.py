#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = ROOT / "projects"
ENVIRONMENTS_DIR = ROOT / "environments"


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def load_registry(directory: Path) -> dict[str, dict]:
    registry = {}

    for path in sorted(directory.glob("*.toml")):
        data = load_toml(path)

        item_id = data.get("id")
        if not item_id:
            raise ValueError(f"{path}: missing required 'id'")

        if item_id in registry:
            raise ValueError(
                f"duplicate id '{item_id}' in {path} "
                f"and {registry[item_id]['_file']}"
            )

        data["_file"] = str(path)
        registry[item_id] = data

    return registry


def registries():
    return (
        load_registry(PROJECTS_DIR),
        load_registry(ENVIRONMENTS_DIR),
    )


def resolve_project(project_id: str) -> dict:
    projects, environments = registries()

    if project_id not in projects:
        raise ValueError(f"unknown project: {project_id}")

    project = dict(projects[project_id])

    resolved_environments = []

    for reference in project.get("environments", []):
        env_id = reference.get("id")

        if not env_id:
            raise ValueError(
                f"project '{project_id}' has an environment reference without an id"
            )

        if env_id not in environments:
            raise ValueError(
                f"project '{project_id}' references unknown environment '{env_id}'"
            )

        resolved = dict(environments[env_id])
        resolved["_role"] = reference.get("role")
        resolved_environments.append(resolved)

    project["_resolved_environments"] = resolved_environments
    return project



def get_native_build(project_id: str):
    project = resolve_project(project_id)

    if project.get("status") != "active":
        raise ValueError(
            f"project '{project_id}' is not active"
        )

    capabilities = project.get("capabilities", {})
    if not capabilities.get("windows_native_build", False):
        raise ValueError(
            f"project '{project_id}' does not permit Windows native builds"
        )

    repo_value = project.get("repo")
    if not repo_value:
        raise ValueError(
            f"project '{project_id}' has no repository path"
        )

    repo = Path(repo_value).resolve()

    if not repo.is_dir():
        raise ValueError(
            f"project '{project_id}' repository does not exist: {repo}"
        )

    build_config = project.get("build", {}).get("windows_native", {})
    command = build_config.get("command")

    if not command:
        raise ValueError(
            f"project '{project_id}' has no Windows native build command"
        )

    command_path = Path(command)

    if command_path.is_absolute():
        raise ValueError(
            f"project '{project_id}' build command must be repository-relative"
        )

    script = (repo / command_path).resolve()

    try:
        script.relative_to(repo)
    except ValueError:
        raise ValueError(
            f"project '{project_id}' build command escapes its repository: {script}"
        )

    if not script.is_file():
        raise ValueError(
            f"project '{project_id}' build command does not exist: {script}"
        )

    if not os.access(script, os.X_OK):
        raise ValueError(
            f"project '{project_id}' build command is not executable: {script}"
        )

    return project, repo, script



def validate() -> list[str]:
    projects, environments = registries()
    errors = []

    for project_id, project in projects.items():
        repo = project.get("repo")
        status = project.get("status")

        if not repo:
            errors.append(f"{project_id}: missing repo")
        elif status == "active" and not Path(repo).is_dir():
            errors.append(
                f"{project_id}: active project repo does not exist: {repo}"
            )

        for reference in project.get("environments", []):
            env_id = reference.get("id")

            if not env_id:
                errors.append(
                    f"{project_id}: environment reference missing id"
                )
            elif env_id not in environments:
                errors.append(
                    f"{project_id}: unknown environment '{env_id}'"
                )

    return errors


def cmd_list(_args):
    projects, environments = registries()

    print("Projects:")
    for item_id, project in projects.items():
        print(
            f"  {item_id:<16} "
            f"{project.get('status', 'unknown'):<10} "
            f"{project.get('name', '')}"
        )

    print()
    print("Environments:")
    for item_id, environment in environments.items():
        print(
            f"  {item_id:<16} "
            f"{environment.get('status', 'unknown'):<10} "
            f"{environment.get('name', '')}"
        )


def cmd_show(args):
    project = resolve_project(args.project)
    print(json.dumps(project, indent=2))



def cmd_build(args):
    project, repo, script = get_native_build(args.project)

    print(f"Project:      {project.get('name', args.project)}")
    print(f"Repository:   {repo}")
    print(f"Native build: {script}")

    if args.dry_run:
        print("Dry run only; build was not started.")
        return

    result = subprocess.run(
        [str(script)],
        cwd=repo,
    )

    raise SystemExit(result.returncode)



def cmd_validate(_args):
    errors = validate()

    if errors:
        print("Registry validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        raise SystemExit(1)

    print("Registry validation passed.")


def main():
    parser = argparse.ArgumentParser(
        description="Resolve Skyrim agent projects and environments."
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list")
    list_parser.set_defaults(func=cmd_list)

    show_parser = subparsers.add_parser("show")
    show_parser.add_argument("project")
    show_parser.set_defaults(func=cmd_show)

    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("project")
    build_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="resolve and validate the build without running it",
    )
    build_parser.set_defaults(func=cmd_build)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.set_defaults(func=cmd_validate)

    args = parser.parse_args()

    try:
        args.func(args)
    except (ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
