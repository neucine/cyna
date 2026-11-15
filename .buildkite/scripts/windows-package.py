#!/usr/bin/env python3
"""Assemble the Windows archive from the verified Buildkite inputs."""

import hashlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path


HOST = "x86_64-pc-windows-gnu"
ROOT = Path(__file__).resolve().parents[2]
version_match = re.search(r'const cyna_version = "([^"]+)"', (ROOT / "build.zig").read_text())
if version_match is None:
    raise SystemExit("Cyna version is missing from build.zig")
VERSION = version_match.group(1)
SOURCE = ROOT
INPUTS = ROOT / "dist/windows-inputs"
STAGE = ROOT / "dist/distributions" / VERSION / HOST


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def copy_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def built_library(name: str) -> Path:
    lib_dir = SOURCE / "zig-out/lib"
    for candidate in (f"lib{name}.a", f"{name}.lib", f"lib{name}.lib"):
        path = lib_dir / candidate
        if path.is_file():
            return path
    raise SystemExit(f"missing Windows {name} library; found: {[path.name for path in lib_dir.glob('*')]}")


def extract(archive: Path, dest: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for name in bundle.namelist():
            path = (dest / name).resolve()
            if not path.is_relative_to(dest.resolve()):
                raise SystemExit(f"unsafe archive path: {name}")
        bundle.extractall(dest)


def target_manifest(target: str) -> str:
    path = STAGE / "targets" / target
    return "\n".join((
        'kind = "target-support"',
        f'target = "{target}"',
        'revision = 1',
        'provisioned_from = "artifact"',
        'runtime_header = "include/cyna.h"',
        f'runtime_header_sha256 = "{digest(path / "include/cyna.h")}"',
        'runtime_archive = "lib/libcyna.a"',
        f'runtime_archive_sha256 = "{digest(path / "lib/libcyna.a")}"',
        'std_archive = "lib/libcyna_std.a"',
        f'std_archive_sha256 = "{digest(path / "lib/libcyna_std.a")}"',
        '',
    ))


def main() -> None:
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)
    copy_file(SOURCE / "zig-out/bin/cyna.exe", STAGE / "bin/cyna.exe")
    shutil.copytree(SOURCE / "src/runtime", STAGE / "src/runtime")
    inventory = (SOURCE / "src/runtime/inventory.txt").read_text(encoding="utf-8")
    for line in inventory.splitlines():
        if line.startswith("package "):
            name = line.split(" ", 1)[1]
            package = STAGE / "packages" / name
            copy_file(SOURCE / "packages" / name / "cyna.toml", package / "cyna.toml")
            shutil.copytree(SOURCE / "packages" / name / "src", package / "src")

    extract(INPUTS / "windows-llvm.zip", STAGE)
    shutil.copy2(STAGE / "llvm/bin/clang.exe", STAGE / "llvm/bin/clang-ir.exe")
    copy_file(ROOT / "dist/windows-clang-wrapper.exe", STAGE / "llvm/bin/clang.exe")
    zig_root = SOURCE / ".tools/zig/0.17.0"
    copy_file(zig_root / "zig.exe", STAGE / "llvm/zig/zig.exe")
    shutil.copytree(zig_root / "lib", STAGE / "llvm/zig/lib")
    support = INPUTS / "support" / "targets"
    for target in support.iterdir():
        if target.is_dir() and target.name != HOST:
            shutil.copytree(target, STAGE / "targets" / target.name)
    native = STAGE / "targets" / HOST
    copy_file(SOURCE / "src/runtime/cyna.h", native / "include/cyna.h")
    copy_file(built_library("cyna"), native / "lib/libcyna.a")
    copy_file(built_library("cyna_std"), native / "lib/libcyna_std.a")
    (native / "manifest.toml").write_text(target_manifest(HOST), encoding="utf-8")

    llvm = STAGE / "llvm"
    builtins = INPUTS / "support" / "compiler-rt"
    paths = []
    for archive in sorted(builtins.rglob("libclang_rt.builtins.a")):
        rel = Path("lib/clang/22/lib") / archive.relative_to(builtins)
        copy_file(archive, llvm / rel)
        paths.append(rel.as_posix())
    tools = ("clang.exe", "llvm-ar.exe", "ld.lld.exe", "llvm-objcopy.exe")
    tool_keys = ("compiler", "archiver", "linker", "objcopy")
    lines = ['id = "llvm"', 'version = "22.1.2"', 'family = "llvm"', f'host = "{HOST}"']
    for key, tool in zip(tool_keys, tools):
        path = llvm / "bin" / tool
        lines.extend((f'{key} = "bin/{tool}"', f'{key}_sha256 = "{digest(path)}"'))
    lines.extend((
        f'compiler_rt_builtins = "{",".join(paths)}"',
        f'compiler_rt_builtins_sha256 = "{",".join(digest(llvm / path) for path in paths)}"',
        'provisioned_from = "artifact"',
        '',
    ))
    (llvm / "bundle.toml").write_text("\n".join(lines), encoding="utf-8")
    (STAGE / "manifest.toml").write_text("\n".join((
        'kind = "distribution"', f'version = "{VERSION}"', f'host = "{HOST}"',
        'bin = "bin/cyna.exe"', 'llvm = "llvm"', 'packages = "packages"',
        'targets = "targets"', '',
    )), encoding="utf-8")
    (STAGE / "BUILDINFO.txt").write_text(
        f"Cyna source commit: {subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()}\n"
        "zig-libs: a91b58271be94a4e402a856403fe0fa83add1709\n"
        "LLVM: llvmorg-22.1.2 (official Windows x64 archive)\n",
        encoding="utf-8",
    )
    archive = STAGE.parent / f"{HOST}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for path in sorted(STAGE.rglob("*")):
            if path.is_file():
                output.write(path, (Path(HOST) / path.relative_to(STAGE)).as_posix())
    print(f"Windows distribution: {archive}")
    print(f"SHA-256: {digest(archive)}")


if __name__ == "__main__":
    main()
