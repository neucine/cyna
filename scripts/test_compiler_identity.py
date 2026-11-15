import shutil
import tempfile
from pathlib import Path
import unittest

from compiler_identity import compiler_identity


class CompilerIdentityTest(unittest.TestCase):
    def test_content_build_configuration_and_dependencies_are_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch) / "source"
            dependency = Path(scratch) / "dependency"
            files = {
                "build.zig": 'const version = "0.2.1";',
                "build.zig.zon": ".{}",
                ".zig-version": "0.17.0",
                "scripts/compiler_identity.py": "# compiler identity contract",
                "src/main.zig": "const behavior = 1;",
                "src/runtime/inventory.txt": "runtime src/runtime/runtime.c",
                "src/runtime/runtime.c": "int runtime(void) { return 1; }",
                "packages/std/src/prelude.cy": "fn answer(): i32 { return 42; }",
            }
            for name, contents in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            for name in ("build.zig", "build.zig.zon", "src/library.zig"):
                path = dependency / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("dependency input")

            def identity(source: Path = root, optimize: str = "debug") -> str:
                return compiler_identity(source, dependency, "0.17.0", optimize, "aarch64-macos")

            baseline = identity()
            relocated = Path(scratch) / "relocated"
            shutil.copytree(root, relocated)
            self.assertEqual(baseline, identity(relocated))
            self.assertNotEqual(baseline, identity(optimize="safe"))
            (root / "src/main.zig").write_text("const behavior = 2;")
            self.assertNotEqual(baseline, identity())
            (root / "src/main.zig").write_text(files["src/main.zig"])
            self.assertEqual(baseline, identity())
            (dependency / "src/library.zig").write_text("changed dependency")
            self.assertNotEqual(baseline, identity())


if __name__ == "__main__":
    unittest.main()
