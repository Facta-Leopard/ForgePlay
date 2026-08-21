#!/usr/bin/env python3

from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Any


BLUETOOTH_USAGE_KEY = "NSBluetoothAlwaysUsageDescription"
REQUIRED_MAIN_ENTITLEMENTS = (
    "com.apple.security.device.usb",
    "com.apple.security.device.bluetooth",
)
EXPECTED_RUNTIME_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
    "com.apple.security.cs.disable-library-validation": True,
}


class ContractError(RuntimeError):
    pass


def require_regular_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"{label} must be a non-symlink regular file: {path}")


def read_plist(path: Path, label: str) -> dict[str, Any]:
    require_regular_file(path, label)
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ContractError(f"{label} is not a valid property list: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"{label} root must be a dictionary: {path}")
    return value


def read_strings(path: Path, label: str) -> dict[str, Any]:
    require_regular_file(path, label)
    try:
        converted = subprocess.run(
            ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)],
            check=True,
            capture_output=True,
        )
        value = plistlib.loads(converted.stdout)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise ContractError(f"{label} is not a valid strings property list: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"{label} root must be a dictionary: {path}")
    return value


def require_nonempty_string(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{label} must be a non-empty string")


def verify_main_entitlements(entitlements_path: Path) -> None:
    entitlements = read_plist(entitlements_path, "main-app entitlements")
    for entitlement in REQUIRED_MAIN_ENTITLEMENTS:
        if entitlements.get(entitlement) is not True:
            raise ContractError(f"main app is missing required controller entitlement: {entitlement}")


def verify_runtime_entitlements(entitlements_path: Path) -> None:
    entitlements = read_plist(entitlements_path, "runtime inherit entitlements")
    if entitlements != EXPECTED_RUNTIME_ENTITLEMENTS:
        expected = ", ".join(sorted(EXPECTED_RUNTIME_ENTITLEMENTS))
        actual = ", ".join(sorted(entitlements)) or "<none>"
        raise ContractError(
            "runtime inherit entitlements must contain exactly "
            f"{expected}; found: {actual}"
        )


def verify_bluetooth_usage_descriptions(info_path: Path, resources_path: Path) -> None:
    info = read_plist(info_path, "Info.plist")
    require_nonempty_string(info.get(BLUETOOTH_USAGE_KEY), f"Info.plist {BLUETOOTH_USAGE_KEY}")

    localizations = info.get("CFBundleLocalizations")
    if not isinstance(localizations, list) or not localizations:
        raise ContractError("Info.plist CFBundleLocalizations must be a non-empty array")
    for localization in localizations:
        require_nonempty_string(localization, "CFBundleLocalizations entry")
    if len(localizations) != len(set(localizations)):
        raise ContractError("Info.plist CFBundleLocalizations must not contain duplicates")
    if resources_path.is_symlink() or not resources_path.is_dir():
        raise ContractError(f"resources root must be a non-symlink directory: {resources_path}")

    for localization in localizations:
        localization_path = resources_path / f"{localization}.lproj"
        if localization_path.is_symlink() or not localization_path.is_dir():
            raise ContractError(
                f"{localization} localization must be a non-symlink directory: {localization_path}"
            )
        strings_path = localization_path / "InfoPlist.strings"
        strings = read_strings(strings_path, f"{localization} InfoPlist.strings")
        require_nonempty_string(
            strings.get(BLUETOOTH_USAGE_KEY),
            f"{localization} InfoPlist.strings {BLUETOOTH_USAGE_KEY}",
        )


def main(arguments: list[str]) -> int:
    if not arguments or arguments[0] not in {"source", "bundle"}:
        raise ContractError(
            "usage: verify-app-store-controller-permissions.py "
            "source <main entitlements> <runtime entitlements> <Info.plist> <Resources> | "
            "bundle <signed main entitlements> <Info.plist> <Resources>"
        )

    mode = arguments[0]
    expected_argument_count = 5 if mode == "source" else 4
    if len(arguments) != expected_argument_count:
        raise ContractError(f"invalid argument count for {mode} mode")

    verify_main_entitlements(Path(arguments[1]))
    if mode == "source":
        verify_runtime_entitlements(Path(arguments[2]))
        info_index = 3
    else:
        info_index = 2
    verify_bluetooth_usage_descriptions(
        Path(arguments[info_index]),
        Path(arguments[info_index + 1]),
    )
    print(f"App Store controller permission verification passed ({mode})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ContractError as error:
        print(f"error: invalid App Store controller permission contract: {error}", file=sys.stderr)
        raise SystemExit(1)
