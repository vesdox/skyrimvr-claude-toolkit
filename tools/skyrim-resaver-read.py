#!/usr/bin/env python3

import argparse
import subprocess
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = ROOT / "projects"
ENVIRONMENTS_DIR = ROOT / "environments"
RESAVER = ROOT / "tools" / "resaver-cli.sh"

READ_ACTIONS = {
    "info",
    "worries",
    "freeze-report",
}


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def load_project(project_id: str) -> dict:
    path = PROJECTS_DIR / f"{project_id}.toml"

    if not path.is_file():
        raise ValueError(
            f"unknown project: {project_id}"
        )

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


def load_environment(
    project: dict,
    environment_id: str,
) -> dict:
    registered = {
        item.get("id")
        for item in project.get("environments", [])
        if isinstance(item, dict)
    }

    if environment_id not in registered:
        raise ValueError(
            f"environment '{environment_id}' is not registered "
            f"for project '{project.get('id')}'"
        )

    path = ENVIRONMENTS_DIR / f"{environment_id}.toml"

    if not path.is_file():
        raise ValueError(
            f"environment definition does not exist: {path}"
        )

    environment = load_toml(path)

    if environment.get("id") != environment_id:
        raise ValueError(
            f"{path}: environment id does not match filename"
        )

    if environment.get("status") != "active":
        raise ValueError(
            f"environment '{environment_id}' is not active"
        )

    return environment


def saves_root(environment: dict) -> Path:
    value = (
        environment
        .get("evidence", {})
        .get("saves")
    )

    if not isinstance(value, str) or not value:
        raise ValueError(
            f"environment '{environment.get('id')}' "
            "has no registered saves evidence path"
        )

    root = Path(value).expanduser().resolve()

    if not root.is_dir():
        raise ValueError(
            f"registered saves path does not exist: {root}"
        )

    return root


def is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def resolve_save(root: Path, requested: str) -> Path:
    if not requested.strip():
        raise ValueError("save name must not be empty")

    # Do not accept arbitrary absolute paths.
    supplied = Path(requested.replace("\\", "/"))

    if supplied.is_absolute():
        raise ValueError(
            "absolute save paths are not accepted; "
            "use a filename or path relative to the registered "
            "saves evidence root"
        )

    direct = (root / supplied).resolve()

    if not is_within(direct, root):
        raise ValueError(
            "save path escapes the registered saves evidence root"
        )

    if direct.is_file():
        if direct.suffix.lower() != ".ess":
            raise ValueError(
                "ReSaver read capability accepts only .ess save files"
            )

        return direct

    # Friendly mode: a bare filename may be anywhere underneath
    # the registered saves evidence root.
    if len(supplied.parts) == 1:
        requested_name = supplied.name.casefold()
        matches = []

        for candidate in root.rglob("*"):
            if (
                candidate.is_file()
                and candidate.suffix.lower() == ".ess"
                and candidate.name.casefold() == requested_name
            ):
                resolved = candidate.resolve()

                if is_within(resolved, root):
                    matches.append(resolved)

        matches = sorted(
            set(matches),
            key=lambda path: str(path).casefold(),
        )

        if len(matches) == 1:
            return matches[0]

        if len(matches) > 1:
            options = "\n".join(
                f"  {path.relative_to(root)}"
                for path in matches
            )

            raise ValueError(
                f"save name '{requested}' is ambiguous:\n{options}"
            )

    raise ValueError(
        f"save '{requested}' was not found inside registered "
        f"saves evidence for this environment"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run an authorized read-only ReSaver operation."
    )
    parser.add_argument("project")
    parser.add_argument(
        "action",
        choices=sorted(READ_ACTIONS),
    )
    parser.add_argument(
        "--environment",
        required=True,
        help="registered active project environment",
    )
    parser.add_argument(
        "--save",
        required=True,
        help=(
            "save filename or path relative to the environment's "
            "registered saves evidence root"
        ),
    )

    args = parser.parse_args()

    try:
        project = load_project(args.project)
        environment = load_environment(
            project,
            args.environment,
        )
        root = saves_root(environment)
        save = resolve_save(root, args.save)
    except ValueError as exc:
        print(
            f"error: {exc}",
            file=sys.stderr,
        )
        return 2

    if not RESAVER.is_file():
        print(
            f"error: ReSaver wrapper is unavailable: {RESAVER}",
            file=sys.stderr,
        )
        return 2

    process = subprocess.run(
        [
            "bash",
            str(RESAVER),
            args.action,
            str(save),
        ],
        cwd=ROOT,
    )

    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
