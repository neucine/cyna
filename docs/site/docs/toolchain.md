# Cyna toolchain and installation

The Cyna distribution contains the `cyna` compiler, its host LLVM/Clang tools,
the bundled `std` package, and target-specific runtime and standard-library
archives. Version 0.5.4 provides compiler hosts for Apple Silicon macOS,
x86-64 Linux, and x86-64 Windows.

## Install and verify

On Apple Silicon macOS or x86-64 Linux:

```sh
curl -fsSL https://cyna.dev/install.sh | sh
export PATH="$HOME/.cyna/current/bin:$PATH"
cyna version
```

The installer downloads the current host archive, installs it under
`~/.cyna/0.5.4/`, and updates `~/.cyna/current` and `~/.cyna/bin/cyna`.
Pass a version as an argument to install a specific release, for example:

```sh
curl -fsSL https://cyna.dev/install.sh | sh -s -- 0.5.4
```

The installer also accepts an explicit host triple as its second argument.
For a custom location, set `CYNA_INSTALL_ROOT` before running it. The installer
prints the path to add to `PATH` after installation.

On Windows x64, run this in PowerShell:

```powershell
irm https://cyna.dev/install.ps1 | iex
cyna version
```

The script downloads the Windows ZIP, checks its layout, installs it under
`~/.cyna/0.5.4/`, and adds `~/.cyna/bin` to your user `PATH`. Open a new
PowerShell window to use `cyna` later. Set `CYNA_RELEASE_VERSION` to install
a specific release or `CYNA_INSTALL_ROOT` for another location. You can also
download the [Windows ZIP directly](https://downloads.cyna.dev/distributions/0.5.4/x86_64-pc-windows-gnu.zip).

## What is installed

The versioned directory contains:

| Path | Purpose |
| --- | --- |
| `bin/cyna` | Compiler and project commands. |
| `llvm/` | Host tools used to compile and link. |
| `packages/` | Bundled source packages, including `std`. |
| `targets/<triple>/` | Target manifest, C header, `libcyna.a`, and `libcyna_std.a`. |

The compiler selects a matching target manifest and archives for each build.
Bundled packages are loaded from the installed distribution. An incomplete
distribution produces a missing-target-support diagnostic rather than silently
linking libraries for a different target.

## Host and build targets

The **host** is where the compiler runs. The **target** is where its output
runs. Cyna targets development hosts: macOS on Apple Silicon, Linux on x86-64,
and Windows on x86-64. It can cross-build for the freestanding
targets `aarch64-none-elf`, `x86_64-none-elf`, `riscv64-none-elf`,
`riscv32-none-elf`, `arm-none-eabi`, and `thumbv7em-none-eabi`.
Server-only hosted targets such as `aarch64-unknown-linux-gnu` are out of
scope.

Use `target = "native"` (or omit it) to build for the host. Hosted targets
also accept `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`, and
`x86_64-pc-windows-gnu`. Windows builds use the GNU toolchain conventions;
the Windows distribution includes the matching C headers and runtime libraries.
Selecting a cross-target still requires its matching headers and link libraries.

Select a target in a project's `cyna.toml`:

```toml
[build]
target = "aarch64-none-elf"
```

`cyna run` and `cyna test` execute native outputs on the supported host.
Cross-target and freestanding outputs are built with `cyna build`; run them in
an appropriate target environment. See [build](build.md) for project layout,
manifest keys, and output options, and [runtime](runtime.md) for what the
target archives provide.
