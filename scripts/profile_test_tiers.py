#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time


DEFAULT_TIERS = [
    ("test-fast", ["zig", "build", "test-fast"]),
    ("test-native", ["zig", "build", "test-native"]),
    ("test-targets", ["zig", "build", "test-targets"]),
    ("test-tooling", ["zig", "build", "test-tooling"]),
    ("test-extended", ["zig", "build", "test-extended"]),
]

NATIVE_TIERS = [
    ("test-native-c-abi", ["zig", "build", "test-native-c-abi"]),
    ("test-native-core", ["zig", "build", "test-native-core"]),
    ("test-native-examples", ["zig", "build", "test-native-examples"]),
    ("test-native-language", ["zig", "build", "test-native-language"]),
    ("test-native-allocator-contexts", ["zig", "build", "test-native-allocator-contexts"]),
    ("test-native-casts", ["zig", "build", "test-native-casts"]),
    ("test-native-generics", ["zig", "build", "test-native-generics"]),
    ("test-native-globals", ["zig", "build", "test-native-globals"]),
    ("test-native-ownership", ["zig", "build", "test-native-ownership"]),
    ("test-native-unions", ["zig", "build", "test-native-unions"]),
    ("test-native-numeric", ["zig", "build", "test-native-numeric"]),
    ("test-native-packed", ["zig", "build", "test-native-packed"]),
    ("test-native-refs", ["zig", "build", "test-native-refs"]),
    ("test-native-storage", ["zig", "build", "test-native-storage"]),
    ("test-native-strings", ["zig", "build", "test-native-strings"]),
]


def parse_args():
    argv = sys.argv[1:]
    passthrough_args = []
    if "--" in argv:
        separator = argv.index("--")
        passthrough_args = argv[separator + 1 :]
        argv = argv[:separator]

    parser = argparse.ArgumentParser(
        description="Profile Cyna test tier wall-clock times.",
    )
    parser.add_argument(
        "tiers",
        nargs="*",
        help="Tier names to run. Defaults to all standard tiers.",
    )
    parser.add_argument(
        "--json-out",
        help="Write machine-readable results to this path.",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop after the first failing tier.",
    )
    args = parser.parse_args(argv)
    args.test_args = passthrough_args
    return args


def tier_map():
    return {name: command for name, command in DEFAULT_TIERS + NATIVE_TIERS}


def selected_tiers(names):
    commands = tier_map()
    if not names:
        return DEFAULT_TIERS
    selected = []
    for name in names:
        if name not in commands:
            valid = ", ".join(commands)
            raise SystemExit(f"unknown tier '{name}' (valid: {valid})")
        selected.append((name, commands[name]))
    return selected


def run_tier(name, command, passthrough_args):
    full_command = list(command)
    if passthrough_args:
        full_command.append("--")
        full_command.extend(passthrough_args)

    print(f"==> {name}: {' '.join(full_command)}", flush=True)
    started = time.monotonic()
    result = subprocess.run(full_command)
    elapsed = time.monotonic() - started
    print(f"<== {name}: exit={result.returncode} elapsed={elapsed:.3f}s", flush=True)
    return {
        "name": name,
        "command": full_command,
        "exit_code": result.returncode,
        "elapsed_seconds": elapsed,
    }


def main():
    args = parse_args()
    passthrough_args = args.test_args

    results = []
    for name, command in selected_tiers(args.tiers):
        result = run_tier(name, command, passthrough_args)
        results.append(result)
        if args.fail_fast and result["exit_code"] != 0:
            break

    failed = [result for result in results if result["exit_code"] != 0]
    total = sum(result["elapsed_seconds"] for result in results)
    print("\nSummary:")
    for result in sorted(results, key=lambda item: item["elapsed_seconds"], reverse=True):
        print(
            f"  {result['name']:<13} {result['elapsed_seconds']:>8.3f}s "
            f"exit={result['exit_code']}"
        )
    print(f"  {'total':<13} {total:>8.3f}s")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "results": results,
                    "total_elapsed_seconds": total,
                },
                handle,
                indent=2,
            )
            handle.write("\n")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
