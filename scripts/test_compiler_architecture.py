import tempfile
import unittest
from pathlib import Path

from check_compiler_architecture import imports, violations


class CompilerArchitectureTests(unittest.TestCase):
    def test_phase_direction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parser = root / "src/compiler/parser"
            sema = root / "src/compiler/sema"
            parser.mkdir(parents=True)
            sema.mkdir(parents=True)
            (parser / "ast.zig").write_text("")
            (sema / "sema.zig").write_text('const ast = @import("../parser/ast.zig");\n')
            self.assertEqual([], violations(root))
            (parser / "parser.zig").write_text('const sir = @import("../sema/sema.zig");\n')
            self.assertEqual(1, len(violations(root)))
            self.assertIn("parser reaches later phase sema", violations(root)[0])

    def test_indirect_phase_dependency_through_shared_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parser = root / "src/compiler/parser"
            sema = root / "src/compiler/sema"
            parser.mkdir(parents=True)
            sema.mkdir(parents=True)
            (parser / "parser.zig").write_text('const shared = @import("../../shared.zig");\n')
            (root / "src/shared.zig").write_text('const later = @import("./compiler/sema/sema.zig");\n')
            (sema / "sema.zig").write_text("")
            failures = violations(root)
            self.assertEqual(1, len(failures))
            self.assertIn("src/compiler/parser/parser.zig:1", failures[0])
            self.assertIn("src/shared.zig -> src/compiler/sema/sema.zig", failures[0])

    def test_import_text_in_comments_and_strings_is_ignored(self):
        source = (
            '// @import("../sema/sema.zig")\n'
            'const note = "@import(\\"../sema/sema.zig\\")";\n'
            "const ch = '@';\n"
            '\\\\@import("../sema/sema.zig")\n'
            'const real = @import ( "../parser/ast.zig" );\n'
        )
        self.assertEqual([("../parser/ast.zig", 5)], imports(source))

    def test_external_import_is_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parser = root / "src/compiler/parser"
            parser.mkdir(parents=True)
            (parser / "parser.zig").write_text('const std = @import("std");\n')
            self.assertEqual([], violations(root))


if __name__ == "__main__":
    unittest.main()
