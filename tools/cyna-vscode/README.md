# Cyna VS Code Extension

Initial VS Code language support for Cyna.

## Features

- `.cy` file association
- TextMate syntax highlighting for current Cyna syntax
- Compiler-backed diagnostics on open and save
- Go-to definition for same-file symbols plus imported module namespaces and selected imported public declarations
- Hover for same-file declarations, simple inferred local types, imported module namespaces, and selected imported public declarations
- Symbol completion for visible names, imported module namespaces, selected imported public declarations, and core language keywords
- Same-file document highlights for symbol occurrences in scope
- Same-file find references
- Same-file rename for symbols tracked by the document index
- Document symbols for the outline view
- Line comments with `//`
- Bracket and quote auto-closing
- Basic folding markers with `// region` and `// endregion`

Diagnostics shell out to the Cyna compiler. By default the extension runs:

```sh
cyna check <file>
```

You can override this with `cyna.compiler.command` and
`cyna.compiler.args`. Use `${file}` inside args for the current document path.
If your command depends on a specific repo root, set `cyna.compiler.cwd` too.

For example, to use the local repo build in a workspace, configure:

```json
{
  "cyna.compiler.command": "zig",
  "cyna.compiler.args": ["build", "run", "--", "check", "${file}"],
  "cyna.compiler.cwd": "${workspaceFolder}"
}
```

`cyna.compiler.cwd` supports absolute paths, workspace-relative paths,
`${workspaceFolder}`, `${file}`, and `${fileDirname}`.

The current navigation is intentionally lightweight. Cross-file support follows
the current import model:

- `import std;` contributes the module namespace binding `std`
- `import foo.bar;` contributes the module namespace binding `bar`
- `import foo.bar as baz;` contributes the namespace binding `baz`
- `import { name } from foo.bar;` contributes the selected exported declaration
- `import { name as local } from foo.bar;` contributes the selected declaration under `local`

Source files do not declare `module ...;`; the normalized file path is the
module path. Redundant self-aliases such as `import foo.bar as bar;` are meant
to be rejected by the compiler.

Non-builtin imports are resolved from the package root used by the current
workspace, typically `src/` for a package directory.

Highlights, references, rename, richer type inference, and deeper semantic
hover are still same-file only and should move to a future language server.

## Local Development

1. Open this folder in VS Code:

   ```sh
   code tools/cyna-vscode
   ```

2. Press `F5` to launch an Extension Development Host.
3. Open `samples/sample.cy` in the Extension Development Host.

## Packaging

Install `vsce` if needed:

```sh
npm install -g @vscode/vsce
```

Package the extension:

```sh
cd tools/cyna-vscode
vsce package
```
