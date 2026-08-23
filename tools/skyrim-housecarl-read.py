#!/usr/bin/env python3

import argparse
import json
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

FORMID_RE = re.compile(
    r"^[0-9A-Fa-f]{6}:[^/\\\r\n]+\.(?:esp|esm|esl)$",
    re.IGNORECASE,
)

PLUGIN_RE = re.compile(
    r"^[^/\\\r\n]+\.(?:esp|esm|esl)$",
    re.IGNORECASE,
)


class BridgeError(RuntimeError):
    pass


def load_toml(path: Path) -> dict:
    if not path.is_file():
        raise BridgeError(f"configuration file not found: {path}")

    with path.open("rb") as f:
        return tomllib.load(f)


def require_active_project(project_id: str) -> dict:
    project_path = ROOT / "projects" / f"{project_id}.toml"
    project = load_toml(project_path)

    if project.get("id") != project_id:
        raise BridgeError(
            f"project id mismatch in {project_path}"
        )

    if project.get("status") != "active":
        raise BridgeError(
            f"project {project_id!r} is not active"
        )

    return project


def require_project_environment(
    project: dict,
    environment_id: str,
) -> None:
    registered = {
        item.get("id")
        for item in project.get("environments", [])
        if isinstance(item, dict)
    }

    if environment_id not in registered:
        raise BridgeError(
            f"environment {environment_id!r} is not registered "
            f"for project {project.get('id')!r}"
        )


def require_environment(environment_id: str) -> dict:
    env_path = ROOT / "environments" / f"{environment_id}.toml"
    env = load_toml(env_path)

    if env.get("id") != environment_id:
        raise BridgeError(
            f"environment id mismatch in {env_path}"
        )

    if env.get("status") != "active":
        raise BridgeError(
            f"environment {environment_id!r} is not active"
        )

    return env


def bridge_base_url(env: dict) -> str:
    bridges = env.get("bridges")

    if not isinstance(bridges, dict):
        raise BridgeError(
            "environment has no [bridges] configuration"
        )

    housecarl = bridges.get("housecarl")

    if not isinstance(housecarl, dict):
        raise BridgeError(
            "environment has no [bridges.housecarl] configuration"
        )

    url = housecarl.get("url")

    if not isinstance(url, str) or not url:
        raise BridgeError(
            "houseCARL bridge URL is missing"
        )

    url = url.rstrip("/")
    parsed = urllib.parse.urlparse(url)

    if parsed.scheme != "https":
        raise BridgeError(
            "houseCARL bridge must use HTTPS"
        )

    if not parsed.hostname:
        raise BridgeError(
            "houseCARL bridge URL has no hostname"
        )

    # This bridge is intentionally expected to be exposed through
    # Tailscale Serve, never as a general Internet/LAN endpoint.
    if not parsed.hostname.lower().endswith(".ts.net"):
        raise BridgeError(
            "houseCARL bridge hostname must be a Tailscale .ts.net host"
        )

    if parsed.username or parsed.password:
        raise BridgeError(
            "credentials are not permitted in the bridge URL"
        )

    if parsed.query or parsed.fragment:
        raise BridgeError(
            "bridge URL must not contain a query or fragment"
        )

    if parsed.path not in ("", "/"):
        raise BridgeError(
            "bridge URL must not contain a path"
        )

    return url


def validate_fields(fields: list[str]) -> list[str]:
    if len(fields) > 32:
        raise BridgeError(
            "at most 32 --field arguments are permitted"
        )

    for field in fields:
        if not field:
            raise BridgeError(
                "field paths cannot be empty"
            )

        if len(field) > 200:
            raise BridgeError(
                "field paths cannot exceed 200 characters"
            )

        if "\r" in field or "\n" in field:
            raise BridgeError(
                "field paths cannot contain newlines"
            )

    return fields


def call_read_record(
    base_url: str,
    *,
    formid: str,
    plugin: str | None,
    fields: list[str],
    depth: int | None,
    resolve_names: bool | None,
) -> dict:
    if not FORMID_RE.fullmatch(formid):
        raise BridgeError(
            "formid must look like 000007:Skyrim.esm"
        )

    body: dict = {
        "formid": formid,
    }

    if plugin is not None:
        if not PLUGIN_RE.fullmatch(plugin):
            raise BridgeError(
                "plugin must be a filename ending in "
                ".esp, .esm, or .esl"
            )
        body["plugin"] = plugin

    fields = validate_fields(fields)

    if fields:
        body["fields"] = fields

    if depth is not None:
        if depth < 1 or depth > 4:
            raise BridgeError(
                "depth must be from 1 through 4"
            )
        body["depth"] = depth

    if resolve_names is not None:
        body["resolve_names"] = resolve_names

    payload = json.dumps(body).encode("utf-8")

    # Important: the caller never controls this path.
    url = f"{base_url}/read-record"

    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=20,
        ) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(
            "utf-8",
            errors="replace",
        )
        raise BridgeError(
            f"houseCARL bridge returned HTTP "
            f"{exc.code}: {detail[:1000]}"
        ) from exc
    except urllib.error.URLError as exc:
        raise BridgeError(
            f"could not reach houseCARL bridge: "
            f"{exc.reason}"
        ) from exc

    try:
        result = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(
            "houseCARL bridge returned invalid JSON"
        ) from exc

    if not isinstance(result, dict):
        raise BridgeError(
            "houseCARL bridge returned an unexpected response"
        )

    if result.get("ok") is not True:
        raise BridgeError(
            "houseCARL bridge rejected the request: "
            f"{result.get('error', 'unknown error')}"
        )

    if result.get("operation") != "read-record":
        raise BridgeError(
            "houseCARL bridge returned an unexpected operation"
        )

    if "data" not in result:
        raise BridgeError(
            "houseCARL bridge returned no data"
        )

    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read one Skyrim record through the constrained "
            "houseCARL bridge."
        )
    )

    parser.add_argument(
        "project",
        help="registered project id",
    )

    parser.add_argument(
        "--environment",
        required=True,
        help="registered environment id",
    )

    parser.add_argument(
        "--formid",
        required=True,
        help="record identifier, e.g. 000007:Skyrim.esm",
    )

    parser.add_argument(
        "--plugin",
        help="optional plugin filename",
    )

    parser.add_argument(
        "--field",
        action="append",
        default=[],
        dest="fields",
        help="field path to request; may be repeated",
    )

    parser.add_argument(
        "--depth",
        type=int,
        choices=range(1, 5),
    )

    names = parser.add_mutually_exclusive_group()

    names.add_argument(
        "--resolve-names",
        dest="resolve_names",
        action="store_true",
    )

    names.add_argument(
        "--no-resolve-names",
        dest="resolve_names",
        action="store_false",
    )

    parser.set_defaults(resolve_names=None)

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        project = require_active_project(args.project)

        require_project_environment(
            project,
            args.environment,
        )

        env = require_environment(args.environment)
        base_url = bridge_base_url(env)

        result = call_read_record(
            base_url,
            formid=args.formid,
            plugin=args.plugin,
            fields=args.fields,
            depth=args.depth,
            resolve_names=args.resolve_names,
        )

        json.dump(
            result,
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")

        return 0

    except BridgeError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": str(exc),
                },
                indent=2,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
