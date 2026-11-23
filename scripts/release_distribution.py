#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path


DEFAULT_SMOKE_PATH = "examples/planner_app/main.cy"
DEFAULT_SMOKE_EXIT_CODE = 42
RELEASE_BUILD_CMD = ["zig", "build", "-Doptimize=fast"]


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run(cmd: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> None:
    printable = " ".join(cmd)
    print(f"+ {printable}")
    subprocess.run(cmd, check=True, cwd=str(cwd), env=env)


def capture(cmd: list[str], *, cwd: Path) -> str:
    result = subprocess.run(
        cmd,
        check=True,
        cwd=str(cwd),
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def capture_optional(cmd: list[str], *, cwd: Path) -> str | None:
    result = subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output if output else None


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


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def infer_version(root: Path) -> str:
    match = re.search(r'const cyna_version = "([^"]+)"', read_text(root / "build.zig"))
    if not match:
        raise SystemExit("unable to infer cyna version from build.zig")
    return match.group(1)


def infer_bootstrap_version(root: Path) -> str:
    match = re.search(r'CYNA_RELEASE_VERSION="\$\{CYNA_RELEASE_VERSION:-([^}]+)\}"', read_text(root / "scripts/install_distribution.sh"))
    if not match:
        raise SystemExit("unable to infer bootstrap version from scripts/install_distribution.sh")
    return match.group(1)


def replace_exactly_once(source: str, pattern: str, replacement: str, *, label: str) -> str:
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"unable to update {label}")
    return updated


def bump_release_version(root: Path, version: str) -> list[Path]:
    changed: list[Path] = []

    build_path = root / "build.zig"
    build_source = read_text(build_path)
    build_updated = replace_exactly_once(
        build_source,
        r'const cyna_version = "[^"]+";',
        f'const cyna_version = "{version}";',
        label="build.zig version",
    )
    if build_updated != build_source:
        write_text(build_path, build_updated)
        changed.append(build_path)

    install_path = root / "scripts/install_distribution.sh"
    install_source = read_text(install_path)
    install_updated = replace_exactly_once(
        install_source,
        r'CYNA_RELEASE_VERSION="\$\{CYNA_RELEASE_VERSION:-[^}]+\}"',
        f'CYNA_RELEASE_VERSION="${{CYNA_RELEASE_VERSION:-{version}}}"',
        label="bootstrap installer version",
    )
    install_updated = install_updated.replace(infer_bootstrap_version(root), version)
    if install_updated != install_source:
        write_text(install_path, install_updated)
        changed.append(install_path)

    windows_install_path = root / "scripts/install_distribution.ps1"
    windows_install_source = read_text(windows_install_path)
    windows_install_updated = replace_exactly_once(
        windows_install_source,
        r"else \{ '[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?' \}\)",
        f"else {{ '{version}' }})",
        label="Windows bootstrap installer version",
    )
    if windows_install_updated != windows_install_source:
        write_text(windows_install_path, windows_install_updated)
        changed.append(windows_install_path)

    return changed


def require_clean_worktree(root: Path) -> None:
    status = capture(["git", "status", "--short"], cwd=root)
    if status:
        raise SystemExit("release flow requires a clean git worktree; commit or stash changes first")


def ensure_branch_has_remote(root: Path, remote: str) -> None:
    branch = capture(["git", "branch", "--show-current"], cwd=root)
    if not branch:
        raise SystemExit("unable to determine current git branch")
    capture(["git", "rev-parse", "--verify", f"{remote}/{branch}"], cwd=root)


def verify_version(binary: Path, version: str, *, cwd: Path, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(
        [str(binary), "version"],
        check=True,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        env=env,
    )
    expected = f"cyna {version}"
    actual = result.stdout.strip() or result.stderr.strip()
    if actual != expected:
        raise SystemExit(f"unexpected compiler version from {binary}: expected `{expected}`, got `{actual}`")


def smoke_run(binary: Path, smoke_path: Path, expected_exit_code: int, *, cwd: Path, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(
        [str(binary), "run", str(smoke_path)],
        cwd=str(cwd),
        text=True,
        capture_output=True,
        env=env,
    )
    if result.returncode != expected_exit_code:
        raise SystemExit(
            "smoke test failed for "
            f"{binary}: expected exit {expected_exit_code}, got {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


def checkout_smoke(
    root: Path,
    version: str,
    smoke_path: Path,
    expected_exit_code: int,
    *,
    env: dict[str, str] | None = None,
) -> None:
    binary = root / "zig-out/bin/cyna"
    if not binary.exists():
        raise SystemExit(f"missing built compiler at {binary}; run `{' '.join(RELEASE_BUILD_CMD)}` first")
    verify_version(binary, version, cwd=root, env=env)
    smoke_run(binary, smoke_path, expected_exit_code, cwd=root, env=env)


def release_integration_gate(root: Path, env: dict[str, str]) -> None:
    run(["zig", "build", "test-tooling-lsp", "--summary", "all"], cwd=root, env=env)
    run(["zig", "build", "test-tooling-fmt", "--summary", "all"], cwd=root, env=env)
    run([sys.executable, "scripts/check_release_integrations.py"], cwd=root, env=env)


def cava_release_gate(root: Path, cava_root: Path, version: str, host: str, archive_path: Path, stage_dir: str) -> None:
    gate = cava_root / "scripts/release_gate.py"
    if not gate.is_file():
        raise SystemExit(f"Cava release gate is missing: {gate}")
    jdk_classes = cava_root / "jdk/classes"
    if not (jdk_classes / "java/lang/System.class").is_file():
        raise SystemExit(f"Cava JDK class fixtures are missing: {jdk_classes}")
    require_clean_worktree(cava_root)
    revision = capture(["git", "rev-parse", "HEAD"], cwd=cava_root)
    print(f"running Cava golden gate at {revision}")
    with tempfile.TemporaryDirectory(prefix="cyna-cava-release.") as tmp:
        home = Path(tmp) / "home"
        home.mkdir()
        cava_copy = Path(tmp) / "cava"
        for name in ("src", "examples", "scripts"):
            shutil.copytree(cava_root / name, cava_copy / name)
        (cava_copy / "jdk").symlink_to(cava_root / "jdk", target_is_directory=True)
        shutil.copy2(cava_root / "cyna.toml", cava_copy / "cyna.toml")
        env = staged_release_test_env(root, version, host, stage_dir, str(home))
        env["CYNA_DISTRIBUTION_URL"] = archive_path.as_uri()
        run([str(root / "scripts/install_distribution.sh"), version, host], cwd=root, env=env)
        compiler = home / ".cyna" / version / "bin/cyna"
        verify_version(compiler, version, cwd=root, env=env)
        run([sys.executable, str(cava_copy / "scripts/release_gate.py"), "--compiler", str(compiler)], cwd=cava_copy, env=env)


def installer_smoke(
    root: Path,
    *,
    version: str,
    host: str,
    archive_url: str | None,
    smoke_path: Path,
    expected_exit_code: int,
    extra_env: dict[str, str] | None = None,
) -> None:
    install_script = root / "scripts/install_distribution.sh"
    with tempfile.TemporaryDirectory(prefix="cyna-release-home.") as tmp:
        home = Path(tmp)
        env = os.environ.copy()
        env["HOME"] = str(home)
        if archive_url is not None:
            env["CYNA_DISTRIBUTION_URL"] = archive_url
        if extra_env:
            env.update(extra_env)
        run([str(install_script), version, host], cwd=root, env=env)
        binary = home / ".cyna" / version / "bin" / "cyna"
        verify_version(binary, version, cwd=root, env=env)
        smoke_run(binary, smoke_path, expected_exit_code, cwd=root, env=env)


def install_local_compiler(root: Path, version: str, host: str, archive_path: Path) -> None:
    """Install the verified release archive on the release machine."""
    env = os.environ.copy()
    env["CYNA_DISTRIBUTION_URL"] = archive_path.as_uri()
    run([str(root / "scripts/install_distribution.sh"), version, host], cwd=root, env=env)
    verify_version(Path.home() / ".cyna/current/bin/cyna", version, cwd=root)


def install_local_extension(root: Path) -> None:
    code = shutil.which("code")
    if code is None:
        raise SystemExit("VS Code CLI is missing; use --skip-local-tools to skip the extension on a headless release host")
    editor = root / "tools/cyna-vscode"
    editor_version = json.loads(read_text(editor / "package.json"))["version"]
    run([code, "--install-extension", str(editor / f"cyna-{editor_version}.vsix"), "--force"], cwd=root)
    installed = capture([code, "--list-extensions", "--show-versions"], cwd=root)
    if f"cyna.cyna@{editor_version}" not in installed.splitlines():
        raise SystemExit(f"VS Code extension cyna.cyna@{editor_version} is not installed")


def stage_distribution(root: Path, version: str, host: str, stage_dir: str, upload: bool,
                       prebuilt_binary: bool = False) -> Path:
    cmd = [
        sys.executable,
        str(root / "scripts/publish_distribution.py"),
        "--version",
        version,
        "--host",
        host,
        "--stage-dir",
        stage_dir,
    ]
    if upload:
        cmd.append("--upload")
    if prebuilt_binary:
        cmd.append("--prebuilt-binary")
    run(cmd, cwd=root)
    return (root / stage_dir / version / f"{host}.tar.gz").resolve()


def release_test_env() -> dict[str, str]:
    env = os.environ.copy()
    # During a new release, the bumped version is intentionally not available
    # from downloads.cyna.dev yet. Nested build tests may still need to provision
    # the just-built compiler-owned toolchain, so allow local host capture.
    env.setdefault("CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE", "1")
    return env


def release_test_command(env: dict[str, str], lane: str = "test") -> list[str]:
    command = ["zig", "build", lane]
    jobs = env.get("CYNA_RELEASE_ZIG_JOBS")
    if jobs:
        if not jobs.isdecimal() or int(jobs) < 1:
            raise SystemExit("CYNA_RELEASE_ZIG_JOBS must be a positive integer")
        command.append(f"-j{jobs}")
    return command


def staged_release_test_env(root: Path, version: str, host: str, stage_dir: str, home: str) -> dict[str, str]:
    env = release_test_env()
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(Path.home() / ".cache/zig"))
    env["HOME"] = home
    env["CYNA_TOOLCHAIN_ARTIFACT_ROOT"] = str((root / stage_dir / version / host).resolve())
    # The staged artifacts are verified by their manifest digests and the
    # installer smoke test, but their release approval hashes are not pinned
    # until the distribution has been published.
    env["CYNA_ALLOW_UNPINNED_TOOLCHAIN_ARTIFACT"] = "1"
    return env


def git_commit_version_bump(root: Path, version: str, paths: list[Path]) -> None:
    if not paths:
        return
    run(["git", "add", *[str(path.relative_to(root)) for path in paths]], cwd=root)
    run(["git", "commit", "-m", f"release: cyna {version}"], cwd=root)


def git_push_branch(root: Path, remote: str) -> None:
    run(["git", "push", remote, "HEAD"], cwd=root)


def git_create_and_push_tag(root: Path, remote: str, version: str) -> None:
    tag = f"v{version}"
    existing = subprocess.run(
        ["git", "rev-parse", "--verify", tag],
        cwd=str(root),
        capture_output=True,
        text=True,
    )
    if existing.returncode == 0:
        raise SystemExit(f"git tag already exists: {tag}")
    run(["git", "tag", "-a", tag, "-m", f"cyna {version}"], cwd=root)
    run(["git", "push", remote, tag], cwd=root)


def git_previous_release_tag(root: Path, tag: str) -> str | None:
    return capture_optional(["git", "describe", "--tags", "--abbrev=0", f"{tag}^"], cwd=root)


def release_changelog(root: Path, tag: str, previous_tag: str | None) -> str:
    revision_range = f"{previous_tag}..{tag}" if previous_tag else tag
    changes = capture_optional(
        ["git", "log", "--pretty=format:- %s (%h)", revision_range],
        cwd=root,
    )
    return changes or "- No commits found for this release."


def sha256_hex(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def render_github_release_notes(root: Path, version: str, host: str, archive_path: Path) -> str:
    tag = f"v{version}"
    previous_tag = git_previous_release_tag(root, tag)
    compare_url = f"https://github.com/neucine/cyna/compare/{previous_tag}...{tag}" if previous_tag else ""
    download_url = f"https://downloads.cyna.dev/distributions/{version}/{host}.tar.gz"
    notes = [
        f"## Cyna {version}",
        "",
        "### Downloads",
        "",
        f"- {host}: {download_url}",
        f"- SHA256: `{sha256_hex(archive_path)}`",
        "",
        "### Changelog",
        "",
        release_changelog(root, tag, previous_tag),
    ]
    if compare_url:
        notes.extend(["", f"Full diff: {compare_url}"])
    return "\n".join(notes) + "\n"


def create_github_release(root: Path, version: str, host: str, archive_path: Path, *, draft: bool = False) -> None:
    tag = f"v{version}"
    existing = subprocess.run(
        ["gh", "release", "view", tag],
        cwd=str(root),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    notes = render_github_release_notes(root, version, host, archive_path)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False) as tmp:
        notes_path = Path(tmp.name)
        tmp.write(notes)
    try:
        if existing.returncode == 0:
            details = json.loads(
                capture(
                    ["gh", "release", "view", tag, "--json", "isDraft,isPrerelease"],
                    cwd=root,
                )
            )
            expected_prerelease = "-" in version
            if details.get("isDraft") != draft:
                raise SystemExit(f"github release {tag} has an unexpected draft state; inspect it before retrying")
            if details.get("isPrerelease") != expected_prerelease:
                raise SystemExit(f"github release {tag} has an unexpected prerelease state; inspect it before retrying")
            run(["gh", "release", "upload", tag, str(archive_path), "--clobber"], cwd=root)
            run(
                [
                    "gh",
                    "release",
                    "edit",
                    tag,
                    "--title",
                    f"Cyna {version}",
                    "--notes-file",
                    str(notes_path),
                ],
                cwd=root,
            )
            return

        cmd = [
            "gh",
            "release",
            "create",
            tag,
            str(archive_path),
            "--verify-tag",
            "--title",
            f"Cyna {version}",
            "--notes-file",
            str(notes_path),
        ]
        if draft:
            cmd.append("--draft")
        if "-" in version:
            cmd.append("--prerelease")
        run(cmd, cwd=root)
    finally:
        notes_path.unlink(missing_ok=True)


def require_site_content_current(root: Path, version: str) -> None:
    run(
        [sys.executable, "scripts/prepare_site_content.py", "--check", "--version", version],
        cwd=root,
    )


def parse_legacy_args() -> argparse.Namespace:
    root = repo_root()
    current_version = infer_version(root)
    parser = argparse.ArgumentParser(
        description="Run the Cyna distribution release flow from preflight checks through installer smoke tests."
    )
    parser.add_argument(
        "--release-version",
        default=current_version,
        help=f"release version to publish, defaults to current version {current_version}",
    )
    parser.add_argument("--host", default=detect_host(), help="host triple to release")
    parser.add_argument(
        "--stage-dir",
        default="dist/distributions",
        help="distribution staging root, defaults to dist/distributions",
    )
    parser.add_argument(
        "--smoke-path",
        default=DEFAULT_SMOKE_PATH,
        help=f"program to compile and run for smoke tests, defaults to {DEFAULT_SMOKE_PATH}",
    )
    parser.add_argument(
        "--smoke-exit-code",
        type=int,
        default=DEFAULT_SMOKE_EXIT_CODE,
        help=f"expected smoke-test exit code, defaults to {DEFAULT_SMOKE_EXIT_CODE}",
    )
    parser.add_argument("--git-remote", default="origin", help="git remote used for pushes and tags")
    parser.add_argument("--cava-root", type=Path, default=root.parent / "cava", help="clean Cava checkout used as the golden release gate")
    parser.add_argument("--allow-dirty", action="store_true", help="allow running without a clean git worktree")
    parser.add_argument("--skip-git", action="store_true", help="skip commit, push, and tag steps")
    parser.add_argument("--skip-push", action="store_true", help="skip pushing the release commit")
    parser.add_argument("--skip-tag", action="store_true", help="skip creating and pushing the git tag")
    parser.add_argument("--skip-upload", action="store_true", help="skip the R2 upload step")
    parser.add_argument("--skip-remote-smoke", action="store_true", help="skip installer smoke test against the remote artifact")
    parser.add_argument("--skip-local-tools", action="store_true", help="skip installing and checking the local VS Code extension")
    parser.add_argument(
        "--skip-github-release",
        action="store_true",
        help="skip creating the GitHub release with generated changelog notes",
    )
    parser.add_argument(
        "--skip-site",
        action="store_true",
        help="skip syncing and deploying cyna.dev (for local release rehearsal)",
    )
    parser.add_argument(
        "--sites-repo",
        type=Path,
        default=root.parent / "sites",
        help="neucine sites workspace used to build and deploy cyna.dev",
    )
    return parser.parse_args()


def legacy_main() -> int:
    args = parse_legacy_args()
    root = repo_root()
    smoke_path = (root / args.smoke_path).resolve()
    if not smoke_path.exists():
        raise SystemExit(f"smoke path does not exist: {smoke_path}")

    if not args.allow_dirty:
        require_clean_worktree(root)
        if not args.skip_git and not args.skip_push:
            ensure_branch_has_remote(root, args.git_remote)

    current_version = infer_version(root)
    target_version = args.release_version
    test_env = release_test_env()

    print(f"preflight release checks for {current_version}")
    run(RELEASE_BUILD_CMD, cwd=root, env=test_env)
    run(["zig", "build", "test"], cwd=root, env=test_env)
    checkout_smoke(root, current_version, smoke_path, args.smoke_exit_code)

    changed_paths: list[Path] = []
    if target_version != current_version:
        print(f"bumping release version to {target_version}")
        changed_paths = bump_release_version(root, target_version)
    else:
        print(f"release version already set to {target_version}; no version bump required")

    print(f"rebuilding release artifacts for {target_version}")
    run(RELEASE_BUILD_CMD, cwd=root, env=test_env)
    print("staging local release artifacts for the bumped-version test gate")
    stage_distribution(root, target_version, args.host, args.stage_dir, upload=False)
    with tempfile.TemporaryDirectory(prefix="cyna-release-test-home.") as test_home:
        bumped_test_env = staged_release_test_env(root, target_version, args.host, args.stage_dir, test_home)
        run(["zig", "build", "test"], cwd=root, env=bumped_test_env)
        checkout_smoke(root, target_version, smoke_path, args.smoke_exit_code, env=bumped_test_env)
    cava_release_gate(root, args.cava_root.resolve(), target_version, args.host,
                      (root / args.stage_dir / target_version / f"{args.host}.tar.gz").resolve(), args.stage_dir)
    release_integration_gate(root, test_env)

    published_release = (
        not args.skip_git
        and not args.skip_push
        and not args.skip_tag
        and not args.skip_upload
        and not args.skip_remote_smoke
        and not args.skip_github_release
    )
    if published_release and not args.skip_site:
        print("preparing cyna.dev release pages before publication")
        run(
            [sys.executable, "scripts/prepare_site_content.py", "--version", target_version],
            cwd=root,
        )
        run(
            [sys.executable, "scripts/prepare_site_content.py", "--check", "--version", target_version],
            cwd=root,
        )
        if subprocess.run(
            ["git", "status", "--porcelain", "--", "docs/site"], cwd=root, capture_output=True, text=True
        ).stdout.strip():
            changed_paths.append(root / "docs" / "site")

    if not args.skip_git:
        if changed_paths:
            git_commit_version_bump(root, target_version, changed_paths)
        else:
            print("no release version commit required")
        if not args.skip_push:
            git_push_branch(root, args.git_remote)
        if not args.skip_tag:
            git_create_and_push_tag(root, args.git_remote, target_version)

    archive_path = stage_distribution(
        root,
        version=target_version,
        host=args.host,
        stage_dir=args.stage_dir,
        upload=not args.skip_upload,
    )

    print("running local installer smoke test")
    installer_smoke(
        root,
        version=target_version,
        host=args.host,
        archive_url=archive_path.as_uri(),
        smoke_path=smoke_path,
        expected_exit_code=args.smoke_exit_code,
    )

    if not args.skip_upload and not args.skip_remote_smoke:
        print("running remote installer smoke test")
        installer_smoke(
            root,
            version=target_version,
            host=args.host,
            archive_url=None,
            smoke_path=smoke_path,
            expected_exit_code=args.smoke_exit_code,
        )

    if published_release:
        install_local_compiler(root, target_version, args.host, archive_path)
        if not args.skip_local_tools:
            install_local_extension(root)

    if published_release:
        print("creating GitHub release")
        create_github_release(root, target_version, args.host, archive_path)
        if not args.skip_site:
            print("syncing and deploying cyna.dev")
            run(
                [sys.executable, "scripts/prepare_site_content.py", "--version", target_version],
                cwd=root,
            )
            run(
                [sys.executable, "scripts/prepare_site_content.py", "--check", "--version", target_version],
                cwd=root,
            )
            sites_repo = args.sites_repo.resolve()
            deploy_site(root, sites_repo, target_version)

    print(f"release flow completed for cyna {target_version}")
    print(f"staged archive: {archive_path}")
    return 0


# The verb CLI and its entry point are defined at the end of this module.

# --- verb layer -------------------------------------------------------------

import time
from datetime import datetime, timezone

STATE_ROOT = "dist/release/state"
SINKS = ("local", "staging", "public")
PUBLIC_BASE_URL = "https://downloads.cyna.dev/distributions"
GATES = ["build", "test", "smoke", "staged-test", "cava", "integrations"]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def state_dir(root: Path) -> Path:
    path = root / STATE_ROOT
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_state(root: Path, name: str, payload: dict) -> Path:
    path = state_dir(root) / name
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def read_state(root: Path, name: str, *, required: bool = True) -> dict | None:
    path = state_dir(root) / name
    if not path.is_file():
        if required:
            verb = name.removesuffix(".json")
            raise SystemExit(f"missing {path}; run `{verb}` first")
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def git_head(root: Path) -> str:
    return capture(["git", "rev-parse", "HEAD"], cwd=root)


def tag_exists(root: Path, tag: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", tag],
        cwd=str(root),
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def archive_sha256(path: Path) -> str:
    return sha256_hex(path)


def require_tag_absent(root: Path, tag: str) -> None:
    if tag_exists(root, tag):
        raise SystemExit(f"git tag already exists: {tag}")


def require_verified_commit(root: Path, state: dict) -> None:
    head = git_head(root)
    if state.get("commit") != head:
        raise SystemExit(
            f"state is for commit {state.get('commit')}, but HEAD is {head}; "
            "re-run verify on the current commit"
        )


def cmd_plan(args: argparse.Namespace) -> int:
    root = repo_root()
    if not args.allow_dirty:
        require_clean_worktree(root)
    current = infer_version(root)
    version = args.release_version or current
    tag = f"v{version}"
    tag_present = tag_exists(root, tag)
    if tag_present and version != current:
        raise SystemExit(f"git tag already exists: {tag}")
    previous = capture_optional(["git", "describe", "--tags", "--abbrev=0", "HEAD"], cwd=root)
    plan = {
        "project": "cyna",
        "version": version,
        "tag": tag,
        "commit": git_head(root),
        "previous": previous,
        "host": args.host,
        "targets": [args.host],
        "artifacts": [f"{args.stage_dir}/{version}/{args.host}.tar.gz"],
        "destinations": {"r2": "distributions", "github": True, "site": "cyna-dev"},
        "gates": GATES,
        "local_only_gates": ["cava"],
        "tag_exists": tag_present,
        "created": utc_now(),
    }
    path = write_state(root, "plan.json", plan)
    print(f"planned cyna {version} on {args.host} at {plan['commit'][:8]}")
    print(f"previous: {previous or 'none'}")
    if tag_present:
        print(f"note: {tag} already exists; this plan is a rehearsal of the current version")
    print(f"state: {path}")
    print("next: prepare (if the version changes), then verify")
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json")
    if not args.allow_dirty:
        require_clean_worktree(root)
    version = plan["version"]
    changed: list[Path] = []
    if infer_version(root) != version:
        changed = bump_release_version(root, version)
    run([sys.executable, "scripts/prepare_site_content.py", "--version", version], cwd=root)
    if capture(["git", "status", "--porcelain", "--", "docs/site"], cwd=root):
        changed.append(root / "docs" / "site")
    if changed:
        git_commit_version_bump(root, version, changed)
    plan["commit"] = git_head(root)
    write_state(root, "plan.json", plan)
    print(f"prepared cyna {version} at {plan['commit'][:8]}")
    print("next: verify")
    return 0


def snapshot_release_outputs(root: Path) -> dict[str, tuple[bytes, int]]:
    """Keep the release build independent of compilers installed by CLI tests."""
    binary = "bin/cyna.exe" if os.name == "nt" else "bin/cyna"
    outputs = {}
    for relative in (binary, "lib/libcyna.a", "lib/libcyna_std.a"):
        path = root / "zig-out" / relative
        outputs[relative] = (path.read_bytes(), path.stat().st_mode & 0o777)
    return outputs


def restore_release_outputs(root: Path, outputs: dict[str, tuple[bytes, int]]) -> None:
    for relative, (contents, mode) in outputs.items():
        path = root / "zig-out" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        path.chmod(mode)


def cmd_verify(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json")
    version = plan["version"]
    if infer_version(root) != version:
        raise SystemExit(f"declared version is {infer_version(root)}, plan says {version}; run prepare")
    if not args.allow_dirty:
        require_clean_worktree(root)
        if plan["commit"] != git_head(root):
            raise SystemExit("plan commit does not match HEAD; re-run plan")
    require_site_content_current(root, version)
    smoke_path = (root / args.smoke_path).resolve()
    if not smoke_path.exists():
        raise SystemExit(f"smoke path does not exist: {smoke_path}")
    started = time.monotonic()
    env = release_test_env()
    reuse_candidate_tests = getattr(args, "reuse_candidate_tests", False)
    if reuse_candidate_tests and os.environ.get("BUILDKITE_STEP_KEY") not in ("final-macos", "final-linux"):
        raise SystemExit("candidate tests may only be reused by a Buildkite final distribution job")
    print(f"verify cyna {version} on {args.host}")
    if getattr(args, "prebuilt_binary", False):
        binary = root / "zig-out/bin" / ("cyna.exe" if os.name == "nt" else "cyna")
        verify_version(binary, version, cwd=root, env=env)
    else:
        run(RELEASE_BUILD_CMD, cwd=root, env=env)
    built_outputs = snapshot_release_outputs(root)
    if not reuse_candidate_tests:
        run(release_test_command(env), cwd=root, env=env)
    # CLI tests install debug compilers and runtime archives into zig-out.
    # Package the original release build, without rebuilding it after tests.
    restore_release_outputs(root, built_outputs)
    checkout_smoke(root, version, smoke_path, args.smoke_exit_code, env=env)
    stage_distribution(root, version, args.host, args.stage_dir, upload=False,
                       prebuilt_binary=True)
    archive = (root / args.stage_dir / version / f"{args.host}.tar.gz").resolve()
    with tempfile.TemporaryDirectory(prefix="cyna-release-test-home.") as test_home:
        bumped_env = staged_release_test_env(root, version, args.host, args.stage_dir, test_home)
        if not reuse_candidate_tests:
            # The full suite already ran against this commit. Check the staged
            # toolchain with the fast lane and the packaged compiler smoke.
            run(release_test_command(bumped_env, "test-fast"), cwd=root, env=bumped_env)
        restore_release_outputs(root, built_outputs)
        checkout_smoke(root, version, smoke_path, args.smoke_exit_code, env=bumped_env)
    if args.no_cava:
        cava = {
            "revision": "not run",
            "result": "skipped",
            "reason": "Cava gate is a local-only gate and was not run in this environment",
        }
    else:
        cava_root = Path(args.cava_root).resolve()
        cava_release_gate(root, cava_root, version, args.host, archive, args.stage_dir)
        cava = {
            "revision": capture(["git", "rev-parse", "HEAD"], cwd=cava_root),
            "host": args.host,
            "command": "scripts/release_gate.py --compiler <staged cyna>",
            "result": "passed",
            "operator": os.environ.get("USER") or "unknown",
            "recorded": utc_now(),
        }
    release_integration_gate(root, env)
    restore_release_outputs(root, built_outputs)
    binary_name = "bin/cyna.exe" if os.name == "nt" else "bin/cyna"
    verify = {
        "version": version,
        "host": args.host,
        "commit": git_head(root),
        "archive": str(archive),
        "sha256": archive_sha256(archive),
        "compiler_sha256": hashlib.sha256(built_outputs[binary_name][0]).hexdigest(),
        "gates": GATES if not reuse_candidate_tests else [gate for gate in GATES if gate not in ("test", "staged-test")],
        "reused_candidate_tests": reuse_candidate_tests,
        "cava": cava,
        "duration_seconds": round(time.monotonic() - started, 1),
        "completed": utc_now(),
    }
    path = write_state(root, "verify.json", verify)
    print(f"verified {version} in {verify['duration_seconds']}s")
    print(f"archive: {archive} sha256 {verify['sha256']}")
    print(f"state: {path}")
    print("next: tag")
    return 0


def cmd_tag(args: argparse.Namespace) -> int:
    root = repo_root()
    require_clean_worktree(root)
    plan = read_state(root, "plan.json")
    verify = read_state(root, "verify.json")
    require_verified_commit(root, verify)
    require_site_content_current(root, plan["version"])
    tag = plan["tag"]
    if not tag_exists(root, tag):
        run(["git", "tag", "-a", tag, "-m", f"cyna {plan['version']}"], cwd=root)
    if not args.no_push:
        run(["git", "push", args.git_remote, tag], cwd=root)
        print(f"pushed {tag}")
    else:
        print(f"created {tag} without pushing")
    print("next: publish")
    return 0


def copy_to_local_sink(root: Path, version: str, host: str, stage_dir: str, archive: Path, bootstrap: Path) -> Path:
    sink = root / "dist/release/sink" / version
    sink.mkdir(parents=True, exist_ok=True)
    target = sink / host
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(root / stage_dir / version / host, target)
    for source, destination in ((archive, sink / f"{host}.tar.gz"), (bootstrap, sink / "install.sh")):
        destination.unlink(missing_ok=True)
        shutil.copy2(source, destination)
    return sink


def cmd_publish(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json")
    verify = read_state(root, "verify.json")
    require_verified_commit(root, verify)
    version = plan["version"]
    host = verify["host"]
    archive = Path(verify["archive"])
    if not archive.is_file():
        raise SystemExit(f"verified archive is missing: {archive}")
    if archive_sha256(archive) != verify["sha256"]:
        raise SystemExit("verified archive hash changed; re-run verify")
    require_site_content_current(root, version)
    stage_root = root / args.stage_dir
    bootstrap = stage_root / "install.sh"
    sink = args.sink
    published = {
        "version": version,
        "host": host,
        "commit": verify["commit"],
        "sink": sink,
        "archive_sha256": verify["sha256"],
        "started": utc_now(),
    }
    if sink == "local":
        target = copy_to_local_sink(root, version, host, args.stage_dir, archive, bootstrap)
        published["destination"] = str(target)
        print(f"local sink: {target}")
        installer_smoke(
            root,
            version=version,
            host=host,
            archive_url=archive.as_uri(),
            smoke_path=(root / args.smoke_path).resolve(),
            expected_exit_code=args.smoke_exit_code,
        )
        published["installer_smoke"] = "passed"
    else:
        import publish_distribution

        if not tag_exists(root, plan["tag"]):
            raise SystemExit(f"tag is missing: {plan['tag']}; run tag first")
        tag_commit = capture(["git", "rev-parse", f"{plan['tag']}^{{commit}}"], cwd=root)
        if tag_commit != verify["commit"]:
            raise SystemExit("tag does not point at the verified commit")
        prefix = "distributions" if sink == "public" else "staging/distributions"
        os.environ["CYNA_R2_PREFIX"] = prefix
        publish_distribution.upload_distribution(stage_root, version, host, archive, bootstrap)
        base = os.environ.get("CYNA_DISTRIBUTION_BASE_URL")
        if sink == "staging" and not base:
            raise SystemExit("staging sink needs CYNA_DISTRIBUTION_BASE_URL for the published check")
        base = base or PUBLIC_BASE_URL
        installer_smoke(
            root,
            version=version,
            host=host,
            archive_url=None,
            smoke_path=(root / args.smoke_path).resolve(),
            expected_exit_code=args.smoke_exit_code,
            extra_env={"CYNA_DISTRIBUTION_BASE_URL": base},
        )
        published["installer_smoke"] = "passed"
        published["base_url"] = base
        if sink == "public":
            create_github_release(root, version, host, archive)
            published["github_release"] = "created"
            if not args.no_site:
                deploy_site(root, args.sites_repo, version)
                published["site"] = "deployed"
            if not args.no_tools:
                install_local_compiler(root, version, host, archive)
                install_local_extension(root)
                published["local_install"] = "installed"
        else:
            create_github_release(root, version, host, archive, draft=True)
            published["github_release"] = "draft"
    published["completed"] = utc_now()
    path = write_state(root, "publish.json", published)
    print(f"published {version} through the {sink} sink")
    print(f"state: {path}")
    print("next: verify-published")
    return 0


def deploy_site(root: Path, sites_repo: Path, version: str) -> None:
    site_root = Path(sites_repo).resolve()
    if not site_root.is_dir():
        raise SystemExit(f"sites workspace not found at {site_root}; use --no-site only for a release without site deployment")
    if capture(["git", "status", "--porcelain"], cwd=site_root):
        raise SystemExit(f"sites workspace has local changes: {site_root}")
    run(["git", "fetch", "origin", "main"], cwd=site_root)
    if capture(["git", "rev-parse", "HEAD"], cwd=site_root) != capture(
        ["git", "rev-parse", "origin/main"], cwd=site_root
    ):
        raise SystemExit(f"sites workspace is not at origin/main: {site_root}")
    run([sys.executable, "scripts/prepare_site_content.py", "--version", version], cwd=root)
    run(["node", "packages/site-tools/bin/site.mjs", "sync", "cyna-dev", "--worktree", "--source", str(root)], cwd=site_root)
    lock = json.loads((site_root / "sites/cyna-dev/content.lock.json").read_text())
    if lock.get("version") != version or lock.get("source", {}).get("commit") != git_head(root):
        raise SystemExit("cyna.dev content lock does not match the published release")
    run(["git", "add", "--", "sites/cyna-dev"], cwd=site_root)
    if capture(["git", "diff", "--cached", "--name-only"], cwd=site_root):
        run(["git", "commit", "-m", f"Sync cyna.dev to {version}"], cwd=site_root)
        run(["git", "push", "origin", "HEAD:main"], cwd=site_root)
    run(["node", "packages/site-tools/bin/site.mjs", "deploy", "cyna-dev"], cwd=site_root)
    request = urllib.request.Request("https://cyna.dev/", headers={"User-Agent": "Cyna-release-verifier/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        homepage = response.read().decode("utf-8")
    request = urllib.request.Request("https://cyna.dev/install.sh", headers={"User-Agent": "Cyna-release-verifier/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        installer = response.read().decode("utf-8")
    if f"Current release v{version}" not in homepage:
        raise SystemExit(f"cyna.dev homepage does not show v{version}")
    if f'CYNA_RELEASE_VERSION="${{CYNA_RELEASE_VERSION:-{version}}}"' not in installer:
        raise SystemExit(f"cyna.dev installer does not default to {version}")
    request = urllib.request.Request("https://cyna.dev/install.ps1", headers={"User-Agent": "Cyna-release-verifier/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        windows_installer = response.read().decode("utf-8")
    if f"else {{ '{version}' }})" not in windows_installer:
        raise SystemExit(f"cyna.dev Windows installer does not default to {version}")


def cmd_verify_published(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json")
    publish = read_state(root, "publish.json")
    version = plan["version"]
    host = publish["host"]
    smoke_path = (root / args.smoke_path).resolve()
    if publish["sink"] == "local":
        archive = Path(publish["destination"]) / f"{host}.tar.gz"
        installer_smoke(
            root,
            version=version,
            host=host,
            archive_url=archive.as_uri(),
            smoke_path=smoke_path,
            expected_exit_code=args.smoke_exit_code,
        )
        url = archive.as_uri()
    else:
        base = publish.get("base_url") or PUBLIC_BASE_URL
        installer_smoke(
            root,
            version=version,
            host=host,
            archive_url=None,
            smoke_path=smoke_path,
            expected_exit_code=args.smoke_exit_code,
            extra_env={"CYNA_DISTRIBUTION_BASE_URL": base},
        )
        url = f"{base.rstrip('/')}/{version}/{host}.tar.gz"
    published = {
        "version": version,
        "host": host,
        "commit": publish["commit"],
        "url": url,
        "installer_smoke": "passed",
        "verified": utc_now(),
    }
    path = write_state(root, "published.json", published)
    print(f"published check passed: {url}")
    print(f"state: {path}")
    print("next: record")
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json")
    verify = read_state(root, "verify.json")
    publish = read_state(root, "publish.json")
    published = read_state(root, "published.json", required=False) or {}
    version = plan["version"]
    cava = verify.get("cava", {})
    record = f"""# Cyna {version}

- Status: done
- Type: release
- Owner: n/a
- Last updated: {datetime.now().date().isoformat()}
- Supersedes: n/a
- Superseded by: n/a
- Related: {plan['tag']}

## Shipped

- Version: {version}
- Host: {verify['host']}
- Commit: {plan['commit']}
- Tag: {plan['tag']}
- Artifact: {Path(verify['archive']).name}
- SHA256: `{verify['sha256']}`
- Sink: {publish['sink']}

## Verification

- [x] Release build
- [x] Full test suite
- [x] Staged install smoke
- [x] Cava gate ({cava.get('revision', 'unknown')}, local attestation)
- [x] Release integration checks
- [x] Published install: {published.get('url', 'not run')}

## Known issues

None recorded.

## Rollback

Restore the previous `latest` pointer to {plan.get('previous') or 'the prior release'}
and keep this versioned artifact in place. Do not move the tag.
"""
    if cava.get("result") != "passed":
        record = record.replace(
            f"- [x] Cava gate ({cava.get('revision', 'unknown')}, local attestation)",
            "- [ ] Cava gate (not run; local-only gate needs a clean Cava checkout)",
        )
    path = state_dir(root) / "record.md"
    path.write_text(record, encoding="utf-8")
    target = f"daydream/projects/cyna/docs/releases/{datetime.now().date().isoformat()}-v{version}.md"
    print(f"wrote {path}")
    print(f"record target: {target}")
    return 0


def cmd_install(args: argparse.Namespace) -> int:
    root = repo_root()
    verify = read_state(root, "verify.json")
    install_local_compiler(root, verify["version"], verify["host"], Path(verify["archive"]))
    if not args.no_tools:
        install_local_extension(root)
    print("installed the verified release locally")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    root = repo_root()
    plan = read_state(root, "plan.json", required=False)
    verify = read_state(root, "verify.json", required=False)
    publish = read_state(root, "publish.json", required=False)
    published = read_state(root, "published.json", required=False)
    if not plan:
        print("no release plan; next: plan")
        return 0
    print(f"cyna {plan['version']} on {plan['host']} at {plan['commit'][:8]}")
    if not verify:
        print("verified: no; next: verify")
    elif not publish:
        print(f"verified: yes ({verify['duration_seconds']}s); next: tag or publish")
    elif not published:
        print(f"published: {publish['sink']}; next: verify-published")
    elif (state_dir(root) / "record.md").is_file():
        print(f"published: {published['url']}; recorded")
    else:
        print(f"published: {published['url']}; next: record")
    return 0


def run_all(args: argparse.Namespace, *, sink: str, rehearse: bool) -> int:
    root = repo_root()
    args.sink = sink
    args.allow_dirty = False
    plan = read_state(root, "plan.json", required=False)
    if (
        not plan
        or plan["version"] != (args.release_version or plan["version"])
        or plan.get("commit") != git_head(root)
    ):
        cmd_plan(args)
    plan = read_state(root, "plan.json")
    if rehearse:
        if infer_version(root) != plan["version"]:
            raise SystemExit("rehearsal does not bump the version; prepare and commit first")
    elif infer_version(root) != plan["version"]:
        cmd_prepare(args)
    cmd_verify(args)
    if not rehearse:
        cmd_tag(args)
    cmd_publish(args)
    cmd_verify_published(args)
    cmd_record(args)
    return 0


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--release-version", default=None)
    parser.add_argument("--host", default=detect_host())
    parser.add_argument("--stage-dir", default="dist/distributions")
    parser.add_argument("--smoke-path", default=DEFAULT_SMOKE_PATH)
    parser.add_argument("--smoke-exit-code", type=int, default=DEFAULT_SMOKE_EXIT_CODE)
    parser.add_argument("--cava-root", type=Path, default=repo_root().parent / "cava")
    parser.add_argument("--sites-repo", type=Path, default=repo_root().parent / "sites")
    parser.add_argument("--git-remote", default="origin")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--sink", choices=SINKS, default="public")
    parser.add_argument("--no-push", action="store_true")
    parser.add_argument("--no-site", action="store_true")
    parser.add_argument("--no-tools", action="store_true")
    parser.add_argument(
        "--no-cava",
        action="store_true",
        help="skip the local-only Cava gate and attest in state that it did not run",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Cyna release verbs. With no verb, prints status.",
    )
    sub = parser.add_subparsers(dest="verb")
    for name, function in (
        ("plan", cmd_plan),
        ("prepare", cmd_prepare),
        ("verify", cmd_verify),
        ("tag", cmd_tag),
        ("publish", cmd_publish),
        ("verify-published", cmd_verify_published),
        ("record", cmd_record),
        ("install", cmd_install),
        ("all", lambda a: run_all(a, sink=a.sink, rehearse=False)),
        ("rehearse", lambda a: run_all(a, sink="local", rehearse=True)),
        ("status", cmd_status),
    ):
        child = sub.add_parser(name)
        add_common_args(child)
        if name == "verify":
            child.add_argument(
                "--prebuilt-binary", action="store_true",
                help="verify and package the binary already built in this workspace",
            )
            child.add_argument(
                "--reuse-candidate-tests", action="store_true",
                help="reuse passing candidate tests for the same Buildkite release build",
            )
        child.set_defaults(func=function)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not getattr(args, "verb", None):
        args = parser.parse_args(["status"])
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
