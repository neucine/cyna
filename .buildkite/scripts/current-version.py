#!/usr/bin/env python3
"""Read Cyna's declared compiler version from build.zig."""

import pathlib
import re


root = pathlib.Path(__file__).resolve().parents[2]
build = (root / "build.zig").read_text()
match = re.search(r'^\s*const cyna_version = "([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?)";', build, re.MULTILINE)
if match is None:
    raise SystemExit("could not read cyna_version from build.zig")
print(match.group(1))
