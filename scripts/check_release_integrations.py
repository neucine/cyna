#!/usr/bin/env python3
"""Check the skill and packaged editor support against the release source."""

import argparse
import json
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", type=Path, default=root / "zig-out/bin/cyna")
    args = parser.parse_args()

    skill = (root / ".agents/skills/cyna/SKILL.md").read_text()
    patterns = (root / ".agents/skills/cyna/references/patterns.md").read_text()
    for phrase in ("T!E", "Task<T!E>", "catch-scoped failure view"):
        require(phrase in skill + patterns, f"Cyna skill is missing release guidance: {phrase}")
    for phrase in ("failure.available", "code-only defaults"):
        require(phrase in patterns, f"Cyna skill patterns are missing: {phrase}")

    editor = root / "tools/cyna-vscode"
    package = json.loads((editor / "package.json").read_text())
    grammar_path = editor / "syntaxes/cyna.tmLanguage.json"
    grammar = json.loads(grammar_path.read_text())
    extension_path = editor / "extension.js"
    extension = extension_path.read_text()
    keywords = grammar["repository"]["keywords"]["patterns"][0]["match"]
    completions = extension.split("const KEYWORD_SET = [", 1)[1].split("];", 1)[0]
    for word in ("throw", "catch", "yield", "try"):
        require(re.search(rf"\b{word}\b", keywords) and f'"{word}"' in completions,
                f"VS Code grammar/completions missing {word}")
    for word in ("case", "ok", "err"):
        require(f'"{word}"' not in completions, f"VS Code still suggests removed {word} syntax")
    require("Result|" not in grammar_path.read_text() and "|result" not in grammar_path.read_text(),
            "VS Code grammar still highlights the removed result type")
    subprocess.run(["node", "--check", str(extension_path)], check=True)

    archive = editor / f"cyna-{package['version']}.vsix"
    require(archive.is_file(), f"package the VS Code extension: {archive}")
    with zipfile.ZipFile(archive) as vsix:
        for source, member in ((extension_path, "extension/extension.js"),
                               (grammar_path, "extension/syntaxes/cyna.tmLanguage.json"),
                               (editor / "package.json", "extension/package.json")):
            require(vsix.read(member) == source.read_bytes(), f"stale VS Code package: {member}")

    subprocess.run([str(args.compiler), "check", str(editor / "samples/sample.cy")], check=True, cwd=root)
    with tempfile.TemporaryDirectory(prefix="cyna-release-fmt.") as tmp:
        sample = Path(tmp) / "sample.cy"
        sample.write_bytes((editor / "samples/sample.cy").read_bytes())
        subprocess.run([str(args.compiler), "fmt", str(sample)], check=True, cwd=root)
        once = sample.read_bytes()
        subprocess.run([str(args.compiler), "fmt", str(sample), "--check"], check=True, cwd=root)
        subprocess.run([str(args.compiler), "fmt", str(sample)], check=True, cwd=root)
        require(sample.read_bytes() == once, "formatter changed source on its second pass")
    print(f"release skill and VS Code {package['version']} checks passed")


if __name__ == "__main__":
    main()
