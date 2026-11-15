#!/usr/bin/env python3
"""Print a stable content identity for this compiler and bundled contracts."""

import hashlib
from pathlib import Path
import sys


def compiler_identity(root: Path, dependency: Path, zig: str, optimize: str, target: str) -> str:
    digest = hashlib.sha256(b"cyna-compiler-build-v1\0")

    def record(name: str, contents: bytes) -> None:
        encoded = name.encode()
        digest.update(len(encoded).to_bytes(8, "little"))
        digest.update(encoded)
        digest.update(len(contents).to_bytes(8, "little"))
        digest.update(contents)

    for name, value in (("zig", zig), ("optimize", optimize), ("target", target)):
        record(name, value.encode())
    suffixes = {".zig", ".zon", ".cy", ".c", ".h", ".toml"}
    inputs = [root / "build.zig", root / "build.zig.zon", root / ".zig-version",
              root / "scripts/compiler_identity.py"]
    for directory in (root / "src", root / "packages"):
        inputs.extend(path for path in directory.rglob("*") if path.is_file() and
                      (path.suffix in suffixes or path.name == "inventory.txt"))
    for path in sorted(inputs):
        record(path.relative_to(root).as_posix(), path.read_bytes())
    dependency_inputs = [dependency / "build.zig", dependency / "build.zig.zon"]
    dependency_inputs.extend(path for path in (dependency / "src").rglob("*")
                             if path.is_file() and path.suffix in suffixes)
    for path in sorted(dependency_inputs):
        record("zig_libs/" + path.relative_to(dependency).as_posix(), path.read_bytes())
    return digest.hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("usage: compiler_identity.py ROOT ZIG_LIBS ZIG_VERSION OPTIMIZE TARGET")
    print(compiler_identity(Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:]))
