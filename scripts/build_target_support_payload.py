#!/usr/bin/env python3
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
from pathlib import Path


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build target-support payload archives for a Cyna target."
    )
    parser.add_argument("--target", required=True, help="target triple, for example thumbv7em-none-eabi")
    parser.add_argument("--clang", required=True, help="path to clang")
    parser.add_argument("--zig", help="use Zig's bundled libc when building the hosted Linux target")
    parser.add_argument("--llvm-ar", required=True, help="path to llvm-ar")
    parser.add_argument("--llvm-nm", help="path to llvm-nm (defaults to the archiver's sibling)")
    parser.add_argument("--output-dir", required=True, help="output directory root")
    parser.add_argument(
        "--hosted-std",
        action="store_true",
        help="also include hosted std objects in libcyna_std.a",
    )
    return parser.parse_args()


def compile_object(clang: Path, zig: Path | None, source: Path, output: Path, target: str, freestanding: bool) -> None:
    if zig is not None:
        zig_targets = {
            "x86_64-unknown-linux-gnu": "x86_64-linux-gnu",
            "aarch64-" + "apple-darwin": "aarch64-macos",
        }
        zig_target = zig_targets.get(target)
        if zig_target is None:
            raise SystemExit(f"--zig is not supported for {target}")
        compiler = [str(zig), "cc", "-target", zig_target]
    else:
        compiler = [str(clang), f"--target={target}"]
    cmd = [
        *compiler,
        "-std=c11",
        "-O2",
        "-c",
        str(source),
        "-o",
        str(output),
    ]
    if freestanding:
        cmd.extend(["-ffreestanding", "-DCYNA_FREESTANDING=1", "-Werror=atomic-alignment"])
    elif target.endswith("-linux-gnu"):
        # glibc exposes Dl_info/dladdr, used by the hosted runtime, under its
        # GNU feature-test profile.
        cmd.append("-D_GNU_SOURCE")
    elif "apple-darwin" in target and platform.system() == "Darwin":
        sdk = subprocess.run(["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True)
        cmd.extend(["-isysroot", sdk.stdout.strip()])
    if target == "arm-none-eabi":
        cmd.append("-mcpu=arm1176jzf-s")
    if target == "riscv64-none-elf":
        cmd.append("-mcmodel=medany")
    run(cmd)


def archive_objects(llvm_ar: Path, archive: Path, objects: list[Path]) -> None:
    run([str(llvm_ar), "rcs", str(archive), *[str(obj) for obj in objects]])


def main() -> int:
    args = parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    if args.zig:
        required_zig = (repo_root / ".zig-version").read_text().strip()
        actual_zig = subprocess.run([args.zig, "version"], check=True, capture_output=True, text=True).stdout.strip()
        if actual_zig != required_zig:
            raise SystemExit(f"hosted Linux payload requires Zig {required_zig}; got {actual_zig}")
    output_dir = Path(args.output_dir).resolve()
    include_dir = output_dir / "include"
    lib_dir = output_dir / "lib"
    build_dir = output_dir / ".build"
    include_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)
    build_dir.mkdir(parents=True, exist_ok=True)

    freestanding = not args.hosted_std

    inventory: dict[str, list[str]] = {}
    for line in (repo_root / "src/runtime/inventory.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        group, path = line.split(" ", 1)
        inventory.setdefault(group, []).append(path)

    def build_sources(sources: list[str]) -> list[Path]:
        objects = []
        for source in sources:
            output = build_dir / (Path(source).stem + ".o")
            compile_object(Path(args.clang).resolve(), Path(args.zig).resolve() if args.zig else None,
                           repo_root / source, output, args.target, freestanding)
            objects.append(output)
        return objects

    runtime_objects = build_sources(inventory["runtime"] + inventory["memory"])
    std_sources = inventory["std"] + (inventory["hosted"] if args.hosted_std else [])
    archive_objects(Path(args.llvm_ar).resolve(), lib_dir / "libcyna.a", runtime_objects)
    archive_objects(Path(args.llvm_ar).resolve(), lib_dir / "libcyna_std.a", build_sources(std_sources))

    if args.hosted_std:
        nm = Path(args.llvm_nm).resolve() if args.llvm_nm else Path(args.llvm_ar).resolve().with_name("llvm-nm")
        result = subprocess.run(
            [str(nm), "--defined-only", "--extern-only", str(lib_dir / "libcyna_std.a")],
            check=True, capture_output=True, text=True,
        )
        symbols = {line.split()[-1].removeprefix("_") for line in result.stdout.splitlines() if len(line.split()) >= 3}
        missing = set(inventory["hosted-symbol"]) - symbols
        if missing:
            raise SystemExit("target archive is missing required symbols: " + ", ".join(sorted(missing)))

    shutil.copy2(repo_root / "src/runtime/cyna.h", include_dir / "cyna.h")
    print(f"built target-support payloads: {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
