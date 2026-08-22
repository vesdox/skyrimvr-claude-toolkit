from datetime import datetime, timezone
from pathlib import Path

from plugin_locator import load_environment_for_project


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
            f"registered saves evidence path does not exist: {root}"
        )

    return root


def is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def list_saves(
    project: dict,
    environment_id: str,
    environments_dir: Path,
    search: str | None = None,
    latest: int = 10,
) -> list[dict]:
    if latest < 1:
        raise ValueError("--latest must be at least 1")

    environment = load_environment_for_project(
        project,
        environment_id,
        environments_dir,
    )

    root = saves_root(environment)

    needle = (
        search.casefold()
        if search and search.strip()
        else None
    )

    results = []

    for candidate in root.rglob("*.ess"):
        if not candidate.is_file():
            continue

        resolved = candidate.resolve()

        if not is_within(resolved, root):
            continue

        relative = resolved.relative_to(root)

        if needle:
            searchable = (
                f"{resolved.name} {relative}"
            ).casefold()

            if needle not in searchable:
                continue

        stat = resolved.stat()

        cosave = resolved.with_suffix(".skse")

        results.append(
            {
                "name": resolved.name,
                "relative_path": str(relative),
                "modified_utc": datetime.fromtimestamp(
                    stat.st_mtime,
                    timezone.utc,
                ).isoformat(timespec="seconds"),
                "modified_epoch": stat.st_mtime,
                "size_bytes": stat.st_size,
                "skse_cosave": cosave.is_file(),
            }
        )

    results.sort(
        key=lambda item: (
            -item["modified_epoch"],
            item["name"].casefold(),
        )
    )

    return results[:latest]
