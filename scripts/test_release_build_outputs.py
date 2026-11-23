import os
import argparse
import contextlib
import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import release_distribution as release

from release_distribution import restore_release_outputs, snapshot_release_outputs


class ReleaseBuildOutputsTests(unittest.TestCase):
    def test_tests_cannot_replace_packaged_release_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = "bin/cyna.exe" if os.name == "nt" else "bin/cyna"
            originals = {}
            for relative in (binary, "lib/libcyna.a", "lib/libcyna_std.a"):
                path = root / "zig-out" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(("release " + relative).encode())
                path.chmod(0o755 if relative == binary else 0o644)
                originals[relative] = (path.read_bytes(), path.stat().st_mode & 0o777)
            snapshot = snapshot_release_outputs(root)
            for relative in originals:
                path = root / "zig-out" / relative
                path.write_bytes(b"debug replacement")
                path.chmod(0o600)
            restore_release_outputs(root, snapshot)
            self.assertEqual(snapshot_release_outputs(root), originals)
            (root / "zig-out" / binary).unlink()
            restore_release_outputs(root, snapshot)
            self.assertEqual(snapshot_release_outputs(root), originals)


    def test_verify_packages_the_original_build_after_debug_test_installs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "main.cy").write_text("fn main(): i32 { return 42; }")
            binary = "bin/cyna.exe" if os.name == "nt" else "bin/cyna"
            for relative in (binary, "lib/libcyna.a", "lib/libcyna_std.a"):
                path = root / "zig-out" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"release output")
                path.chmod(0o755)
            original = snapshot_release_outputs(root)

            def install_debug(*args, **kwargs):
                for relative in original:
                    (root / "zig-out" / relative).write_bytes(b"debug output")

            def smoke(*args, **kwargs):
                self.assertEqual(snapshot_release_outputs(root), original)

            def package(*args, **kwargs):
                self.assertTrue(kwargs["prebuilt_binary"])
                self.assertEqual(snapshot_release_outputs(root), original)
                archive = root / "dist/0.5.4/aarch64-apple-darwin.tar.gz"
                archive.parent.mkdir(parents=True, exist_ok=True)
                archive.write_bytes(b"verified archive")

            mocks = {
                "repo_root": Mock(return_value=root),
                "read_state": Mock(return_value={"version": "0.5.4", "commit": "release-sha"}),
                "infer_version": Mock(return_value="0.5.4"),
                "git_head": Mock(return_value="release-sha"),
                "require_clean_worktree": Mock(),
                "require_site_content_current": Mock(),
                "verify_version": Mock(),
                "release_test_env": Mock(return_value={}),
                "release_test_command": Mock(side_effect=lambda env, tier="test": [tier]),
                "run": Mock(side_effect=install_debug),
                "checkout_smoke": Mock(side_effect=smoke),
                "stage_distribution": Mock(side_effect=package),
                "staged_release_test_env": Mock(return_value={}),
                "release_integration_gate": Mock(side_effect=install_debug),
                "write_state": Mock(return_value=root / "verify.json"),
            }
            args = argparse.Namespace(
                allow_dirty=False, prebuilt_binary=True, reuse_candidate_tests=False,
                smoke_path="main.cy", smoke_exit_code=42,
                host="aarch64-apple-darwin", stage_dir="dist", no_cava=True,
            )
            with patch.multiple(release, **mocks), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(release.cmd_verify(args), 0)
            self.assertEqual(snapshot_release_outputs(root), original)
            self.assertEqual([call.args[0] for call in mocks["run"].call_args_list], [["test"], ["test-fast"]])
            state = mocks["write_state"].call_args.args[2]
            self.assertEqual(state["compiler_sha256"], hashlib.sha256(b"release output").hexdigest())


if __name__ == "__main__":
    unittest.main()
