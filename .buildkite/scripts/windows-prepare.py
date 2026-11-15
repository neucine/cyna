#!/usr/bin/env python3
"""Fetch pinned inputs for a Windows release on the Windows runner."""

import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import tarfile
import urllib.request
import urllib.error
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "dist/windows-inputs"
LIBS_COMMIT = "a91b58271be94a4e402a856403fe0fa83add1709"
ZIG_SHA256 = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"
LLVM_SHA256 = "6550bcc308bf972f7f956001b73f6478da3d22f1ebd4b01653c978a6c7ff3698"
SUPPORT_SHA256 = "75be10a04f4390f26c0d36dbe0fea81d97b57b5e24df6d8ecb9c0bd4e7ac17db"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def download(url: str, path: Path, expected: str, token: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and digest(path) == expected:
        return
    temporary = path.with_suffix(path.suffix + ".part")
    request = urllib.request.Request(url, headers={
        "User-Agent": "cyna-release-build",
        **({"Authorization": f"Bearer {token}"} if token else {}),
    })
    try:
        try:
            with urllib.request.urlopen(request, timeout=120) as source, temporary.open("wb") as target:
                shutil.copyfileobj(source, target)
        except urllib.error.URLError as error:
            if not (sys.platform == "win32" and token is None and
                    isinstance(error.reason, ssl.SSLCertVerificationError)):
                raise
            # Schannel can retrieve a missing intermediate from Windows' trust store.
            # curl.exe keeps TLS verification enabled; the pinned hash is checked below.
            subprocess.run(["curl.exe", "--fail", "--location", "--silent", "--show-error",
                            "--output", str(temporary), url], check=True)
        if digest(temporary) != expected:
            raise SystemExit(f"checksum mismatch for {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_dependencies() -> None:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    buildkite_commit = os.environ.get("BUILDKITE_COMMIT")
    if buildkite_commit and commit != buildkite_commit:
        raise SystemExit(f"checkout {commit} does not match Buildkite commit {buildkite_commit}")
    token = os.environ.get("PRIVATE_REPO_READ_TOKEN")
    if not token:
        raise SystemExit("PRIVATE_REPO_READ_TOKEN is required for zig-libs")
    request = urllib.request.Request(
        f"https://api.github.com/repos/neucine/zig-libs/commits/{LIBS_COMMIT}",
        headers={"User-Agent": "cyna-release-build", "Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if json.load(response)["sha"] != LIBS_COMMIT:
            raise SystemExit("zig-libs revision mismatch")
    destination = ROOT.parent / "zig-libs"
    marker = destination / ".cyna-release-revision"
    if destination.exists():
        if marker.is_file() and marker.read_text().strip() == LIBS_COMMIT:
            return
        if (destination / ".git").exists():
            existing_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
            if existing_commit == LIBS_COMMIT:
                return
        raise SystemExit(f"unexpected existing zig-libs directory: {destination}")
    INPUTS.mkdir(parents=True, exist_ok=True)
    archive = INPUTS / "zig-libs.zip"
    request = urllib.request.Request(
        f"https://api.github.com/repos/neucine/zig-libs/zipball/{LIBS_COMMIT}",
        headers={"User-Agent": "cyna-release-build", "Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(request, timeout=120) as source, archive.open("wb") as target:
        shutil.copyfileobj(source, target)
    destination.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            parts = Path(member.filename).parts[1:]
            if not parts:
                continue
            if ".." in parts or Path(*parts).is_absolute():
                raise SystemExit("unsafe zig-libs archive entry")
            target = destination.joinpath(*parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
    marker.write_text(LIBS_COMMIT + "\n")
    print(f"prepared Cyna {commit} and zig-libs {LIBS_COMMIT}")


def stage_support(archive: Path) -> None:
    destination = INPUTS / "support"
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            if not member.isfile():
                continue
            parts = Path(member.name).parts
            if len(parts) < 4 or parts[0] != "x86_64-unknown-linux-gnu":
                continue
            if parts[1] == "targets":
                relative = Path(*parts[1:])
            elif parts[1:5] == ("llvm", "lib", "clang", "22") and "libclang_rt.builtins.a" == parts[-1]:
                relative = Path("compiler-rt", *parts[6:])
            else:
                continue
            if ".." in relative.parts:
                raise SystemExit("unsafe support archive entry")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            assert source is not None
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
    if not (destination / "targets/x86_64-none-elf/manifest.toml").is_file():
        raise SystemExit("missing freestanding target support")
    if not (destination / "compiler-rt/x86_64-unknown-none-elf/libclang_rt.builtins.a").is_file():
        raise SystemExit("missing compiler-rt builtins")


def prepare_tools() -> None:
    INPUTS.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get("CYNA_RELEASE_INPUT_CACHE") or
                 Path(os.environ.get("LOCALAPPDATA", str(INPUTS))) / "neucine/cyna-release")
    cache.mkdir(parents=True, exist_ok=True)
    zig_archive = cache / "zig-x86_64-windows-0.17.0.zip"
    download("https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
             zig_archive, ZIG_SHA256)
    shutil.copy2(zig_archive, INPUTS / "windows-zig.zip")
    llvm_name = "clang+llvm-22.1.2-x86_64-pc-windows-msvc.tar.xz"
    llvm_archive = cache / llvm_name
    download(f"https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.2/{llvm_name.replace('+', '%2B')}",
             llvm_archive, LLVM_SHA256)
    llvm_subset = cache / "windows-llvm.zip"
    subset_marker = cache / "windows-llvm-source.sha256"
    subset_valid = False
    if llvm_subset.is_file() and subset_marker.is_file() and subset_marker.read_text().strip() == LLVM_SHA256:
        try:
            with zipfile.ZipFile(llvm_subset) as bundle:
                names = set(bundle.namelist())
                subset_valid = bundle.testzip() is None and all(
                    f"llvm/bin/{tool}" in names
                    for tool in ("clang.exe", "llvm-ar.exe", "ld.lld.exe", "llvm-objcopy.exe")
                )
        except zipfile.BadZipFile:
            pass
    if not subset_valid:
        llvm_subset.unlink(missing_ok=True)
        subset_marker.unlink(missing_ok=True)
        subprocess.run([sys.executable, str(ROOT / ".buildkite/scripts/stage-windows-llvm.py"),
                        str(llvm_archive), str(llvm_subset)], check=True)
        subset_marker.write_text(LLVM_SHA256 + "\n")
    shutil.copy2(llvm_subset, INPUTS / "windows-llvm.zip")
    support = cache / "linux-support.tar.gz"
    download("https://downloads.cyna.dev/distributions/0.5.1/x86_64-unknown-linux-gnu.tar.gz",
             support, SUPPORT_SHA256)
    stage_support(support)
    print("prepared pinned Windows Zig, LLVM, and target support")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("dependencies", "tools"):
        raise SystemExit("usage: windows-prepare.py dependencies|tools")
    {"dependencies": prepare_dependencies, "tools": prepare_tools}[sys.argv[1]]()
