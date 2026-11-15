#!/usr/bin/env python3
"""Require a merged release PR and its exact commit before approval."""

import json
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def command(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main() -> None:
    version = command("buildkite-agent", "meta-data", "get", "release_version")
    number = command("buildkite-agent", "meta-data", "get", "release_pr")
    commit = os.environ.get("BUILDKITE_COMMIT", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?", version):
        raise SystemExit("release_version must be a version such as 0.5.2")
    if not number.isdecimal() or os.environ.get("BUILDKITE_BRANCH") != "master":
        raise SystemExit("release needs a merged release PR number and the master branch")
    if command("git", "rev-parse", "HEAD") != commit:
        raise SystemExit("Buildkite commit differs from the checked-out commit")
    pr = json.loads(command("env", "-u", "GH_TOKEN", "gh", "api", f"repos/neucine/cyna/pulls/{number}"))
    if not pr.get("merged_at") or pr.get("merge_commit_sha") != commit:
        raise SystemExit("the release PR is not merged at this exact commit")
    if pr["head"]["ref"] != f"release/v{version}" or pr["base"]["ref"] != "master":
        raise SystemExit("the PR is not this version's release branch into master")
    subprocess.run(["git", "fetch", "origin", "master"], cwd=ROOT, check=True)
    if command("git", "rev-parse", "origin/master") != commit:
        raise SystemExit("master moved after this release candidate was started")
    declared = (ROOT / "build.zig").read_text(encoding="utf-8")
    if f'const cyna_version = "{version}";' not in declared:
        raise SystemExit("declared Cyna version differs from the promoted version")
    subprocess.run(["python3", "scripts/prepare_site_content.py", "--check", "--version", version], cwd=ROOT, check=True)
    subprocess.run(["buildkite-agent", "meta-data", "set", "release_version", version], cwd=ROOT, check=True)
    subprocess.run(["buildkite-agent", "meta-data", "set", "release_mode", "full"], cwd=ROOT, check=True)
    print(f"verified {version} from merged PR #{number} at {commit}")


if __name__ == "__main__":
    main()
