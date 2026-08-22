from pathlib import Path
import tomllib


PLUGIN_EXTENSIONS = {
    ".esp",
    ".esm",
    ".esl",
}


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def load_environment_for_project(
    project: dict,
    environment_id: str,
    environments_dir: Path,
) -> dict:
    references = project.get("environments", [])

    registered = {
        item.get("id")
        for item in references
        if isinstance(item, dict)
    }

    if environment_id not in registered:
        raise ValueError(
            f"environment '{environment_id}' is not registered "
            f"for project '{project.get('id')}'"
        )

    config = environments_dir / f"{environment_id}.toml"

    if not config.is_file():
        raise ValueError(
            f"environment definition does not exist: {config}"
        )

    environment = load_toml(config)

    if environment.get("id") != environment_id:
        raise ValueError(
            f"{config}: environment id does not match filename"
        )

    if environment.get("status") != "active":
        raise ValueError(
            f"environment '{environment_id}' is not active"
        )

    return environment


def mod_roots(environment: dict) -> list[Path]:
    value = (
        environment
        .get("evidence", {})
        .get("mods")
    )

    if not isinstance(value, str) or not value:
        raise ValueError(
            f"environment '{environment.get('id')}' "
            "has no registered mods evidence path"
        )

    configured = Path(value).expanduser().resolve()

    if not configured.is_dir():
        raise ValueError(
            f"registered mods evidence path does not exist: {configured}"
        )

    candidates = []

    # Some environments register the MO2 mods directory itself.
    candidates.append(configured)

    # Others register the enclosing MO2/modlist directory.
    nested = configured / "mods"

    if nested.is_dir():
        candidates.insert(0, nested.resolve())

    result = []

    for candidate in candidates:
        if candidate not in result:
            result.append(candidate)

    return result


def resolve_mod_directory(
    environment: dict,
    mod_name: str,
) -> Path:
    requested = mod_name.casefold()
    matches = []

    for root in mod_roots(environment):
        exact = root / mod_name

        if exact.is_dir():
            matches.append(exact.resolve())
            continue

        try:
            children = root.iterdir()
        except OSError:
            continue

        for child in children:
            if (
                child.is_dir()
                and child.name.casefold() == requested
            ):
                matches.append(child.resolve())

    unique = []

    for match in matches:
        if match not in unique:
            unique.append(match)

    if not unique:
        searched = "\n".join(
            f"  {root}"
            for root in mod_roots(environment)
        )

        raise ValueError(
            f"mod '{mod_name}' was not found in environment "
            f"'{environment.get('id')}'. Searched:\n{searched}"
        )

    if len(unique) > 1:
        options = "\n".join(
            f"  {path}"
            for path in unique
        )

        raise ValueError(
            f"mod name '{mod_name}' is ambiguous:\n{options}"
        )

    return unique[0]


def plugin_files(mod_dir: Path) -> list[Path]:
    plugins = {
        path.resolve()
        for path in mod_dir.rglob("*")
        if (
            path.is_file()
            and path.suffix.lower() in PLUGIN_EXTENSIONS
        )
    }

    return sorted(
        plugins,
        key=lambda path: str(path).casefold(),
    )


def choose_plugin(
    mod_dir: Path,
    plugin_name: str | None,
) -> Path:
    plugins = plugin_files(mod_dir)

    if not plugins:
        raise ValueError(
            f"mod '{mod_dir.name}' contains no ESP/ESM/ESL files"
        )

    if plugin_name:
        requested = plugin_name.replace("\\", "/").casefold()

        matches = []

        for plugin in plugins:
            relative = (
                str(plugin.relative_to(mod_dir))
                .replace("\\", "/")
                .casefold()
            )

            if (
                plugin.name.casefold() == requested
                or relative == requested
            ):
                matches.append(plugin)

        if not matches:
            available = "\n".join(
                f"  {plugin.relative_to(mod_dir)}"
                for plugin in plugins[:30]
            )

            raise ValueError(
                f"plugin '{plugin_name}' was not found in "
                f"mod '{mod_dir.name}'. Available plugins:\n"
                f"{available}"
            )

        if len(matches) > 1:
            available = "\n".join(
                f"  {plugin.relative_to(mod_dir)}"
                for plugin in matches
            )

            raise ValueError(
                f"plugin name '{plugin_name}' is ambiguous:\n"
                f"{available}"
            )

        return matches[0]

    if len(plugins) == 1:
        return plugins[0]

    available = "\n".join(
        f"  {plugin.relative_to(mod_dir)}"
        for plugin in plugins[:30]
    )

    extra = ""

    if len(plugins) > 30:
        extra = f"\n  ... and {len(plugins) - 30} more"

    raise ValueError(
        f"mod '{mod_dir.name}' contains {len(plugins)} plugins. "
        "Specify --plugin.\n"
        f"{available}{extra}"
    )


def resolve_plugin(
    project: dict,
    environment_id: str,
    mod_name: str,
    plugin_name: str | None,
    environments_dir: Path,
) -> dict:
    environment = load_environment_for_project(
        project,
        environment_id,
        environments_dir,
    )

    mod_dir = resolve_mod_directory(
        environment,
        mod_name,
    )

    plugin = choose_plugin(
        mod_dir,
        plugin_name,
    )

    return {
        "project": project.get("id"),
        "environment": environment_id,
        "runtime": environment.get("runtime"),
        "mod": mod_dir.name,
        "mod_directory": mod_dir,
        "plugin": plugin,
    }
