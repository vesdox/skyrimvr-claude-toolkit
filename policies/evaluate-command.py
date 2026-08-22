#!/usr/bin/env python3

import argparse
import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE_POLICY = ROOT / "policies" / "core.toml"
ENVIRONMENTS_DIR = ROOT / "environments"


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def registered_evidence_paths() -> list[str]:
    paths = []

    for config in sorted(ENVIRONMENTS_DIR.glob("*.toml")):
        data = load_toml(config)

        for value in data.get("evidence", {}).values():
            if isinstance(value, str) and value:
                paths.append(value.replace("\\", "/").lower().rstrip("/"))

    return paths


def result(decision: str, reason: str, rule: str | None) -> dict:
    return {
        "decision": decision,
        "reason": reason,
        "rule": rule,
    }


def evaluate(command: str) -> dict:
    policy = load_toml(CORE_POLICY)

    normalized = command.replace("\\", "/")
    lower = normalized.lower()

    destructive = re.search(
        r"\b("
        r"rm|rmdir|del|erase|remove-item|remove-itemproperty|"
        r"move-item|rename-item"
        r")\b",
        lower,
    )

    modifying = re.search(
        r"\b("
        r"rm|rmdir|del|erase|remove-item|"
        r"mv|cp|move|copy|move-item|copy-item|rename-item|"
        r"sed\s+-i|set-content|add-content|out-file"
        r")\b",
        lower,
    ) or re.search(r"(^|[^>])>>?[^>]", lower)

    # Registered Windows/runtime evidence is never a command write target.
    evidence_hits = [
        path
        for path in registered_evidence_paths()
        if path and path in lower
    ]

    if evidence_hits and destructive:
        return result(
            "deny",
            "Destructive command references registered read-only environment "
            f"evidence: {evidence_hits[0]}",
            "live_environment.read_only_evidence",
        )

    if evidence_hits and modifying:
        return result(
            "deny",
            "Write-capable command references registered read-only environment "
            f"evidence: {evidence_hits[0]}",
            "live_environment.read_only_evidence",
        )

    # Structural read-only evidence/reference areas.
    protected_markers = (
        "/windows-ro/",
        "/reference/mod-sources/",
    )

    if modifying and any(marker in lower for marker in protected_markers):
        return result(
            "deny",
            "Command attempts to modify a protected read-only evidence/reference area.",
            "live_environment.read_only_evidence",
        )

    # Strong destructive protection for Skyrim installations/configuration.
    skyrim_markers = (
        "skyrim special edition",
        "skyrim vr",
        "/my games/skyrim",
        "/data/",
    )

    if destructive and any(marker in lower for marker in skyrim_markers):
        return result(
            "deny",
            "Destructive command targets or references a Skyrim runtime/configuration area.",
            "live_environment.default_write",
        )

    # Bethesda registry deletion is never an ordinary agent operation.
    if re.search(r"\breg(\.exe)?\s+delete\b", lower) and "bethesda" in lower:
        return result(
            "deny",
            "Deleting Bethesda registry configuration is blocked.",
            "live_environment.configuration",
        )

    if "remove-itemproperty" in lower and "bethesda" in lower:
        return result(
            "deny",
            "Deleting Bethesda registry configuration is blocked.",
            "live_environment.configuration",
        )

    # Plugin/archive commands require review unless clearly routed through the
    # shared project-aware build command.
    binary_extensions = tuple(
        ext.lower()
        for ext in policy["binary_mod_files"]["extensions"]
    )

    if any(ext in lower for ext in binary_extensions):
        return result(
            "ask",
            "Command references a Skyrim plugin/archive file; confirm that the "
            "operation uses an approved format-aware workflow.",
            "binary_mod_files",
        )

    # Load-order state is environment-sensitive.
    if "loadorder.txt" in lower or "plugins.txt" in lower:
        return result(
            "ask",
            "Command references load-order state; confirm the correct registered "
            "environment and MO2 context.",
            "mo2.load_order_dependent_operations",
        )

    # Direct modification of obvious live Skyrim paths requires approval even
    # when it is not destructive.
    if modifying and any(marker in lower for marker in skyrim_markers):
        return result(
            "ask",
            "Command may modify a live Skyrim runtime/configuration area.",
            "live_environment.default_write",
        )

    return result(
        "allow",
        "No shared command policy requires intervention.",
        None,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Evaluate a shell command against shared Skyrim agent policy."
    )
    parser.add_argument("command")
    parser.add_argument(
        "--format",
        choices=("json", "decision"),
        default="json",
    )
    args = parser.parse_args()

    evaluation = evaluate(args.command)

    if args.format == "decision":
        print(evaluation["decision"])
    else:
        print(json.dumps(evaluation))


if __name__ == "__main__":
    main()
