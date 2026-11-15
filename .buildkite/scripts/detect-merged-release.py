#!/usr/bin/env python3
"""Add release checks to the ordinary main build for a merged release PR."""

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def command(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main() -> None:
    if os.environ.get("BUILDKITE_BRANCH") != "main":
        raise SystemExit("release detection requires main")
    commit = os.environ["BUILDKITE_COMMIT"]
    if command("git", "rev-parse", "HEAD") != commit:
        raise SystemExit("checkout differs from Buildkite commit")
    pulls = json.loads(command("gh", "api", f"repos/neucine/cyna/commits/{commit}/pulls"))
    matches = [pr for pr in pulls if pr.get("merged_at") and pr.get("merge_commit_sha") == commit
               and pr["base"]["ref"] == "main"
               and re.fullmatch(r"release/v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?", pr["head"]["ref"])]
    if not matches:
        print("No merged release PR at this commit; ordinary checks only.")
        return
    if len(matches) != 1:
        raise SystemExit("expected exactly one merged release PR")
    pr = matches[0]
    version = pr["head"]["ref"].removeprefix("release/v")
    if command("python3", ".buildkite/scripts/current-version.py") != version:
        raise SystemExit("merged release PR version differs from build.zig")
    command("buildkite-agent", "meta-data", "set", "release_version", version)
    command("buildkite-agent", "meta-data", "set", "release_mode", "full")
    command("buildkite-agent", "meta-data", "set", "release_pr", str(pr["number"]))
    subprocess.run(["buildkite-agent", "pipeline", "upload", ".buildkite/merged-release.yml"], cwd=ROOT, check=True)
    print(f"Added Cyna {version} release checks for merged PR #{pr['number']} at {commit}")


if __name__ == "__main__":
    main()
