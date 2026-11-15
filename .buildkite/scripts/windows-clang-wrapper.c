#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

int main(int argc, char **argv) {
    char path[MAX_PATH];
    DWORD length = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return 1;
    char *separator = strrchr(path, '\\');
    if (separator == NULL) return 1;
    size_t prefix = (size_t)(separator + 1 - path);
    char zig_path[MAX_PATH];
    char ir_path[MAX_PATH];
    if (snprintf(zig_path, sizeof(zig_path), "%.*s..\\zig\\zig.exe", (int)prefix, path) >= MAX_PATH) return 1;
    if (snprintf(ir_path, sizeof(ir_path), "%.*sclang-ir.exe", (int)prefix, path) >= MAX_PATH) return 1;

    int llvm_ir = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], "-x") == 0 && strcmp(argv[i + 1], "ir") == 0) llvm_ir = 1;
    }

    int offset = llvm_ir ? 1 : 3;
    char **args = (char **)calloc((size_t)argc + (size_t)offset + 1, sizeof(char *));
    if (args == NULL) return 1;
    const char *driver = llvm_ir ? ir_path : zig_path;
    args[0] = (char *)driver;
    args[1] = llvm_ir ? "--target=x86_64-pc-windows-gnu" : "cc";
    if (!llvm_ir) {
        args[2] = "-target";
        args[3] = "x86_64-windows-gnu";
    }
    for (int i = 1; i < argc; ++i) args[i + offset] = argv[i];
    int result = _spawnv(_P_WAIT, driver, (const char *const *)args);
    if (result == -1) perror(driver);
    free(args);
    return result == -1 ? 1 : result;
}
