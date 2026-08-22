#!/usr/bin/env python3

import argparse
import json
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE_POLICY = ROOT / "policies" / "core.toml"


def load_policy():
    with CORE_POLICY.open("rb") as f:
        return tomllib.load(f)


def evaluate(path_value: str) -> dict:
    policy = load_policy()
    path = Path(path_value)
    lower_path = path_value.replace("\\", "/").lower()
    suffix = path.suffix.lower()

    binary = policy["binary_mod_files"]
    papyrus = policy["papyrus"]

    # Hard deny: direct binary mod/archive writes.
    if suffix in {ext.lower() for ext in binary["extensions"]}:
        return {
            "decision": "deny",
            "reason": (
                "Direct writes to Skyrim plugin/archive binaries are blocked. "
                "Use a registered format-aware tool."
            ),
            "rule": "binary_mod_files.direct_write",
        }

    # Explicit approval: Papyrus source/compiled files.
    if suffix in {
        *(ext.lower() for ext in papyrus["source_extensions"]),
        *(ext.lower() for ext in papyrus["compiled_extensions"]),
    }:
        return {
            "decision": "ask",
            "reason": f"Papyrus file modification requires explicit scope: {path_value}",
            "rule": "papyrus",
        }

    # High-value Skyrim configuration files.
    config_names = {
        "skyrim.ini",
        "skyrimprefs.ini",
        "skyrimcustom.ini",
        "skyrimvr.ini",
        "loadorder.txt",
        "plugins.txt",
    }

    if path.name.lower() in config_names:
        return {
            "decision": "ask",
            "reason": f"Skyrim runtime/profile configuration edit: {path_value}",
            "rule": "live_environment.configuration",
        }

    # SKSE plugin configuration.
    if "/data/skse/plugins/" in lower_path and suffix == ".ini":
        return {
            "decision": "ask",
            "reason": f"SKSE plugin configuration edit: {path_value}",
            "rule": "live_environment.skse_config",
        }

    # Catch-all for paths that plainly look like live Skyrim locations.
    live_markers = (
        "/skyrim special edition/",
        "/skyrim vr/",
        "/my games/skyrim",
    )

    if any(marker in lower_path for marker in live_markers):
        return {
            "decision": "ask",
            "reason": f"File appears to be inside a live Skyrim environment: {path_value}",
            "rule": "live_environment.default_write",
        }

    return {
        "decision": "allow",
        "reason": "No shared file-write policy requires intervention.",
        "rule": None,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Evaluate a proposed file write against shared Skyrim agent policy."
    )
    parser.add_argument("path")
    parser.add_argument(
        "--format",
        choices=("json", "decision"),
        default="json",
    )
    args = parser.parse_args()

    result = evaluate(args.path)

    if args.format == "decision":
        print(result["decision"])
    else:
        print(json.dumps(result))


if __name__ == "__main__":
    main()
