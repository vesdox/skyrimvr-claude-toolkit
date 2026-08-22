#!/usr/bin/env python3

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAPABILITIES_DIR = ROOT / "capabilities"

VALID_STATUS = {
    "unconfigured",
    "available",
    "disabled",
}

VALID_EXECUTION = {
    "linux",
    "windows",
    "windows-mo2",
    "windows-runtime",
}

VALID_RISK = {
    "read",
    "source-write",
    "environment-write",
    "runtime",
}


def main():
    errors = []
    seen = {}

    files = sorted(CAPABILITIES_DIR.glob("*.toml"))

    if not files:
        errors.append("no capability definitions found")

    for path in files:
        try:
            with path.open("rb") as f:
                data = tomllib.load(f)
        except tomllib.TOMLDecodeError as exc:
            errors.append(f"{path}: invalid TOML: {exc}")
            continue

        capability_id = data.get("id")

        if not capability_id:
            errors.append(f"{path}: missing id")
            continue

        if capability_id in seen:
            errors.append(
                f"{path}: duplicate capability id '{capability_id}' "
                f"(already defined by {seen[capability_id]})"
            )
        else:
            seen[capability_id] = path

        status = data.get("status")
        execution = data.get("execution")
        risk = data.get("risk")

        if status not in VALID_STATUS:
            errors.append(
                f"{path}: invalid status {status!r}"
            )

        if execution not in VALID_EXECUTION:
            errors.append(
                f"{path}: invalid execution class {execution!r}"
            )

        if risk not in VALID_RISK:
            errors.append(
                f"{path}: invalid risk class {risk!r}"
            )

        if execution == "windows-mo2" and not data.get(
            "requires_mo2_vfs", False
        ):
            errors.append(
                f"{path}: windows-mo2 capability must require MO2 VFS"
            )

        if execution == "windows-runtime" and not data.get(
            "requires_running_game", False
        ):
            errors.append(
                f"{path}: windows-runtime capability must require running game"
            )

        if risk in {"environment-write", "runtime"} and not data.get(
            "requires_environment_write", False
        ):
            errors.append(
                f"{path}: {risk} capability must require environment-write "
                "authorization"
            )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)

        raise SystemExit(1)

    print(f"Capability validation passed: {len(files)} definitions.")


if __name__ == "__main__":
    main()
