#!/usr/bin/env python3
"""Reject direct and indirect reverse dependencies between compiler phases."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path
import re
import sys


PHASES = {"lexer": 0, "parser": 1, "sema": 2, "lower": 3, "backend": 4}
IMPORT = re.compile(r'@import\s*\(\s*"([^"\\\n]+\.zig)"\s*\)')


def _skip_quoted(source: str, start: int) -> int:
    quote = source[start]
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
        elif source[index] == quote:
            return index + 1
        else:
            index += 1
    return index


def imports(source: str) -> list[tuple[str, int]]:
    """Find literal Zig imports in code, skipping comments and string data."""
    found = []
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end + 1
            continue
        if source.startswith("\\\\", index) and not source[source.rfind("\n", 0, index) + 1 : index].strip():
            end = source.find("\n", index)
            index = len(source) if end < 0 else end + 1
            continue
        if source[index] in {'"', "'"}:
            index = _skip_quoted(source, index)
            continue
        match = IMPORT.match(source, index)
        if match:
            found.append((match.group(1), source.count("\n", 0, index) + 1))
            index = match.end()
            continue
        index += 1
    return found


def phase(path: Path, src: Path) -> str | None:
    parts = path.relative_to(src).parts
    if len(parts) >= 3 and parts[0] == "compiler" and parts[1] in PHASES:
        return parts[1]
    return None


def violations(root: Path) -> list[str]:
    root = root.resolve()
    src = root / "src"
    graph: dict[Path, list[tuple[Path, int]]] = {}
    for source in sorted(src.rglob("*.zig")):
        edges = []
        for name, line in imports(source.read_text()):
            if not name.startswith("."):
                continue
            target = (source.parent / name).resolve()
            if target.is_relative_to(src) and target.is_file():
                edges.append((target, line))
        graph[source] = edges

    failures = []
    for source in graph:
        source_phase = phase(source, src)
        if source_phase is None:
            continue
        previous: dict[Path, tuple[Path, int]] = {}
        visited = {source}
        pending = deque([source])
        violation = None
        while pending and violation is None:
            current = pending.popleft()
            for target, line in graph[current]:
                if target in visited:
                    continue
                visited.add(target)
                previous[target] = (current, line)
                target_phase = phase(target, src)
                if target_phase is not None and PHASES[target_phase] > PHASES[source_phase]:
                    violation = (target, target_phase)
                    break
                pending.append(target)
        if violation is None:
            continue
        target, target_phase = violation
        path = [target]
        while path[-1] != source:
            path.append(previous[path[-1]][0])
        path.reverse()
        first_line = previous[path[1]][1]
        route = " -> ".join(node.relative_to(root).as_posix() for node in path)
        failures.append(
            f"{source.relative_to(root)}:{first_line}: {source_phase} reaches later phase "
            f"{target_phase} via {route}"
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    failures = violations(args.root.resolve())
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Compiler phase imports: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
