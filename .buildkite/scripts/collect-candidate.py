#!/usr/bin/env python3
"""Check that one Buildkite build produced all three host archives."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LINUX_HOST = "x86_64-unknown-linux-gnu"
WINDOWS_HOST = "x86_64-pc-windows-gnu"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def download(pattern: str, step: str, destination: Path) -> None:
    subprocess.run(
        ["buildkite-agent", "artifact", "download", pattern, str(destination), "--step", step],
        cwd=ROOT,
        check=True,
    )


def one_file(directory: Path, pattern: str) -> Path:
    matches = list(directory.rglob(pattern))
    if len(matches) != 1:
        raise SystemExit(f"expected one {pattern} under {directory}, found {len(matches)}")
    return matches[0]


def verify_unix(directory: Path, version: str, commit: str, host: str) -> dict:
    archive = one_file(directory, f"{host}.tar.gz")
    state = one_file(directory, "verify.json")
    evidence = json.loads(state.read_text(encoding="utf-8"))
    if evidence.get("version") != version or evidence.get("commit") != commit or evidence.get("host") != host:
        raise SystemExit(f"{host} verification evidence does not match this candidate")
    actual = digest(archive)
    if evidence.get("sha256") != actual or Path(evidence.get("archive", "")).name != archive.name:
        raise SystemExit(f"{host} archive differs from its verification evidence")
    return {"host": host, "archive": archive.name, "sha256": actual, "size": archive.stat().st_size}


def verify_windows(directory: Path, version: str, commit: str) -> dict:
    archive = one_file(directory, f"{WINDOWS_HOST}.zip")
    with zipfile.ZipFile(archive) as bundle:
        buildinfo = bundle.read(f"{WINDOWS_HOST}/BUILDINFO.txt").decode("utf-8")
        manifest = tomllib.loads(bundle.read(f"{WINDOWS_HOST}/manifest.toml").decode("utf-8"))
    if f"Cyna source commit: {commit}" not in buildinfo.splitlines():
        raise SystemExit("Windows ZIP was built from another commit")
    if manifest.get("version") != version or manifest.get("host") != WINDOWS_HOST:
        raise SystemExit("Windows ZIP version or host differs from this candidate")
    return {"host": WINDOWS_HOST, "archive": archive.name, "sha256": digest(archive), "size": archive.stat().st_size}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=("verify", "final"), default="verify")
    parser.add_argument("--step-prefix", default=None)
    args = parser.parse_args()
    step_prefix = args.step_prefix or args.stage
    version = subprocess.check_output(["buildkite-agent", "meta-data", "get", "release_version"], text=True).strip()
    commit = os.environ["BUILDKITE_COMMIT"]
    if not version or len(commit) != 40:
        raise SystemExit("candidate version or commit is missing")
    mac_host = subprocess.check_output([sys.executable, "-c", "import sys; sys.path.insert(0, 'scripts'); import release_distribution; print(release_distribution.detect_host())"], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory(prefix="cyna-release-artifacts.") as tmp:
        base = Path(tmp)
        for step, extension in ((f"{step_prefix}-macos", "tar.gz"), (f"{step_prefix}-linux", "tar.gz"), (f"{step_prefix}-windows", "zip")):
            directory = base / step
            directory.mkdir()
            download(f"dist/distributions/{version}/*.{extension}", step, directory)
            if not step.endswith("windows"):
                download("dist/release/state/verify.json", step, directory)
        platforms = [
            verify_unix(base / f"{step_prefix}-macos", version, commit, mac_host),
            verify_unix(base / f"{step_prefix}-linux", version, commit, LINUX_HOST),
            verify_windows(base / f"{step_prefix}-windows", version, commit),
        ]
    output = ROOT / f"dist/release/{args.stage}-collected.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"version": version, "commit": commit, "platforms": platforms}, indent=2) + "\n", encoding="utf-8")
    subprocess.run(["buildkite-agent", "artifact", "upload", f"dist/release/{args.stage}-collected.json"], cwd=ROOT, check=True)
    for platform in platforms:
        print(f"verified {platform['host']}: {platform['sha256']}", flush=True)


if __name__ == "__main__":
    main()
