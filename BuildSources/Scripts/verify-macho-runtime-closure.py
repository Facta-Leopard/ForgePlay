#!/usr/bin/env python3

import os
import stat
import subprocess
import sys
from pathlib import Path


LOAD_DYLIB_COMMANDS = {
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
}
SYSTEM_DEPENDENCY_PREFIXES = ("/System/Library/", "/usr/lib/")
PROHIBITED_ABSOLUTE_PREFIXES = ("/opt/", "/usr/local/", "/Users/", "/Volumes/")


class ClosureError(RuntimeError):
    pass


def command_output(arguments: list[str], label: str) -> str:
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ClosureError(f"{label} failed: {detail}")
    return result.stdout


def is_macho(path: Path) -> tuple[bool, bool]:
    description = command_output(["file", "-b", str(path)], f"file inspection for {path}").strip()
    return description.startswith("Mach-O"), "executable" in description


def parse_load_commands(path: Path) -> tuple[list[str], list[str]]:
    output = command_output(["otool", "-l", str(path)], f"Mach-O load-command inspection for {path}")
    dependencies: list[str] = []
    runpaths: list[str] = []
    current_command: str | None = None
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line.startswith("cmd "):
            current_command = line.removeprefix("cmd ").strip()
            continue
        if current_command in LOAD_DYLIB_COMMANDS and line.startswith("name "):
            dependencies.append(line.removeprefix("name ").split(" (offset ", 1)[0])
            current_command = None
        elif current_command == "LC_RPATH" and line.startswith("path "):
            runpaths.append(line.removeprefix("path ").split(" (offset ", 1)[0])
            current_command = None
    return list(dict.fromkeys(dependencies)), list(dict.fromkeys(runpaths))


def require_safe_root(root: Path) -> Path:
    if root.is_symlink() or not root.is_dir():
        raise ClosureError(f"runtime root must be a non-symlink directory: {root}")
    return root.resolve(strict=True)


def is_bundled_regular_file(path: Path, root: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        return False
    try:
        path.resolve(strict=True).relative_to(root)
    except (OSError, ValueError):
        return False
    return True


def expand_token_path(value: str, loader: Path, executable_directories: list[Path]) -> list[Path]:
    if value == "@loader_path":
        return [loader.parent]
    if value.startswith("@loader_path/"):
        return [loader.parent / value.removeprefix("@loader_path/")]
    if value == "@executable_path":
        return executable_directories
    if value.startswith("@executable_path/"):
        suffix = value.removeprefix("@executable_path/")
        return [directory / suffix for directory in executable_directories]
    if value.startswith("/"):
        return [Path(value)]
    return [loader.parent / value]


def dependency_candidates(
    dependency: str,
    runpaths: list[str],
    loader: Path,
    executable_directories: list[Path],
) -> list[Path]:
    if dependency.startswith("@rpath/"):
        suffix = dependency.removeprefix("@rpath/")
        candidates: list[Path] = []
        for runpath in runpaths:
            candidates.extend(path / suffix for path in expand_token_path(runpath, loader, executable_directories))
        return candidates
    return expand_token_path(dependency, loader, executable_directories)


def verify_runtime_closure(root: Path) -> None:
    root = require_safe_root(root)
    macho_files: list[Path] = []
    executable_directories: list[Path] = []
    for current_root, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_root)
        directory_names[:] = [name for name in directory_names if not (current / name).is_symlink()]
        for name in file_names:
            candidate = current / name
            if candidate.is_symlink() or not candidate.is_file():
                continue
            macho, executable = is_macho(candidate)
            if not macho:
                continue
            macho_files.append(candidate)
            if executable:
                executable_directories.append(candidate.parent)

    executable_directories = list(dict.fromkeys(executable_directories))
    failures: list[str] = []
    for macho in macho_files:
        dependencies, runpaths = parse_load_commands(macho)
        relative_macho = macho.relative_to(root)
        for runpath in runpaths:
            if runpath.startswith(PROHIBITED_ABSOLUTE_PREFIXES):
                failures.append(f"developer-machine LC_RPATH: {relative_macho} -> {runpath}")
        for dependency in dependencies:
            if dependency.startswith(SYSTEM_DEPENDENCY_PREFIXES):
                continue
            if dependency.startswith("/") and not dependency.startswith(str(root) + "/"):
                failures.append(f"unbundled absolute dependency: {relative_macho} -> {dependency}")
                continue
            candidates = dependency_candidates(
                dependency,
                runpaths,
                macho,
                executable_directories if executable_directories else [macho.parent],
            )
            if any(is_bundled_regular_file(candidate, root) for candidate in candidates):
                continue
            rendered_candidates = ", ".join(str(candidate) for candidate in candidates) or "no LC_RPATH candidates"
            if dependency.startswith("@rpath/"):
                failures.append(
                    f"unresolved @rpath dependency: {relative_macho} -> {dependency}; tried {rendered_candidates}"
                )
            else:
                failures.append(
                    f"unresolved Mach-O dependency: {relative_macho} -> {dependency}; tried {rendered_candidates}"
                )

    if failures:
        raise ClosureError("\n".join(failures))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify-macho-runtime-closure.py <runtime root>", file=sys.stderr)
        return 2
    try:
        verify_runtime_closure(Path(sys.argv[1]))
    except ClosureError as exc:
        print(f"Mach-O runtime closure error: {exc}", file=sys.stderr)
        return 1
    print(f"Mach-O runtime closure verification passed: {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
