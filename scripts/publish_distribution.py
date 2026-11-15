#!/usr/bin/env python3

import argparse
import hashlib
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from clang_resources import stage_clang_resource_headers, resource_header_manifest


SUPPORTED_TARGETS = [
    ("aarch64-apple-darwin", True),
    ("x86_64-unknown-linux-gnu", True),
    ("aarch64-none-elf", False),
    ("x86_64-none-elf", False),
    ("riscv64-none-elf", False),
    ("riscv32-none-elf", False),
    ("arm-none-eabi", False),
    ("thumbv7em-none-eabi", False),
]
RELEASE_BUILD_CMD = ["zig", "build", "-Doptimize=fast"]


def run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.run(cmd, check=True, cwd=str(cwd) if cwd else None)


def sha256_hex(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def copy_file(src: Path, dst: Path, executable: bool = False) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if executable:
        dst.chmod(dst.stat().st_mode | 0o111)
    return sha256_hex(dst)


def copy_lld_runtime_deps(ld_lld: Path, llvm_root: Path) -> list[Path]:
    lld_lib_dir = ld_lld.parent.parent / "lib"
    if not lld_lib_dir.exists():
        return []

    copied: list[Path] = []
    for pattern in ("liblld*.dylib", "liblld*.so", "liblld*.so.*"):
        for src in sorted(lld_lib_dir.glob(pattern)):
            dst = llvm_root / "lib" / src.name
            copy_file(src, dst)
            copied.append(dst)
    return copied


def detect_host() -> str:
    system = platform.system()
    machine = platform.machine()
    if system == "Darwin" and machine == "arm64":
        return "aarch64-apple-darwin"
    if system == "Darwin" and machine == "x86_64":
        return "x86_64-apple-darwin"
    if system == "Linux" and machine == "x86_64":
        return "x86_64-unknown-linux-gnu"
    if system == "Windows" and machine in ("AMD64", "x86_64"):
        return "x86_64-pc-windows-gnu"
    raise SystemExit(f"unsupported host: {system} {machine}")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def infer_version(root: Path) -> str:
    source = (root / "build.zig").read_text(encoding="utf-8")
    match = re.search(r'const cyna_version = "([^"]+)"', source)
    if not match:
        raise SystemExit("unable to infer cyna version from build.zig")
    return match.group(1)


def infer_llvm_bundle_version(root: Path) -> str:
    source = (root / "src/build/model.zig").read_text(encoding="utf-8")
    match = re.search(r'\.id = "llvm",\s*\.version = "([^"]+)"', source, re.S)
    if not match:
        raise SystemExit("unable to infer llvm bundle version from src/build/model.zig")
    return match.group(1)


def pick_existing(candidates: list[str]) -> Path:
    for value in candidates:
        path = Path(value)
        if path.exists():
            return path.resolve()
    name = Path(candidates[0]).name
    found = shutil.which(name)
    if found:
        return Path(found).resolve()
    raise SystemExit(f"required tool not found; checked: {', '.join(candidates)}")


def host_family(host: str) -> str:
    if host.endswith("-apple-darwin"):
        return "darwin"
    if host.endswith("-linux-gnu"):
        return "linux"
    if "windows" in host:
        return "windows"
    raise SystemExit(f"unsupported distribution host: {host}")


def executable_suffix(host: str) -> str:
    return ".exe" if host_family(host) == "windows" else ""


def dynamic_library_names(host: str, llvm_lib_dir: Path) -> tuple[str, str]:
    if host_family(host) == "darwin":
        return ("libLLVM.dylib", "libclang-cpp.dylib")
    if host_family(host) == "linux":
        patterns = ("libLLVM.so", "libLLVM.so.*")
        clang_patterns = ("libclang-cpp.so", "libclang-cpp.so.*")

        def first(names: tuple[str, str]) -> str:
            candidates: list[Path] = []
            for pattern in names:
                candidates.extend(sorted(llvm_lib_dir.glob(pattern)))
            if not candidates:
                raise SystemExit(f"no LLVM shared library matching {names} in {llvm_lib_dir}")
            exact = [path for path in candidates if path.name in names]
            return (exact or candidates)[0].name

        return (first(patterns), first(clang_patterns))
    raise SystemExit(f"distribution packaging is not implemented for {host}")


def render_llvm_manifest(
    version: str,
    host: str,
    exe_suffix: str,
    libllvm_name: str,
    libclang_cpp_name: str,
    compiler_hash: str,
    archiver_hash: str,
    linker_hash: str,
    objcopy_hash: str,
    libllvm_hash: str,
    libclang_cpp_hash: str,
    compiler_rt_builtins: str,
    compiler_rt_builtins_sha256: str,
) -> str:
    return "\n".join([
        'id = "llvm"',
        f'version = "{version}"',
        'family = "llvm"',
        f'host = "{host}"',
        f'compiler = "bin/clang{exe_suffix}"',
        f'compiler_sha256 = "{compiler_hash}"',
        f'archiver = "bin/llvm-ar{exe_suffix}"',
        f'archiver_sha256 = "{archiver_hash}"',
        f'linker = "bin/ld.lld{exe_suffix}"',
        f'linker_sha256 = "{linker_hash}"',
        f'objcopy = "bin/llvm-objcopy{exe_suffix}"',
        f'objcopy_sha256 = "{objcopy_hash}"',
        f'libllvm = "lib/{libllvm_name}"',
        f'libllvm_sha256 = "{libllvm_hash}"',
        f'libclang_cpp = "lib/{libclang_cpp_name}"',
        f'libclang_cpp_sha256 = "{libclang_cpp_hash}"',
        f'compiler_rt_builtins = "{compiler_rt_builtins}"',
        f'compiler_rt_builtins_sha256 = "{compiler_rt_builtins_sha256}"',
        'provisioned_from = "artifact"',
        "",
    ])


def render_target_manifest(target: str, runtime_header: Path, runtime_archive: Path, std_archive: Path) -> str:
    lines = [
        'kind = "target-support"',
        f'target = "{target}"',
        "revision = 1",
        'provisioned_from = "artifact"',
        'runtime_header = "include/cyna.h"',
        f'runtime_header_sha256 = "{sha256_hex(runtime_header)}"',
        'runtime_archive = "lib/libcyna.a"',
        f'runtime_archive_sha256 = "{sha256_hex(runtime_archive)}"',
        'std_archive = "lib/libcyna_std.a"',
        f'std_archive_sha256 = "{sha256_hex(std_archive)}"',
    ]
    lines.append("")
    return "\n".join(lines)


def render_distribution_manifest(version: str, host: str) -> str:
    return "\n".join([
        'kind = "distribution"',
        f'version = "{version}"',
        f'host = "{host}"',
        'bin = "bin/cyna"',
        'llvm = "llvm"',
        'packages = "packages"',
        'targets = "targets"',
        "",
    ])


def stage_bundled_packages(root: Path, dist_root: Path) -> None:
    for line in (root / "src/runtime/inventory.txt").read_text().splitlines():
        if not line.startswith("package "):
            continue
        name = line.split(" ", 1)[1]
        package_root = dist_root / "packages" / name
        package_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "packages" / name / "cyna.toml", package_root / "cyna.toml")
        shutil.copytree(root / "packages" / name / "src", package_root / "src", dirs_exist_ok=True)


def compiler_rt_builtins_relative_path(clang: Path, target: str) -> Path:
    result = subprocess.run(
        [str(clang), f"--target={target}", "-rtlib=compiler-rt", "-print-libgcc-file-name"],
        check=True,
        text=True,
        capture_output=True,
    )
    archive = Path(result.stdout.strip()).resolve()
    toolchain_root = clang.parent.parent.resolve()
    try:
        return archive.relative_to(toolchain_root)
    except ValueError as error:
        raise SystemExit(
            f"compiler-rt archive path for {target} is outside the LLVM toolchain: {archive}"
        ) from error


def stage_compiler_rt_builtins(
    root: Path,
    bundle_version: str,
    llvm_root: Path,
    clang: Path,
) -> tuple[str, str]:
    source_root = root / "dist/compiler-rt" / f"llvm-{bundle_version}"
    required_paths = [
        compiler_rt_builtins_relative_path(clang, target)
        for target, hosted in SUPPORTED_TARGETS
        if not hosted
    ]
    missing = [path for path in required_paths if not (source_root / path).is_file()]
    if missing:
        rendered = "\n".join(f"  - {path.as_posix()}" for path in missing)
        raise SystemExit(
            "distribution is missing compiler-rt builtins for advertised freestanding targets:\n"
            f"{rendered}"
        )

    paths: list[str] = []
    hashes: list[str] = []
    for src in sorted(source_root.rglob("libclang_rt.builtins.a")):
        relative_path = src.relative_to(source_root).as_posix()
        dst = llvm_root / relative_path
        hashes.append(copy_file(src, dst))
        paths.append(relative_path)
    return (",".join(paths), ",".join(hashes))


def stage_llvm_payload(args: argparse.Namespace, bundle_version: str, host: str, dist_root: Path) -> None:
    llvm_root = dist_root / "llvm"
    exe_suffix = executable_suffix(host)
    resource_headers = stage_clang_resource_headers(args.clang, llvm_root)
    compiler_hash = copy_file(args.clang, llvm_root / f"bin/clang{exe_suffix}", executable=True)
    archiver_hash = copy_file(args.llvm_ar, llvm_root / f"bin/llvm-ar{exe_suffix}", executable=True)
    linker_hash = copy_file(args.ld_lld, llvm_root / f"bin/ld.lld{exe_suffix}", executable=True)
    objcopy_hash = copy_file(args.llvm_objcopy, llvm_root / f"bin/llvm-objcopy{exe_suffix}", executable=True)
    llvm_root_src = args.clang.parent.parent
    libllvm_name, libclang_cpp_name = dynamic_library_names(host, llvm_root_src / "lib")
    libllvm_hash = copy_file(llvm_root_src / "lib" / libllvm_name, llvm_root / "lib" / libllvm_name)
    libclang_cpp_hash = copy_file(llvm_root_src / "lib" / libclang_cpp_name, llvm_root / "lib" / libclang_cpp_name)
    copy_lld_runtime_deps(args.ld_lld, llvm_root)
    compiler_rt_builtins, compiler_rt_builtins_sha256 = stage_compiler_rt_builtins(
        repo_root(),
        bundle_version,
        llvm_root,
        args.clang,
    )
    manifest = render_llvm_manifest(
        bundle_version,
        host,
        exe_suffix,
        libllvm_name,
        libclang_cpp_name,
        compiler_hash,
        archiver_hash,
        linker_hash,
        objcopy_hash,
        libllvm_hash,
        libclang_cpp_hash,
        compiler_rt_builtins,
        compiler_rt_builtins_sha256,
    )
    manifest += resource_header_manifest(llvm_root, resource_headers)
    (llvm_root / "bundle.toml").write_text(manifest, encoding="utf-8")


def build_target_supports(root: Path, args: argparse.Namespace, dist_root: Path) -> None:
    helper = root / "scripts/build_target_support_payload.py"
    with tempfile.TemporaryDirectory(prefix="cyna-dist-targets.") as tmp:
        tmp_root = Path(tmp)
        for target, hosted in SUPPORTED_TARGETS:
            target_root = dist_root / "targets" / target
            target_root.mkdir(parents=True, exist_ok=True)
            if target == args.host:
                copy_file(root / "src/runtime/cyna.h", target_root / "include/cyna.h")
                copy_file(root / "zig-out/lib/libcyna.a", target_root / "lib/libcyna.a")
                copy_file(root / "zig-out/lib/libcyna_std.a", target_root / "lib/libcyna_std.a")
                manifest = render_target_manifest(
                    target,
                    target_root / "include/cyna.h",
                    target_root / "lib/libcyna.a",
                    target_root / "lib/libcyna_std.a",
                )
                (target_root / "manifest.toml").write_text(manifest, encoding="utf-8")
                continue

            output_root = tmp_root / target
            cmd = [
                "python3",
                str(helper),
                "--target",
                target,
                "--clang",
                str(args.clang),
                "--llvm-ar",
                str(args.llvm_ar),
                "--output-dir",
                str(output_root),
            ]
            if hosted:
                cmd.append("--hosted-std")
            if hosted:
                if args.zig is None:
                    raise SystemExit("hosted cross-targets require the pinned Zig compiler on PATH or --zig")
                cmd.extend(["--zig", str(args.zig)])
            run(cmd, cwd=root)
            shutil.copytree(output_root / "include", target_root / "include", dirs_exist_ok=True)
            shutil.copytree(output_root / "lib", target_root / "lib", dirs_exist_ok=True)
            manifest = render_target_manifest(
                target,
                target_root / "include/cyna.h",
                target_root / "lib/libcyna.a",
                target_root / "lib/libcyna_std.a",
            )
            (target_root / "manifest.toml").write_text(manifest, encoding="utf-8")


def normalize_tarinfo(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    if info.isdir():
        info.mode = 0o755
    elif info.issym() or info.islnk():
        pass
    else:
        info.mode = 0o755 if info.mode & 0o111 else 0o644
    return info


def create_archive(stage_root: Path, version: str, host: str) -> Path:
    archive_path = stage_root / version / f"{host}.tar.gz"
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    source_root = stage_root / version / host
    import gzip

    with archive_path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
                tar.add(source_root, arcname=host, recursive=False, filter=normalize_tarinfo)
                for current, dirs, files in os.walk(source_root):
                    dirs.sort()
                    for name in sorted(files) + dirs:
                        path = Path(current) / name
                        relative = path.relative_to(source_root)
                        tar.add(
                            path,
                            arcname=str(Path(host) / relative),
                            recursive=False,
                            filter=normalize_tarinfo,
                        )
    return archive_path


def stage_bootstrap_script(root: Path, stage_root: Path) -> Path:
    bootstrap_path = stage_root / "install.sh"
    copy_file(root / "scripts/install_distribution.sh", bootstrap_path, executable=True)
    return bootstrap_path


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def upload_distribution(stage_root: Path, version: str, host: str, archive_path: Path, bootstrap_path: Path) -> None:
    account_id = require_env("CYNA_R2_ACCOUNT_ID")
    bucket = require_env("CYNA_R2_BUCKET")
    endpoint = f"https://{account_id}.r2.cloudflarestorage.com"
    profile = os.environ.get("AWS_PROFILE", "").strip()
    key_prefix = os.environ.get("CYNA_R2_PREFIX", "distributions").strip("/")

    common = ["aws", "--endpoint-url", endpoint]
    if profile:
        common.extend(["--profile", profile])

    remote_dir = f"s3://{bucket}/{key_prefix}/{version}/{host}"
    run(common + ["s3", "sync", str(stage_root / version / host), remote_dir, "--delete"])

    remote_archive = f"s3://{bucket}/{key_prefix}/{version}/{host}.tar.gz"
    run(common + ["s3", "cp", str(archive_path), remote_archive])

    remote_bootstrap = f"s3://{bucket}/{key_prefix}/install.sh"
    run(common + ["s3", "cp", str(bootstrap_path), remote_bootstrap])


def parse_args() -> argparse.Namespace:
    root = repo_root()
    parser = argparse.ArgumentParser(description="Stage and optionally publish a Cyna host distribution.")
    parser.add_argument("--version", default=infer_version(root), help="Cyna version to publish")
    parser.add_argument("--host", default=detect_host(), help="host triple, for example aarch64-apple-darwin")
    parser.add_argument("--stage-dir", default="dist/distributions", help="staging root, defaults to dist/distributions")
    parser.add_argument("--upload", action="store_true", help="upload staged distribution to R2 with the aws CLI")
    parser.add_argument("--prebuilt-binary", action="store_true",
                        help="package the binary already built in this workspace")
    parser.add_argument("--clang", type=Path, default=pick_existing([
        "/opt/homebrew/opt/llvm/bin/clang",
        "/usr/local/opt/llvm/bin/clang",
        "/usr/lib/llvm-22/bin/clang",
        "/usr/bin/clang",
    ]), help="path to clang")
    parser.add_argument("--llvm-ar", type=Path, default=pick_existing([
        "/opt/homebrew/opt/llvm/bin/llvm-ar",
        "/usr/local/opt/llvm/bin/llvm-ar",
        "/usr/lib/llvm-22/bin/llvm-ar",
        "/usr/bin/llvm-ar",
    ]), help="path to llvm-ar")
    parser.add_argument("--ld-lld", type=Path, default=pick_existing([
        "/opt/homebrew/bin/ld.lld",
        "/usr/local/bin/ld.lld",
        "/opt/homebrew/opt/lld/bin/ld.lld",
        "/usr/local/opt/lld/bin/ld.lld",
        "/usr/lib/llvm-22/bin/ld.lld",
        "/usr/bin/ld.lld",
    ]), help="path to ld.lld")
    parser.add_argument("--llvm-objcopy", type=Path, default=pick_existing([
        "/opt/homebrew/opt/llvm/bin/llvm-objcopy",
        "/usr/local/opt/llvm/bin/llvm-objcopy",
        "/usr/lib/llvm-22/bin/llvm-objcopy",
        "/usr/bin/llvm-objcopy",
    ]), help="path to llvm-objcopy")
    parser.add_argument("--zig", type=Path, default=shutil.which("zig"),
                        help="pinned Zig compiler used to build hosted Linux target archives")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    llvm_bundle_version = infer_llvm_bundle_version(root)

    if not args.prebuilt_binary:
        run(RELEASE_BUILD_CMD, cwd=root)

    required = [
        root / "zig-out/bin/cyna",
        root / "zig-out/lib/libcyna.a",
        root / "zig-out/lib/libcyna_std.a",
        root / "src/runtime/cyna.h",
    ]
    for path in required:
        if not path.exists():
            raise SystemExit(f"missing required build output: {path}; run `{' '.join(RELEASE_BUILD_CMD)}` first")

    stage_root = (root / args.stage_dir).resolve()
    dist_root = stage_root / args.version / args.host
    if dist_root.exists():
        shutil.rmtree(dist_root)
    dist_root.mkdir(parents=True, exist_ok=True)

    copy_file(root / "zig-out/bin/cyna", dist_root / "bin/cyna", executable=True)
    stage_llvm_payload(args, llvm_bundle_version, args.host, dist_root)
    build_target_supports(root, args, dist_root)
    stage_bundled_packages(root, dist_root)
    # Static libraries compile bundled dependencies from source. Ship those
    # inputs at the same relative paths used by std's C include directives.
    shutil.copytree(root / "src/runtime", dist_root / "src/runtime", dirs_exist_ok=True)
    (dist_root / "manifest.toml").write_text(render_distribution_manifest(args.version, args.host), encoding="utf-8")

    archive_path = create_archive(stage_root, args.version, args.host)
    bootstrap_path = stage_bootstrap_script(root, stage_root)

    print(f"staged distribution: {dist_root}")
    print(f"archive: {archive_path}")
    print(f"bootstrap installer: {bootstrap_path}")

    if args.upload:
        upload_distribution(stage_root, args.version, args.host, archive_path, bootstrap_path)
        print("upload complete")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
