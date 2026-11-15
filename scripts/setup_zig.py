#!/usr/bin/env python3
"""Install the repository's exact Zig release with a pinned SHA-256 digest."""

import argparse
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


# https://ziglang.org/download/index.json, Zig 0.17.0, checked 2026-10-24.
SHA256 = {
    "aarch64-macos": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    "x86_64-macos": "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6",
    "aarch64-linux": "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8",
    "x86_64-linux": "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    "aarch64-windows": "0a59d91fa1cb40cf068e9b0954434ce973500c7a2ea749f1e01af62cdab52d26",
    "x86_64-windows": "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
}


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-dir", type=Path, default=root / ".tools/zig")
    args = parser.parse_args()
    version = (root / ".zig-version").read_text().strip()
    if version != "0.17.0":
        raise SystemExit("update setup_zig.py checksums for the new .zig-version")
    system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}.get(platform.system())
    machine = platform.machine().lower()
    arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(machine, machine)
    host = f"{arch}-{system}"
    if host not in SHA256:
        raise SystemExit(f"unsupported setup host {host}; install Zig {version} from https://ziglang.org/download/")
    destination = args.install_dir.resolve() / version
    executable = destination / ("zig.exe" if system == "windows" else "zig")
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".zig-download-", dir=destination.parent) as scratch:
            stage = Path(scratch)
            suffix = "zip" if system == "windows" else "tar.xz"
            name = f"zig-{host}-{version}"
            archive = stage / f"{name}.{suffix}"
            url = f"https://ziglang.org/download/{version}/{archive.name}"
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(archive), url], check=True)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256[host]:
                raise SystemExit("Zig archive checksum mismatch; nothing installed")
            if suffix == "zip":
                with zipfile.ZipFile(archive) as bundle:
                    bundle.extractall(stage)
            else:
                with tarfile.open(archive) as bundle:
                    bundle.extractall(stage, filter="data")
            shutil.move(stage / name, destination)
    actual = subprocess.check_output([str(executable), "version"], text=True).strip()
    if actual != version:
        raise SystemExit(f"{executable} reports {actual}; expected {version}")
    print(f"Zig {actual} ready: {executable}")
    print(f"Put {destination} first on PATH before building or running tests.")


if __name__ == "__main__":
    main()
