#!/usr/bin/env python3

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional
from clang_resources import stage_clang_resource_headers, resource_header_manifest


def sha256_hex(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def copy_tool(src: Path, dst: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    dst.chmod(dst.stat().st_mode | 0o111)
    return sha256_hex(dst)


def copy_file(src: Path, dst: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return sha256_hex(dst)


def clang_resource_relative_path(path: Path) -> str:
    parts = path.parts
    marker = ("lib", "clang")
    for index in range(0, len(parts) - 1):
        if tuple(parts[index : index + 2]) == marker:
            return Path(*parts[index:]).as_posix()
    raise SystemExit(f"compiler-rt archive is not under a Clang resource lib/clang tree: {path}")


def clang_expected_builtins_archive(clang: Path, target: str) -> Optional[Path]:
    result = subprocess.run(
        [str(clang), f"--target={target}", "-rtlib=compiler-rt", "-print-libgcc-file-name"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    if not value:
        return None
    path = Path(value)
    return path if path.exists() else None


def parse_builtins_input(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise SystemExit("--compiler-rt-builtins entries must use TARGET=PATH")
    target, raw_path = value.split("=", 1)
    target = target.strip()
    path = Path(raw_path).expanduser().resolve()
    if not target:
        raise SystemExit("compiler-rt builtins target must not be empty")
    if not path.exists():
        raise SystemExit(f"compiler-rt builtins archive not found for {target}: {path}")
    return target, path


def collect_compiler_rt_builtins(args: argparse.Namespace, clang: Path) -> list[tuple[str, Path]]:
    found: dict[str, Path] = {}
    for entry in args.compiler_rt_builtins:
        target, path = parse_builtins_input(entry)
        found[target] = path

    for target in args.compiler_rt_builtins_target:
        target = target.strip()
        if not target:
            continue
        archive = clang_expected_builtins_archive(clang, target)
        if archive is None:
            if args.require_compiler_rt_builtins:
                raise SystemExit(f"clang did not provide compiler-rt builtins for {target}")
            print(f"warning: compiler-rt builtins not found for {target}; skipping")
            continue
        found[target] = archive.resolve()

    return sorted(found.items())


def stage_compiler_rt_builtins(stage_root: Path, builtins: list[tuple[str, Path]]) -> tuple[str, str]:
    relative_paths: list[str] = []
    hashes: list[str] = []
    for target, source in builtins:
        relative = clang_resource_relative_path(source)
        dest = stage_root / relative
        digest = copy_file(source, dest)
        relative_paths.append(relative)
        hashes.append(digest)
        print(f"staged compiler-rt builtins for {target}: {relative}")
    return ",".join(relative_paths), ",".join(hashes)


def copy_lld_runtime_deps(ld_lld: Path, stage_root: Path) -> list[Path]:
    lld_lib_dir = ld_lld.parent.parent / "lib"
    if not lld_lib_dir.exists():
        return []

    copied: list[Path] = []
    for pattern in ("liblld*.dylib", "liblld*.so", "liblld*.so.*"):
        for src in sorted(lld_lib_dir.glob(pattern)):
            dst = stage_root / "lib" / src.name
            copy_file(src, dst)
            copied.append(dst)
    return copied


def render_manifest(
    args: argparse.Namespace,
    compiler_hash: str,
    archiver_hash: str,
    linker_hash: Optional[str],
    objcopy_hash: Optional[str],
    libllvm_hash: Optional[str],
    libclang_cpp_hash: Optional[str],
    compiler_rt_builtins: str,
    compiler_rt_builtins_hashes: str,
) -> str:
    lines = [
        f'id = "{args.bundle_id}"',
        f'version = "{args.bundle_version}"',
        f'family = "{args.family}"',
        f'host = "{args.host_tag}"',
        'compiler = "bin/clang"',
        f'compiler_sha256 = "{compiler_hash}"',
        'archiver = "bin/llvm-ar"',
        f'archiver_sha256 = "{archiver_hash}"',
    ]
    if linker_hash is not None:
        lines.append('linker = "bin/ld.lld"')
        lines.append(f'linker_sha256 = "{linker_hash}"')
    else:
        lines.append('linker = ""')
        lines.append('linker_sha256 = ""')
    if objcopy_hash is not None:
        lines.append('objcopy = "bin/llvm-objcopy"')
        lines.append(f'objcopy_sha256 = "{objcopy_hash}"')
    else:
        lines.append('objcopy = ""')
        lines.append('objcopy_sha256 = ""')
    if libllvm_hash is not None:
        lines.append('libllvm = "lib/libLLVM.dylib"')
        lines.append(f'libllvm_sha256 = "{libllvm_hash}"')
    else:
        lines.append('libllvm = ""')
        lines.append('libllvm_sha256 = ""')
    if libclang_cpp_hash is not None:
        lines.append('libclang_cpp = "lib/libclang-cpp.dylib"')
        lines.append(f'libclang_cpp_sha256 = "{libclang_cpp_hash}"')
    else:
        lines.append('libclang_cpp = ""')
        lines.append('libclang_cpp_sha256 = ""')
    lines.append(f'compiler_rt_builtins = "{compiler_rt_builtins}"')
    lines.append(f'compiler_rt_builtins_sha256 = "{compiler_rt_builtins_hashes}"')
    lines.append('provisioned_from = "artifact"')
    lines.append("")
    return "\n".join(lines)


def render_target_support_manifest(args: argparse.Namespace) -> str:
    lines = [
        'kind = "target-support"',
        f'target = "{args.target_id}"',
        f"revision = {args.target_revision}",
        'provisioned_from = "artifact"',
    ]
    payloads = [
        ("runtime_header", args.runtime_header, "include/cyna.h"),
        ("runtime_archive", args.runtime_archive, "lib/libcyna.a"),
        ("std_archive", args.std_archive, "lib/libcyna_std.a"),
    ]
    for key, source, relative_path in payloads:
        if not source:
            continue
        staged_path = Path(relative_path)
        sha = sha256_hex(Path(source).resolve())
        lines.append(f'{key} = "{staged_path.as_posix()}"')
        lines.append(f'{key}_sha256 = "{sha}"')
    lines.append("")
    return "\n".join(lines)


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def upload_to_r2(args: argparse.Namespace, stage_root: Path, relative_dir: str) -> None:
    account_id = require_env("CYNA_R2_ACCOUNT_ID")
    bucket = require_env("CYNA_R2_BUCKET")
    endpoint = f"https://{account_id}.r2.cloudflarestorage.com"
    key_prefix = os.environ.get("CYNA_R2_PREFIX", "").strip("/")
    remote_prefix = f"{key_prefix}/{relative_dir}" if key_prefix else relative_dir
    remote_url = f"s3://{bucket}/{remote_prefix}"

    cmd = [
        "aws",
        "--endpoint-url",
        endpoint,
    ]
    profile = os.environ.get("AWS_PROFILE", "").strip()
    if profile:
        cmd.extend(["--profile", profile])
    cmd.extend(
        [
            "s3",
            "sync",
            str(stage_root),
            remote_url,
            "--delete",
        ]
    )

    print(f"uploading bundle to {remote_url}")
    subprocess.run(cmd, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stage and optionally publish a Cyna toolchain bundle to Cloudflare R2."
    )
    parser.add_argument("--kind", choices=["llvm", "target-support"], default="llvm")
    parser.add_argument("--bundle-id", help="bundle id, for example llvm")
    parser.add_argument("--bundle-version", help="bundle version, for example 22.1.2")
    parser.add_argument("--host-tag", help="host triple, for example aarch64-apple-darwin")
    parser.add_argument("--family", default="llvm", help="toolchain family, defaults to llvm")
    parser.add_argument("--clang", help="path to clang executable")
    parser.add_argument("--llvm-ar", help="path to llvm-ar or ar executable")
    parser.add_argument("--ld-lld", help="path to ld.lld executable")
    parser.add_argument("--llvm-objcopy", help="path to llvm-objcopy or objcopy executable")
    parser.add_argument("--libllvm", help="path to libLLVM.dylib")
    parser.add_argument("--libclang-cpp", help="path to libclang-cpp.dylib")
    parser.add_argument(
        "--compiler-rt-builtins",
        action="append",
        default=[],
        metavar="TARGET=PATH",
        help="stage a compiler-rt builtins archive for TARGET from PATH; may be repeated",
    )
    parser.add_argument(
        "--compiler-rt-builtins-target",
        action="append",
        default=[],
        metavar="TARGET",
        help="ask clang for TARGET's compiler-rt builtins archive and stage it if present; may be repeated",
    )
    parser.add_argument(
        "--require-compiler-rt-builtins",
        action="store_true",
        help="fail if any --compiler-rt-builtins-target archive cannot be discovered",
    )
    parser.add_argument("--target-id", help="target support id, for example thumbv7em-none-eabi")
    parser.add_argument("--target-revision", type=int, help="target support revision, for example 1")
    parser.add_argument("--runtime-header", help="path to cyna.h for a target-support bundle")
    parser.add_argument("--runtime-archive", help="path to libcyna.a for a target-support bundle")
    parser.add_argument("--std-archive", help="path to libcyna_std.a for a target-support bundle")
    parser.add_argument(
        "--stage-dir",
        default="dist/toolchains",
        help="local staging root, defaults to dist/toolchains",
    )
    parser.add_argument(
        "--upload",
        action="store_true",
        help="upload the staged bundle to Cloudflare R2 using the aws CLI",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    stage_root_base = Path(args.stage_dir).resolve()

    if args.kind == "llvm":
        if not args.bundle_id or not args.bundle_version or not args.host_tag:
            raise SystemExit("--bundle-id, --bundle-version, and --host-tag are required for --kind llvm")
        if not args.clang or not args.llvm_ar:
            raise SystemExit("--clang and --llvm-ar are required for --kind llvm")
        clang = Path(args.clang).resolve()
        llvm_ar = Path(args.llvm_ar).resolve()
        ld_lld = Path(args.ld_lld).resolve() if args.ld_lld else None
        llvm_objcopy = Path(args.llvm_objcopy).resolve() if args.llvm_objcopy else None
        libllvm = Path(args.libllvm).resolve() if args.libllvm else None
        libclang_cpp = Path(args.libclang_cpp).resolve() if args.libclang_cpp else None
        for path in [clang, llvm_ar, ld_lld, llvm_objcopy, libllvm, libclang_cpp]:
            if path is None:
                continue
            if not path.exists():
                raise SystemExit(f"tool not found: {path}")

        relative_dir = f"{args.bundle_id}/{args.bundle_version}/{args.host_tag}"
        stage_root = stage_root_base / relative_dir
    else:
        if not args.target_id or args.target_revision is None:
            raise SystemExit("--target-id and --target-revision are required for --kind target-support")
        for path in [args.runtime_header, args.runtime_archive, args.std_archive]:
            if path and not Path(path).resolve().exists():
                raise SystemExit(f"payload file not found: {path}")
        relative_dir = f"targets/{args.target_id}/{args.target_revision}"
        stage_root = stage_root_base / relative_dir

    if stage_root.exists():
        shutil.rmtree(stage_root)
    stage_root.mkdir(parents=True, exist_ok=True)

    if args.kind == "llvm":
        resource_headers = stage_clang_resource_headers(clang, stage_root)
        (stage_root / "bin").mkdir(parents=True, exist_ok=True)
        compiler_hash = copy_tool(clang, stage_root / "bin" / "clang")
        archiver_hash = copy_tool(llvm_ar, stage_root / "bin" / "llvm-ar")
        linker_hash = None
        objcopy_hash = None
        libllvm_hash = None
        libclang_cpp_hash = None
        compiler_rt_builtins_paths = ""
        compiler_rt_builtins_hashes = ""
        if ld_lld is not None:
            linker_hash = copy_tool(ld_lld, stage_root / "bin" / "ld.lld")
            copy_lld_runtime_deps(ld_lld, stage_root)
        if llvm_objcopy is not None:
            objcopy_hash = copy_tool(llvm_objcopy, stage_root / "bin" / "llvm-objcopy")
        if libllvm is not None:
            libllvm_hash = copy_file(libllvm, stage_root / "lib" / "libLLVM.dylib")
        if libclang_cpp is not None:
            libclang_cpp_hash = copy_file(libclang_cpp, stage_root / "lib" / "libclang-cpp.dylib")
        compiler_rt_builtins = collect_compiler_rt_builtins(args, clang)
        if compiler_rt_builtins:
            compiler_rt_builtins_paths, compiler_rt_builtins_hashes = stage_compiler_rt_builtins(stage_root, compiler_rt_builtins)
        manifest = render_manifest(
            args,
            compiler_hash,
            archiver_hash,
            linker_hash,
            objcopy_hash,
            libllvm_hash,
            libclang_cpp_hash,
            compiler_rt_builtins_paths,
            compiler_rt_builtins_hashes,
        )
        manifest += resource_header_manifest(stage_root, resource_headers)
        manifest_path = stage_root / "bundle.toml"
    else:
        if args.runtime_header:
            copy_file(Path(args.runtime_header).resolve(), stage_root / "include" / "cyna.h")
        if args.runtime_archive:
            copy_file(Path(args.runtime_archive).resolve(), stage_root / "lib" / "libcyna.a")
        if args.std_archive:
            copy_file(Path(args.std_archive).resolve(), stage_root / "lib" / "libcyna_std.a")
        manifest = render_target_support_manifest(args)
        manifest_path = stage_root / "manifest.toml"

    manifest_path.write_text(manifest, encoding="utf-8")

    print(f"staged bundle: {stage_root}")
    print(f"manifest: {manifest_path}")

    if args.upload:
        upload_to_r2(args, stage_root, relative_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
