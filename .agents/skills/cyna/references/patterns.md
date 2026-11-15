# Cyna patterns and pitfalls

These recommendations reflect the Cyna checkout on 2026-10-16. Recheck current
`docs/SPEC.md`, `docs/STATUS.md`, and library signatures for evolving APIs.
Examples are fragments unless they include a complete program.

## Bindings and construction

```cyna
struct Point {
    x: i32;
    y: i32;
}

fn origin(): Point {
    return { x: 0, y: 0 };
}

fn main(): i32 {
    const a: Point = { x: 20, y: 22 };
    const b = Point { x: 1, y: 2 };
    return a.x + a.y + b.x - 1;
}
```

Prefer one useful type spelling: the binding/return type supplies context, or the
constructor supplies inference. Removing the repeated `Point` in
`const a: Point = Point { ... };` is a style simplification. Do not remove
constructor types merely because another type appears somewhere in the context:
optionals, distinct aliases, conversions, generics, and larger expressions need
individual checks. Preserve initializer evaluation order.

- `{ ... }` is keyed construction; fields use `name: value`.
- `[...]` is positional sequence construction; a bare sequence needs context.
- `fn name(args): Return` is Cyna syntax; `-> Return` is not the canonical form.
- Methods have explicit `self`; constructors are ordinary namespace functions,
  such as `Type.init`, when the type provides them.
- Imports are explicit package/module paths. Do not add a `module ...;` line.
- Keep runtime startup in `main` or explicit initialization functions rather than
  effectful top-level initialization.

## Short switch arms

```cyna
enum State { ready; failed; }

fn score(state: State): i32 {
    return switch state {
        .ready => 1;
        .failed => 0;
    };
}
```

The short arm yields the expression as the switch value. In a standalone
`switch`, `.ready => 1;` does not return from the enclosing function. Keep
an explicit arm for each existing variant when that exhaustiveness is useful:
replacing them with `_` would silently cover variants added later. Use a
block arm when the arm needs statements, with `yield value;` for the switch
result or `return value;` to exit the function.

For a catch handler that only supplies a fallback value, use
`source() catch (code) => fallback(code)`. The short form yields the catch
expression's value; use a block with `yield`, `return`, or `throw` when the
handler needs control flow or more than one statement.

For a stable owned field of a live owning local, `const field = owner.inner;`
creates a read-only projected binding without moving `inner`. Prefer it to
`const field = &owner.inner;` when local read-only access suffices. An explicit
borrow remains appropriate for alias access and borrowed parameters. This
projected-binding rule does not extend to indexed elements, alias roots,
temporaries, or checked union payloads.

## Choose ownership and access deliberately

| Need | Typical Cyna shape |
| --- | --- |
| Ordinary data | `struct` value |
| Growable owned sequence | `List<T>` via `list<T>()` |
| Keyed ownership / unique keys | `Map<K, V>` / `Set<T>` via supported constructors |
| Relationship to collection-owned data | ID, index, or handle |
| Reused slots with deletion | Verify `SlotMap<T>` and its key API |
| Compile-time fixed element count | `[N]T` |
| Runtime fixed contiguous owned storage | `[:]T` |
| Potentially empty storage slots | `[;]T` |
| Read-only contiguous range | `[]const T` |
| Mutate elements in a borrowed range | `[]T` |
| Mutate one caller-owned value/container | `&T` / `&List<T>` |
| Read one caller-owned value by borrow | `&const T` |
| Unique heap object / recursive link | `^T`, or `?^T` for an empty link |
| C, hardware, or allocator address | `*T` with a narrow `unchecked` boundary |

Prefer `List<User>` plus `UserId` relationships to a graph of `List<^User>`
objects unless independent identity/lifetime is required. Do not store temporary
`&T` aliases in ordinary owning aggregates or return them from safe APIs.

```cyna
fn sum(values: []const i32): i32 {
    var total: i32 = 0;
    for value in values {
        total = total + value;
    }
    return total;
}

fn zero(values: []i32): void {
    var i: usize = 0;
    while i < values.len() {
        values[i] = 0;
        i = i + 1;
    }
}
```

Use `[]T` for element mutation and `&List<T>` when push/pop/reserve or other
container changes are needed. `List<T>` indexing, iteration, and `view()` are
read-only; indexed assignment, `get_mut`, and `view_mut()` provide explicit
mutation. Do not retain a view across a mutation that may invalidate it.
Const bindings freeze their carriers, not automatically the memory behind
`&T`, `[]T`, or `*T`; their const element/pointee variants restrict that access.

## Copy, handoff, and removal

```cyna
var users = list<i32>();
users.push(1);
var independent = users.clone();
var handed_off = users;
// users is unavailable after the handoff.
handed_off.push(2);
independent.push(3);
```

Assignment of a resource hands off cleanup responsibility; replacement drops the
old value when needed. Ordinary value behavior follows the type. Do not assume
assignment duplicates a resource or translates to a reference-counted alias.

- Use `text.clone()` or `dense.clone()` for independent duplication when the
  type's `Clone` implementation supports it. The old `copy` operator is retired.
- For library resources, use an ordinary API such as `items.clone()` when it
  exists and its constraints are met.
- `take optional_place` extracts the optional and writes `none`. It applies to
  supported writable optional locals, fields, and storage places.
- To keep a displaced named struct field, write
  `box.field = replacement @ const old;` (or `@ var old`). The replacement is
  evaluated first; the old field becomes a new local after a successful write.
  Indexed-place and borrowed-value captures are not supported yet.
- Use `const _ = expression;` to evaluate and discard an unused result. It
  consumes an owned local when that local is handed to the discard.
- Use `items.pop()` for a list's last item and `slots.remove(key)` for a slot map.
  Do not substitute `take items[i]` or invent arbitrary list/map removal methods;
  inspect current library support.
- `drop resource` ends a language resource lifetime early. External handles use
  explicit close/release APIs; dropping an ordinary integer handle is not close.

## Absence, failure, and cleanup

```cyna
enum Status: i32 {
    ok = 0,
    invalid,
}

fn checked_value(valid: bool): i32!Status {
    if not valid {
        throw Status.invalid;
    }
    return 42;
}

fn compute(): i32!Status {
    const value = try checked_value(true);
    return value;
}
```

`T!E` is a function return form, not a storable result type. `try` propagates
the typed error from one return into the caller; it does not imply arbitrary
error conversion. Use `?T` and `none` for absence without an error reason;
narrow with `if maybe { ... }` when the original name is clearest, or
`if maybe is value { ... }` to name the payload separately. Use
`if maybe is none { return; }` to guard absence and narrow the original name
for following statements in the same block. `not` negates Boolean values;
prefix `!` is not a negation operator.
The narrowed payload name is immutable even when the optional was `var`.

```cyna
fn main(): i32 {
    const value: i32 = compute() catch (code) {
        yield switch code {
            .invalid => 0;
            .ok => 0;
        };
    };
    return value;
}
```

The catch body is an ordinary block. It can inspect the error code, `yield` a
replacement value, `throw` again, or return from the enclosing function.
Use `catch (code, failure)` when diagnostics are needed. The `failure` binding
exists only inside that catch block. Check `failure.available` before relying
on its origin, message, or propagation sites; hosted builds record them when
storage is available, while freestanding builds use code-only defaults. The
message and file accessors produce owned strings. Do not store or pass the
failure view, and do not write `Task<T!E>`: task result transport is inferred.

For an external handle, pair the real API's successful acquisition with
`defer close(handle);` in the owning scope. Deferred statements run in reverse
order. Inspect ownership before handing the handle elsewhere; do not both hand
off cleanup and retain a deferred close. Use the actual library's error type and
signatures rather than assuming an `open`/`close` pair exists.

## Containers, conversions, and boundaries

```cyna
const fixed: [3]i32 = [1, 2, 3];
var dense: [:]i32 = [1, 2, 3];
var sparse: [;]i32 = { 3: 42, 10: 99 };
var values = list_from<i32>([:]i32 [1, 2, 3]);
```

`[:]T` owns runtime-sized dense storage; `push` grows its capacity when needed.
It does not have every `List<T>` operation. Sparse slots may be empty. A slice
borrows storage without allocation or ownership transfer.
Use `.len()` for sequence APIs; confirm the concrete type before copying an
older example that uses `.len`.

- `as` is a checked value conversion that traps on failure; `as?` returns an
  optional. `as!` reinterprets exact bits under its width/type rules; it is not a
  general unchecked conversion.
- Arithmetic overflow traps. Use `+%`, `-%`, or `*%` only when wrapping is intended.
- Prefer `extern c("symbol") fn ...` and `export c("symbol") fn ...`, `c_*`
  scalars, and `c struct` / `c union` / `c enum` at public C ABI boundaries.
- Keep Cyna strings, slices, owned pointers, containers, and results behind a
  C-compatible wrapper. Raw pointers do not imply ownership transfer.
- `c_str` is a borrowed, non-null terminated parameter view. Static NUL-free
  string literals can adapt; dynamic strings require a scoped explicit adapter.
  Use the appropriate raw pointer type for nullable, stored, or returned C strings.
- Keep raw dereferences and C union reads in narrow `unchecked` regions. Do not
  use `unchecked` as a general response to a borrow or ownership diagnostic.
- In `unchecked`, `p + n` offsets a typed raw pointer by `n` pointee elements,
  not bytes. Direct `p[n]` syntax is still unsupported.

### C ABI adapters

Match the foreign declaration's C types exactly. Use `c_int`, `c_size_t`,
`c_float`, and the other `c_*` types for direct callable scalars; use fixed-width
or semantic Cyna types in ordinary code. A C-layout record must be declared
`c struct` (or `c union` / `c enum` as appropriate). An ordinary `struct` does
not acquire C layout from its fields, even if they are `c_*` scalars. Function
attributes such as `@abi("c")` and `@link.export` describe the callable
declaration, not the layout of a struct. Prefer the canonical `extern c` and
`export c` spellings for plain declarations.

Use the foreign C types in the `extern c` signature and put conversion in an
ordinary Cyna wrapper. For exports, put the application behavior in an ordinary
Cyna function and make the `export c` function an adapter that converts both
directions. Ordinary Cyna code calls the import wrapper or the underlying Cyna
implementation, never the raw extern or exported entry point. Document pointer
lifetime, ownership, nullability, and conversion
failure behavior at each boundary; `as` may trap when a value does not fit.
This complete example
shows both directions; `host_scale` must be supplied by a linked C library:

```cyna
c struct CPoint {
    x: c_int;
    y: c_int;
}

struct Point {
    x: i32;
    y: i32;
}

fn sum_native(point: Point): i32 {
    return point.x + point.y;
}

export c("point_sum") fn point_sum(raw: CPoint): c_int {
    const point: Point = { x: raw.x as i32, y: raw.y as i32 };
    return sum_native(point) as c_int;
}

extern c("host_scale") fn host_scale(value: c_int): c_int;

fn scale(value: i32): i32 {
    return host_scale(value as c_int) as i32;
}

fn main(): i32 {
    return sum_native(Point { x: 1, y: 2 });
}
```

`as` is checked and can trap when the value does not fit the destination type;
the example is suitable only when the API contract bounds these values. For
untrusted or target-dependent ranges, use `as?` and map failure to an explicit
C status/out-parameter convention. Convert native `result` to status plus out
parameter, slices to pointer plus `c_size_t` length, and ordinary structs to
`c struct` field by field. Never expose `result`, `string`, slices, containers,
or owned pointers directly in a public C signature. A raw pointer conveys an
address, not ownership; document and implement any transfer explicitly. For
`c_str`, static NUL-free literals can adapt, while dynamic strings need a
scoped adapter that keeps terminated storage alive through the call.

## Generics, concurrency, and implementation boundaries

Generics are monomorphized and protocols are explicit static capabilities. Do
not invent runtime protocol objects, inheritance, specialization, or implicit
cleanup hooks. Check declared bounds and actual impl signatures for generic APIs.

Prefer stable hosted thread/synchronization APIs for ordinary work. `Thread`
join is status-only. Experimental `Task<R>`/`TaskGroup` APIs have distinct result
and settlement contracts; read `docs/STATUS.md`, the current thread library,
and concurrency tests before suggesting them. Do not assume a task API is
verified for every ownership/control-flow shape merely because it is exported.

## Current boundaries

Direct `panic(message);` and literal `assert(false);` statements are terminal
when checking a function's return paths. User-defined wrappers do not acquire
a never-returning type. For other open or deferred capabilities, check
the daydream `projects/cyna/docs/investigations/LANGUAGE_GAPS.md` ledger, when
available, and verify against the compiler version in use.

## Verification examples

```sh
cyna check path/to/main.cy
cyna test path/to/project
cyna run path/to/main.cy
```

Inline tests use `test "name" { ... }` and builtin `assert(...)`. For test helper
APIs, inspect `packages/std/src/std_testing.cy`; helpers return typed results and
can use `try`. Check `docs/BUILD.md` and the current test examples for project
test discovery and target support.
Do not claim a fragment was checked as a complete program. If library examples
or design notes disagree with the current compiler, preserve a minimal reproducer
and explain the specific limitation.
