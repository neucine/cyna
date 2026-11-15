#!/usr/bin/env python3

import argparse
import shutil
import subprocess
from pathlib import Path
from typing import Optional


def run(cmd: list[str], *, cwd: Optional[Path] = None) -> None:
    print("+ " + " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=str(cwd) if cwd else None)


def capture(cmd: list[str]) -> str:
    result = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def clang_resource_dir(clang: Path) -> Path:
    return Path(capture([str(clang), "-print-resource-dir"]))


def clang_builtins_destination(clang: Path, target: str) -> Path:
    value = capture([str(clang), f"--target={target}", "-rtlib=compiler-rt", "-print-libgcc-file-name"])
    return Path(value)


def find_builtins_archive(build_dir: Path, target: str) -> Path:
    candidates = sorted(build_dir.rglob("libclang_rt.builtins*.a"))
    if not candidates:
        raise SystemExit(f"compiler-rt build did not produce a builtins archive for {target}")
    exact = [path for path in candidates if path.name == "libclang_rt.builtins.a"]
    return exact[0] if exact else candidates[0]


def builtins_output_path(args: argparse.Namespace, target: str) -> Path:
    resource_dir = clang_resource_dir(args.clang)
    toolchain_root = resource_dir.parent.parent.parent
    return args.output_dir / clang_builtins_destination(args.clang, target).relative_to(toolchain_root)


def build_target(args: argparse.Namespace, target: str) -> Path:
    dest = builtins_output_path(args, target)
    if dest.exists() and not args.clean and not args.force:
        print(f"compiler-rt builtins already exist for {target}: {dest}")
        return dest

    build_target = args.build_target or target
    build_dir = args.build_dir / target
    if build_dir.exists() and args.clean:
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True, exist_ok=True)

    install_dir = args.output_dir / "install" / target
    if install_dir.exists() and args.clean:
        shutil.rmtree(install_dir)
    install_dir.mkdir(parents=True, exist_ok=True)

    c_flags = f"--target={build_target} -ffreestanding -fno-builtin"
    asm_flags = f"--target={build_target} -ffreestanding"
    if args.target_cpu:
        c_flags = f"--target={build_target} -mcpu={args.target_cpu} -ffreestanding -fno-builtin"
        asm_flags = f"--target={build_target} -mcpu={args.target_cpu} -ffreestanding"

    cmake = [
        args.cmake,
        "-S",
        str(args.llvm_project / "compiler-rt"),
        "-B",
        str(build_dir),
        "-G",
        args.generator,
        f"-DCMAKE_C_COMPILER={args.clang}",
        f"-DCMAKE_AR={args.llvm_ar}",
        f"-DCMAKE_RANLIB={args.llvm_ranlib}",
        "-DCMAKE_SYSTEM_NAME=Generic",
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
        f"-DCMAKE_C_COMPILER_TARGET={build_target}",
        f"-DCMAKE_ASM_COMPILER_TARGET={build_target}",
        f"-DCMAKE_C_FLAGS={c_flags}",
        f"-DCMAKE_ASM_FLAGS={asm_flags}",
        "-DCOMPILER_RT_BUILD_BUILTINS=ON",
        "-DCOMPILER_RT_BUILD_SANITIZERS=OFF",
        "-DCOMPILER_RT_BUILD_XRAY=OFF",
        "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
        "-DCOMPILER_RT_BUILD_PROFILE=OFF",
        "-DCOMPILER_RT_BUILD_MEMPROF=OFF",
        "-DCOMPILER_RT_BUILD_ORC=OFF",
        "-DCOMPILER_RT_BUILD_GWP_ASAN=OFF",
        "-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF",
        "-DCOMPILER_RT_BAREMETAL_BUILD=ON",
        "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
        f"-DCMAKE_INSTALL_PREFIX={install_dir}",
    ]

    run(cmake)
    run([args.cmake, "--build", str(build_dir)])

    built_archive = find_builtins_archive(build_dir, target)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built_archive, dest)
    print(f"built compiler-rt builtins for {target}: {dest}")
    return dest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build compiler-rt builtins archives for Cyna freestanding toolchain bundles."
    )
    parser.add_argument("--llvm-project", type=Path, required=True, help="path to an llvm-project checkout")
    parser.add_argument("--target", action="append", required=True, help="target triple to build; may be repeated")
    parser.add_argument(
        "--build-target",
        help="optional compiler-rt build triple; the archive is still staged for --target",
    )
    parser.add_argument("--output-dir", type=Path, default=Path("dist/compiler-rt"), help="output root")
    parser.add_argument("--build-dir", type=Path, default=Path(".zig-cache/compiler-rt"), help="CMake build root")
    parser.add_argument("--clang", type=Path, default=Path("clang"))
    parser.add_argument("--llvm-ar", type=Path, default=Path("llvm-ar"))
    parser.add_argument("--llvm-ranlib", type=Path, default=Path("llvm-ranlib"))
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--generator", default="Ninja")
    parser.add_argument("--target-cpu", help="optional -mcpu value for all requested targets")
    parser.add_argument("--clean", action="store_true", help="remove existing per-target build/install dirs first")
    parser.add_argument("--force", action="store_true", help="rebuild even when the staged archive already exists")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.build_target and len(args.target) != 1:
        raise SystemExit("--build-target requires exactly one --target")
    args.llvm_project = args.llvm_project.resolve()
    args.output_dir = args.output_dir.resolve()
    args.build_dir = args.build_dir.resolve()
    if not (args.llvm_project / "compiler-rt" / "CMakeLists.txt").exists():
        raise SystemExit(f"not an llvm-project checkout with compiler-rt: {args.llvm_project}")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    for target in args.target:
        build_target(args, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
