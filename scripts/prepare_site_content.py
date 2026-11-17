#!/usr/bin/env python3
"""Prepare the public cyna.dev content inside this repository.

``docs/site/docs`` is a release snapshot generated from ``docs``. Edit the source
documents, not the generated copies. ``--check`` verifies that a snapshot is
current without writing it.
"""

import argparse
import difflib
import json
import re
import shutil
import tempfile
from pathlib import Path


DOC_PAGES = {
    "SPEC": "spec",
    "CHEATSHEET": "cheatsheet",
    "GUIDE": "guide",
    "CONCURRENCY": "concurrency",
    "SEMANTICS": "semantics",
    "RUNTIME": "runtime",
    "PHILOSOPHY": "philosophy",
    "STATUS": "status",
    "BUILD": "build",
    "TOOLCHAIN": "toolchain",
    "GLOSSARY": "glossary",
}

SEMVER_PATTERN = r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?"
SITE_OWNED_PAGES = {"index.md", "language_gaps.md"}


def rewrite_links(text: str) -> str:
    for source_name, site_slug in DOC_PAGES.items():
        text = text.replace(f"]({source_name}.md", f"]({site_slug}.md")
    return text


def expected_pages(version: str) -> set[str]:
    return {f"{slug}.md" for slug in DOC_PAGES.values()} | SITE_OWNED_PAGES | {f"release-{version}.md"}


def prepare(source: Path, version: str, site: Path | None = None) -> None:
    site = site or source / "docs" / "site"
    docs = site / "docs"
    docs.mkdir(parents=True, exist_ok=True)

    for name, slug in DOC_PAGES.items():
        text = (source / "docs" / f"{name}.md").read_text()
        if name == "SPEC":
            text = "---\noutline: [1, 4]\n---\n\n" + text
        (docs / f"{slug}.md").write_text(rewrite_links(text))

    release_name = version.replace(".", "_").replace("-", "_")
    release_source = source / "docs" / f"RELEASE_{release_name}.md"
    if not release_source.is_file():
        raise SystemExit(f"missing release notes: {release_source}")
    release_text = rewrite_links(release_source.read_text())
    release_text = re.sub(
        r"\]\(RELEASE_(\d+)_(\d+)_(\d+)(?:_([0-9A-Za-z_]+))?\.md\)",
        lambda match: (
            f"](release-{match[1]}.{match[2]}.{match[3]}.{match[4].replace('_', '.')}.md)"
            if match[4]
            else f"](release-{match[1]}.{match[2]}.{match[3]}.md)"
        ),
        release_text,
    )
    (docs / f"release-{version}.md").write_text(release_text)

    index_path = docs / "index.md"
    index_text = index_path.read_text()
    index_text, count = re.subn(rf"text: Cyna {SEMVER_PATTERN}", f"text: Cyna {version}", index_text)
    if count != 1:
        raise SystemExit(f"expected one homepage version label, found {count}")
    index_path.write_text(index_text)

    manifest_path = site / "site.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["version"] = version
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    expected = expected_pages(version)
    for path in docs.glob("*.md"):
        if path.name in expected or path.name.startswith("release-"):
            continue
        path.unlink()


def check(source: Path, version: str) -> int:
    site = source / "docs" / "site"
    with tempfile.TemporaryDirectory(prefix="cyna-site-") as temporary:
        candidate = Path(temporary) / "site"
        shutil.copytree(site, candidate)
        prepare(source, version, candidate)

        expected = expected_pages(version) | {"site.json"}
        problems: list[str] = []
        for name in sorted(expected):
            relative = Path("site.json") if name == "site.json" else Path("docs") / name
            current = site / relative
            generated = candidate / relative
            if not current.is_file():
                problems.append(f"missing generated file: {relative}")
                continue
            if current.read_bytes() == generated.read_bytes():
                continue
            diff = difflib.unified_diff(
                current.read_text().splitlines(),
                generated.read_text().splitlines(),
                fromfile=f"docs/site/{relative}",
                tofile="docs source snapshot",
                lineterm="",
            )
            problems.append("\n".join(list(diff)[:40]))

        for path in sorted((site / "docs").glob("*.md")):
            if path.name not in expected_pages(version) and not path.name.startswith("release-"):
                problems.append(f"stale generated file: docs/site/docs/{path.name}")

        if problems:
            print("site content is out of date; run scripts/prepare_site_content.py")
            print("\n".join(problems))
            return 1
    print(f"site content matches docs for {version}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--check", action="store_true", help="verify without writing")
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    source = args.source.resolve()
    version = args.version
    if version is None:
        version = json.loads((source / "docs" / "site" / "site.json").read_text()).get("version")
    if not isinstance(version, str) or not re.fullmatch(SEMVER_PATTERN, version):
        parser.error("version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-PRERELEASE")
    if args.check:
        return check(source, version)
    prepare(source, version)
    print(f"prepared cyna site content for {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
