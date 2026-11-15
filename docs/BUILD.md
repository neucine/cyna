# Cyna Build And Project Model

This document describes the current user-facing build model for Cyna projects.

It is non-normative. `SPEC.md` remains the language authority. This file is
about commands, manifests, outputs, and project shape.

## Start a project

After [installing the toolchain](TOOLCHAIN.md), a small executable project can
use `src/main.cy` and a `cyna.toml` manifest:

```toml
name = "hello"
version = "0.1.0"
src = "src"
type = "exe"
entry = "src/main.cy"
```

From the project directory, use `cyna check .` for diagnostics, `cyna run .`
to build and run on the supported native host, or `cyna build .` to produce
an artifact. Use `cyna build src/main.cy` to build a single source file without
a manifest. `cyna version` identifies the installed compiler.

## Current Command Surface

The current implemented command set is:

```text
cyna build
cyna run
cyna test
cyna clean
cyna install
cyna package
cyna check
cyna fmt
cyna lsp
cyna version
```

Practical meaning:

- `cyna build`
  compile a file or project and emit the requested artifacts
- `cyna run`
  build and run a native executable target
- `cyna test`
  discover and run independent `*.test.cy` test roots on the native host
- `cyna clean`
  remove local build output
- `cyna install`
  ensure the compiler distribution is present and install/verify manifest dependencies
- `cyna package`
  build, stage, or publish package artifacts
- `cyna check`
  run the parser and semantic analysis pass only; emits diagnostics without producing artifacts
- `cyna fmt`
  format sources and normalize directly redundant struct constructor types
- `cyna lsp`
  start the language server protocol server for editor integration
- `cyna version`
  print the current compiler version

## Source Formatting

```sh
cyna fmt [paths...] [--check]
```

With no paths, format the current directory recursively. Explicit inputs may be
`.cy` files or directories. Directory traversal skips hidden directories,
`build`, `zig-out`, `dist`, `node_modules`, and symlink entries. Paths to changed
files are printed to stderr; unchanged files produce no output. Use `--` before
paths beginning with a dash. Explicit symlink inputs are rejected; pass the
source path directly. Inputs are independent: an invalid file is left
untouched and reported, while other valid files can still be formatted.

Repository formatting runs through `./scripts/format.sh [--check]`. It covers
examples, the standard library, hand-written embedded sources, and the editor
sample while excluding generated SVD device bindings. The wrapper uses
`zig-out/bin/cyna` by default; set `CYNA_BIN` to select another build.

The formatter uses four-space indentation, normalizes ordinary token spacing,
places brace-delimited fields and statements on separate lines, retains existing
multiline sequence/parameter layouts and at most one blank line between tokens,
and ensures a final newline for nonempty source. Comments and literal contents
are preserved. Ambiguous generic-angle and type-suffix adjacency is retained
rather than guessed; line wrapping and automatic trailing commas are not yet
part of the formatter.

When semantic analysis supplies the cast target as the literal's expected type,
`cyna fmt` removes an explicit numeric literal cast if the literal fits exactly.
Potentially rounded float casts and casts that establish an otherwise absent
type context remain explicit.

Formatting also normalizes a directly annotated binding such as
`const point: Point = Point { x: 1, y: 2 };` to
`const point: Point = { x: 1, y: 2 };` (with formatted line breaks). This applies
to `const` and `var`, with matching simple named types and a complete struct
initializer. Inferred bindings, optional contexts, qualified/generic types,
different constructor types, and larger initializer expressions retain their
explicit constructors. No separate lint command is required for this rule.

Formatting also prefers direct slices for zero-argument methods carrying
`@syntax.slice_view`. Semantic analysis must prove that `receiver[..]` selects
the same method and result access as the explicit call. For example,
`items.view_mut()` becomes `items[..]`; `items.view()` becomes `items[..]` for
a read-only receiver, but stays explicit on a writable receiver when it forces
a const view. Renamed annotated methods work under the same rule. Method names
alone never authorize a rewrite. Generic caller bodies and calls containing
comments remain conservative. Missing imports or semantic errors disable this
normalization without preventing ordinary formatting. This policy is part of
`cyna fmt`, including `--check`; it does not require a separate lint command.

For integer-key index hooks, formatting removes a direct checked cast that only
converts the complete key expression to the hook parameter type. For example,
`items[key as usize]` becomes `items[key]` when semantic analysis confirms an
integer-key hook. Direct method calls, casts inside larger key expressions,
non-integer conversions, and casts whose role cannot be proved are retained.

Parsing validates inputs and outputs; token comparison guards non-trivia text
around syntax-only normalizations, and semantic proof gates slice-call and
index-key edits.
Files are replaced atomically with their original permissions. Formatting does
not replace `cyna check` for project validation.

`--check` performs the same formatting and normalization without writing. Exit
status is 0 for clean inputs and 1 for differences or input failures. Normal
formatting exits 1 on input failures and 0 otherwise. No compiler backend or
native toolchain is needed to format source.

## Current Build CLI

Today `cyna build <file-or-project>` supports:

- `--emit-tok`
- `--emit-ast`
- `--emit-sir`
- `--emit-lir`
- `--emit-ll` / `--emit-llvm`
- `--emit-c-header`
- `--emit-asm-include`
- `--emit-obj`
- `--emit-elf`
- `--emit-bin`
- `--emit-hex`
- `--verbose`
- `--output <path>`

`--emit-ast` writes the versioned `ast-summary-v1` declaration inventory. It
covers imports, globals, aliases, enums, unions, protocols, impls, structs,
function signatures, and inline tests with representative counts. Within the
`v1` format its line grammar and declaration-family ordering are stable. It is
not a lossless serialization of the parser's full internal AST, source order,
or expression/statement tree; a future incompatible summary must use a new
header.

Current artifact naming is path-based:

- the main native artifact uses `--output` exactly when provided
- side artifacts reuse that same base path with suffixes such as
  `.tok`, `.ast`, `.sir`, `.lir`, `.ll`, `.h`, `.o`, `.elf`, `.bin`, and `.hex`
- `--verbose` prints build pipeline progress to stderr; emitted stage text is
  still written to artifact files

Native object caching:

- generated LLVM objects are cached under `<project>/.cyna-cache/native-objects`
- cache keys include source contents, compiler build identity, resolved tool
  contents, target, CPU, optimization mode, and native flags
- C and assembly sources are compiled normally until complete dependency
  tracking is available; this includes quoted/transitive headers without an
  explicit include path, not just sources using `-I`
- `cyna clean <project>` removes this cache together with the build outputs

For normal native builds, Cyna also caches the complete emitted LLVM module
under `<project>/.cyna-cache/llvm-modules`. The key covers all loaded Cyna
module sources, target and optimization settings, native source contents,
link settings, and the compiler build identity. A cache hit skips LIR lowering
and LLVM emission, but never current semantic validation; requests for AST/SIR/LIR/header/assembly
inspection continue to run the full pipeline.

The final executable/shared-library link is cached under
`<project>/.cyna-cache/native-artifacts`; object/archive contents and linker
settings are part of its key. Resolved tool contents, the hosted linker's actual
executable, and Darwin SDK link inputs are fingerprinted. Ordered object content
digests, not temporary object filenames, identify the linked objects.
Explicit search directories and `LIBRARY_PATH` contents (including versioned
shared libraries and negative/missing candidates) participate in link identity.
The currently shipped compiler distribution supports an aarch64 macOS host.
A cross-built Linux executable reports an unsupported-host diagnostic before
toolchain provisioning rather than selecting the macOS bundle. The following
Linux cache logic is preparatory, not a claim of a supported Linux distribution:
on native Linux hosted links, Clang's reported library roots and the linker's
default-script search roots are inventoried too. If those roots cannot be
established, or the request uses an explicit target whose sysroot/emulation is
not yet inventoried, Cyna links normally but skips native-artifact and
whole-build cache reuse for that request. This Linux path has synthetic
contract coverage but awaits a Linux-host runtime verification. Linker-script
directories prefixed by `=` or `$SYSROOT` also trigger this bypass until the
configured linker sysroot can be resolved authoritatively.

For eligible native-only builds with no custom library search paths or libraries, the
completed native artifact is also cached under
`<project>/.cyna-cache/builds`. Its manifest records every loaded source file,
native source, and linker script. The current resolved loader graph and semantic
checks precede restoration. C/assembly sources, bundled runtime/std dependencies,
leak-check builds, and freestanding outputs are not admitted to this whole-build
shortcut. The implicit prelude normally excludes a public hosted program.

Cache entries use a single checksummed publication containing metadata and the
complete artifact set. Executable modes survive restoration into an absent
output directory; static libraries retain their required `.cyna-link.toml`
sidecar. ELF/bin/hex derivatives are regenerated by the command. LLVM/module
metadata and bytes are published together, and concurrent writers use exclusive
temporary files plus atomic replacement rather than a fixed `.tmp` name.
Corrupt or incomplete entries are misses, not successful partial restores.

`cyna version --verbose` reports the compiler build identity separately from
the public release. That identity covers compiler/runtime/package source, build
configuration, target, Zig version, and the resolved zig-libs source. Runtime
archive contents also participate in native link keys. Normalization N13 is
closed for the shipped aarch64-macOS distribution; the macOS evidence is not
a claim of verified Linux-host behavior or Linux distribution support.

Native-only builds partition the loaded graph into independently cached LLVM
modules. Cache misses are lowered and emitted in parallel with a bounded
worker count, and the resulting LLVM objects are compiled through bounded
child-process workers. Results remain ordered for linking and diagnostics. The
default parallelism follows the host CPU count and is capped to avoid excessive
memory use; `--jobs <count>` provides an explicit limit.
Text inspection stages and object-only output continue to use the whole-program
pipeline so their output and diagnostics remain unchanged.

Modules declaring generic functions, owners, methods, or impls conservatively
include the whole loaded graph in their module-cache key. Their emitted
instantiations depend on importer use sites, not just their own imports. Other
modules retain dependency-closure cache keys.

Build planning keeps the loader graph separate from cache storage. Each loaded
module is represented by its name, canonical source path, source contents, and
declared imports; that graph is included in cache fingerprints and drives
per-module artifact scheduling.

## Project Layout

The conventional project shape is:

```text
src/
test/
cyna.toml
```

Typical executable project:

```text
src/main.cy
```

Typical package or library project:

```text
src/lib.cy
```

Current package/project resolution is manifest-first. The compiler resolves
`cyna.toml`, derives the package root, and loads modules from the configured
source root or entry root.

## Manifest Surface

The current manifest is intentionally declarative.

Example:

```toml
name = "hello"
version = "0.1.0"
src = "src"
type = "exe"
entry = "src/main.cy"

[dependencies]
std = { version = "0.1.2" }
util = { path = "../util", version = "0.2.0" }

[build]
target = "native"
cpu = ""
opt = "debug"
emit = []
leak_check = false

[link]
libs = []
search_paths = []
script = ""
entry_symbol = ""

[c]
sources = []
include_paths = []
flags = []

[asm]
sources = []
include_paths = []
flags = []
```

Current root keys:

- `name`
- `version`
- `src`
- `type`
- `entry`

Current `[dependencies]` forms:

- `dep = "../local/path"`
- `dep = { path = "../local/path", version = "..." }`
- `dep = { version = "..." }`
- `dep = { registry = "...", version = "..." }`
- `dep = { url = "...", version = "..." }`

Current `[build]` keys:

- `target`
- `cpu`
- `opt`
- `emit`
- `leak_check`

`leak_check = true` links executable targets with the Cyna runtime allocation
leak-check hook. On hosted targets, set `CYNA_LEAK_DIAGNOSTICS=1` when running
the executable to enable tracked allocation diagnostics; if tracked runtime
allocations remain at process exit, the shutdown check aborts and prints grouped
allocation-site details plus leaked allocation samples.

Current `[link]` keys:

- `libs`
- `search_paths`
- `script`
- `entry_symbol`

Current `[c]` keys:

- `sources`
- `include_paths`
- `flags`

Current `[asm]` keys:

- `sources`
- `include_paths`
- `flags`

Unsupported manifest categories should be rejected clearly rather than ignored.

## Output Kinds

Current output kinds:

- `exe`
- `staticlib`
- `sharedlib`

These are selected with:

```toml
type = "exe"
type = "staticlib"
type = "sharedlib"
```

## Targets

Current supported targets:

- `native`
- `aarch64-none-elf`
- `x86_64-none-elf`
- `riscv64-none-elf`
- `riscv32-none-elf`
- `arm-none-eabi`
- `thumbv7em-none-eabi`

Current notes:

- `build.target` accepts `native` or one of the compiler-supported target triples
- `build.cpu` is forwarded to the toolchain
- `arm-none-eabi` defaults to the ARM1176JZF-S ARMv6 baseline so the runtime's
  pointer-sized atomic reference counts remain lock-free; an explicit
  `build.cpu` overrides it and must provide ARMv6-compatible atomic primitives
- `build.opt` supports `debug` and `release`
- supported targets are compiler-defined, not discovered from external manifest data

## Emit Rules

Current emit support depends on target kind.

Important current rules:

- `--emit-c-header` is supported for current exported C ABI surface generation
- `--emit-asm-include` emits assembler include definitions for
  `export asm const` declarations
- `--emit-obj` emits an object file beside or instead of the linked artifact
- `--emit-elf`, `--emit-bin`, and `--emit-hex` are primarily useful for freestanding executable builds
- freestanding `bin` / `hex` builds currently require both:
  - `[link].script`
  - `[link].entry_symbol`
- `link.script` and `link.entry_symbol` currently support executable outputs only

## Native Interop

The current build model supports explicit native interop:

- companion C sources through `[c]`
- companion assembly sources through `[asm]`
- native library names through `[link].libs`
- native search paths through `[link].search_paths`
- linker script through `[link].script`
- explicit entry symbol through `[link].entry_symbol`

This is enough for current hosted builds, freestanding bring-up, and mixed
C/Cyna/assembly projects without introducing a programmable build DSL.

## Header Emission

Current C header generation is intentionally narrow:

- exported declarations must use `export c fn`
- exported signatures must use strict target-C representations; compiler
  runtime carriers such as `string`, slices, storage, and `result` are rejected
- exposed aggregate types must use `c struct`
- exposed enum-like types must use `c enum` or `flags`
- aliases are accepted only when they remain ABI-safe and C-layout-safe
- generic ABI types are rejected
- ordinary `struct`, `union`, `packed struct`, and non-C-layout aliases are
  not part of the emitted header surface
- `c_str` parameters emit as `const char *`; nested raw-pointer const/volatile
  qualifiers are preserved at their C declarator level

Practical current workflow:

```sh
cyna build examples/c_header_surface.cy --emit-c-header
cyna build examples/c_header_surface.cy --emit-c-header --emit-ll --output build/c_header_surface
```

Current artifact naming with the explicit output-base form:

- `build/c_header_surface`
- `build/c_header_surface.h`
- `build/c_header_surface.ll`

The validated compile-check example is under `examples/c_header_consumer/`.

```sh
cyna build examples/c_header_consumer/api.cy --emit-c-header --output build/c_header_consumer
cc -std=c11 -c examples/c_header_consumer/consumer.c -I build -o build/c_header_consumer_consumer.o
```

This proves the current header output is consumable from ordinary C source.

## Install And Dependencies

`cyna install` now serves two roles:

1. ensure the compiler-owned distribution is installed locally
2. install or verify manifest dependencies and update the lockfile

That means build-oriented project work assumes:

- the host distribution is installed under `~/.cyna/<version>/...`
- bundled `std` is resolved from that distribution
- other dependencies are resolved from installed package roots according to the manifest and lockfile

For installation, the distribution layout, and available targets, see
[toolchain](TOOLCHAIN.md).

## Current Limitations

- `cyna run` is native-only
- non-native and freestanding targets are build-only for now
- `cyna test` runs native test roots on the supported compiler host
- some packaging/distribution naming is still being normalized internally even though the public model is now clearer

## Design Rule

The build system should stay declarative:

- describe what to build
- describe the target and explicit native inputs
- avoid turning manifests into a second programming language

If a need is unusual, external scripts are preferred over growing a programmable build DSL into the manifest surface.
