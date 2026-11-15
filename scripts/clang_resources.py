"""Stage Clang's builtin headers beside a relocated compiler."""

import shutil
import hashlib
import subprocess
from pathlib import Path


def stage_clang_resource_headers(clang: Path, llvm_root: Path) -> Path:
    result = subprocess.run(
        [str(clang), "-print-resource-dir"], check=True, capture_output=True, text=True
    )
    resource_dir = Path(result.stdout.strip()).resolve()
    source = resource_dir / "include"
    for header in ("stdbool.h", "stdint.h", "stdatomic.h"):
        if not (source / header).is_file():
            raise RuntimeError(f"Clang resource header missing: {source / header}")
    destination = llvm_root / "lib" / "clang" / resource_dir.name / "include"
    shutil.copytree(source, destination, dirs_exist_ok=True)
    return destination


def resource_header_manifest(llvm_root: Path, headers: Path) -> str:
    files = sorted(path for path in headers.rglob("*") if path.is_file())
    paths = ",".join(path.relative_to(llvm_root).as_posix() for path in files)
    hashes = ",".join(hashlib.sha256(path.read_bytes()).hexdigest() for path in files)
    return f'resource_headers = "{paths}"\nresource_headers_sha256 = "{hashes}"\n'
