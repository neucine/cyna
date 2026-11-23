#!/usr/bin/env python3
"""Check the Windows driver's dispatch and target spelling without a Windows VM."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WindowsClangWrapperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("cc")
        if compiler is None:
            raise unittest.SkipTest("a host C compiler is required")
        cls.temporary = tempfile.TemporaryDirectory(prefix="cyna-windows-driver-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        (root / "process.h").write_text(
            '#define _P_WAIT 0\nint _spawnv(int, const char *, const char *const *);\n'
        )
        (root / "windows.h").write_text(
            '#define MAX_PATH 260\ntypedef unsigned long DWORD;\n'
            'DWORD GetModuleFileNameA(void *, char *, DWORD);\n'
        )
        (root / "host.c").write_text(r'''
#include <stdio.h>
#include <string.h>
#include "windows.h"
DWORD GetModuleFileNameA(void *module, char *path, DWORD size) {
    (void)module; (void)size;
    strcpy(path, "C:\\portable\\llvm\\bin\\clang.exe");
    return (DWORD)strlen(path);
}
int _spawnv(int mode, const char *path, const char *const *args) {
    (void)mode; (void)path;
    for (int i = 0; args[i]; ++i) puts(args[i]);
    return 42;
}
''')
        cls.driver = root / "driver"
        subprocess.run([
            compiler, "-Wall", "-Wextra", "-Werror", "-I", str(root),
            str(ROOT / ".buildkite/scripts/windows-clang-wrapper.c"),
            str(root / "host.c"), "-o", str(cls.driver),
        ], check=True)

    def test_dispatch_preserves_gnu_target_and_arguments(self):
        for arguments, ir in [
            (["-c", "helper.c", "-o", "helper.o"], False),
            (["-c", "helper.S", "-o", "helper.o"], False),
            (["main.o", "-o", "app.exe"], False),
            (["-c", "-x", "ir", "main.ll", "-o", "main.o"], True),
        ]:
            for explicit in (False, True):
                with self.subTest(arguments=arguments, explicit=explicit):
                    supplied = arguments + (["--target=x86_64-pc-windows-gnu"] if explicit else [])
                    result = subprocess.run([str(self.driver), *supplied], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 42)
                    actual = result.stdout.splitlines()
                    self.assertTrue(actual[0].endswith("clang-ir.exe" if ir else "zig.exe"))
                    prefix = ["--target=x86_64-pc-windows-gnu"] if ir else ["cc", "-target", "x86_64-windows-gnu"]
                    expected = [arg.replace("--target=x86_64-pc-windows-gnu", "--target=x86_64-windows-gnu") if not ir else arg for arg in supplied]
                    self.assertEqual(actual[1:], prefix + expected)

    def test_explicit_linux_target_reaches_zig_without_vendor(self):
        result = subprocess.run([
            str(self.driver), "--target=x86_64-unknown-linux-gnu", "-c", "helper.c",
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 42)
        self.assertEqual(result.stdout.splitlines()[1:], [
            "cc", "-target", "x86_64-windows-gnu",
            "--target=x86_64-linux-gnu", "-c", "helper.c",
        ])


if __name__ == "__main__":
    unittest.main()
