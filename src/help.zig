pub const usage =
    \\usage: cyna <command> [path] [options]
    \\
    \\commands:
    \\  fmt      format sources and simplify redundant construction types [--check]
    \\  check    run semantic analysis
    \\  build    compile a file or project; optional emits: --emit-tok --emit-ast --emit-sir --emit-lir --emit-ll --emit-c-header --emit-asm-include --emit-obj --emit-elf --emit-bin --emit-hex [--verbose] [--timings] [--jobs <count>] --output <path>
    \\  install  prepare the Cyna distribution and resolve local manifest dependencies
    \\  run      build and execute a file or project
    \\  test     discover and run independent *.test.cy test roots
    \\  package  build, pack, and publish packages
    \\  clean    remove local build outputs for a file or project
    \\  lsp      run the Cyna language server over stdio
    \\  version  print compiler version
    \\
;

pub const build_usage =
    \\usage: cyna build [path] [options]
    \\
    \\options:
    \\  --build <name>          use a named manifest build config
    \\  --output <path>         write the main artifact to path
    \\  --emit-tok              emit lexer tokens
    \\  --emit-ast              emit an AST declaration summary
    \\  --emit-sir              emit semantic IR text
    \\  --emit-lir              emit lowered IR text
    \\  --emit-ll, --emit-llvm  emit LLVM IR
    \\  --emit-c-header         emit a C header for exported C declarations
    \\  --emit-asm-include      emit assembler include definitions
    \\  --emit-obj              emit an object file
    \\  --emit-elf              emit an ELF image
    \\  --emit-bin              emit a raw binary image
    \\  --emit-hex              emit an Intel HEX image
    \\  --verbose               print detailed build progress and external tool commands
    \\  --jobs <count>          compile modules and LLVM objects with up to count workers
    \\  --timings               print structured compilation phase timings
    \\
    \\build prints phase and per-object progress by default; long clang, link, and
    \\archive invocations report elapsed time every 10 seconds.
    \\
;

pub const run_usage =
    \\usage: cyna run [path] [-- args...]
    \\
    \\Build and execute a file or project. Arguments after -- are passed to the program.
    \\
;

pub const test_usage =
    \\usage: cyna test [path] [options]
    \\
    \\options:
    \\  --filter <text>  run only tests whose file, module, or name contains text
    \\  --jobs <count>   compile independent test roots with up to count workers
    \\  --timings        print compilation phase and cache statistics
    \\
;

pub const check_usage =
    \\usage: cyna check [path] [options]
    \\
    \\options:
    \\  --build <name>                 use a named manifest build config
    \\  --diagnostic-format <format>   render diagnostics as human (default) or compact
    \\
;

pub const package_usage =
    \\usage: cyna package <build|pack|publish> [path]
    \\
;

pub const fmt_usage =
    \\usage: cyna fmt [paths...] [--check]
    \\
    \\Format .cy files or directories recursively (default: current directory).
    \\Normalize indentation, spacing, and directly repeated struct construction types.
    \\Hidden directories, build, zig-out, dist, node_modules, and symlink entries are skipped.
    \\Print changed file paths. --check reports changes without writing and exits 1.
    \\
;
