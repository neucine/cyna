#!/usr/bin/env python3
"""Verify regenerated hosted payloads through an isolated public compiler.

The existing LLVM payload supplies tools, not runtime archives. Runtime/std
archives are regenerated from this checkout. The account and distribution are
temporary, leaving the user's installed compiler and target payloads untouched.
"""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Thread

from clang_resources import stage_clang_resource_headers, resource_header_manifest
from publish_distribution import infer_version, render_target_manifest, stage_bundled_packages


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--llvm-root", type=Path, required=True)
    parser.add_argument("--source-clang", type=Path, required=True)
    parser.add_argument("--llvm-nm", type=Path, required=True)
    parser.add_argument("--target", default="aarch64-apple-darwin")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    scratch = Path(tempfile.mkdtemp(prefix="cyna-runtime-distribution."))
    print(f"verification workspace: {scratch}", flush=True)
    version = infer_version(root)
    account = scratch / "account"
    distribution = account / ".cyna" / version
    (distribution / "bin").mkdir(parents=True)
    compiler = distribution / "bin/cyna"
    shutil.copy2(args.compiler.resolve(), compiler)
    llvm = distribution / "llvm"
    shutil.copytree(args.llvm_root.resolve(), llvm)
    headers = stage_clang_resource_headers(args.source_clang.resolve(), llvm)
    manifest_path = llvm / "bundle.toml"
    manifest = "\n".join(line for line in manifest_path.read_text().splitlines()
                         if not line.startswith("resource_headers")) + "\n"
    manifest_path.write_text(manifest + resource_header_manifest(llvm, headers))
    stage_bundled_packages(root, distribution)
    shutil.copytree(root / "src/runtime", distribution / "src/runtime")
    payload = distribution / "targets" / args.target
    subprocess.run([
        "python3", str(root / "scripts/build_target_support_payload.py"),
        "--target", args.target, "--hosted-std", "--clang", str(llvm / "bin/clang"),
        "--llvm-ar", str(llvm / "bin/llvm-ar"), "--llvm-nm", str(args.llvm_nm.resolve()),
        "--output-dir", str(payload),
    ], check=True)
    (payload / "manifest.toml").write_text(render_target_manifest(
        args.target, payload / "include/cyna.h", payload / "lib/libcyna.a",
        payload / "lib/libcyna_std.a",
    ))
    environment = dict(os.environ, HOME=str(account), CYNA_ALLOW_HOST_TOOLCHAIN_CAPTURE="0")

    def run(*argv: object, expected: int = 0) -> subprocess.CompletedProcess[str]:
        command = [str(arg) for arg in argv]
        result = subprocess.run(command, cwd=scratch, env=environment, capture_output=True, text=True)
        if result.returncode != expected or "leaked" in result.stderr:
            raise RuntimeError(f"{command}: expected {expected}, got {result.returncode}\n{result.stdout}\n{result.stderr}")
        return result

    # This exercises the installed executable and freshly generated archives,
    # including queued ownership, task results, descendant admission, and drain.
    for example, expected in (("task_group_owned_result", 5), ("task_group_descendant", 42)):
        project = scratch / example
        project.mkdir()
        shutil.copy2(root / f"examples/{example}.cy", project / "main.cy")
        (project / "cyna.toml").write_text('entry = "main.cy"\n')
        output = project / "program"
        run(compiler, "build", project, "--output", output)
        run(output, expected=expected)

    installed_thread = distribution / "packages/std/src/std_thread.cy"
    thread_source = installed_thread.read_text()
    try:
        installed_thread.write_text(thread_source + "\nnot_a_declaration\n")
        rejection = run(compiler, "check", scratch / "task_group_descendant/main.cy", expected=1)
        if str(installed_thread) not in rejection.stderr:
            raise RuntimeError("compiler did not diagnose its installed std source")
    finally:
        installed_thread.write_text(thread_source)

    library = scratch / "library"
    library.mkdir()
    (library / "cyna.toml").write_text('name = "taskprobe"\ntype = "staticlib"\nentry = "lib.cy"\n')
    (library / "lib.cy").write_text('''import { TaskGroup } from std.thread;
export c("probe") fn probe(): c_int {
    switch TaskGroup.init(1 as u32) {
    case .ok(group) { group.finish(); return 42; }
    case .err(problem) { const ignored = problem; return 1; }
    }
}
''')
    archive = library / "libtaskprobe.a"
    run(compiler, "build", library, "--output", archive)
    if not Path(str(archive) + ".cyna-link.toml").is_file():
        raise RuntimeError("static library link metadata is missing")
    runtime_source = distribution / "src/runtime/runtime.c"
    parked_source = runtime_source.with_suffix(".c.disabled")
    runtime_source.rename(parked_source)
    try:
        rejection = run(compiler, "build", library, "--output", library / "must-not-build.a", expected=1)
        if str(runtime_source) not in rejection.stderr:
            raise RuntimeError("missing installed runtime input was concealed by a checkout fallback")
    finally:
        parked_source.rename(runtime_source)
    consumer = scratch / "consumer"
    consumer.mkdir()
    (consumer / "cyna.toml").write_text('entry = "main.cy"\n[link]\nlibs = ["taskprobe"]\nsearch_paths = ["../library"]\n')
    (consumer / "main.cy").write_text('extern c("probe") fn probe(): c_int;\nfn main(): i32 { return probe() as i32; }\n')
    run(compiler, "build", consumer, "--output", consumer / "program")
    run(consumer / "program", expected=42)
    print("packaged tasks and source-built static-library consumption passed", flush=True)

    # Exercise the actual per-file remote fetcher against the staged manifest.
    # All writes and the development trust override are confined to this account.
    artifact_root = scratch / "artifacts"
    artifact_root.mkdir()
    shutil.move(llvm, artifact_root / "llvm")

    class QuietHandler(SimpleHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(artifact_root)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        environment.update(CYNA_TOOLCHAIN_ARTIFACT_BASE_URL=f"http://127.0.0.1:{server.server_port}",
                           CYNA_ALLOW_UNPINNED_TOOLCHAIN_ARTIFACT="1")
        run(compiler, "build", library, "--output", library / "librefetched.a")
        installed_header = llvm / headers.relative_to(llvm) / "stdbool.h"
        if not installed_header.is_file():
            raise RuntimeError("remote provisioning did not restore builtin headers")
        print("remote header provisioning and source static-library rebuild passed", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
