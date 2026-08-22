from pathlib import Path
import tomllib


VALID_STATUS = {
    "unconfigured",
    "available",
    "disabled",
}


def load_catalog(capabilities_dir: Path) -> dict[str, dict]:
    catalog = {}

    for path in sorted(capabilities_dir.glob("*.toml")):
        with path.open("rb") as f:
            data = tomllib.load(f)

        capability_id = data.get("id")

        if not capability_id:
            raise ValueError(f"{path}: missing capability id")

        if capability_id in catalog:
            raise ValueError(
                f"duplicate capability id '{capability_id}'"
            )

        data["_config"] = str(path)
        catalog[capability_id] = data

    return catalog


def allowed_capabilities(project: dict) -> list[str]:
    grants = project.get("capability_grants", {})
    allowed = grants.get("allow", [])

    if not isinstance(allowed, list):
        raise ValueError(
            "capability_grants.allow must be a list"
        )

    if not all(isinstance(item, str) for item in allowed):
        raise ValueError(
            "capability_grants.allow entries must be strings"
        )

    return allowed


def validate_project_grants(
    projects: dict[str, dict],
    catalog: dict[str, dict],
) -> list[str]:
    errors = []

    for project_id, project in sorted(projects.items()):
        try:
            allowed = allowed_capabilities(project)
        except ValueError as exc:
            errors.append(f"project '{project_id}': {exc}")
            continue

        seen = set()

        for capability_id in allowed:
            if capability_id in seen:
                errors.append(
                    f"project '{project_id}': duplicate capability grant "
                    f"'{capability_id}'"
                )
                continue

            seen.add(capability_id)

            if capability_id not in catalog:
                errors.append(
                    f"project '{project_id}': unknown capability grant "
                    f"'{capability_id}'"
                )

    return errors


def capability_requirements(capability: dict) -> list[str]:
    requirements = []

    if capability.get("requires_mo2_vfs"):
        requirements.append("MO2 VFS")

    if capability.get("requires_running_game"):
        requirements.append("running game")

    if capability.get("requires_environment_write"):
        requirements.append("environment-write authorization")

    return requirements


def project_report(
    project_id: str,
    project: dict,
    catalog: dict[str, dict],
) -> str:
    allowed = set(allowed_capabilities(project))

    project_caps = project.get("capabilities", {})
    build = project.get("build", {}).get("windows_native", {})

    lines = [
        f"Project: {project_id}",
        "",
        "Project capabilities:",
    ]

    if project_caps.get("windows_native_build"):
        if build.get("command"):
            lines.append(
                "  native-windows-build"
                "  authorized, configured"
                f"  -> skyrim-agent build {project_id}"
            )
        else:
            lines.append(
                "  native-windows-build"
                "  authorized, NOT configured"
            )
    else:
        lines.append(
            "  native-windows-build"
            "  not authorized"
        )

    if project_caps.get("runtime_deployment"):
        lines.append(
            "  runtime-deployment"
            "     authorized"
        )
    else:
        lines.append(
            "  runtime-deployment"
            "     not authorized"
        )

    lines += [
        "",
        "Catalog capabilities:",
    ]

    for capability_id, capability in sorted(catalog.items()):
        name = capability.get("name", capability_id)
        status = capability.get("status", "unknown")
        execution = capability.get("execution", "unknown")
        risk = capability.get("risk", "unknown")

        granted = capability_id in allowed

        if granted and status == "available":
            state = "available"
        elif granted:
            state = f"granted, but {status}"
        else:
            state = f"not granted; catalog {status}"

        lines.append(
            f"  {capability_id}"
            f" ({name})"
        )
        lines.append(
            f"    state: {state}"
        )
        lines.append(
            f"    route: {execution}"
        )
        lines.append(
            f"    risk: {risk}"
        )

        actions = capability.get("actions", {})

        if isinstance(actions, dict) and actions:
            lines.append(
                "    actions: " + ", ".join(sorted(actions))
            )

        requirements = capability_requirements(capability)

        if requirements:
            lines.append(
                "    requires: " + ", ".join(requirements)
            )

    return "\n".join(lines)


def require_project_capability(
    project_id: str,
    project: dict,
    capability_id: str,
    catalog: dict[str, dict],
) -> dict:
    if capability_id not in catalog:
        raise ValueError(
            f"unknown capability: {capability_id}"
        )

    capability = catalog[capability_id]

    allowed = set(
        allowed_capabilities(project)
    )

    if capability_id not in allowed:
        raise ValueError(
            f"capability '{capability_id}' is not granted "
            f"to project '{project_id}'"
        )

    status = capability.get("status")

    if status != "available":
        raise ValueError(
            f"capability '{capability_id}' is granted to "
            f"project '{project_id}' but is {status!r}, not available"
        )

    if capability.get("requires_environment_write"):
        project_caps = project.get("capabilities", {})

        if not project_caps.get("runtime_deployment", False):
            raise ValueError(
                f"capability '{capability_id}' requires environment-write "
                f"authorization, but project '{project_id}' does not have "
                "runtime deployment authorization"
            )

    return capability


def require_capability_action(
    capability_id: str,
    capability: dict,
    action: str,
) -> dict:
    actions = capability.get("actions", {})

    if not isinstance(actions, dict):
        raise ValueError(
            f"capability '{capability_id}' has invalid actions metadata"
        )

    config = actions.get(action)

    if not isinstance(config, dict):
        available = ", ".join(sorted(actions)) or "none"

        raise ValueError(
            f"capability '{capability_id}' has no action '{action}'. "
            f"Available actions: {available}"
        )

    handler = config.get("handler")

    if not isinstance(handler, str) or not handler:
        raise ValueError(
            f"capability '{capability_id}' action '{action}' "
            "has no valid handler"
        )

    return config
