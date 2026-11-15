# Tooling Tests

This domain protects user-facing commands and editor workflows.

Subareas:

- `cli/`
- `build/`
- `package/`
- `test_command/`
- `fmt/`
- `doc/`
- `lsp/`
- `vscode/`

Current build steps:

```text
zig build test-tooling-fmt
zig build test-tooling-smoke
zig build test-tooling-cli
zig build test-tooling-cli-build
zig build test-tooling-cli-build-project
zig build test-tooling-cli-build-freestanding
zig build test-tooling-cli-build-clean
zig build test-tooling-cli-build-emit
zig build test-tooling-cli-build-emit-stage
zig build test-tooling-cli-build-emit-asm
zig build test-tooling-cli-build-emit-module-ll
zig build test-tooling-cli-build-emit-obj
zig build test-tooling-cli-build-emit-header
zig build test-tooling-cli-help
zig build test-tooling-cli-test-command
zig build test-tooling-check
zig build test-tooling-cli-check
zig build test-tooling-check-smoke
zig build test-tooling-check-extended
zig build test-tooling-check-extended-core
zig build test-tooling-check-extended-core-basic
zig build test-tooling-check-extended-core-hosted-std
zig build test-tooling-check-extended-core-hosted-std-fs
zig build test-tooling-check-extended-core-hosted-std-thread
zig build test-tooling-check-extended-core-hosted-std-thread-accept
zig build test-tooling-check-extended-core-hosted-std-thread-bridge
zig build test-tooling-check-extended-core-hosted-std-thread-raw
zig build test-tooling-check-extended-core-hosted-std-sync
zig build test-tooling-check-extended-core-hosted-std-sync-accept
zig build test-tooling-check-extended-core-hosted-std-sync-bridge
zig build test-tooling-check-extended-core-hosted-std-sync-raw
zig build test-tooling-check-extended-core-prelude
zig build test-tooling-check-extended-core-emit-alias
zig build test-tooling-check-extended-prelude
zig build test-tooling-check-extended-build
zig build test-tooling-check-extended-native-run
zig build test-tooling-check-extended-native-std
zig build test-tooling-check-extended-native-std-fs
zig build test-tooling-check-extended-native-std-process
zig build test-tooling-check-extended-native-std-path-time
zig build test-tooling-check-extended-native-std-thread-sync
zig build test-tooling-check-extended-emit
zig build test-tooling-lsp
zig build test-tooling
```

`test-tooling-smoke` is the quick feedback step. `test-tooling` is the full
aggregate and may run substantially longer because the CLI integration tests
spawn compiler commands.
`test-tooling-cli` is now split into `build`, `help`, and `test-command`
substeps so the broader CLI surface can be profiled and run more selectively.
The `build` lane is further split into `project`, `freestanding`, `clean`, and
`emit` substeps so cross-target work and artifact-emission regressions do not
hide inside the same long loop as ordinary project builds.
The `emit` lane is further split into stage artifacts, asm include output,
module-resolution LLVM emission, object-plus-header output, and ABI-header
surface checks so emission work can be profiled at feature granularity.
Those selective build substeps run in Debug mode by default so they behave like
real edit loops instead of mini release builds.
`test-tooling-check` is the focused loop for `cyna check` command work,
covering manifest-backed project diagnostics and standalone semantic failures.
`test-tooling-cli-check` remains as a compatibility alias.
`test-tooling-check-smoke` is the smallest direct loop for `cyna check`
development.
`test-tooling-check-extended` carries the larger legacy regression bucket that
still exercises broader hosted-std and build-surface interactions after the
core `check command` cases are split out.
The `test-tooling-check-extended-*` steps split that legacy bucket by behavior
cluster so slow paths can be profiled and worked independently.
The `core-*` substeps break the old acceptance/rejection bucket into basic
project diagnostics, hosted `std.*` imports, prelude coverage, and emitted
import/alias checks.
The hosted-std slice is further split into `fs`, `thread`, and `sync` groups
because those checks still carry multiple independent `cyna check` launches.
The `thread` and `sync` groups are further split into acceptance, bridge-import,
and raw-field subsets so the slow remaining regressions can be run in much
smaller loops.
Those split substeps run in Debug mode so the extended regressions remain
usable while editing.
The `native-std-*` substeps further isolate filesystem, process, path/time, and
thread/sync hosted surfaces.
