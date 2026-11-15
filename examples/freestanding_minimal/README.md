# Freestanding Minimal

This example shows the current closed freestanding build contract:

- explicit freestanding target and CPU
- one startup assembly file
- one linker script
- explicit entry symbol
- raw image emission through `--emit-elf` and `--emit-bin`

Build from the repository root with:

```sh
zig build
zig-out/bin/cyna build examples/freestanding_minimal
```

Expected outputs:

- `examples/freestanding_minimal/build/freestanding-minimal`
- `examples/freestanding_minimal/build/freestanding-minimal.elf`
- `examples/freestanding_minimal/build/freestanding-minimal.bin`
