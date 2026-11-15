---
name: cyna
description: Write, review, and refactor Cyna (.cy) application code using idiomatic syntax, ownership, standard library patterns, and current toolchain support. Use for Cyna language advice and language consumers, not compiler implementation.
---

# Idiomatic Cyna

Help the user produce clear, supported Cyna code. Distinguish language requirements,
recommended style, and implementation limitations. Preserve behavior when improving
style; a shorter spelling is not sufficient evidence of an equivalent program.

## Establish the available language

Find the Cyna checkout from the current workspace, a sibling `cyna` directory, or
this skill's location (`../../..` from its directory in a Cyna checkout). Resolve
symlinks before using the last route. Treat paths below as relative to that
checkout, not to the user's application. If no checkout is available, use the
bundled patterns, inspect the installed compiler's help/version and available
library sources, and state any support you cannot verify.

Read only the documents relevant to the task:

- `docs/SPEC.md`: authority for syntax and language rules. Search the relevant
  section instead of loading the entire specification.
- `docs/STATUS.md`: implemented boundaries and known gaps. Check it when a
  request may expose a missing capability.
- `docs/CHEATSHEET.md`, `docs/GUIDE.md`: conventions and modeling advice.
- `docs/BUILD.md`: commands, manifests, and dependencies when needed.
- `packages/std/src/`: actual library signatures and available methods.
- `examples/`, `test/language/`, `test/ownership/`: executable evidence for
  unfamiliar or subtle constructs.

The current spec wins over sketches and stale examples. Design decisions marked
accepted but unimplemented are direction, not available features. If the compiler
rejects a spec-supported pattern, report the discrepancy and use a supported
spelling; do not silently redefine the language or widen `unchecked` to hide it.
Check the compiler version/source used by the application when it differs from
this checkout.

If the central daydream engineering repository is available, report Cyna
language, compiler, standard library, runtime, and toolchain gaps in its
`projects/cyna/docs/investigations/LANGUAGE_GAPS.md`, including gaps found while
working in Cava, Cory, Lightcept, or another downstream project. Do not add
new Cyna gap entries to downstream historical logs. Record the affected site,
compiler revision and target, minimal reproduction, expected and actual
behavior, complete diagnostic or runtime output, workaround, and relevant
contract or test links. Distinguish a confirmed compiler defect from a proposal
or project-specific mismatch. Before carrying forward an older report, rerun
its reproduction with the current compiler where practical and label historical
evidence separately from current status. Do not treat a ledger entry as approval
to change language semantics or expand the user's task.
When an older report is verified fixed, invalid, or superseded, keep its stable
ID and a short disposition in the ledger and archive the detailed history in
`projects/cyna/docs/archive/` in daydream. Preserve the original evidence and link
both directions. Do not move an unverified report out of the active ledger.

When a Cyna application adopts a language fix or feature, check affected Cava,
Cory, and Lightcept usage when those sibling checkouts are available. Update
downstream code or references only where the change applies, and verify against
the compiler each project actually uses. A pinned project adopts the fix only
after its published compiler revision and relevant tests are updated; preserve
unrelated work in active checkouts. Keep project-specific implementation tasks
in their own project backlogs.

## Defaults that should shape the code

- Prefer values, containers of values, and IDs/indexes for relationships. Use
  `^T` when unique heap identity or recursion requires it, and `*T` at raw/foreign
  boundaries. Choose types by ownership and access intent.
- Prefer `const` when the required access permits it. Use `var` when rebinding
  or ordinary value/container mutation requires it. Const on a pointer or slice
  carrier does not make its referent const; inspect the pointee/element type.
- Use explicit types at public boundaries; infer obvious locals. With a known
  expected struct type, prefer `const a: A = { field: value };` over
  `const a: A = A { field: value };`. Keep `const a = A { field: value };`
  when inference needs the constructor type. These are preferences, not syntax
  restrictions; do not remove an explicit type when it changes contextual
  conversions, overload/generic resolution, or the value's constructed type.
- Match the repository's layout; default to four spaces, braces on the same
  line, snake_case functions/bindings, and PascalCase types/protocols. Keep
  comments and field evaluation order when normalizing code.
- Prefer `pattern => expression;` for a switch arm that only yields a value.
  Use `return switch value { ... };` when that value is the function result;
  a short arm in a standalone switch does not return from the function. Keep
  explicit variant arms when the existing switch is exhaustive, so a new
  variant still requires review. Use `_` only when it is an intentional
  catch-all for current and future variants.
- Prefer `catch (code) => expression` when recovery only yields one value.
  Keep a block for statements, `return`, or `throw`. The short form yields the
  catch expression's value; it does not return from the enclosing function.
- For read-only access to an owned field of a live local unpacked struct,
  prefer `const field = owner.field;` over an unnecessary `&owner.field` borrow.
  This is a projected binding, not an ownership transfer. Keep `&` when an
  alias is needed, such as a borrowed parameter; do not apply this rule to
  indexed elements, alias roots, temporaries, or checked payloads.
- Use `T!E` only as a function return form for typed failures; handle it with
  `try` or `catch`. Use `?T` for absence and explicit cleanup APIs with `defer`
  for external handles. Do not store the catch-scoped failure view or spell a
  task result type as `Task<T!E>`; task result transport is inferred.
- Spell Boolean negation `not`. Prefix `!` is no longer a negation operator;
  keep `!` in `T!E` return types and `as!` casts. Test optional absence with
  `is none`; an early `if value is none { return; }` guard narrows `value` in
  the following scope.
- Prefer a small supported library operation over an invented convenience API.
  Do not port Rust, Zig, C++, or TypeScript syntax by analogy.
- For C interop, keep `extern c` declarations in the foreign API's C types.
  Prefer ordinary Cyna functions with semantic Cyna types as the application
  interface. An import wrapper calls the extern function and explicitly converts
  arguments, results, and ownership at that edge. In the other direction, a thin
  `export c` wrapper converts inputs, calls the ordinary Cyna implementation,
  and converts its result. Ordinary Cyna callers use these Cyna interfaces:
  they do not call the raw extern or exported entry point directly. Keep C ABI
  types out of ordinary application APIs unless their C meaning is itself the
  intended contract.

For concrete examples, pitfalls, and common modeling choices, read
[references/patterns.md](references/patterns.md) when writing or reviewing code.
It is a focused guide, not a substitute for the current specification.

## Write, review, and verify

When reviewing, explain the most useful changes with a small before/after and
why they help. Separate correctness/ownership issues from optional style advice.
Apply only changes authorized by the user's task; advice does not imply a broad
rewrite of the application.

Use `cyna check <file-or-project>` for parser and semantic validation, then the
relevant `cyna test` or `cyna run` command when behavior needs verification.
Inspect project configuration before choosing a build target. A successful
`check` is not evidence of runtime or link correctness.

Confirm formatter availability in the actual binary before recommending or
running `cyna fmt`. If available, use the single command for formatting and its
supported safe syntax normalizations; use `--check` for a read-only check. Do not
invent a separate lint command or claim planned flags exist. Until it is
available, make scoped source edits and validate them with the compiler.

When delivering code or advice, state what was validated and any concrete
support limitation. Keep new examples compileable or label incomplete fragments.
