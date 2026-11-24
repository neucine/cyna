#!/usr/bin/env python3
"""Tag and publish one verified three-host Buildkite release."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from release_distribution import DEFAULT_SMOKE_EXIT_CODE, DEFAULT_SMOKE_PATH, deploy_site, detect_host, installer_smoke  # noqa: E402

HOSTS = (detect_host(), "x86_64-unknown-linux-gnu", "x86_64-pc-windows-gnu")
BASE = "https://downloads.cyna.dev/distributions"


def run(*args: str, capture: bool = False, missing_ok: bool = False) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=capture)
    if result.returncode and not missing_ok:
        if capture and result.stderr:
            print(result.stderr, file=sys.stderr)
        raise SystemExit(f"command failed ({result.returncode}): {args[0]} {args[1] if len(args) > 1 else ''}")
    return result.stdout.strip() if capture and result.returncode == 0 else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_version() -> str:
    return run("buildkite-agent", "meta-data", "get", "release_version", capture=True)


def check_master(version: str, commit: str) -> None:
    if os.environ.get("BUILDKITE_BRANCH") != "master":
        raise SystemExit("publication is restricted to a master build")
    if run("git", "rev-parse", "HEAD", capture=True) != commit:
        raise SystemExit("checkout differs from the verified release commit")
    run(sys.executable, ".buildkite/scripts/promote-check.py")


def load_manifest() -> tuple[str, str, list[dict], Path]:
    destination = ROOT / "dist/release/downloaded-manifest"
    destination.mkdir(parents=True, exist_ok=True)
    run("buildkite-agent", "artifact", "download", "dist/release/verify-collected.json", str(destination), "--step", "merged-candidate-artifacts")
    matches = list(destination.rglob("verify-collected.json"))
    if len(matches) != 1:
        raise SystemExit("expected one verified release manifest")
    path = matches[0]
    data = json.loads(path.read_text(encoding="utf-8"))
    version, commit, platforms = data["version"], data["commit"], data["platforms"]
    if version != release_version() or commit != os.environ.get("BUILDKITE_COMMIT"):
        raise SystemExit("verified manifest differs from the Buildkite release build")
    if len(platforms) != 3 or {entry["host"] for entry in platforms} != set(HOSTS):
        raise SystemExit("verified manifest must contain exactly Mac, Linux, and Windows")
    check_master(version, commit)
    return version, commit, platforms, path


def archives(version: str, platforms: list[dict], destination: Path) -> list[tuple[dict, Path]]:
    result = []
    for entry in platforms:
        host = entry["host"]
        step = "merged-verify-" + ("macos" if host.endswith("apple-darwin") else "windows" if "windows" in host else "linux")
        ext = ".zip" if "windows" in host else ".tar.gz"
        if entry["archive"] != host + ext:
            raise SystemExit(f"unexpected archive name for {host}")
        folder = destination / step
        folder.mkdir()
        run("buildkite-agent", "artifact", "download", f"dist/distributions/{version}/{host}{ext}", str(folder), "--step", step)
        found = list(folder.rglob(host + ext))
        if len(found) != 1 or sha256(found[0]) != entry["sha256"] or found[0].stat().st_size != entry["size"]:
            raise SystemExit(f"artifact hash or size changed for {host}")
        result.append((entry, found[0]))
    return result


def parse_remote_tag(output: str, tag: str) -> str | None:
    refs = {}
    for line in output.splitlines():
        commit, separator, ref = line.partition("\t")
        if separator:
            refs[ref] = commit
    return refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")


def ensure_tag(version: str, commit: str) -> None:
    tag = f"v{version}"
    existing = parse_remote_tag(
        run("git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}", capture=True),
        tag,
    )
    if existing:
        if existing != commit:
            raise SystemExit(f"{tag} already points to another commit")
        return
    created = json.loads(run(
        "gh", "api", "-X", "POST", "repos/neucine/cyna/git/tags",
        "-f", f"tag={tag}", "-f", f"message=Cyna {version}",
        "-f", f"object={commit}", "-f", "type=commit", capture=True,
    ))
    run("gh", "api", "-X", "POST", "repos/neucine/cyna/git/refs", "-f", f"ref=refs/tags/{tag}", "-f", f"sha={created['sha']}", capture=True)
    print(f"created {tag} at {commit}", flush=True)


def aws_base() -> list[str]:
    account = os.environ["CYNA_R2_ACCOUNT_ID"]
    return ["aws", "--region", "auto", "--endpoint-url", f"https://{account}.r2.cloudflarestorage.com"]


def remote_object(bucket: str, key: str) -> dict | None:
    result = subprocess.run(aws_base() + ["s3api", "head-object", "--bucket", bucket, "--key", key], capture_output=True, text=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "Not Found" in result.stderr or "404" in result.stderr or "NoSuchKey" in result.stderr:
        return None
    raise SystemExit(f"could not inspect R2 object {key}: {result.stderr}")


def upload_immutable(path: Path, key: str, digest: str) -> None:
    bucket = os.environ["CYNA_R2_BUCKET"]
    previous = remote_object(bucket, key)
    if previous is not None:
        if previous.get("ContentLength") != path.stat().st_size or previous.get("Metadata", {}).get("sha256") != digest:
            raise SystemExit(f"R2 object already differs: {key}")
        print(f"R2 already has {key}", flush=True)
        return
    run(*(aws_base() + ["s3", "cp", str(path), f"s3://{bucket}/{key}", "--metadata", f"sha256={digest}"]))
    uploaded = remote_object(bucket, key)
    if uploaded is None or uploaded.get("ContentLength") != path.stat().st_size or uploaded.get("Metadata", {}).get("sha256") != digest:
        raise SystemExit(f"R2 upload could not be verified: {key}")


def upload_latest(path: Path, key: str) -> None:
    bucket = os.environ["CYNA_R2_BUCKET"]
    digest = sha256(path)
    previous = remote_object(bucket, key)
    if previous is None or previous.get("Metadata", {}).get("sha256") != digest:
        run(*(aws_base() + ["s3", "cp", str(path), f"s3://{bucket}/{key}", "--metadata", f"sha256={digest}"]))
    current = remote_object(bucket, key)
    if current is None or current.get("ContentLength") != path.stat().st_size or current.get("Metadata", {}).get("sha256") != digest:
        raise SystemExit(f"latest object could not be verified: {key}")


def release_for_tag(releases: list[dict], tag: str) -> dict | None:
    return next((item for item in releases if item["tag_name"] == tag), None)


def find_release(tag: str, wait_seconds: float = 0) -> dict | None:
    # GitHub's release-by-tag endpoint returns 404 for draft releases.
    deadline = time.monotonic() + wait_seconds
    while True:
        releases = json.loads(run("gh", "api", "repos/neucine/cyna/releases?per_page=100", capture=True))
        release = release_for_tag(releases, tag)
        if release is not None or time.monotonic() >= deadline:
            return release
        time.sleep(1)


def github_release(version: str, files: list[tuple[dict, Path]], manifest: Path, notes: Path) -> None:
    tag = f"v{version}"
    current = find_release(tag)
    if current is None:
        run("gh", "release", "create", tag, "--verify-tag", "--draft", "--title", f"Cyna {version}", "--notes-file", str(notes))
        current = find_release(tag, wait_seconds=20)
    if current is None:
        raise SystemExit(f"GitHub release {tag} was not found after creation")
    assets = {asset["name"]: asset for asset in current["assets"]}
    for entry, path in [*files, ({"sha256": sha256(manifest)}, manifest)]:
        prior = assets.get(path.name)
        if prior is not None:
            if prior.get("digest") != f"sha256:{entry['sha256']}":
                raise SystemExit(f"existing GitHub asset needs inspection: {path.name}")
            continue
        run("gh", "release", "upload", tag, str(path))
    run("gh", "release", "edit", tag, "--draft=false", "--notes-file", str(notes))


def live_digest(url: str, size: int, expected: str) -> None:
    for attempt in range(8):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "curl/8.0.0"})
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status != 200 or int(response.headers.get("Content-Length", "-1")) != size:
                    raise ValueError("unexpected live object size")
                digest = hashlib.sha256()
                while block := response.read(1024 * 1024):
                    digest.update(block)
                if digest.hexdigest() == expected:
                    return
        except (urllib.error.URLError, ValueError, TimeoutError):
            pass
        time.sleep(min(2 ** attempt, 30))
    raise SystemExit(f"live distribution is unavailable or has the wrong hash: {url}")


def main() -> None:
    version, commit, platforms, manifest = load_manifest()
    with tempfile.TemporaryDirectory(prefix="cyna-final-release.") as temp:
        files = archives(version, platforms, Path(temp))
        ensure_tag(version, commit)
        notes = Path(temp) / "release-notes.md"
        lines = [f"# Cyna {version}", "", "## Downloads", ""]
        for entry, path in files:
            lines.extend((f"- [{path.name}]({BASE}/{version}/{path.name}) — SHA256 `{entry['sha256']}`", ""))
        lines.extend((f"- [Build manifest]({BASE}/{version}/manifest.json) — source `{commit}`", ""))
        release_notes = ROOT / f"docs/RELEASE_{version.replace('.', '_')}.md"
        if release_notes.is_file():
            lines.extend(("## Changes", "", release_notes.read_text(encoding="utf-8")))
        notes.write_text("\n".join(lines), encoding="utf-8")
        for entry, path in files:
            upload_immutable(path, f"distributions/{version}/{path.name}", entry["sha256"])
            live_digest(f"{BASE}/{version}/{path.name}?v={version}", entry["size"], entry["sha256"])
        upload_immutable(manifest, f"distributions/{version}/manifest.json", sha256(manifest))
        live_digest(f"{BASE}/{version}/manifest.json?v={version}", manifest.stat().st_size, sha256(manifest))
        installer = ROOT / "scripts/install_distribution.sh"
        upload_latest(installer, "distributions/install.sh")
        windows_installer = ROOT / "scripts/install_distribution.ps1"
        upload_latest(windows_installer, "distributions/install.ps1")
        installer_smoke(
            ROOT,
            version=version,
            host=HOSTS[0],
            archive_url=None,
            smoke_path=ROOT / DEFAULT_SMOKE_PATH,
            expected_exit_code=DEFAULT_SMOKE_EXIT_CODE,
        )
        github_release(version, files, manifest, notes)
    release_token = os.environ.pop("GH_TOKEN", None)
    try:
        deploy_site(ROOT, Path(os.environ.get("CYNA_SITES_REPO", str(ROOT.parent / "sites"))), version)
    finally:
        if release_token is not None:
            os.environ["GH_TOKEN"] = release_token
    print(f"published Cyna {version} from {commit} with all three distributions", flush=True)


if __name__ == "__main__":
    main()
