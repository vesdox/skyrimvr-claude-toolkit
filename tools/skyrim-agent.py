#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib

from capability_registry import (
    load_catalog,
    project_report,
    require_capability_action,
    require_project_capability,
    validate_project_grants,
)

from plugin_locator import (
    resolve_plugin,
    search_plugins,
)
from pathlib import Path, PureWindowsPath
from save_locator import list_saves

ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = ROOT / "projects"
ENVIRONMENTS_DIR = ROOT / "environments"
POLICIES_DIR = ROOT / "policies"
CORE_POLICY = POLICIES_DIR / "core.toml"
CAPABILITIES_DIR = ROOT / "capabilities"

AGENT_BLOCK_START = "<!-- skyrim-agent-toolkit:start -->"
AGENT_BLOCK_END = "<!-- skyrim-agent-toolkit:end -->"


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

    if not CORE_POLICY.is_file():
        errors.append(f"missing core safety policy: {CORE_POLICY}")
    else:
        try:
            policy = load_toml(CORE_POLICY)
        except tomllib.TOMLDecodeError as exc:
            errors.append(f"invalid core safety policy: {exc}")
        else:
            if policy.get("version") != 1:
                errors.append(
                    f"unsupported core safety policy version: "
                    f"{policy.get('version')!r}"
                )

            if policy.get("binary_mod_files", {}).get("direct_write") != "deny":
                errors.append(
                    "core policy must deny direct binary mod-file writes"
                )

            if policy.get("live_environment", {}).get("default_write") != "deny":
                errors.append(
                    "core policy must deny live-environment writes by default"
                )

            deployment_policy = policy.get("deployment", {})
            for key in (
                "registered_project_files_only",
                "registered_environment_and_target_only",
                "native_artifacts_require_build_proof",
                "report_hashes_before_and_after",
                "backup_replaced_artifacts",
            ):
                if deployment_policy.get(key) is not True:
                    errors.append(f"core deployment policy must require {key}")

            if deployment_policy.get("load_order_mutation") != "separate-capability":
                errors.append("core deployment policy must separate load-order mutation")

    deployment_physical_targets = {}

    for project_id, project in projects.items():
        repo = project.get("repo")
        status = project.get("status")

        if not repo:
            errors.append(f"{project_id}: missing repo")
        elif status == "active" and not Path(repo).is_dir():
            errors.append(
                f"{project_id}: active project repo does not exist: {repo}"
            )

        project_environment_ids = set()
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
            else:
                project_environment_ids.add(env_id)

        deployment = project.get("deployment", {})
        sets = deployment.get("sets", [])
        targets = deployment.get("targets", [])
        set_ids = set()
        artifact_ids = set()

        if not isinstance(sets, list) or not isinstance(targets, list):
            errors.append(f"{project_id}: deployment sets/targets must be arrays")
            continue

        if any(
            isinstance(file_set, dict)
            and file_set.get("provenance") == "windows-native-build"
            for file_set in sets
        ):
            source_hash = (
                project.get("build", {})
                .get("windows_native", {})
                .get("expected_source_sha256")
            )
            if (
                not isinstance(source_hash, str)
                or not re.fullmatch(r"[0-9A-Fa-f]{64}", source_hash)
            ):
                errors.append(
                    f"{project_id}: native deployment requires a pinned source archive SHA256"
                )

        for file_set in sets:
            if not isinstance(file_set, dict) or not isinstance(file_set.get("id"), str):
                errors.append(f"{project_id}: deployment set missing id")
                continue
            set_id = file_set["id"]
            if set_id in set_ids:
                errors.append(f"{project_id}: duplicate deployment set '{set_id}'")
            set_ids.add(set_id)
            if file_set.get("provenance") not in ("repository", "windows-native-build"):
                errors.append(f"{project_id}: deployment set '{set_id}' has invalid provenance")
            files = file_set.get("files", [])
            if not isinstance(files, list) or not files:
                errors.append(f"{project_id}: deployment set '{set_id}' has no files")
                continue
            provenance = file_set.get("provenance")
            for item in files:
                if not isinstance(item, dict):
                    errors.append(f"{project_id}: deployment set '{set_id}' has invalid file")
                    continue
                artifact_id = item.get("id")
                source = item.get("source")
                destination = item.get("destination")
                if not all(isinstance(value, str) and value for value in (artifact_id, source, destination)):
                    errors.append(f"{project_id}: deployment set '{set_id}' has incomplete file metadata")
                    continue
                if artifact_id in artifact_ids:
                    errors.append(f"{project_id}: duplicate deployment artifact '{artifact_id}'")
                artifact_ids.add(artifact_id)
                if provenance == "windows-native-build":
                    expected_hash = item.get("expected_sha256")
                    if (
                        not isinstance(expected_hash, str)
                        or not re.fullmatch(r"[0-9A-Fa-f]{64}", expected_hash)
                    ):
                        errors.append(
                            f"{project_id}: native deployment artifact '{artifact_id}' "
                            "has no valid pinned SHA256"
                        )
                for label, value in (("source", source), ("destination", destination)):
                    normalized = value.replace("\\", "/")
                    path = Path(normalized)
                    if path.is_absolute() or ".." in path.parts or "." in path.parts:
                        errors.append(
                            f"{project_id}: deployment artifact '{artifact_id}' has unsafe {label}"
                        )

        target_keys = set()
        for target in targets:
            if not isinstance(target, dict):
                errors.append(f"{project_id}: invalid deployment target")
                continue
            target_id = target.get("id")
            env_id = target.get("environment")
            mod = target.get("mod")
            allowed_sets = target.get("sets")
            if (
                not isinstance(target_id, str)
                or not isinstance(mod, str)
                or not mod
                or mod in (".", "..")
                or any(character in mod for character in "/\\:\r\n")
            ):
                errors.append(f"{project_id}: deployment target has incomplete or unsafe identity")
                continue
            target_key = (env_id, target_id)
            if target_key in target_keys:
                errors.append(
                    f"{project_id}: duplicate deployment target '{target_id}' for '{env_id}'"
                )
            target_keys.add(target_key)
            if env_id not in project_environment_ids:
                errors.append(f"{project_id}: deployment target '{target_id}' has unregistered environment")
            if not isinstance(allowed_sets, list) or not allowed_sets:
                errors.append(f"{project_id}: deployment target '{target_id}' has no set allowlist")
            else:
                for set_id in allowed_sets:
                    if set_id not in set_ids:
                        errors.append(
                            f"{project_id}: deployment target '{target_id}' references unknown set '{set_id}'"
                        )
            environment = environments.get(env_id, {})
            env_deployment = environment.get("deployment", {})
            windows_mods_root = env_deployment.get("mo2_mods_root_windows")
            if not windows_mods_root:
                errors.append(f"{project_id}: deployment environment '{env_id}' has no Windows mods root")
            else:
                physical_target = str(PureWindowsPath(windows_mods_root) / mod).casefold()
                prior = deployment_physical_targets.get(physical_target)
                if prior is not None:
                    errors.append(
                        f"{project_id}: deployment target '{target_id}' duplicates physical target {prior}"
                    )
                else:
                    deployment_physical_targets[physical_target] = f"{project_id}:{target_id}"
            if not env_deployment.get("mo2_mods_root_evidence"):
                errors.append(f"{project_id}: deployment environment '{env_id}' has no evidence mods root")
            deploy_bridge = environment.get("bridges", {}).get("project_deploy", {})
            if not deploy_bridge.get("url"):
                errors.append(f"{project_id}: deployment environment '{env_id}' has no bridge URL")
            if deploy_bridge.get("protocol") != "project-deploy-v1":
                errors.append(f"{project_id}: deployment environment '{env_id}' has invalid bridge protocol")
            if not deploy_bridge.get("backup_root_windows"):
                errors.append(f"{project_id}: deployment environment '{env_id}' has no backup root")

    try:
        catalog = load_catalog(CAPABILITIES_DIR)
    except (ValueError, tomllib.TOMLDecodeError, OSError) as exc:
        errors.append(f"capability catalog error: {exc}")
    else:
        errors.extend(
            validate_project_grants(
                projects,
                catalog,
            )
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



def project_agent_block(project_id: str, project: dict) -> str:
    toolkit_contract = ROOT / "AGENTS.md"

    capabilities = project.get("capabilities", {})
    native_build = capabilities.get("windows_native_build", False)
    runtime_deployment = capabilities.get("runtime_deployment", False)

    lines = [
        AGENT_BLOCK_START,
        "## Shared Skyrim Agent Toolkit",
        "",
        f"This repository is registered with the shared Skyrim Agent Toolkit as "
        f"`{project_id}`.",
        "",
        f"Shared toolkit contract: `{toolkit_contract}`",
        "",
        "For Skyrim-specific tooling, environment inspection, Windows operations, "
        "or shared infrastructure:",
        "",
        f"- Resolve this project with `skyrim-agent show {project_id}`.",
        f"- Inspect registered runtime evidence with "
        f"`skyrim-agent evidence {project_id}`.",
    ]

    if native_build:
        lines.append(
            f"- Run the authorized native Windows build through "
            f"`skyrim-agent build {project_id}`."
        )
        lines.append(
            "- Do not invoke the repository-local build implementation directly "
            "unless explicitly debugging the toolkit/bridge itself."
        )

    if runtime_deployment:
        lines.append(
            f"- Plan authorized bounded deployment with `skyrim-agent deploy "
            f"{project_id} --environment <id> --target <id> --set <id> --dry-run`."
        )
        lines.append(
            "- Deployment covers only registered project-owned files and targets; "
            "it does not authorize load-order changes, game launch, saves, or "
            "runtime configuration mutation."
        )

    lines += [
        "",
        "Project-specific design, architecture, source, and acceptance rules in this "
        "`AGENTS.md` remain authoritative for this repository.",
        "",
        "The shared toolkit contract additionally governs toolkit capabilities, "
        "environment ownership, bridge boundaries, and shared safety policy. If a "
        "project instruction and a toolkit safety restriction differ, follow the "
        "stricter restriction and report the conflict.",
        "",
        "Do not hardcode another project's repository, Windows environment, build "
        "identity, or deployment path when a registered project/environment "
        "capability exists.",
        AGENT_BLOCK_END,
    ]

    return "\n".join(lines)


def cmd_run(args):
    project = resolve_project(args.project)
    catalog = load_catalog(CAPABILITIES_DIR)

    try:
        capability = require_project_capability(
            args.project,
            project,
            args.capability,
            catalog,
        )

        action = require_capability_action(
            args.capability,
            capability,
            args.action,
        )
    except ValueError as exc:
        raise SystemExit(f"error: {exc}")

    handler = action["handler"]

    known_handlers = {
        "inspect-plugin",
        "resaver-read",
        "housecarl-read",
        "project-deploy",
    }

    if handler not in known_handlers:
        raise SystemExit(
            f"error: capability handler is not registered with "
            f"skyrim-agent: {handler}"
        )

    forwarded = list(args.arguments)

    if forwarded and forwarded[0] == "--":
        forwarded = forwarded[1:]

    if handler == "inspect-plugin":
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            handler,
            args.project,
            *forwarded,
        ]
    elif handler == "resaver-read":
        command = [
            sys.executable,
            str(ROOT / "tools" / "skyrim-resaver-read.py"),
            args.project,
            args.action,
            *forwarded,
        ]
    elif handler == "housecarl-read":
        command = [
            sys.executable,
            str(ROOT / "tools" / "skyrim-housecarl-read.py"),
            args.project,
            "--operation",
            args.action,
            *forwarded,
        ]
    elif handler == "project-deploy":
        command = [
            sys.executable,
            str(ROOT / "tools" / "project_deploy.py"),
            args.project,
            *forwarded,
        ]
    else:
        raise SystemExit(
            f"error: no execution route for capability handler: {handler}"
        )

    process = subprocess.run(
        command,
        cwd=ROOT,
    )

    if process.returncode != 0:
        raise SystemExit(process.returncode)


def cmd_saves(args):
    project = resolve_project(args.project)

    try:
        results = list_saves(
            project,
            args.environment,
            ENVIRONMENTS_DIR,
            search=args.search,
            latest=args.latest,
        )
    except ValueError as exc:
        raise SystemExit(f"error: {exc}")

    if args.json:
        print(
            json.dumps(
                results,
                indent=2,
            )
        )
        return

    print(f"Project: {args.project}")
    print(f"Environment: {args.environment}")

    if args.search:
        print(f"Search: {args.search}")

    print()

    if not results:
        print("No matching saves found.")
        return

    for item in results:
        mib = item["size_bytes"] / (1024 * 1024)
        cosave = "yes" if item["skse_cosave"] else "no"

        print(f"Save:     {item['relative_path']}")
        print(f"Modified: {item['modified_utc']}")
        print(f"Size:     {mib:.2f} MiB")
        print(f"SKSE:     {cosave}")
        print()


def cmd_plugins(args):
    project = resolve_project(args.project)

    try:
        results = search_plugins(
            project,
            args.environment,
            args.search,
            ENVIRONMENTS_DIR,
            args.limit,
        )
    except ValueError as exc:
        raise SystemExit(f"error: {exc}")

    if args.json:
        import json
        print(
            json.dumps(
                results,
                indent=2,
            )
        )
        return

    if not results:
        print(
            f"No matching plugins found for {args.search!r} "
            f"in environment '{args.environment}'."
        )
        return

    print(f"Project: {args.project}")
    print(f"Environment: {args.environment}")
    print(f"Search: {args.search}")
    print()

    for result in results:
        print(f"Mod:    {result['mod']}")
        print(f"Plugin: {result['relative_plugin']}")
        print()


def cmd_inspect_plugin(args):
    project = resolve_project(args.project)

    try:
        resolved = resolve_plugin(
            project,
            args.environment,
            args.mod,
            args.plugin,
            ENVIRONMENTS_DIR,
        )
    except ValueError as exc:
        raise SystemExit(f"error: {exc}")

    plugin = resolved["plugin"]

    if args.resolve_only:
        print(f"Project: {resolved['project']}")
        print(f"Environment: {resolved['environment']}")
        print(f"Runtime: {resolved['runtime']}")
        print(f"Mod: {resolved['mod']}")
        print(f"Plugin: {plugin}")
        return

    inspector = ROOT / "tools" / "skyrim-inspect-plugin.py"

    if not inspector.is_file():
        raise SystemExit(
            f"error: plugin inspector is unavailable: {inspector}"
        )

    process = subprocess.run(
        [
            str(inspector),
            args.project,
            str(plugin),
        ],
        cwd=ROOT,
    )

    if process.returncode != 0:
        raise SystemExit(process.returncode)


def cmd_capabilities(args):
    project = resolve_project(args.project)
    catalog = load_catalog(CAPABILITIES_DIR)

    print(
        project_report(
            args.project,
            project,
            catalog,
        )
    )


def cmd_attach(args):
    project = resolve_project(args.project)

    if project.get("status") != "active":
        raise ValueError(
            f"project '{args.project}' is not active"
        )

    repo_value = project.get("repo")
    if not repo_value:
        raise ValueError(
            f"project '{args.project}' has no repository path"
        )

    repo = Path(repo_value).resolve()

    if not repo.is_dir():
        raise ValueError(
            f"project '{args.project}' repository does not exist: {repo}"
        )

    agents_file = repo / "AGENTS.md"
    block = project_agent_block(args.project, project)

    if agents_file.exists():
        original = agents_file.read_text()
    else:
        original = "# AGENTS.md\n"

    has_start = AGENT_BLOCK_START in original
    has_end = AGENT_BLOCK_END in original

    if has_start != has_end:
        raise ValueError(
            f"{agents_file}: incomplete managed toolkit block"
        )

    if has_start:
        before, remainder = original.split(AGENT_BLOCK_START, 1)
        _old_block, after = remainder.split(AGENT_BLOCK_END, 1)

        updated = (
            before.rstrip()
            + "\n\n"
            + block
            + after
        )
    else:
        updated = (
            original.rstrip()
            + "\n\n"
            + block
            + "\n"
        )

    if not args.apply:
        print(f"Would update: {agents_file}")
        print()
        print(block)
        print()
        print("Dry run only; use --apply to write the managed block.")
        return

    if updated == original:
        print(f"Already current: {agents_file}")
        return

    agents_file.write_text(updated)

    print(f"Updated: {agents_file}")
    print(f"Project: {args.project}")



def cmd_evidence(args):
    project = resolve_project(args.project)

    print(f"Project: {project.get('name', args.project)}")

    found_active = False

    for environment in project.get("_resolved_environments", []):
        env_id = environment.get("id", "unknown")
        name = environment.get("name", env_id)
        status = environment.get("status", "unknown")
        role = environment.get("_role") or "unspecified"
        runtime = environment.get("runtime", "unknown")

        print()
        print(f"Environment: {name} ({env_id})")
        print(f"  Role:      {role}")
        print(f"  Runtime:   {runtime}")
        print(f"  Status:    {status}")

        if status != "active":
            print("  Evidence:  not required while environment is pending")
            continue

        found_active = True
        evidence = environment.get("evidence", {})

        if not evidence:
            raise ValueError(
                f"active environment '{env_id}' has no evidence paths configured"
            )

        for label, value in evidence.items():
            evidence_path = Path(value)

            exists = evidence_path.exists()
            writable = evidence_path.exists() and os.access(evidence_path, os.W_OK)

            print(f"  {label}:")
            print(f"    path:      {evidence_path}")
            print(f"    exists:    {'yes' if exists else 'NO'}")
            print(f"    writable:  {'YES' if writable else 'no'}")

            if not exists:
                raise ValueError(
                    f"environment '{env_id}' evidence path does not exist: "
                    f"{evidence_path}"
                )

            if writable:
                raise ValueError(
                    f"environment '{env_id}' evidence path is writable but "
                    f"must be read-only: {evidence_path}"
                )

    if not found_active:
        print()
        print("No active environments are configured for this project.")



def cmd_deploy(args):
    command = [
        sys.executable,
        str(ROOT / "tools" / "project_deploy.py"),
        args.project,
        "--environment",
        args.environment,
        "--target",
        args.target,
    ]

    for set_id in args.sets:
        command += ["--set", set_id]

    if args.build_evidence:
        command += ["--build-evidence", args.build_evidence]

    command.append("--apply" if args.apply else "--dry-run")

    result = subprocess.run(command, cwd=ROOT)
    raise SystemExit(result.returncode)



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

    run_parser = subparsers.add_parser(
        "run",
        help="run an authorized project capability action",
    )
    run_parser.add_argument(
        "project",
        help="registered project id",
    )
    run_parser.add_argument(
        "capability",
        help="capability id",
    )
    run_parser.add_argument(
        "action",
        help="capability action",
    )
    run_parser.add_argument(
        "arguments",
        nargs=argparse.REMAINDER,
        help="arguments passed to the registered capability handler",
    )
    run_parser.set_defaults(
        func=cmd_run
    )

    saves_parser = subparsers.add_parser(
        "saves",
        help="list saves from a registered project environment",
    )
    saves_parser.add_argument(
        "project",
        help="registered project id",
    )
    saves_parser.add_argument(
        "--environment",
        required=True,
        help="registered active project environment",
    )
    saves_parser.add_argument(
        "--latest",
        type=int,
        default=10,
        help="maximum number of newest saves to return",
    )
    saves_parser.add_argument(
        "--search",
        help="case-insensitive save-name search",
    )
    saves_parser.add_argument(
        "--json",
        action="store_true",
        help="return structured JSON for agent consumption",
    )
    saves_parser.set_defaults(
        func=cmd_saves
    )

    plugins_parser = subparsers.add_parser(
        "plugins",
        help="search plugins in a registered project environment",
    )
    plugins_parser.add_argument("project")
    plugins_parser.add_argument(
        "--environment",
        required=True,
        help="registered project environment id",
    )
    plugins_parser.add_argument(
        "--search",
        required=True,
        help="case-insensitive mod/plugin search text",
    )
    plugins_parser.add_argument(
        "--limit",
        type=int,
        default=30,
        help="maximum number of matching plugins to return",
    )
    plugins_parser.add_argument(
        "--json",
        action="store_true",
        help="return structured JSON for agent/tool consumption",
    )
    plugins_parser.set_defaults(
        func=cmd_plugins
    )

    inspect_plugin_parser = subparsers.add_parser(
        "inspect-plugin",
        help="inspect a plugin by registered environment and MO2 mod name",
    )
    inspect_plugin_parser.add_argument("project")
    inspect_plugin_parser.add_argument(
        "--environment",
        required=True,
        help="registered project environment id",
    )
    inspect_plugin_parser.add_argument(
        "--mod",
        required=True,
        help="MO2 mod directory name",
    )
    inspect_plugin_parser.add_argument(
        "--plugin",
        help=(
            "plugin filename or path relative to the mod; "
            "optional when the mod contains exactly one plugin"
        ),
    )
    inspect_plugin_parser.add_argument(
        "--resolve-only",
        action="store_true",
        help="resolve the plugin without running Spriggit",
    )
    inspect_plugin_parser.set_defaults(
        func=cmd_inspect_plugin
    )

    capabilities_parser = subparsers.add_parser(
        "capabilities",
        help="show capability authorization and routing for a project",
    )
    capabilities_parser.add_argument("project")
    capabilities_parser.set_defaults(func=cmd_capabilities)

    attach_parser = subparsers.add_parser(
        "attach",
        help="attach the shared toolkit contract to a registered project",
    )
    attach_parser.add_argument("project")
    attach_parser.add_argument(
        "--apply",
        action="store_true",
        help="write/update the managed AGENTS.md block",
    )
    attach_parser.set_defaults(func=cmd_attach)

    evidence_parser = subparsers.add_parser("evidence")
    evidence_parser.add_argument("project")
    evidence_parser.set_defaults(func=cmd_evidence)

    deploy_parser = subparsers.add_parser(
        "deploy",
        help="deploy explicitly registered project files through a bounded bridge",
    )
    deploy_parser.add_argument("project", help="registered project id")
    deploy_parser.add_argument(
        "--environment",
        required=True,
        help="registered project environment id",
    )
    deploy_parser.add_argument(
        "--target",
        required=True,
        help="registered deployment target id",
    )
    deploy_parser.add_argument(
        "--set",
        action="append",
        dest="sets",
        required=True,
        help="registered deployment set; may be repeated",
    )
    deploy_parser.add_argument(
        "--build-evidence",
        help="registered Windows build evidence directory for native sets",
    )
    deploy_mode = deploy_parser.add_mutually_exclusive_group()
    deploy_mode.add_argument(
        "--dry-run",
        action="store_true",
        help="plan only (the safe default)",
    )
    deploy_mode.add_argument(
        "--apply",
        action="store_true",
        help="copy through the constrained deployment bridge",
    )
    deploy_parser.set_defaults(func=cmd_deploy)

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
