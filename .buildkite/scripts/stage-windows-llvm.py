#!/usr/bin/env python3
"""Extract the LLVM 22.1.2 Windows tools needed by Cyna from the verified release."""

import argparse
import shutil
import tarfile
import zipfile
from pathlib import Path


TOOLS = {"clang.exe", "llvm-ar.exe", "ld.lld.exe", "llvm-objcopy.exe"}
PREFIX = "clang+llvm-22.1.2-x86_64-pc-windows-msvc/"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with tarfile.open(args.archive, "r:xz") as source, zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        found = set()
        for member in source:
            if not member.isfile() or not member.name.startswith(PREFIX):
                continue
            relative = member.name[len(PREFIX):]
            if relative.startswith("bin/"):
                if Path(relative).name not in TOOLS:
                    continue
                found.add(Path(relative).name)
            elif not relative.startswith("lib/clang/22/include/"):
                continue
            input_file = source.extractfile(member)
            assert input_file is not None
            with input_file, output.open(f"llvm/{relative}", "w") as output_file:
                shutil.copyfileobj(input_file, output_file)
    if found != TOOLS:
        raise SystemExit(f"LLVM archive missing tools: {sorted(TOOLS - found)}")
    print(f"staged LLVM Windows tools: {args.output}")


if __name__ == "__main__":
    main()
