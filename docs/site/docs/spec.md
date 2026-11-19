---
outline: [1, 4]
---

# Cyna Language Spec

Version: 0.5.0

Cyna is a C-compatible systems programming language with modern syntax,
explicit memory, structured cleanup, safer defaults, and a practical C-like
semantics model.

The core identity is:

> Cyna syntax can be modern. Cyna semantics should stay close to C.

Cyna is not C source compatible. It is intended to be C ABI compatible and to
fit into existing C projects with low ceremony.

## How to Read This Spec

This spec is organized for a normal language user first and a language
implementer second. A reader should be able to move from basic program shape,
to data modeling, to ownership and storage behavior, and only then into lower-
level escape hatches and ecosystem details.

The document is organized in five parts:

1. **Foundations:** source files, modules, declarations, function syntax, and
   primitive types.
2. **Data modeling:** structs, enums, unions, error values, and how named
   program types are formed.
3. **Values, ownership, and storage:** pointer forms, aliases, safety
   boundaries, strings, containers, assignment, copying, ownership handoff,
   cleanup, and allocator behavior.
4. **Expressions and execution:** control flow, integer rules, and generics.
5. **Interoperability and ecosystem:** C interop, standard library shape,
   tooling, examples, and language scope.

The parts are real document levels:

1. part = `#`
2. chapter = `##`
3. subsection = `###`

Quick reader map:

1. readers who need common syntax first should start with `docs/CHEATSHEET.md`
2. language users usually want Parts I-IV in order
3. library and runtime implementers should pay special attention to chapters
   15-19 and 23-25
4. ownership questions should start with chapters 11 and 13, then read
   chapters 15-18 in order
5. construction and container surface questions usually start in chapter 15
6. assignment, parameter passing, and ownership handoff questions are
   centralized in chapter 17

Section 17 is the normative assignment model. When another section says that a
type is a plain value, owned value, alias, or view, assignment and parameter
passing follow the rules in section 17.

`docs/SEMANTICS.md` is the companion document for checker-oriented meaning.
This spec defines the language surface and its normative behavior. The
semantics document explains the abstract model used to make that behavior
precise and auditable.

## Implementation Status and Audit Convention

This document is both the normative language specification and the description
of the v1 surface currently intended for users. To keep those roles honest,
feature claims use these categories:

| Status | Meaning |
| --- | --- |
| **Implemented** | Exercised by the compiler/runtime and covered by repository tests or runnable examples. |
| **Implemented, constrained** | Available, but only in the explicitly documented subset or on the documented targets. |
| **Reserved / planned** | Recorded as a direction or module name; users must not rely on it yet. |
| **Rejected / outside v1** | Deliberately not part of this language version. |

Unqualified normative examples in Parts I-IV describe the implemented surface
unless the surrounding text explicitly says `planned`, `reserved`, `future`,
`deferred`, or `outside v1`. Standard-library material in Part V is more
fine-grained: the module-availability table and the status notes in each module
section control what is currently shipped. A design intention is not evidence
of implementation.

The audit baseline is the compiler, bundled `packages/std`, runtime, tests, and
examples in this repository. Distribution packaging, editor tooling, and
release availability may lag the language implementation; those limitations
are called out rather than implied away.

Audit index by chapter:

| Chapters | Current status | Audit result |
| --- | --- | --- |
| 1-6 | Implemented, constrained | Core source, declaration, function, and primitive surfaces match the parser/sema contract. |
| 7-10 | Implemented, constrained | Data modeling is shipped; packed layout, C layout, and union forms retain their documented restrictions. |
| 11-14 | Implemented, constrained | Ownership, raw/volatile pointers, unchecked code, and strings are implemented within the documented safety subset. |
| 15-19 | Implemented, constrained | Storage, views, assignment, cleanup, and allocator contexts are shipped; selected removal and allocator edge cases remain limited. |
| 20-24 | Implemented, constrained | Expressions, generics, protocols, C ABI, and inline assembly are available in the documented subset. |
| 25 | Implemented, constrained | Shipped std modules and target restrictions are listed explicitly; `std.string` and `std.c` remain reserved. |
| 26-27 | Implemented / summary | The example uses the shipped hosted filesystem surface; the summary is limited to the v1 surface above. |

This index is a navigation aid, not a substitute for the rules in each
chapter. Where a chapter describes a future API or a rejected form, that local
status controls the claim.

# Part I. Foundations

## 1. Design Goals

1. Keep C's control, speed, predictable machine mapping, explicit allocation,
   value-oriented data, and ABI usefulness.
2. Replace C headers with modules.
3. Replace the preprocessor with constants, imports, generics, inline
   functions, and compile-time facilities.
4. Make dangerous operations visible through `unchecked`.
5. Avoid undocumented hidden allocation, user-defined hidden destructors,
   exceptions, garbage collection, and surprise dynamic dispatch.
6. Avoid user-written ownership and lifetime annotations while still preventing
   common memory bugs in normal code.
7. Keep the language procedural, data-oriented, and readable to C programmers.

## 2. Source Model

The language name is:

```text
Cyna
```

The preferred file extension is:

```text
.cy
```

The core tool surface is:

```text
cyna build
cyna run
cyna test
cyna check
cyna fmt
cyna clean
cyna install
cyna package
cyna lsp
cyna version
```

### 2.1 Identifiers

Normal identifiers use ASCII letters, digits, and `_`, and cannot start with a
digit. Keywords are reserved.

Backtick identifiers escape keywords and generated or foreign names that do not
fit the normal identifier grammar. The semantic identifier is the text inside
the backticks:

```cyna
packed struct Fmt {
    pub `protocol`: u2;
}

fn read_protocol(fmt: Fmt): u2 {
    return fmt.`protocol`;
}
```

Use escaped identifiers sparingly. They currently accept ASCII letters, digits,
`_`, and `$`; normal Cyna source should still follow the naming conventions in
section 25.3.

## 3. Modules

Cyna uses modules instead of header files.

```cyna
import std.io;
import std.fs;
```

Module paths are Python-like and package-rooted. A file path maps to a module
path relative to the package entry directory:

```text
src/main.cy        -> main
src/math/vector.cy -> math.vector
src/math.cy        -> math
```

Source files do not declare module names explicitly. The normalized `.cy`
path is the module path.

Canonical import forms:

```cyna
import std.io;
import std.io as console_io;

import { FsError, read_file } from std.fs;
import { dirname as parent_dir, join as join_paths } from std.path;
```

Meaning:

```text
import module.path;                    // bind module basename in local scope
import module.path as local_name;      // bind module under an explicit local alias
import { name } from module.path;      // import selected exported declaration
import { name as local_name } from module.path;
```

Import behavior:

1. `import module.path;` imports the module namespace, not all of its exported
   names into the current scope
2. the default local name is the final path segment
3. `import module.path as local_name;` gives that namespace a different local
   name
4. `import { name } from module.path;` imports a specific exported declaration
   into the current scope
5. `import { name as local_name } from module.path;` imports a specific
   exported declaration under a different local name
6. non-builtin imports resolve from the package root, not from the importing
   file's directory
7. source files do not use a `module ...;` declaration; the normalized file
   path already defines the module path
8. redundant self-aliases such as `import std.io as io;` when the default name
   is already `io`, or `import { read_file as read_file } ...`, are rejected
9. each function call resolves to a concrete declaration in a concrete module;
   later same-named declarations in other modules do not change that binding

Examples:

```cyna
import hal.console;

pub fn panic(): void {
    console.print_panic();
}
```

```cyna
import hal.console as debug_console;

pub fn panic(): void {
    debug_console.print_panic();
}
```

```cyna
import { print_panic } from hal.console;

pub fn panic(): void {
    print_panic();
}
```

Exports are explicit:

```cyna
pub fn hash(data: []const u8): u64 {
    ...
}
```

No textual include, include guards, or macro leakage.

### 3.1 Module Execution Model

A Cyna module is a declaration namespace and visibility boundary, not a runtime
object.

Importing a module:

1. makes the imported module namespace and/or selected exported declarations
   available for name resolution
2. does not create a first-class module value
3. does not execute arbitrary top-level code

Name resolution is module-scoped. Two modules may contain private functions
with the same local name, including private `extern c` declarations with
different ABI symbols or arities. Once a call is resolved, it remains bound to
that declaration; it cannot accidentally bind to another same-named declaration
from a different module.

Program execution begins at `main`, not at module import time.

This keeps import behavior side-effect free and avoids hidden initialization
order, import-time allocation, and cycle-sensitive runtime semantics.

Package manifests and toolchain workflow are documented outside the language
spec. This document defines source-level language behavior.

## 4. Declarations

Cyna uses `const`, `var`, type-after-name, and `fn`.

```cyna
const max_users: usize = 1024;
var count: usize = 0;

fn add(a: i32, b: i32): i32 {
    return a + b;
}
```

Local type inference is allowed:

```cyna
const x = 10;
var name = "Cyna";
```

Public APIs should use explicit types.

Local `const` declarations may destructure struct fields, indexed storage, and
tuple positions:

```cyna
const { x, y: vertical } = point;
const { rows: [{ title }] } = document;
const [first, second] = entries;
const (left, right) = pair;
const (name, ({ x }, [head])) = record;
```

`x` binds the field named `x`; `y: vertical` binds the field `y` under the
name `vertical`. Nested braces, brackets, and parentheses compose field,
positional index, and tuple position selections. Bracket and tuple entries
select positions starting at zero. Fields and
elements not named in a pattern remain in the source value; no `..` marker is
needed. A pattern must bind at least one name. A type annotation after the
pattern checks the complete initializer. The initializer is evaluated once.
Dynamic index selection uses an ordinary binding such as
`const selected = entries[index];`. Destructuring is local and `const` only.
A one-position tuple pattern needs a trailing comma: `const (only,) = value;`.

An owned value initializer moves into one owner for the pattern; an owned local
used as that initializer becomes unavailable. A projected initializer retains
its existing owner. Owned resource leaves are read-only projected bindings into
that owner, including nested fields, checked named-union payloads, and indexed
elements. They do not detach resources or take cleanup responsibility.
Borrowed initializers preserve their alias capability and lifetime for admitted
leaves; owned resource leaves through reference parameter roots are currently
rejected by the projected binding rule. The owner cleans up once after its
projected leaves' final uses and defers. The ordinary projected place rules in
§9 apply to each leaf. Indexed patterns require direct storage or tracked slice
views; value-returning indexing hooks cannot supply places.

Use `const _ = expression;` to deliberately discard a value without creating
a binding. The expression is evaluated once. An owned result is destroyed at
the end of that statement; moving an owned local into the discard makes the
local unavailable. The form can be repeated in one scope. It requires `const`
and has no type annotation. An ordinary value expression statement still
requires `void`.

### 4.1 Const

`const` means the binding cannot be changed.

```cyna
const x: i32 = 10;
x = 20; // error
```

For owned values, `const` freezes the binding and prevents creating mutable
aliases from that binding:

```cyna
const users: List<User> = list<User>();
users = list<User>(); // error
users.push(User { name: "A" }); // error: mutating methods need a mutable binding
```

`const` does not change the value's type and does not recursively freeze every
object reachable from it. It restricts access through that binding. Borrowing
the binding or one of its ordinary projections is allowed, but produces a
read-only alias:

```cyna
const user = User { age: 42 };
const whole: &const User = &user;
const age: &const i32 = &user.age;
```

Field, index, and slice projection preserve or reduce the access of their
base; they never turn read-only access into writable access. A field whose
stored value is itself an `&T` retains that alias value's capability—this is a
shallow access rule, not transitive deep constness.

Mutating the pointed-to object is controlled by the operation and receiver type,
not by rebinding the local name. APIs that mutate a caller-owned object should
use an alias pointer such as `&List<T>`, and callers need a mutable binding to
create that alias.

Pointer constness and pointee constness are distinct:

```cyna
const p: *User = get_user();      // p cannot point elsewhere
var q: *const User = get_user();  // q can change, pointee is read-only
```

### 4.2 Top-Level Initialization Policy

Functions, types, structs, enums, and unions may be declared at top level.
Every ordinary top-level `const` or `var` binding requires an initializer.
The initializer must be statically constructible, and the binding must have a
declarative, copy-valued type. Resource-valued globals are not supported.
These rules apply equally to `const` and `var`; `var` permits subsequent
mutation but does not permit runtime initialization. An `extern c` global is
a declaration of storage supplied by C and has a type but no Cyna initializer.

A statically constructible initializer may contain literals, enum or union
cases, supported unary and binary operations, fixed arrays, tuples, and struct
literals composed of such expressions. It may reference an earlier `const` or
`var` global in the same module. A reference to a global in another module
requires that global to be public and non-`extern`. The reference uses the
global's declared initial value, even if it is a `var` that later changes.
The new binding receives its own copy of that value. These dependencies cannot
form a cycle, and import order does not change their values.

An initializer cannot call a function, allocate or build a resource, perform
fallible setup, or depend on module load order. Runtime setup belongs in an
explicit function. Importing a module does not run its declarations.

Use declarative top-level constants for static configuration:

```cyna
const max_users: usize = 1024;
const default_name: string = "guest";
const maximum_channel_magnitude: f64 = 65536.0;
```

Runtime setup belongs in an explicit function:

```cyna
fn main(): i32 {
    const config = load_config();
    const cache = build_cache(config);
    return run(config, cache);
}
```

This policy preserves the module model above:

1. modules are compile-time declaration scopes
2. imports are side-effect free
3. startup work is explicit in `main` or explicit init functions

### 4.3 Type Definitions

Use `type` for aliases and distinct nominal types. Runtime sum types use
`union`.

```cyna
type Bytes = []u8;          // alias
type UserId = distinct u64; // distinct type
```

Rule:

```text
type Name = ExistingType;          alias, no new nominal type
type Name = distinct ExistingType; new nominal type
```

Distinct types do not implicitly mix with their underlying type or with each
other.

### 4.4 Visibility

Declarations are private by default. Use `pub` to export from a module or type
namespace.

```cyna
pub fn open(path: string): File!FsStatus {
    ...
}

fn normalize_path(path: string): string {
    ...
}
```

`pub struct` exposes the type, not its fields. Fields and namespace functions
need their own `pub`:

```cyna
pub struct User {
    pub name: string;
    age: i32;

    pub fn birthday(self: &User): void {
        self.age = self.age + 1;
    }

    fn normalize(self: &User): void {
        ...
    }
}
```

## 5. Function Syntax

Canonical syntax:

```cyna
fn name(arg: Type): Return {
    ...
}
```

Examples:

```cyna
fn square(x: i32): i32 {
    return x * x;
}

pub fn parse_i32(text: string): i32!ParseStatus {
    ...
}
```

Syntax note: earlier sketches also used `fn name(...) -> Return`. This spec
uses `: Return`.

## 6. Primitive Types

Normal Cyna code uses fixed-width and semantic primitive types:

```cyna
i1   i2   ... i64
u1   u2   ... u64
isize
usize
f32  f64
bool
char
void
```

`iN` and `uN` are signed and unsigned fixed-width integer types with exactly
`N` value bits, where `N` is any integer from 1 through 64. Wider types such as
`i128` and `u128` are not supported. `u1` is a numeric one-bit integer, not
`bool`. The common widths `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, and `u64`
should be preferred in
ordinary code; sub-byte and unusual widths are mainly for packed layouts,
register descriptions, protocols, and generated bindings.

Semantic width and physical storage are separate concepts:

1. the declared integer type defines the value's semantic width and signedness
2. casts, arithmetic, comparisons, overflow behavior, enum representation
   checks, and packed layout all use that semantic width
3. the compiler/backend may use a wider or byte-aligned carrier internally
   when that does not change observable semantics

So `i1` is still a one-bit integer semantically even if a backend chooses to
store it in an 8-bit slot for convenience. Backend widening is allowed as an
implementation detail; it must not change integer semantics or packed layout.

`char` is a Unicode scalar value. Its valid values are `U+0000` through
`U+10FFFF`, excluding surrogate code points `U+D800` through `U+DFFF`.
`char` is distinct from integer types even though its value can be represented
as a `u32`.

C ABI types exist separately and should be used at C boundaries:

```cyna
c_char
c_schar
c_uchar
c_short
c_ushort
c_int
c_uint
c_long
c_ulong
c_llong
c_ullong
c_ptrdiff_t
c_size_t
c_void
```

Example:

```cyna
var x: i32 = 10;   // exactly 32-bit
var y: c_int = 10; // target C int
```

# Part II. Data Modeling

## 7. Structs

### 7.1 Layout Forms

This section defines struct data layout together with the ordinary struct forms
users work with day to day.

Normal structs use type-after-field syntax:

```cyna
struct Vec2 {
    x: f32;
    y: f32;
}
```

`struct` means normal Cyna layout. The compiler may choose an efficient internal
layout unless a layout form is requested.

C-compatible structs use `c struct`:

```cyna
c struct CPoint {
    x: c_int;
    y: c_int;
}
```

Packed structs use `packed struct`:

```cyna
packed struct PacketHeader {
    kind: u8;
    flags: u8;
    len: u16;
}
```

`packed struct` has deterministic declaration-order layout with no padding
between fields. It is useful for embedded protocols, wire formats, device
register blocks, flash records, and other byte-exact data.

Rules:

1. field order is exactly declaration order
2. field alignment may be lower than the field type's natural alignment
3. total size is the sum of field storage sizes, rounded only by an explicit
   requested alignment if one exists
4. direct field reads and writes are safe; the compiler emits unaligned access
   code when required
5. taking `&field` of a possibly unaligned packed field is rejected in safe code
   and packed fields never become safe aliasable places through nesting either
6. packed structs should contain only integer fields, enum fields with an
   explicit integer representation, and nested packed structs that recursively
   follow the same rule
7. floats, `bool`, pointers, fixed arrays, normal structs, `c struct`, unions,
   and types with hidden storage or cleanup responsibility are not allowed as
   packed fields in v1; use `u1` or `i1` rather than `bool` for single-bit
   fields

Struct bodies may contain nested `struct` and `packed struct` declarations.
Nested type references use qualified type syntax:

```cyna
struct Uart0 {
    pub packed struct Txdata {
        data: u8;
        reserved0: u23;
        full: u1;
    }

    txdata: Reg<Uart0.Txdata, u32>;
}
```

Nested struct declarations are type namespace convenience. A nested type
declaration does not add a runtime field by itself.

Example:

```cyna
fn packet_len(header: PacketHeader): u16 {
    return header.len;
}

fn invalid_packed_field_alias(header: &PacketHeader): &u16 {
    return &header.len; // error: packed field may be unaligned
}
```

The same rule applies through containing structs:

```cyna
struct Outer {
    header: PacketHeader;
}

fn invalid_nested_packed_field_alias(outer: &Outer): &u16 {
    return &outer.header.len; // error: packed fields are never safe alias places
}
```

Packed structs may use exact-bit integer fields for bit-level layouts. This is
the preferred replacement for C bitfields:

```cyna
packed struct StatusReg {
    ready: u1;
    mode: u3;
    error: u4;
}
```

`u1` and `i1` are numeric integer types, not aliases for `bool`. In a normal
non-packed struct, unusual-width integers may still use ABI-friendly storage;
only `packed struct` promises exact bit placement.

For packed layout, field placement is determined by the field's semantic bit
width, not by any widened carrier the backend may use internally. For example,
an `i1` or `u1` packed field occupies one bit in layout even if native codegen
chooses to materialize loads, stores, or temporaries through byte-aligned
storage.

Packed layout does not imply volatile access. Memory-mapped I/O should use a
separate raw-pointer qualifier such as `*volatile T`.

Direction:

1. `packed struct` describes register or wire layout
2. `*volatile T` describes volatile device-memory access semantics
3. `&T` remains part of the safe alias model and should not be extended into
   `&volatile T` in v1

That keeps layout and access semantics separate:

```cyna
packed struct UartRegs {
    dr: u32;
    sr: u32;
}
```

```cyna
fn uart0(): *volatile UartRegs {
    unchecked {
        return 0x4000_1000 as! *volatile UartRegs;
    }
}
```

Volatile access semantics remain a low-level feature. In particular, packed
bitfield writes through MMIO may require read-modify-write behavior and are not
the same thing as ordinary struct field mutation.

Layout forms:

```text
struct        normal Cyna layout
c struct       normal C ABI layout
packed struct byte-exact Cyna layout with no padding
```

### 7.2 Methods and Namespaces

Cyna has no classes and no inheritance.

A `struct` defines both a data layout and a namespace. Functions related to the
type should be defined inside the struct body.

```cyna
struct Buffer {
    data: *u8;
    len: usize;
    cap: usize;

    fn init(data: *u8, cap: usize): Buffer {
        return Buffer {
            data: data,
            len: 0,
            cap: cap,
        };
    }

    fn clear(self: &Buffer): void {
        self.len = 0;
    }

    fn len(self: Buffer): usize {
        return self.len;
    }
}
```

Functions without `self` are namespace functions:

```cyna
var buf = Buffer.init(memory, 4096);
```

Functions with an explicit first parameter named `self` can use dot-call sugar:

```cyna
buf.clear();
const n = buf.len();
```

The dot-call is equivalent to calling the namespaced function:

```cyna
Buffer.clear(&buf);
```

`self` is always explicit in the function signature. It is not implicitly
available:

```cyna
fn clear(self: &Buffer): void {
    self.len = 0;
}
```

Visibility is private by default unless marked `pub`:

```cyna
pub struct String {
    data: *u8;
    len: usize;
    cap: usize;

    pub fn init(alloc: &Allocator): String {
        ...
    }

    pub fn len(self: String): usize {
        return self.len;
    }

    fn grow(self: &String, new_cap: usize): Status {
        ...
    }
}
```

So this is not a class method model. It is a type-owned namespace plus call
syntax sugar. No constructors, destructors, inheritance, or hidden dispatch are
implied.

### 7.3 Initialization

Struct construction is keyed and field-based. The explicit form names the
target type:

```cyna
var user = User {
    name: "Chao",
    age: 30,
};
```

When the expected type is already known, a struct may also use the contextual
keyed form:

```cyna
var user: User = {
    name: "Chao",
    age: 30,
};
```

Every entry in `Type { ... }` or contextual `{ ... }` must name a field:

```cyna
Type { field: value, ... }
```

Braces are for keyed initialization, not positional element construction. For
structs, keys are field names. For sparse storage, maps, or other keyed
containers, keys are expressions checked against the target key/index type.
Arrays, dense storage, lists, and sets use `[...]` forms instead.

All struct fields must be initialized unless they have defaults:

```cyna
struct User {
    name: string;
    age: i32 = 0;
}

var user = User {
    name: "Chao",
};
```

For plain data with public fields, use keyed initialization when the caller can
supply the complete value directly. A type's canonical reusable construction
path should be a namespace function named `init` when it supplies defaults,
validates input, sets up a resource, or hides representation details. `init` is
an ordinary function, so it does not prevent keyed initialization of public
fields. A type that must protect a construction invariant should keep the
relevant fields private.

Use a descriptive namespace function such as `Type.from_bytes` for a distinct
construction route. Keep a module function when it names an operation whose
result happens to be that type, such as `json.parse`, or when it serves as a
clear entry point to a module workflow, such as `process.command`.

For example, a type can offer reusable value and heap construction:

```cyna
struct User {
    name: string;
    age: i32;

    pub fn init(name: string): User {
        return User {
            name: name,
            age: 0,
        };
    }

    pub fn new(name: string): ^User {
        return new User {
            name: name,
            age: 0,
        };
    }
}
```

There are no hidden constructors. `new Type { ... }` creates a `^Type`; use
`Type.new` for a reusable construction path that returns an owned heap value.

### 7.1 Tuples

Tuples are fixed-size, ordered, structural values. A comma distinguishes a
tuple from grouping: `(i32, bool)` is a type, `(40, true)` is a value, and
`(i32)` and `(40)` are parenthesized forms. One-element tuples require a
trailing comma, `(i32,)` and `(40,)`. `()` is the zero-element tuple type and
value; it is distinct from `void`. Tuple identity compares ordered element
types, so `(i32, bool)` and `(bool, i32)` differ. No implicit conversion exists
between a tuple, fixed array, or named struct.

Positions use decimal selectors such as `pair.0` and `pair.1`. The position
must be within the tuple's arity. Nested positions compose (`value.1.0`).
Tuples can be local values, declarative constants, function parameters, and
function returns, including generic and cross-module calls. They lower as
ordered native aggregates with target padding and alignment; tuple values do
not flatten into multiple call arguments.
`extern c` and `export c` reject tuple types because they have no C ABI mapping.

Tuple elements may contain owned storage. A resource-bearing position read is
a projection into the tuple owner and does not create a second owner. Moves,
replacement, and drop of the tuple must respect live projected borrows. Tuple
construction records checked transfers for owned members, and cleanup follows
the aggregate owner.

## 8. Enums

C-style enums have explicit representation:

```cyna
enum Color: u8 {
    red = 0,
    green,
    blue,
}
```

Status enums are the main error model:

```cyna
enum FsStatus: i32 {
    ok = 0,
    not_found,
    denied,
    no_memory,
    io_error,
}
```

Enums define named values with no payload. For payload variants, use `union`.
Enum cases may end with `,` or `;`; the examples in this specification use
commas. Struct field declarations end with `;`, while struct literal fields
are separated by commas.

### 8.1 C Enums

`c enum` is for C ABI enum-like integer values:

```cyna
c enum CColor: c_int {
    red = 1,
    green = 2,
}
```

A `c enum` may receive unknown values from C. Switching over a `c enum` should
require `else` unless the value has been validated.

### 8.2 Flags

Use `flags` for bitsets. Do not use `enum` as a C-style integer flag bag.

```cyna
flags FileMode: u32 {
    read  = 1 << 0,
    write = 1 << 1,
    exec  = 1 << 2,
}

const mode = FileMode.read | FileMode.write;

if mode has FileMode.read {
    ...
}
```

Rule:

```text
enum  = one closed named value
flags = set of named bits
c enum = C ABI enum-like integer
```

## 9. Unions

Cyna has three related union forms:

```text
union Name { ... }      safe named-case tagged union
union Name = A | B;     type union
c union Name { ... }     raw C-compatible union
```

The rule:

> `union` remembers what it holds. `c union` trusts the programmer.

### 9.1 Named Unions

Use a named `union` when tag names matter or when multiple variants have the
same payload type.

```cyna
union Token {
    ident: string;
    int_lit: i64;
    string_lit: string;
    eof;
}
```

Named unions are tag-oriented. Construction uses `.tag`:

```cyna
const a: Token = .ident("name");
const b: Token = .int_lit(42);
const c: Token = .eof;
```

For struct payloads, the tag provides the payload type:

```cyna
union Value {
    obj: Obj;
    text: string;
    none;
}

const v: Value = .obj({
    id: 1,
    name: "box",
});
```

Switching over a named union uses `.tag` patterns and should be exhaustive unless
a final `_` arm is present:

```cyna
switch token {
.ident(name) => {
    io.println(name);
}
.int_lit(n) => {
    io.println(n);
}
.string_lit(s) => {
    io.println(s);
}
.eof => {
    io.println("end");
}
}
```

### 9.2 Type Unions

Use a type union when the payload type itself is the tag:

```cyna
union Event = KeyEvent | MouseEvent | ResizeEvent;
```

This is useful for lightweight "one of these concrete types" APIs.
Prefer noun names for type unions because they are concrete runtime value
categories:

```cyna
union Stream = FileStream | MemoryStream;
union Event = KeyEvent | MouseEvent | ResizeEvent;
```

Module-qualified variants are allowed and keep the variant identity explicit:

```cyna
union Event = input.KeyEvent | ui.MouseEvent;
```

When the expected type is known, wrapping is automatic:

```cyna
const e: Event = KeyEvent {
    code: KeyCode.enter,
    pressed: true,
};

handle_event(MouseEvent {
    x: 10,
    y: 20,
});
```

When type context is missing, use an explicit cast/wrap:

```cyna
const e = Event(KeyEvent {
    code: KeyCode.enter,
    pressed: true,
});
```

Type unions are type-oriented, so switch cases use type names directly:

```cyna
switch event {
KeyEvent(key) => {
    handle_key(key);
}
MouseEvent(mouse) => {
    handle_mouse(mouse);
}
ResizeEvent(resize) => {
    handle_resize(resize);
}
}
```

The `is .tag(name)` narrowing form captures a named-union payload. Type unions
use checked `as` or `as?` projection. Exhaustive `switch` remains the preferred
form when every variant must be handled explicitly.

Derived protocol dispatch over type unions is available through explicit derived
implementations such as:

```cyna
impl Stream: Readable;
```

That declaration is valid only when every variant of `Stream` implements
`Readable`. Type-union variants used for derived protocol dispatch must be
concrete struct variants.

Type unions cannot contain the same effective type twice:

```cyna
union Bad = string | string; // error
```

If two variants have the same representation but different meanings, use a
named union or distinct types:

```cyna
type UserId = distinct u64;
type OrderId = distinct u64;

union Id = UserId | OrderId;
```

### 9.3 Narrowing and Projection

`is` narrows a named-union value and can capture its payload:

```cyna
if value is .int_lit(n) {
    io.println(n);
}
```

For optionals, `is name` tests for presence and declares `name` as an immutable
payload binding in the true branch. The name is a declaration, not a comparison
with an existing variable:

```cyna
if user is u {
    io.println(u.name);
}
```

For type unions, checked projection uses `as`:

```cyna
const key = event as KeyEvent;   // traps if event is not KeyEvent
const key = event as? KeyEvent;  // returns ?KeyEvent
```

For named unions, payload projection uses the variant name as a field-like
projection:

```cyna
const name = token.ident; // checked projection, traps if not .ident
```

Inside a narrowed branch, projection does not need a runtime check.

Projection is still a projection, not a detach. If the payload is an owned
value, reading through `token.case_name` does not hand it off from the union or
an enclosing aggregate. In safe v1, direct use of a
projected owned value in a handoff-shaped position is rejected rather than treated
as an implicit borrow. Use `&token.case_name` for alias access where supported,
`token.case_name.clone()` for an owned duplicate, or an explicit detachable
operation where the place kind supports it.

A `const` binding may name an owned field of an ordinary unpacked struct, an
owned payload of a checked named-union case, or an indexed element of owned
array storage when its root is a live owning local:
`const field = owner.inner;`, `const payload = boxed.payload;`, or
`const item = entries[index];`. An indexed element may also be reached through
a slice borrowed from a live owner, including a writable parameter alias.
Inside a narrowed named-union branch, a path may cross the checked payload and
continue into stable owned storage, as in
`const items = boxed.payload.items;`.

These are read-only projected bindings. `const same = field;` and further
owned field bindings preserve the original owner and checked path, including
ordinary field, named-union payload, and constant-index steps. An explicit
type annotation checks the projected type without transferring ownership. The
owner alone cleans up the value, after uses of the projected binding and its
defers. An indexed binding captures the selected element when the binding is
created; later changes to the index variable do not redirect the binding.
The projected borrow remains live through its last use, including a deferred
use. Once no use remains, the owner may be moved or dropped and the selected
place may be replaced under ordinary place rules.

A projected binding cannot be dropped, returned, stored as an owned value, or
passed to an owned parameter. It blocks moves, drops, detaches, and replacements
that overlap its checked place path. Disjoint sibling fields and distinct
constant indices remain mutable under ordinary place rules; dynamic indices
conservatively overlap. `var` bindings, temporaries, packed fields, alias
roots without a tracked borrow dependency, value-returning indexing hooks,
`c union` fields, and optional or switch capture bindings do not acquire this
rule. Captured payload bindings keep their existing owning-mode behavior.

Other projected owned value reads in binding, assignment, return, or owned-value
call-argument positions are rejected unless the program spells an explicit
operation such as `.clone()`, `take`, `&`, or `[..]` where that operation applies.

This rule prevents an ordinary field-like projection from silently detaching
cleanup responsibility from the owner that still contains the resource.

The explicit owned-duplicate form is `root.field.clone()` when the type
implements `Clone`; it duplicates according to that type's contract without
detaching ownership from the projected subplace.

A broader projected-borrow model would need a source-level rule that remains
explicit about whether the program asks for an alias, a view, a copy, or a
detached value. Plain projected ownership handoff is not part of safe v1.

### 9.4 Raw C Unions

`c union` is the raw C-compatible union form. It has no tag.

```cyna
c union CValue {
    i: c_int;
    f: f32;
    ptr: *c_void;
}
```

Reading a `c union` field requires `unchecked` because the compiler cannot know
which field is active:

```cyna
unchecked {
    const x = value.i;
}
```

Use `union` for safe tagged data. Use `c union` only for ABI layout, C interop,
and low-level code.

## 10. Error Handling

A function that can fail declares `T!E` as its return type. `T` is the success
value; `E` is an enum or a closed union of error enums. A plain `return`
produces success, and `throw` produces an error. `T!E` and its
`.ok`/`.err` cases are compiler-internal carriers, not public source syntax.

The success payload supplies the expected type for contextual literals. A
function returning `?U!E` uses normal optional construction: it can return a
`U` value or `none` as a successful optional value. Absence does not become an
error; `throw` still constructs an error. An expression already carrying the
declared `T!E` can be returned unchanged.

```cyna
enum ParseStatus: i32 {
    invalid = 0,
    overflow,
}

fn parse_i32(text: string): i32!ParseStatus {
    if text == "" { throw ParseStatus.invalid; }
    return 123;
}
```

`try` reads the success value or propagates the error to the enclosing
error-returning function. The outward error must be admitted by that function's
`E`; a bare `T!` return can infer its error set from `throw` and `try`.

```cyna
fn doubled(text: string): i32!ParseStatus {
    return (try parse_i32(text)) * 2;
}
```

Use an ordinary `catch` block to recover. The error code is bound by name; a
second binding may name a scoped failure view. `yield` supplies the replacement
value for the catch expression, while `return` or `throw` exits the enclosing
function. `throw code, "literal";` can attach a diagnostic message. A plain
`throw code;` still carries its typed code and can have an empty message.

When recovery is one expression, `catch (code) => expression` yields that
expression as the replacement value. The expression runs only on failure; the
enclosing statement supplies its usual semicolon. The scoped failure view is
also available as `catch (code, failure) => expression`. Use a block when the
handler needs statements, `return`, or `throw`:

```cyna
const value = parse_i32(text) catch (code) => 0;
```

The optional `failure` binding is a read-only view limited to its catch block.
It cannot be returned, stored, assigned, captured, passed to a task, or read
after the block. Its scalar and copied string reads can outlive the catch:

- `failure.available` says whether a live trace record exists. When storage is
  exhausted or a trace cannot be recorded, the typed code remains available and
  the view uses code-only defaults.
- `failure.origin` is the one-based `throw` source line, or zero when unavailable;
  `failure.origin_file` is its source path, or an empty string.
- `failure.site_count` counts retained propagation sites and `failure.omitted`
  counts sites beyond the bounded store. `failure.site(index)` returns `?u32`
  with a one-based `try` source line; `failure.site_file(index)` returns
  `?string` for the same site. Negative and out-of-range indices return `none`.
  A present path may be empty when source path data is unavailable.
- `failure.message` returns a separate owned string. It is empty when no message
  was supplied or its bytes cannot be copied. Source paths refer to emitted
  module constants and remain valid after the catch.

A record is released when the catch handles it or the enclosing result is
retired. `try` appends a site while propagating the same failure. When a hosted task entry returns `T!E`, its failure trace survives `join`,
`try_join`, and nested `TaskContext` work; discarded task results retire the trace. The store is bounded, so code
handling must not depend on `failure.available` being true.

When `main` returns an unhandled error, hosted execution prints its message,
`throw` location, and retained `try` propagation locations to stderr before
retiring the trace. If trace storage was unavailable, it prints a trace
unavailable notice. A successful result prints no failure trace and exits with
status zero; an unhandled error exits with status one.

```cyna
fn main(): i32 {
    const value = parse_i32("") catch (code) {
        if code == ParseStatus.invalid { yield 0; }
        yield 1;
    };
    return value;
}
```

For a `void!E` function, `return;` succeeds and `throw code;` fails. Use `?T`
when absence is the only information; optional absence does not propagate
through `try`.

# Part III. Values, Ownership, and Storage

This part is the semantic center of the spec. It moves from vocabulary, to
storage forms, to borrowed views, to assignment, and then to cleanup:

1. chapter 11 names the ownership categories used throughout the rest of the
   document
2. chapters 12-13 define the safe/unchecked boundary and the guarantees safe
   code is supposed to preserve
3. chapters 14-16 define strings, sequence/storage forms, views, mutation, and
   invalidation
4. chapter 17 gives the normative assignment and handoff rules
5. chapters 18-19 define cleanup and allocation behavior

When a rule in this part seems surprising, read chapter 17 together with
`docs/SEMANTICS.md`. The semantics document gives the checker-oriented model
behind the user-facing rules in this part.

## 11. Memory Type Taxonomy

This section names the memory-related type categories used throughout the spec.
Detailed assignment rules are in section 17, and cleanup rules are in section
18. The [terminology glossary](glossary.md) collects these names for use across
public documentation.

Core terms:

```text
binding    a name attached to a value, such as `user` in `var user = ...`
value      the thing a binding denotes
plain value
           a value copied by assignment without compiler-tracked cleanup
shared value
           a value whose backing or claim is shared by assignment
owned value
           a value with one active holder of compiler-tracked cleanup responsibility
alias      temporary access to an existing value; not cleanup responsibility
view       temporary access to a range inside existing storage
```

`value` does not mean "stored inline only." A value may contain pointers to
heap storage. A pointer value is still a value. For example, `^User` is a value
whose payload is an owned pointer to one heap `User`.

Cyna's everyday memory model is:

```cyna
T         // value
?T        // optional value; absence is none
&T        // observe-and-mutate alias pointer to an existing T place
&const T  // observation-only alias pointer to an existing T place
*T        // raw non-null pointer
?*T       // nullable raw pointer
*const T  // raw pointer whose pointee is read-only through this pointer
?*const T // nullable raw pointer with a read-only pointee
*volatile T        // volatile raw non-null pointer
?*volatile T       // nullable volatile raw pointer
**const T // raw pointer to a raw pointer to read-only T
^T        // owned pointer to a unique heap value
?^T       // nullable owned pointer
[]T       // view: pointer plus length
[]const T // read-only view
```

The unified binding model:

```text
plain values           assignment copies the value
shared values          assignment shares backing or another claim
owned values           assignment hands off cleanup responsibility
alias pointers         temporary pointer to another place
slices/views           view is copied; storage is not owned by the view
raw pointers           address is copied; use is unchecked
external handles       token is copied; cleanup is explicit API protocol
```

Binding assignment never asks the programmer to reason about hidden calling
conventions. A name always receives a local binding. The type decides what that
binding denotes: a copied plain value, a handed-off owned value, a shared value,
a copied view, or a copied external token. Function parameters use
the same rule: a parameter is a new local binding unless its type is `&T`.

Memory-related types are split by role:

| Kind | Spelling | Meaning |
|---|---|---|
| alias pointer | `&T`, `&const T` | mutable or observation-only capability for an existing place |
| owned value | `[:]T`, `List<T>`, `Map<K,V>`, `Set<T>`, `^T` | value responsible for cleanup, with one active holder |
| owned pointer | `^T` | owned value for one heap-allocated `T` |
| immutable builtin value | `string` | immutable UTF-8 value with shared backing storage |
| view | `[]T`, `[]const T` | non-owning range view |
| raw pointer | `*T`, `?*T`, `*const T`, `*volatile T`, and nested forms | manual address for low-level/foreign code |
| external handle | `File`, `Socket`, OS/library handles | ordinary token cleaned up by explicit APIs |

The formal model is deliberately small:

```text
plain values      copied and reused freely
shared values     share backing or a claim through assignment
owned values      a handoff or drop makes the source unavailable
aliases/views     non-owning access; may be copied but cannot own source cleanup
raw pointers      unchecked addresses outside the safe model
```

`@ownership.owned` and `@ownership.shared` are restricted to trusted std/core
struct declarations. They mark particular library types as owned or shared;
they are not additional value behaviors or general user-package attributes.

Raw pointers are for C interop, low-level code, allocators, intrusive data
structures, and hardware work. `*volatile T` is the intended MMIO/device-memory
form when loads and stores must remain visible to the machine rather than being
treated like ordinary RAM accesses. Alias pointers are fixed aliases for safe
single-object mutation. Slices are pointer-plus-length views for safe range
mutation. External handles are not owned pointers.

`string` is an immutable builtin value. Assignment and argument passing may
share backing storage because strings cannot be mutated in place. `.clone()` creates
a distinct-backing string value when that distinction matters.

All views in the language are non-owning, including:

- `&T`
- `[]T`
- `[]const T`
- slices produced from arrays, lists, and dense storage
- `string.bytes()`

They differ in projected type, mutability, and invalidation conditions, but
they follow one common rule: copying the view does not copy storage, and the
source owner must outlive every use of the view.

The checker models every non-owning view with the same abstract lifetime
principle:

1. a view carries provenance describing the possible storage roots it depends on
2. provenance may contain multiple possible roots after control-flow joins,
   aggregate flow, or helper-call substitution
3. a view may escape only when every possible root outlives the destination
4. mutation is rejected when it may invalidate a live alias or view with an
   overlapping root and projection
5. `&T`, `[]T`, `[]const T`, and `string.bytes()` differ only in projected type,
   mutability, and invalidation predicate, not in lifetime machinery

Implementations may conservatively widen provenance when exact subplace
identity is not recoverable. Such widening may reject otherwise-safe programs,
but it must not accept a program where a view can outlive or be invalidated
before its use.

Owned values are values that are responsible for ending some storage
lifetime exactly once. They have one active holder at a time. Assignment and
argument passing hand off that responsibility unless the programmer explicitly
calls `.clone()` first, and the old name becomes unavailable after the handoff.

This invalidation is flow-sensitive, not merely lexical. If control flow
reaches a point where a binding may already have been dropped or handed off on
some earlier path, later ownership-consuming or resource-observing use of that
binding is invalid in safe code.

In type-theory terms, Cyna owned values are affine resources. "Used at most
once" means an ownership-consuming use may happen at most once; it does not mean
the value can only be read once or have one method call. Ownership-consuming
uses are:

1. assigning an owned value to another binding
2. passing it by value to a parameter
3. returning it by value
4. storing it by value into another owner, such as a struct field or container
5. explicitly dropping it

Non-consuming access through `&T` / `&const T` alias pointers and `[]T` views
does not hand off the resource. The current holder remains responsible for
cleanup.

`^T` is the built-in owned value for heap-allocating one `T`. Standard
containers are ordinary owned values, not a separate ownership category.

Alias pointers are the exception to normal rebinding: an `&T` or `&const T`
parameter is a fixed alias to an existing place. Assigning through `&T` writes
the referent instead of rebinding the alias; assigning through `&const T` is
rejected.

Cyna is not a pure linear or affine calculus. It allows aliases, but aliases
do not hold cleanup responsibility. An alias stored in another value makes that
value borrow-carrying rather than owned. Safe code rejects aliases that outlive
the value they refer to or conflict with mutation that could invalidate them.
Slices use `[]T` for mutable views and `[]const T` for read-only views. Alias
pointers use the parallel `&T` and `&const T` capability distinction.

### 11.1 Alias Pointers

`&T` is a mutable alias pointer to an existing `T` place. `&const T` is the
read-only form. They are pointers with safe, non-owning semantics and are the
single-place counterparts to `[]T` and `[]const T`: all carry provenance, all
are non-owning, and all may be stored only when the containing value cannot
outlive the borrowed source.

Rules:

1. an alias pointer is non-null
2. an alias pointer parameter or local cannot be rebound by ordinary assignment
3. reading an alias reads the referent
4. assigning through `&T` writes the referent; assigning through `&const T` is rejected
5. binding, passing, returning, or storing an alias copies the alias carrier,
   not the referent
6. `&T` implicitly narrows to `&const T`; the reverse conversion is rejected
7. constness is a capability of that alias, not a global freeze: another valid
   mutable alias or root place may still change the referent
8. alias pointers are first-class borrow-carrying values: they may be stored,
   returned, compared, and passed through aggregates only when provenance
   proves the borrowed source outlives the destination
9. alias pointers are non-owning; safe code rejects escapes when alias
   provenance may outlive the referred storage
10. safe code can form place aliases from addressable paths such as
   `&user.age`, `&user.inner.age`, `&users[i]`, and `&self.fields[i]`,
   provided every projected field in the path is a normal aligned safe place and
   every indexed step addresses an aliasable element place

```cyna
fn rename(user: &User, name: string): void {
    user.name = name;
}

fn inc(x: &i32): void {
    x = x + 1; // writes through to the referred i32
}

fn copy_into(dst: &i32, src: &i32): void {
    dst = src; // copies src's value into dst's referent
}

fn inspect(value: &const i32): i32 {
    return value;
}

const mutable: &i32 = &counter;
const readonly: &const i32 = mutable; // capability narrowing
```

Alias pointers are not Rust lifetimes. There are no user-written lifetime
annotations. Cyna still rejects escapes when the alias provenance does not
outlive the destination:

```cyna
fn invalid_local_alias_return(): &User {
    var user = User { name: "local" };
    return &user; // error
}
```

Alias pointers may appear in ordinary struct fields, but the struct value then
becomes borrow-carrying:

```cyna
struct UserView {
    user: &User;
}
```

Moving or copying `UserView` moves only the borrowed capability. It does not
move, copy, or drop the referred `User`.

Returning a borrow-carrying struct is legal only when the borrowed source can
escape the function:

```cyna
struct UserView {
    user: &User;
}

fn ok(user: &User): UserView {
    return UserView { user: user };
}

fn invalid_local_view_return(): UserView {
    var user = User { name: "local" };
    return UserView { user: &user }; // error
}
```

Use owned values, raw pointers, handles, or indexes when a relationship must
outlive the borrowed source or cross an unchecked ABI boundary.

Safe alias-place boundary:

1. `&local` aliases the object itself; it produces `&T` from a writable local
   and `&const T` from a const local
2. `&root.field`, `&root.inner.field`, `&root[i]`, and projected indexed
   paths such as `&self.fields[i]` preserve the access capability of the place
   root; roots may be locals, parameters, globals, aliases, slices, or raw
   pointees reached inside `unchecked`
3. projection through a writable root produces `&T`; projection through a
   read-only root produces `&const T`; capability may narrow but never widen
4. a field whose stored value is itself `&T` or `[]T` retains that shallow
   capability even when the containing aggregate is reached read-only
5. packed fields never form safe aliasable places, including when reached
   through nesting such as `&outer.inner.bits`

An indexed step is an aliasable element place when it is a built-in array,
slice, dense-storage, or sparse-storage place access, or when the indexed
struct type exposes an accessible `@syntax.index` method with an alias output:

```cyna
struct Container {
    @syntax.index
    fn read(self: &const Container, key: K): &const T { ... }
}
```

In that form, `container[key]` reads through the returned alias and
`&container[key]` aliases the element. An index hook returning plain `T` is a
value read hook only; it does not make `&container[key]` or deeper place
projection through the element valid.

The alias returned by the hook is the implementation of the place, not the
source-level type of a bare indexed expression:

```cyna
var value: T = container[key];       // read the element value
var alias: &const T = &container[key]; // explicitly borrow for observation
```

Element aliases produced by such indexed places carry the same root provenance
as built-in indexed places. Mutating a different constant element is allowed
when the compiler can prove the indexes do not overlap, but structural mutation
of the container root is rejected while an overlapping element alias is live.

Use `&const T` for observation-only APIs and receivers. Use `&T` only when the
callee needs mutation capability. This distinction is local to the alias: a
read-only alias does not globally freeze the referent.

### 11.2 Optionals

`?T` means an optional value. The absence value is `none`.

```cyna
var name: ?string = none;
var user: ?^User = none;
var ptr: ?*User = none;
```

Use `?T` when absence is the only information. Use status enums when failure
has reasons.

```cyna
fn find_user(id: UserId): ?User {
    if missing {
        return none;
    }

    return User { id: id };
}
```

Optional narrowing can use the optional directly as an `if` condition:

```cyna
if user {
    io.println(user.name); // user is narrowed from ?User to User
}
```

Only `bool` and `?T` are valid `if` conditions. There is no general truthiness
for integers, strings, arrays, containers, or pointers.
Boolean negation is spelled `not`; prefix `!` is not a negation operator.
Use `is none` to test optional absence.

An early absence check narrows the optional after the return:

```cyna
if user is none {
    return;
}

io.println(user.name); // user is narrowed to User after the early exit
```

Use capture syntax when a separate payload name is clearer:

```cyna
if user is u {
    io.println(u.name);
}
```

Here `u` is a new immutable binding scoped to the true branch. It names the
present payload; it does not compare `user` with an existing `u`. Use `if user`
when the original name should be narrowed instead. Capturing a resource payload
follows the usual ownership and cleanup rules.

Use `none` for explicit absence checks:

```cyna
if user is none {
    return;
}
```

`none` is not a raw pointer null. Cyna should avoid `null` in normal code.

Optional absence does not have a propagation operator in v1. A function that
returns `?T` propagates absence with an explicit test and `return none`:

```cyna
fn extension_length(path: string): ?usize {
    const extension = std.path.extension(path);
    if extension is none {
        return none;
    }
    return extension.len();
}
```

This is intentionally distinct from `try`, which propagates the typed error
case of `T!E`. In particular:

- `try optional_value` is rejected
- optional absence is not converted implicitly to an error return
- a present resource payload is narrowed or captured under the normal
  ownership and cleanup rules
- returning `none` does not acquire, detach, or suppress cleanup of another
  value

The current standard-library and example corpus contains too few repeated
optional-returning call chains to justify a second propagation form. Any
postfix or keyword proposal must demonstrate a material reduction in real
code, remain visually distinct from typed-error propagation, and specify
resource-payload cleanup before it can change this rule.

### 11.3 Owned Pointers

Owned pointers are owned values with automatic cleanup. `^T` is the
explicit single-object heap form. It is one ownership-bearing form, not the only
way for a value to own storage or resources.

Single-object heap allocation uses `new T { ... }` and returns an owned
pointer `^T`:

```cyna
var user = new User {
    name: "Chao",
    age: 30,
};
```

The inferred type is:

```cyna
^User
```

Meaning:

```text
non-null
heap allocated
uniquely owned
automatically destroyed
owned value
allocated from current allocator context
```

Runtime-sized owned arrays are standard-library owned values:

```cyna
var users = [:]User [seed_user(), seed_admin()];
```

The type is `[:]User`, not `^User`. It owns a contiguous heap array with
runtime length.

`^T` is a restricted pointer: it points to one non-null heap value and carries
cleanup responsibility. Cyna tracks one active cleanup holder
for `^T`. External resources such as file descriptors, sockets, mutexes, and
threads are explicit handles unless a library chooses to build a resource
wrapper.

```cyna
var a = new User { name: "A", age: 1 };

var b = a;      // hands off the heap value; a becomes unusable
```

Returning `^T` hands off cleanup responsibility automatically:

```cyna
fn make_user(name: string): ^User {
    var user = new User { name: name, age: 0 };
    return user;
}
```

`^T` auto-dereferences for field and method access:

```cyna
user.name
user.birthday()
```

not:

```cyna
(*user).name
```

### 11.4 Aliasing Owned Values

An owned pointer `^T` can be passed to an alias pointer `&T` parameter
without handing off cleanup responsibility:

```cyna
fn rename(user: &User, name: string): void {
    user.name = name;
}

var user = new User { name: "Chao", age: 30 };

rename(user, "Cyna");
```

This call-site conversion is an implicit, call-duration borrow, not an owned
handoff. The parameter type declares whether the callee can mutate the
referent: `&T` permits mutation and `&const T` permits only reads. The owner
remains live and cannot be handed off or dropped while the borrow is live.
Requiring `&user` at every `^T` call would repeat the parameter's alias
contract without adding an ownership capability, so the conversion is
intentional.

Passing a `^T` by value hands off cleanup responsibility:

```cyna
destroy_later(user);
```

### 11.5 Raw Pointer Escape

Raw pointer conversion from an owned value is explicit:

```cyna
const ptr: *User = user.ptr();
```

Handing cleanup responsibility to C is more explicit:

```cyna
const raw: *User = resource.leak(user);
```

Reconstructing cleanup responsibility is explicit:

```cyna
var user: ^User = resource.from_raw(raw);
```

`resource.from_raw(raw)` must directly initialize an owning local. When `raw`
names a local or parameter, reconstruction consumes that binding so the same
handle cannot be reconstructed twice through the same name. The local's scope
exit drops its nested owned values before releasing the outer allocation
created by `resource.leak(...)`.

### 11.6 Volatile Raw Pointers

Volatile access is a raw-pointer feature for device memory and other foreign
storage whose reads and writes must remain visible to the machine.

The intended forms are:

```cyna
*volatile T
?*volatile T
```

Direction:

1. `*T` is a raw unchecked address
2. `*volatile T` is a raw unchecked address with volatile load/store semantics
3. `&T` remains part of the safe alias model
4. `&volatile T` is not part of the v1 surface

Volatile does not replace concurrency primitives:

1. volatile is not atomicity
2. volatile is not inter-thread synchronization
3. volatile does not by itself imply a hardware or compiler fence beyond the
   access itself

The main intended use is MMIO:

```cyna
packed struct UartRegs {
    dr: u32;
    sr: u32;
}

fn uart0(): *volatile UartRegs {
    unchecked {
        return 0x4000_1000 as! *volatile UartRegs;
    }
}
```

Volatile accesses stay in raw-pointer space rather than entering the ordinary
safe alias model.

## 12. Unchecked Code

The keyword is `unchecked`.

`unchecked` is the audit boundary where C-like danger is allowed.

Allowed only in `unchecked`:

1. raw pointer dereference
2. pointer arithmetic
3. integer-to-pointer casts
4. transmute/manual layout tricks
5. reading C union fields
6. uninitialized memory operations
7. inline assembly
8. calling functions declared as requiring `unchecked`

In the current implementation, `p + n` advances a raw `*T` pointer by `n`
elements of `T` inside `unchecked`. `n` has type `usize`, and `T` must be
sized. The caller must prove that the resulting pointer remains within the
allocation (or one element past it) before dereferencing. `p[n]` syntax is
not yet supported. An explicit address conversion remains available when a
byte offset is needed:

```cyna
unchecked {
    const byte_offset: usize = index * 4; // for a four-byte pointee
    const element = *((((pointer as! usize) + byte_offset) as! *const c_float));
}
```

The pointer-arithmetic allowance above covers both the typed element offset
and the raw-address operation.

Example:

```cyna
fn read_raw(p: *i32): i32 {
    unchecked {
        return *p;
    }
}
```

Rule:

> Safe Cyna has no undefined behavior. `unchecked` code may have C-like danger.

### 12.1 Volatile Dereference And MMIO

Dereferencing a volatile raw pointer is also an `unchecked` operation.

Rules:

1. a volatile load must be emitted as an actual machine-visible load
2. a volatile store must be emitted as an actual machine-visible store
3. the compiler must not elide a volatile access merely because the value seems
   unused or redundant under ordinary RAM assumptions
4. volatile access still remains target-specific low-level behavior
5. volatile access is about visibility of the access, not ownership, safety,
   or synchronization

Field access through `*volatile packed struct` should inherit volatile access
behavior from the pointer.

Rules:

1. `(*regs).sr` should be a volatile field read
2. `(*regs).dr = value` should be a volatile field write
3. whole-field register reads and writes are the intended common case
4. volatile packed bitfield reads may be allowed
5. volatile packed bitfield writes are a separate hazard because they usually
   require read-modify-write
6. volatile packed bitfield writes may require a volatile
   load-plus-rebuild-plus-volatile-store sequence
7. write-sensitive registers should prefer whole-register integer fields plus
   helper APIs instead of bitfield mutation

Example:

```cyna
packed struct StatusReg {
    ready: u1;
    mode: u3;
    error: u4;
}

fn read_status(regs: *volatile StatusReg): u8 {
    unchecked {
        return (*regs).error as u8;
    }
}
```

## 13. Safe-Code Guarantees

Normal Cyna code, without `unchecked`, should prevent common C/C++ memory bugs:

| Bug class | Cyna rule |
|---|---|
| Null dereference | `&T`, `^T`, and `string` are non-null |
| Accidental null logic | absence uses `?T` and `none`, and must be narrowed before value use |
| Use-after-free | owned values are handed off, not implicitly copied, and are dropped at the end of their lifetime |
| Double free | handing off an owned value makes the source unavailable |
| Buffer overflow | slices and arrays are bounds-checked |
| Wrong union access | checked projection traps; raw C union access is `unchecked` |
| Uninitialized read | variables must be initialized before use |
| Integer undefined behavior | checked arithmetic or defined wrapping operators |
| Dangling local alias | cannot return/store alias pointers to locals |
| Raw pointer accidents | raw dereference requires `unchecked` |

Cyna does not try to prove every aliasing property like Rust. It aims to make
the common dangerous cases impossible in normal code and visually isolate the
rest.

## 14. Strings

`string` is a builtin immutable UTF-8 value with sharable backing storage.
This section defines the language semantics of `string`. Representation choices
such as reference counting, immortal literal storage, substring sharing, or
interning are implementation details as long as they preserve the rules below.

### 14.1 Core Semantic Model

The core model is:

```text
string is immutable
string is sharable
plain binding/assignment/passing/returning shares backing
drop releases one shared owner
clone creates distinct backing
views into strings are non-owning like all other views
string equality is by contents, not backing identity
```

More explicitly:

1. `string` values cannot be mutated in place in safe code
2. multiple `string` values may refer to the same immutable backing storage
3. plain value flow such as binding, assignment, parameter passing, return, and
   container insertion does not require duplicating string bytes
4. implementations may keep track of shared ownership internally, for example
   through reference counting
5. `s.clone()` for `string` must produce a string value whose
   backing is distinct from `s`'s backing, even though contents remain equal
6. the language does not expose string-backing identity as an observable
   semantic property
7. all string observations are defined by contents, length, and view behavior,
   not by whether storage is shared
8. `string.bytes()` is an ordinary borrow-producing projection, not a special
   ownership category

The last point is important. A program may not rely on whether two equal
strings share backing storage.

### 14.2 Backing Classes

The semantic model allows at least two backing classes:

1. static backing, such as string literals
2. runtime-managed backing, such as file reads, interpolation results, or
   builder-produced strings

These backing classes are not separate surface types. Both are ordinary
`string`.

Required semantic rules:

1. string literals may use static backing
2. dropping a string literal is a semantic no-op
3. runtime-created strings may use shared runtime-managed backing
4. sharing a runtime-created string must keep the backing alive until the last
   owner is dropped
5. `.clone()` on either kind must produce a string with distinct backing

So, for example:

```cyna
const a = "abc";
const b = a;        // shares backing
const c = a.clone(); // equal contents, distinct backing
```

and:

```cyna
const a = try fs.read_file(path);
const b = a;        // shares backing
const c = a.clone(); // equal contents, distinct backing
```

must follow the same user-visible rules.

Ordinary string literals decode `\\`, `\"`, `\n`, `\r`, and `\t` into the
corresponding bytes. Interpolated strings additionally use `\{` and `\}` for
literal braces.

### 14.3 Sharing Semantics

Plain string value flow shares backing by default.

This includes:

1. local binding from another string binding
2. plain assignment
3. argument passing to `string` parameters
4. returning `string`
5. storing a string into a struct field
6. storing a string into an optional or error-return payload
7. storing a string into container elements
8. reading a string out of a field, payload, or container element

Examples:

```cyna
const a = "hello";
const b = a;                 // share
```

```cyna
fn echo(text: string): string {
    return text;             // share
}
```

```cyna
struct User {
    name: string;
}

const name = "Ada";
const user = User { name: name }; // share
```

```cyna
var names: List<string> = list<string>();
names.push("Ada");           // inserted string may share backing
const first = names[0];      // shares backing with stored element
```

The language meaning is still "copy the string value", but builtin string copy
semantics are sharing semantics by default rather than byte duplication.

### 14.4 `clone()` On Strings

`clone()` on `string` duplicates backing storage.

This is different from ordinary string assignment:

```cyna
const a = "hello";
const b = a;        // share backing
const c = a.clone(); // distinct backing
```

Required rules:

1. `s.clone()` must preserve contents exactly
2. `s.clone()` must produce distinct backing from `s`
3. later drops of the original and the copy must be independent
4. `clone()` must force distinct backing even for literals and static-backed
   strings

That means `"abc".clone()` is not allowed to be a semantic no-op merely because
the source is a literal.

The distinction is:

```text
plain string flow   share backing
clone string        duplicate backing
```

This rule is specific to builtin `string` semantics and is intentionally
stronger than the generic notion of ordinary value copying.

### 14.5 Drop Semantics

Dropping a string ends one owner of that string value.

For runtime-managed shared backing, this means:

1. drop releases one shared owner
2. backing storage is freed when the last owner is released

For static-backed strings, drop is a no-op.

This is an implementation detail at the storage level, but the language effect
is:

```text
dropping a string never mutates its contents
dropping one shared string does not invalidate still-live shared copies
dropping the last owner ends the backing lifetime
```

Example:

```cyna
const a = try fs.read_file(path);
const b = a;

drop a;         // releases one owner
use(b);         // valid; b still keeps the backing alive
```

This is one reason sharing is safe: strings are immutable.

### 14.6 Non-Observable Identity

Whether two strings share backing is not an observable language property.

Programs may observe:

1. contents
2. byte length
3. results of string operations
4. validity of derived non-owning views while the owner remains live

Programs may not rely on:

1. pointer identity of string backing
2. whether a particular operation reused or duplicated backing internally
3. whether a particular implementation uses reference counts, immortal storage,
   substring slices, or interning

As a result:

```cyna
const a = "abc";
const b = a;
const c = a.clone();
```

must guarantee:

```text
a == b
a == c
b == c
```

but the language does not promise any particular backing-identity relationship
between them.

### 14.7 String Surface

For v1, ordinary `string` usage should stay ergonomic, but the API must remain
explicit about UTF-8.

Core string surface:

```text
len() -> usize
is_empty() -> bool
bytes() -> []const u8
starts_with(prefix: string) -> bool
ends_with(suffix: string) -> bool
contains(needle: string) -> bool
find(needle: string) -> ?usize
rfind(needle: string) -> ?usize
slice(start: usize, end: usize) -> string
```

Semantics for the byte-oriented surface:

1. `bytes()` exposes the string's UTF-8 bytes as a read-only byte slice
2. `find(...)` returns a byte index
3. `rfind(...)` returns a byte index
4. `slice(...)` is byte-range slicing in v1
5. prefix/suffix/contains checks operate on byte-equal UTF-8 sequences
6. these operations are defined by contents, not by string identity

The long-term surface should keep byte-level and text-level operations
visibly distinct. `bytes()` is the systems/protocol view. A future `chars()`
view would decode valid UTF-8 into `char` values without failure; it is not
implemented in the current standard library. A generic string slicing API is
inherently ambiguous
unless its unit is explicit; APIs should prefer names such as
`byte_slice(...)` or `char_slice(...)` if both forms are supported.

### 14.8 Views Derived From Strings

`string.bytes()` returns a non-owning view, not an owned byte container.

This follows the same rule as all other slices and views in the language:

```text
all views are non-owning
copying a view copies the view, not the storage
the source owner must outlive the view
```

`bytes()` is therefore not a special lifetime loophole. It is an ordinary
borrow-producing projection from a shared immutable value to a read-only byte
view.

So:

```cyna
const s = "abc";
const bs = s.bytes();
```

means `bs` is a read-only byte view into `s`'s backing storage.

Required rules:

1. `bytes()` does not deep-copy string bytes
2. the returned `[]const u8` does not own storage
3. copying or forwarding that byte view copies only the view, not the backing
4. a byte view into a static literal may remain valid as long as the literal's
   static storage remains valid
5. a byte view into runtime-managed backing is valid only while the source
   string storage remains live
6. compiler/lifetime rules for views must reject escapes when the byte view's
   provenance does not outlive the destination, just as they do for other
   non-owning views

Examples:

```cyna
const s = "abc";
const bs = s.bytes();    // okay
assert(bs[0] == 97);
```

```cyna
fn head(text: string): u8 {
    return text.bytes()[0]; // valid: local view used within owner lifetime
}
```

```cyna
fn invalid_local_string_bytes_return(): []const u8 {
    const s = try fs.read_file("data.txt");
    return s.bytes(); // error: returns a view tied to local string storage
}
```

```cyna
fn invalid_parameter_string_bytes_return(text: string): []const u8 {
    return text.bytes(); // error: by-value string params do not make the view owning
}
```

Even though `string` values are immutable and may share backing storage, the
`[]const u8` returned by `bytes()` still does not retain ownership of that
storage. A by-value `string` parameter may be the last live owner, so a byte
view derived from it cannot be returned unless the API instead takes and
returns a view directly.

The precise escape rules belong to the general view/slice lifetime model.
`string.bytes()` follows that model; it does not define a separate one.

### 14.9 Interpolation And String Construction

`+` is numeric addition only. It does not concatenate strings.

String construction uses interpolation:

```cyna
fn greet(name: string): string {
    return $"Hello, {name}";
}
```

Interpolated strings use `$"..."`. Holes support projection paths:

```cyna
$"name={user.name}"
$"id={user.id:x}"
```

The first supported format suffixes are integer-only:

1. `d` decimal
2. `x` lowercase hexadecimal
3. `X` uppercase hexadecimal
4. `b` binary
5. `o` octal

Literal braces inside interpolation are escaped with backslash: `\{` and
`\}`.

Example:

```cyna
fn greet(name: string): string {
    return $"Hello, {name}";
}

var a = greet("Chao");
var b = a;

a = $"{a}!";

io.println(a); // "Hello, Chao!"
io.println(b); // "Hello, Chao"
```

Required rules:

1. interpolation never mutates existing string contents in place
2. interpolation produces a new `string` value
3. existing shared strings keep their previous contents
4. `string + string` is a compile-time error; use interpolation or explicit
   formatting/builder APIs

### 14.10 char Literals

A `char` literal denotes exactly one Unicode scalar value.

```cyna
const a: char = 'A';
const zhong: char = '中';
const face: char = '\u{1F600}';
```

char literals are compile-time scalar constants. They are not inherently `u8`
or any other integer type, but they may be shaped by an expected target type
when the value is representable.

Examples:

```cyna
const r: char = 'A';  // ok
const x: u32 = 'A';   // ok, value 65
const b: u8 = 'A';    // ok, value 65 fits u8
const w: u16 = '中';  // ok, U+4E2D fits u16
```

The following are compile-time errors:

```cyna
const empty: char = '';        // empty literal
const two: char = 'ab';        // more than one char
const b: u8 = '中';            // value does not fit u8
const w: u16 = '😀';           // value does not fit u16
const bad: char = '\u{D800}';  // surrogate code point
const huge: char = '\u{110000}'; // outside Unicode range
```

Required literal rules:

1. a `char` literal must decode to exactly one Unicode scalar value
2. surrogate code points are rejected
3. code points above `U+10FFFF` are rejected
4. shaping a `char` literal to an integer type is allowed only when the value is
   representable by the target type
5. shaping to `char` is allowed only for valid Unicode scalar values
6. in an operation with a concrete integer operand, a `char` literal may be
   shaped to that operand's type when the value is representable
7. runtime casts from `char` to narrower integer types use the ordinary checked
   `as` / `as?` conversion rules

This gives ASCII-heavy systems code concise constants without making text and
bytes the same type:

```cyna
if tag == 'L' {
    ...
}

const slash: u8 = '/';
```

### 14.11 String Indexing And Iteration

Direct indexing on `string` is intentionally not part of v1.

```text
text[i] is not defined for string in v1
```

Reason:

1. Cyna strings are UTF-8
2. UTF-8 does not support fixed-width character indexing
3. the language should not blur byte indexing and Unicode-scalar indexing

Byte access should be written explicitly through `bytes()`:

```cyna
const b = text.bytes()[0];
```

Byte iteration follows the normal slice model:

```cyna
const bs = text.bytes();
for b in bs {
    ...
}
```

Unicode-scalar iteration needs a decoder; `string.chars()` is a planned API,
not a current method. Its intended element type is `char`, a Unicode scalar
value. This is not the same as a
user-perceived character or grapheme cluster. For example, a base letter plus a
combining mark is two `char` values, and a flag emoji formed from regional
indicator symbols is also multiple `char` values.

### 14.12 Performance Intent

String operations must be optimized because `string` is an everyday type:

1. string literals use static storage
2. assignment and argument passing are cheap and share immutable storage
3. substring may share backing storage while keeping it alive
4. interpolation may allocate, but implementations should fold literals and
   avoid unnecessary intermediate strings where evaluation order permits
5. repeated construction should use an explicit builder/buffer API in
   allocation-sensitive code
6. interning is permitted as an optimization, but not required by
   semantics

### 14.13 Borrowed C Strings

`c_str` is a distinct borrowed C-string view. Its ABI representation is
`*const c_char`, but the additional source-level contract is that the pointer is
non-null and reaches a NUL terminator before the end of accessible storage.
`?c_str` is not the nullable spelling; use `?*const c_char` when a C API accepts
or returns a nullable pointer.

The type does not own storage and there is no owning `CString` language type.
It may be used for C parameters, C callback parameters, and non-escaping local
bindings whose source outlives the use. It may not be stored in structs, unions,
or globals, and it may not be returned because those positions do not express
the required borrow lifetime. A C function that returns text therefore returns
`?*const c_char` (or another explicit raw pointer) and documents its lifetime.

Conversion from a dynamic `string` to `c_str` is explicit because it may need
allocation or NUL validation. The standard adaptation shape is a scoped helper
such as `std.c.with_str(text, callback)`, which guarantees both termination and
the temporary buffer's lifetime. A compiler may contextually adapt a static,
NUL-free string literal when it can prove the same properties without
allocation. Embedded NUL bytes are rejected for that adaptation.

## 15. Sequence, View, and Container Types

This chapter defines the storage and sequence shapes themselves. It is about
what the types are. Chapter 16 builds on this chapter and explains the
borrowed-access and invalidation rules for views after they have been created.

### 15.1 Overview and Type Matrix

Cyna has three related families here:

1. ownership-bearing storage foundations
2. non-owning views into existing storage
3. ordinary library containers layered on those foundations

The language-level storage core is:

| Type | Owns storage? | Length/capacity known where? | Can have empty slots? | Meaning |
|---|---:|---:|---:|---|
| `[N]T` | yes | compile time | no | fixed-size inline storage |
| `[:]T` | yes | runtime | no | dense storage with initialized prefix |
| `[;]T` | yes | runtime | yes | sparse storage with explicit occupancy |
| `[]T` | no | runtime | n/a | mutable slice view |
| `[]const T` | no | runtime | n/a | read-only slice view |

Ordinary library containers such as `List<T>`, `Map<K, V>`, and `Set<T>` are
not storage primitives. They are expected to build on the storage foundations
rather than define separate ownership rules.

Their surface conveniences may still use the transitional language-supported
construction, indexing, and iteration hooks described in Section 22.3, but
that does not make them separate storage primitives in the language model.
Membership is an ordinary library operation spelled `container.contains(value)`;
it does not participate in language syntax or compiler lookup.

There is no C-style array-to-pointer decay.

### 15.2 Slices

`[]T` and `[]const T` are pointer-plus-length views. A slice never owns storage.

```cyna
[]T
[]const T
```

Examples:

```cyna
fn sum(xs: []const i32): i32 {
    var total: i32 = 0;

    for value in xs {
        total = total + value;
    }

    return total;
}
```

Slice indexing is bounds-checked in safe code.

```cyna
const x = xs[i]; // bounds checked
```

Slice indexing is a view operation. It does not define core ownership-removal
semantics, so `take xs[i]` is not a slice operation in the core language.

View contract:

1. a view is iterable
2. a view is indexable
3. `[]T` supports indexed mutation such as `xs[i] = value`
4. `[]const T` is read-only and does not support indexed mutation
5. a view remains a sequence surface, so once slice-range syntax is
   available it may itself be sliced again

Unchecked indexing is explicit:

```cyna
unchecked {
    const x = xs.ptr[i];
}
```

Slice fields are intentionally simple:

```cyna
xs.ptr // raw pointer to first element
xs.len // number of elements
```

Access to `ptr` is allowed, but dereferencing it follows raw pointer rules.

Assigning or passing a slice copies the view, not the elements:

```cyna
var a: []i32 = data[..];
var b = a; // copies ptr + len
```

Mutating through a mutable slice mutates the backing storage:

```cyna
b[0] = 99; // changes data[0]
```

### 15.3 Fixed Arrays

`[N]T` is a value containing exactly `N` inline elements.

```cyna
[N]T
```

Example:

```cyna
var pixels: [1024]Color;
var pair: [2]i32 = [2]i32 [10, 20];
var zeros = [4]i32 [];
var scores: [3]i32 = [10, 20, 12];
```

The length is part of the type:

```cyna
[4]u8
[8]u8
```

are different types.

Assigning a fixed array copies its elements according to normal assignment
rules:

```cyna
var a: [4]i32 = [4]i32 [1, 2, 3, 4];
var b = a; // copies four i32 values
```

Fixed arrays are for inline buffers, ABI/layout-specific storage, stack scratch
space, and embedded-style code. They should not be the everyday growable
collection.

`[N]T [ ... ]` is explicit fixed-array construction. A fixed array consumes
positional elements. Empty brackets default-initialize all elements.

```cyna
var a = [4]i32 [1, 2, 3, 4];
var zeros = [4]i32 [];
```

When the expected type is known, a fixed array may also use a contextual
sequence literal:

```cyna
const scores: [3]i32 = [10, 20, 12];
const zeros: [3]i32 = [];
```

The contextual form requires an expected fixed-array type. Bare `[10, 20, 12]`
does not infer a fixed array.

Ordered sequence literals may be repeated with `**`:

```cyna
const zeros: [64]i32 = [0] ** 64;
const pairs: [6]i32 = [1, 2] ** 3;
const repeated: [:]i32 = [1, 2] ** 3;
var xs: List<i32> = list_from<i32>(repeated);
```

The left side must be a sequence literal. The repeat count is an integer
literal or a compile-time value generic such as `N` inside
`struct Pool<T, const N: usize>` or `fn fill<T, const N: usize>(...)`. The
repeated result is checked as the expected target sequence; for fixed arrays,
`pattern_length * count` must match the target array length.

### 15.4 `[:]T`

`[:]T` is dense owned storage with runtime capacity and an initialized prefix.

Conceptually:

```text
ptr
capacity
init_len
```

Invariant:

```text
0 <= init_len <= capacity

[0, init_len) initialized
[init_len, capacity) uninitialized
```

Dense storage is for code that needs direct control over owned element storage
shape without introducing empty-slot semantics.

Construction forms:

```cyna
var pixels: [:]Color = [red, green, blue];
var scratch: [:]i32 = [: 16] [1, 2, 3];
var empty: [:]i32 = [];

fn sample_header_bytes(): [:]u8 {
    return [0xCA, 0xFE, 0xBA, 0xBE];
}
```

The declared return type supplies the expected type for a contextual sequence
literal, so repeating `[:]u8` in that return expression is unnecessary.

The `[: 16]` prefix is construction syntax that chooses capacity. It is not a
distinct type. The type remains `[:]T`.

`[:]T` is an owned value: assignment, argument passing, and return perform
ownership handoff.

Indexed access names a place in dense storage. In safe code, reads and writes
are defined only for initialized slots. Owned element types are not
transferred out by ordinary indexed read; use explicit `.clone()` or a higher-level
API when ownership of an element must leave the storage.

### 15.5 `[;]T`

`[;]T` is sparse owned storage with runtime capacity and explicit slot
occupancy.

Conceptually:

```text
ptr
capacity
occupancy
```

Invariant:

```text
slot initialized iff occupied
```

Sparse storage is the core language-level removal-friendly storage form.

Construction form:

```cyna
var slots: [;]User = [; 128];
```

Sparse storage also supports inline construction with optional-slot semantics:

```cyna
var slots0: [;]i32 = [1, none, 3];
var slots1 = [;]i32 [1, none, 3];
var slots: [;]i32 = [; 8] [1, none, 3];
var slots2 = [; 8]i32 [1, none, 3];
```

Inline sparse items initialize indices `0..N-1` positionally:

- `some(v)` or a plain `v` occupies the slot
- `none` leaves the slot empty
- when capacity is explicit, it must be at least the initializer length
- when capacity is omitted, capacity is inferred from the initializer length

Sparse storage also supports keyed construction:

```cyna
var slots0: [;]i32 = {
    3: 42,
    10: 99,
};
var slots1 = [;]i32 {
    3: 42,
    10: 99,
};
var slots: [;]i32 = [; 16] {
    3: 42,
    10: 99,
};
var slots2 = [; 16]i32 {
    3: 42,
    10: 99,
};
```

Keyed sparse items initialize exactly the named indices. The capacity must be
greater than every keyed index. When capacity is omitted, capacity is inferred
as one greater than the largest keyed integer index.

Sparse construction supports:

1. empty construction: `[; N]`
2. positional sparse construction: `[; N] [...]`
3. keyed sparse construction: `[; N] { k: v, ... }`

A sparse initializer is invalid when its capacity cannot cover the initializer.

Indexed access names a place in sparse storage. The place behaves like `?T`:

- occupied slot behaves like `some(T)`
- empty slot behaves like `none`
- explicit `take` may detach from an occupied slot and leave it empty

Sparse storage iteration follows the same slot model:

- `for slot in slots` yields `?T` for each slot in index order
- `slots.indices()` yields a `List<int>` containing the occupied indices

Sparse storage iteration visits slots in index order. It does not imply that all
iterable values in the language are index-based.

`[;]T` is also an owned value: assignment, argument passing, and return
perform ownership handoff.

### 15.6 `List<T>`

`List<T>` is an ordinary standard-library type and an ordinary owned value.
It is available from `std.prelude` without an explicit import and provides a
growable owned sequence surface layered on the storage foundations.

```cyna
var users: List<User> = list<User>();
users.push(User { name: "A" });
users.push(User { name: "B" });

io.println(users.len());
io.println(users[0].name);
```

Expected core operations:

```text
users.len
users.capacity
users[i]
users.push(x)
users.pop()
users.clear()
users.reserve(n)
```

The exact internal representation is library-defined. The language does not
grant `List<T>` special ownership semantics beyond those already described for
ordinary owned values.

`List<T>` indexing is defined by an annotated inherent method, not by
compiler knowledge of its storage fields:

```cyna
struct List<T> {
    @syntax.index
    fn index(self: &const List<T>, index: usize): &const T { ... }
}
```

Therefore `users[i]` reads the element through an alias returned by the hook,
and `&users[i]` forms a read-only alias to that element. Writable element
access is explicit through `users.get_mut(i)`, while mutable slice access is
explicit through `users.view_mut()`. `users.view()` returns `[]const T`.

### 15.7 Map<K: Eq, V> and Set<T: Eq>

Common containers are core standard library types:

```cyna
Map<K: Eq, V>
Set<T: Eq>
```

Their standard-library home is the prelude surface.

No explicit module import is required for these types in the v1 surface.

Set elements and Map keys must explicitly implement `Eq`. Collection lookup,
membership, duplicate detection, and replacement call `Eq.eq` through borrowed
references. They do not make `==` protocol-backed, and a type supported by
concrete `==` is not a valid collection key unless it also has an explicit
core or user-declared `Eq` conformance.

They are ordinary library types, not syntax primitives like `i32`, `*T`,
`[N]T`, `[:]T`, or `[;]T`. Like `List<T>`, they are owned values in the
source language.

Their detailed assignment and copy behavior follows the global rules in chapter
17. This chapter only defines the container kinds themselves and their surface
construction forms.

The standard `Set` and `Map` `clone()` methods produce independent copies,
including for ownership-bearing keys whose fields can be duplicated by the
compiler's normal descriptor-driven storage operation. Growth, clearing,
literal construction, duplicate Set insertion, and Map replacement transfer
each stored resource exactly once.

The current prelude also ships `SlotMap<T>` and `SlotMapKey` as an implemented
container surface. `SlotMap` supports slot-map insertion, generation-checked
membership, removal, clearing, and capacity management. It is useful to the
current runtime and synchronization wrappers, but remains a provisional
library extension rather than a new language-level storage primitive; its
stable API is not part of the compact v1 container list above.

V1 language hooks still return collection items by value. Consequently:

- direct Set indexing and Set iteration reject ownership-bearing elements
- Map indexing rejects ownership-bearing values
- `Map.keys()` rejects ownership-bearing keys, and `Map.values()` rejects
  ownership-bearing values, because these methods create selected-value
  snapshots from projected sparse entries

These cases fail semantically at the user operation. They must not reach
lowering or native-code invariants. Copyable key/value snapshots remain
supported, including `values()` when only the Map key is ownership-bearing.

The implementation may store metadata and backing storage however it chooses.
Programs should not depend on representation.

General language-level shared ownership, such as `ref<T>`, is not part of v1.
Standard containers should not require hidden runtime ownership
mechanisms in order to justify their source-level semantics.

### 15.8 Construction and Literals

Initialization follows a delimiter split:

1. `{ ... }` is always keyed initialization
2. `[ ... ]` is always positional sequence initialization

The target type decides which compiler-owned storage or aggregate shape is
accepted:

- structs accept field/value entries in `{ ... }`
- sparse storage accepts index/value entries in `[; cap] { ... }`
- fixed arrays accept elements in `[ ... ]`
- dense storage `[:]T` accepts elements in `[ ... ]`

User-defined sequence targets opt in through `@syntax.sequence_literal` on a
public top-level Cyna factory. The function must define a body, take exactly
one owned dense-storage parameter `[:]Item`, and declare a non-`void` return
type. The attribute takes no arguments and is invalid on methods, imported or
bodyless declarations, globals, types, and protocol members. Invalid signatures
are diagnosed even when the factory is unused. Function names have no syntax
meaning.

The expected target type selects visible marked factories by declaration
identity and instantiated return type. Generic arguments are inferred from the
expected return type and item type; unresolved arguments are an error. Exactly
one applicable factory is required; multiple candidates produce an ambiguity
diagnostic naming the factories. Visibility follows ordinary imports (including
named imports and aliases), module access, and prelude autoloading. Loading a
module transitively does not import its factory into unrelated modules.

The compiler checks elements against `Item`, constructs owned `[:]Item` storage
in source order, and transfers that storage through ordinary call ownership
and cleanup rules. An empty literal creates empty storage of the inferred item
type. Native fixed-array, dense-storage, and sparse-storage targets retain
their intrinsic construction paths, including capacities and repetition.
User-defined targets require contextual typing; an untyped `[]` or `[1, 2]`
remains ambiguous. Explicit capacities and repetition do not opt a library
target into native storage construction.

The standard prelude marks `list_from<T>(items: [:]T): List<T>`, so both literal
construction and explicit factory calls are supported:

```cyna
var xs: List<i32> = [];
var ys: List<i32> = [1, 2, 3];
var explicit = list_from<i32>([:]i32 [1, 2, 3]);
var names = set<string>();
var scores = map<string, i32>();
var objects = slot_map<Object>();
```

Additional elements are added through the container's named operations.

The compiler must validate the chosen construction path against the target
type. In particular:

1. struct types support contextual sequence literals only through a visible
   marked factory
2. keyed literals target struct fields or sparse-storage indices
3. sequence literals target fixed arrays, dense storage, sparse storage, or
   the contextual return type of a marked factory
4. the compiler must reject unsupported forms even when the target is
   struct-backed

Construction uses exactly one construction form at a time. A struct-form
initializer does not compose with a trailing sequence or keyed literal, and a
literal construction form does not perform an implicit pre-initialization step
through struct fields or another construction mode.

Both explicit typed initialization and contextual initialization are allowed.
The explicit form names the target type before the delimiter, and the
contextual form relies on the expected type:

```cyna
var u = User { name: "Ada", age: 42 };
var u2: User = { name: "Ada", age: 42 };

var m = map<string, i32>();
m["ok"] = 42;

var fixed = [3]i32 [1, 2, 3];
var fixed2: [3]i32 = [1, 2, 3];

var zeros = [3]i32 [];
var zeros2: [3]i32 = [];

var dense = [:]i32 [1, 2, 3];
var dense2: [:]i32 = [1, 2, 3];
var empty_dense: [:]i32 = [];
var reserved: [:]i32 = [: 8] [1, 2, 3];

var sparse = [;]i32 [1, none, 3];
var sparse_reserved = [; 16]i32 [1, none, 3];
var sparse2: [;]i32 = { 3: 42, 10: 99 };
var sparse2_reserved: [;]i32 = [; 16] { 3: 42, 10: 99 };

var xs = list_from<i32>([:]i32 [1, 2, 3]);
var empty_xs = list<i32>();

var names = set<string>();
names.add("Ada");
names.add("Lin");
```

Accepted forms by type:

```text
Struct          T { field: value, ... }         or contextual { field: value, ... }
Fixed array     [N]T [a, b, c]                  or contextual [a, b, c]
Fixed array     [N]T []                         or contextual []      (default-initialize all N elements)
Dense storage   [:]T [a, b, c]                  or contextual [a, b, c]
Dense storage   [:]T []                         or contextual []      (empty dense storage)
Dense storage   [: n] [a, b, c]                 explicit capacity plus initialized prefix
Sparse storage  [;]T [; n] [a, none, c]         explicit capacity plus optional-slot prefix
Sparse storage  [;]T [; n] { i: value, ... }    explicit capacity plus keyed slots
```

Rejected forms:

```cyna
var xs: List<i32> = [1, 2, 3];       // invalid: list construction is named
var ids: Set<i32> = [];              // invalid: set construction is named
var slots: [;]i32 = { 3: 42 };        // invalid: sparse keyed form needs explicit capacity
var counts: Map<string, i32> = {};   // invalid: map construction is named
var u = User [1, 2];                  // invalid: structs do not use sequence literals
```

Bare literals without an expected type remain ambiguous. Bare `[1, 2, 3]` does
not choose between fixed array, `[:]T`, `List<T>`, and `Set<T>`, and bare
`{ "a": 1 }` does not choose a default map type.

## 16. Views, Mutation, and Invalidation

This chapter covers the behavioral rules around borrowed access. Chapter 15
defined the types themselves; this chapter explains how APIs should accept
them, how mutable access works, and when views or element aliases become
invalid.

The important split is:

1. chapter 15 says what a slice, dense storage value, sparse storage value, or
   container is
2. chapter 16 says what borrowed use of those values permits and what makes an
   existing borrow invalid

### 16.0 Places, Projections, and Uses

A place is an addressable storage location. Every place is resolved as a root
plus an ordered projection path:

```text
Place = Root × ProjectionPath
```

Roots include local bindings, parameter storage, globals, alias/slice
referents, and raw-pointer pointees inside `unchecked`. Projection steps include
ordinary fields and indexes. A temporary value is not a place merely because
field or index syntax can read from it.

The value type answers what the place contains. Access capability separately
answers whether the place is read-only or writable. Mutability is therefore
not a general nominal qualifier on values such as `List<i32>`: a `const` binding
makes that binding's ordinary root access read-only, while `&T`, `&const T`,
`[]T`, and `[]const T` explicitly carry referent/element access capability.

Projection normally preserves root capability. Stored alias and slice fields
are shallow capabilities of their own, so reading such a field does not rewrite
`&T` to `&const T` or `[]T` to `[]const T` merely because the containing
aggregate is read-only.

After resolving a place, the use determines the operation:

1. read observes the current value
2. borrow (`&place` or a view operation) creates non-owning access with source
   provenance
3. mutate replaces the place only when access is writable and no live borrow
   overlaps it
4. detach (`take place`) is available only when the place has a defined empty
   post-state

For a named struct-field place, assignment can capture the displaced value:

```cyna
box.items = next_items @ const old;
box.count = next_count @ var previous_count;
```

The right-hand side is evaluated before replacement. If that evaluation fails,
the field is unchanged and the capture is not created. On success, the old
field value moves into the new local, the replacement fills the field, and
ordinary cleanup belongs to the capture. `const` and `var` control the new
binding. The root must be writable, the binding name must be new in the active
scope, and borrowed-value captures are not yet supported. Capture currently
applies to named field paths; indexed and library-defined places remain future
extensions.

Packed fields remain non-addressable in safe code. Union payload aliases remain
conservative in v1 because field syntax alone does not prove the active case.
These are addressability rules, not a second mutability system.

### 16.1 Parameter-Passing by Intent

APIs should choose parameter types by intent:

```text
List<T>   take the list resource
&List<T>  mutate the caller's list object
[]const T read elements from any contiguous sequence
[]T       mutate elements in a caller-provided range
```

Read-only APIs should usually accept `[]const T`:

```cyna
fn print_all(users: []const User): void {
    for user in users {
        io.println(user.name);
    }
}

print_all(users); // List<User> -> []const User view; cleanup responsibility is not handed off
```

Passing `List<T>` by value hands off cleanup responsibility:

```cyna
fn take_users(users: List<User>): void {
    users.clear();
}

take_users(users);
users.len; // error: users was handed off
```

To replace the caller's binding, return the new container and let the caller
assign it. The full assignment model lives in chapter 17; this section is only
about choosing the right parameter shape for an API. In short: `List<T>` asks
for root handoff, `&List<T>` asks for borrow-based access to the container
object, and `[]T` / `[]const T` ask for a sequence view.

### 16.2 Mutable Views

Element-mutating APIs should accept `[]T`:

```cyna
fn zero(xs: []i32): void {
    var i: usize = 0;
    while i < xs.len {
        xs[i] = 0;
        i = i + 1;
    }
}

zero(scores[..]); // explicit mutable view
```

List-mutating APIs that should preserve the caller's cleanup responsibility take
`&List<T>`:

```cyna
fn add_default(users: &List<User>): void {
    users.push(User { name: "new" });
}

add_default(users); // owned value can be aliased for the call
```

The explicit slice expression is the signal that the callee can mutate elements
in that range. There is no extra `&` because `[]T` is already a range view.

### 16.3 Slice Creation

Slice/view syntax is sequence-only. It is intended for contiguous sequence
storage and sequence-backed containers, not for associative or sparse
container surfaces such as `Map<K, V>` or `Set<T>`.

The intended slice surface is Rust-style range indexing:

```cyna
xs[..]
xs[a..b]
xs[..b]
xs[a..]
```

Semantics:

1. each form creates a non-owning borrowed view
2. none of these forms transfer ownership
3. the source owner must outlive the resulting view
4. the range-based spellings are sequence-only, not a general container hook
   for every iterable type

A fixed array can be sliced:

```cyna
var data: [4]i32 = [4]i32 [1, 2, 3, 4];

var all: []i32 = data[..];
var part: []i32 = data[1..3];
```

A library sequence type opts into direct slicing with `@syntax.slice_view`
on an inherent instance method. The method defines a body, has no method-level
generic parameters, and takes only `self`, borrowed as the enclosing type.
A mutable receiver `&Owner` returns `[]Item`; a read-only receiver
`&const Owner` returns `[]const Item`. Generic owners use their enclosing
generic parameters. Invalid placement, arguments, signatures, and duplicate
methods for the same receiver access are rejected even when unused. If both
access modes are provided, they expose the same item type.

The method name is ordinary. Selection uses the receiver's declaration identity
and accessible annotated methods. Read-only receivers require the const role;
writable receivers prefer the mutable role and fall back to a const role when
there is no accessible mutable role. A missing role is a diagnostic. Private
methods retain ordinary access restrictions, including for generic owners.

The receiver is evaluated once, then its selected method is called under normal
borrow and return-provenance rules, followed by the start and end bounds in
source order. Omitted bounds are zero and the returned view's length. The bounds
must satisfy `0 <= start <= end <= length`; an invalid range fails at runtime.
The attribute does not grant receiver provenance to unrelated storage returned
by the method, or allow a borrow of a local or temporary to escape.

Native array, dense-storage, slice, and string targets retain their intrinsic
construction path. Indexing and iteration roles are separate from slice views.
The compiler does not recognize a library type or method by name.

The standard `List<T>` annotates both `view` and `view_mut`. Direct slices are
preferred when they preserve the intended access:

```cyna
var writable: []User = users[..];
var middle: []User = users[1..3];
var readonly: []const User = users.view();
```

Explicit `view()` remains useful when a writable receiver must produce a
read-only view. All annotated methods remain callable by their ordinary names.

The same spelling is preferred for a `List<T>` field inside an aggregate:

```cyna
var view: []User = bag.users[..];
```

`&bag.users` aliases the `List` object itself; `bag.users[..]` borrows its
elements. These are ordinary, distinct operations.

An owned dense storage value can also produce a borrowed view:

```cyna
var storage: [:]i32 = [1, 2, 3];
var view: []i32 = storage[..];
var tail: []i32 = storage[1..];
```

View forms:

1. `[..]` borrows the full sequence
2. `[a..b]`, `[..b]`, and `[a..]` borrow range-based subviews for fixed arrays,
   dense storage, strings, and existing slices
3. library containers expose direct views through annotated instance methods
4. all slice forms are semantically borrow-producing sequence views, never
   ownership transfer
5. mutation is rejected when it conflicts with a live borrow rooted in the
   affected storage

### 16.4 Slice Lifetime

A slice does not manage memory. It is a temporary view into storage owned by
something else.

```text
List<T> owns growable storage
[N]T    owns fixed storage
[:]T    owns dense owned storage
^T      owns one heap value
[]T     views a range of elements
```

This same non-owning view model also covers `[]const T` and views returned by
operations such as `string.bytes()`. The source may differ, but the lifetime
rule does not: a view is valid only while its source storage remains live.

Creating a slice does not allocate and does not extend the owner's lifetime:

```cyna
var data: List<i32> = list<i32>();
data.push(1);
data.push(2);
data.push(3);
var view: []i32 = data[..]; // views data storage
```

The owner must outlive the slice. Safe code rejects escapes when the slice
provenance does not outlive the destination:

```cyna
fn invalid_local_slice_return(): []i32 {
    var local: [4]i32;
    return local[..]; // error: returns view into local storage
}
```

Returning a slice is allowed only when its provenance traces exclusively to:

1. one or more `[]T`, `[]const T`, or `&T` parameters
2. module-global storage

Subslice, indexing, field projection, local rebinding, helper calls, branch
joins, and loop joins may preserve those roots. They do not create a new
lifetime.

A by-value parameter does not qualify merely because it is a parameter. Its
local parameter storage ends with the call, so a view derived from a by-value
array, struct, string, or container parameter cannot be returned. Local
storage and temporary expression storage also cannot be returned by view.

```cyna
fn first_half(xs: []i32): []i32 {
    return xs[0 .. xs.len / 2]; // valid: derived from parameter view
}

fn invalid_value_param(xs: [4]i32): []i32 {
    return xs[..]; // error: by-value parameter storage ends with the call
}
```

The same rule applies to nested borrowed projections more broadly: a nested
read may still depend on an owner/root, so it carries provenance and remains
subject to invalidation and escape checks rather than becoming detached
ownership.

This remains true even after binding the result to a local name. For example:

```cyna
const a = xs[i].f.g;
```

`a` is a local binding name, but that does not by itself make the value an
owned detached root. In safe v1, if `g` has an owned type, this direct
projection read is rejected because the binding would be handoff-shaped. Spell
the intended operation explicitly:

```cyna
const a = xs[i].f.g.clone(); // owned duplicate, when Clone is implemented
const a = take xs[i].f.g; // detach, only for detachable place kinds
use(&xs[i].f.g);          // alias borrow, where aliasing that place is allowed
use(xs[i].f.g.view());    // ordinary view-producing method, when provided
```

This keeps the user-facing model explicit: direct projected access to an owned
value means attempted handoff; `&` asks for alias borrow; `[..]` asks for a
sequence view borrow.

Projected owned value reads in handoff-shaped positions such as binding,
assignment, return, and owned-value call arguments are rejected unless the
program spells an explicit operation such as `.clone()`, `take`, `&`, or `[..]`
where that operation applies.

Projection is explicit by use:

- `&place.field` requests an alias borrow
- `place.field[..]` requests a slice/view borrow
- `place.field.clone()` requests an owned duplicate
- `take place.field` requests detachment, only where the projected place is
  detachable

Plain projected owned value reads do not implicitly become borrows. They are
treated as attempted handoff and rejected in positions that would move cleanup
responsibility out of an owner without an explicit detach operation.

Conservative sink matrix:

- rejected:
  plain projected owned value flow into binding, assignment, return, and
  owned-value call-argument sinks
- accepted:
  explicit `.clone()` of the projected owned value into those same sinks when the
  type implements `Clone`
- accepted:
  explicit detachable operations such as `take` where the projected place is
  detachable
- not the issue:
  borrowed/read-only projected use such as observation, container queries, and
  borrowed container operations that already have dedicated place-first paths

For stored long-lived data, prefer storing the owner, not the slice:

```cyna
struct Document {
    bytes: List<u8>; // owns data
}
```

If a program needs a long-lived view into another owner, v1 should prefer an
index/range handle over a stored slice:

```cyna
struct Token {
    start: usize;
    len: usize;
}
```

This avoids hidden lifetime machinery while keeping common APIs ergonomic.

### 16.5 Slice Invalidation

While a slice into a growable container is live, operations that may relocate
or destroy that storage are rejected:

```cyna
var users: List<User> = list<User>();
users.push(User { name: "A" });

var view = users.view();

users.push(User { name: "B" }); // error while view is live
```

This is a local invalidation rule, not a global Rust-style lifetime system. The
goal is to reject obvious invalidating mutations without introducing user-visible
lifetime machinery.

When stability across mutation is needed, use indexes:

```cyna
const first_index = 0;
users.push(User { name: "B" });
io.println(users[first_index].name);
```

### 16.6 Element Aliases

Element aliases follow the same invalidation rule as slices: while an alias
into a growable container is live, operations that may relocate or destroy that
storage are rejected.

```cyna
const first = &users[0];

users.push(User { name: "B" }); // error while first is live
```

### 16.7 Container Mutation

Container mutation rules follow the same split as section 16.1: by-value
parameters take the resource, while alias and view parameters borrow access.

Container parameters of owned value type receive a local owned binding:

```cyna
fn take_scores(scores: Map<string, i32>): void {
    ...
}
```

To mutate the caller's container without taking ownership, use an alias
pointer:

```cyna
fn set_score(scores: &Map<string, i32>, name: string, score: i32): void {
    scores[name] = score;
}

set_score(scores, "alice", 99);
```

Use the collection's ordinary `clone()` method when code needs an independent
collection while keeping the original usable:

```cyna
fn normalized(scores: &Map<string, i32>): Map<string, i32> {
    var result = scores.clone();
    result["alice"] = 0;
    return result;
}
```

Container cloning is ordinary library behavior. If a key or value contains
owned values, the container API must provide an explicit element-duplication
policy; `Clone` supplies that policy through explicit implementations.

## 17. Assignment, Clone, and Handoff

Cyna assignment is value-shaped at the syntax level and type-directed at the
semantic level. There are three assignment forms:

```text
new binding       var b = a       copy or hand off from the source
rebinding         b = a           replace the target binding's value
alias write       x = a           when x is &T, write through to the referent
```

For an `&T` alias, `x = a` is the safe write-through spelling; the alias is
fixed and cannot be rebound. Safe `*x = a` is rejected: unary `*` dereferences
raw pointers inside `unchecked`, and it does not select a second spelling for
alias assignment. The alias type at the declaration or parameter is the
visible mutation contract.

For ordinary bindings, the source type decides whether assignment copies a plain
value, shares a value's backing or claim, hands off an owned value, copies a
view or address, or copies an external handle token. For rebinding, the target's
old live owned value is dropped before the new value becomes bound.

The three value behaviors are:

```text
plain                 assignment copies without compiler-tracked cleanup
shared                assignment shares backing or another claim
owned                 assignment hands off cleanup responsibility
```

Alias pointers and slices are non-owning access forms: assignment copies their
carriers and preserves their dependence on source storage. Raw pointers copy an
address without safe provenance. External handles copy a token and follow an
explicit cleanup API protocol.

| Category | Examples | `b = a` means |
|---|---|---|
| plain | `i32`, `bool`, enum, fixed array of plain values | copy the value |
| shared | `string`, `Arc<T>` | share backing or another claim |
| owned | `^User`, `List<T>`, `Map<K,V>`, `Set<T>` | hand off cleanup responsibility; `a` becomes unusable |

A type's assignment category is part of its public contract. Primitive values
and structs containing only plain fields are plain values by default. Types that
own storage or resources, such as `List<T>` or `^T`, are owned values unless
they are explicitly documented with another behavior.

Structs are composite values, not a fourth value behavior or a pointer type.
Their assignment applies each field's behavior recursively:

```text
value field             copy
string field            share immutable backing storage
owned field            hand off
nested struct field      apply the same rule recursively
view or address field    copy the view or address
external handle field    copy the handle token
```

If any field handoff occurs, the source struct binding becomes invalid as a
whole. Cyna does not expose partially-handed-off struct values in safe code.

Example:

```cyna
struct Point {
    x: i32;
    y: i32;
}

struct Image {
    pixels: List<u8>;
}

var p2 = p1; // copies Point fields; p1 remains usable
var i2 = i1; // hands off Image.pixels; i1 is unavailable as a whole
```

For a struct containing mixed fields:

```cyna
struct User {
    id: i32;
    addresses: List<string>;
}

var other = user;
```

is equivalent to:

```text
other.id = user.id;                  // copy
other.addresses = user.addresses;    // hand off owned field
user is now unavailable as a whole
```

Operators:

```text
=     create a binding, rebind an existing binding, or write through an alias
==    compare values according to the equality rules below
!=    negation of ==
clone()  create another value under the type's Clone contract
&     create a fixed alias at call site
```

This is the normative ownership-transfer chapter for the source language.
Earlier chapters may classify a type as a plain value, owned value, view, or
alias, but this chapter is where that classification becomes operational at
assignment sites, call sites, returns, and explicit removal operations such as
`take`.

The `=` line above describes ordinary assignment. Normative examples follow.

### 17.0 Equality Operators

`==` and `!=` are value-comparison operators. They should compare the semantic
value of their operands, not incidental storage identity, except for explicitly
address-like types.

Equality support:

1. integers compare by numeric value
2. floats compare by floating-point value
3. `bool` compares by value
4. enums and flags compare by their represented value
5. `string` compares by byte contents, not backing identity
6. `none` can be compared with an optional value of known type
7. raw pointers and alias pointers compare by address value

Sequence equality:

1. fixed arrays compare element-wise when their lengths and element types match
2. slices compare element-wise when their element types match
3. `[]T` and `[]const T` may compare when their element types match, with
   constness ignored for read-only comparison
4. dense storage `[:]T` compares element-wise by length and contents
5. sparse storage `[;]T` compares by occupied indices and occupied values
6. sequence equality supports integer, float, `bool`, `string`, enum, and flags
   elements

Not provided implicitly:

1. structs do not receive implicit whole-value equality
2. unions and error returns do not receive implicit whole-value equality
3. optional values do not receive implicit whole-value equality; compare with
   `none` for absence checks, then narrow and compare the payload explicitly
4. maps and sets do not receive implicit whole-container equality
5. sequence equality for struct, union, error return, map, set, pointer, optional, or
   nested sequence elements is outside the v1 surface

Sequence equality is length-sensitive. Two sequences of different lengths are
not equal. For sparse storage, two values are equal only when they contain the
same occupied index set and equal values at each occupied index.

Examples:

```cyna
"abc" == "abc"              // true: string contents
"abc".bytes() == "abc".bytes() // true: byte-slice contents
[1, 2, 3] == [1, 2, 3]      // true: fixed-array contents
```

### 17.1 `take` And Optional Places

`take` is a distinct ownership-removing operation:

```cyna
var value = take place;
```

`take place` is not ordinary replacement. Ordinary assignment can already write
`none` into an optional place. The purpose of `take` is to extract the prior
occupant from a place while also installing that place's language-defined
post-take state.

In safe v1, `take place` is valid only when `place` is a writable place of
optional type `?T`. This includes sparse-storage slots, because indexing `[;]T`
produces a place with optional-slot semantics. It evaluates to `?T` and updates
the source place to `none`.

Dense storage indexing does not have this rule. Indexing `[:]T` produces a
dense element place of type `T`, not an optional place, so `take dense[i]` is
not defined in safe v1.

So the distinction is:

- `place = none` replaces or drops the old occupant according to normal
  assignment rules
- `take place` extracts the old occupant as the result, then writes the
  post-take state

Examples:

```cyna
var x: ?i32 = 42;
const y = take x;              // y: ?i32, x becomes none

const profile = take user.profile; // user.profile: ?Profile -> none
const item = take slots[i];        // slots[i]: ?T -> none
```

The core language supports `take` on optional locals, optional struct fields
rooted at mutable locals, optional places reached through array or `[;]T`
indexing paths, and the same supported place shapes when reached through
supported ref roots such as `&?T` and `&[;]T`.

The core language does not support `take` on `[:]T` indexing paths. Dense
storage elements do not have an implicit empty post-state, so removal from
`[:]T` needs an explicit replacement value or a dedicated removal API rather
than `take`.

`take` is ownership-removing. After `take place`, the source place is treated
as having already been rewritten to `none` for later cleanup and later use.
Any value yielded by `take` follows the ordinary ownership rules of its result
binding. The source place cannot still be observed as though it retained the
old occupant.

The core language does not define `take` for list/map indexing sugar.
Detachment from a library container must use an operation whose name states
the container's policy. The current standard-library surface provides:

```cyna
ls.pop()          // detach the last List element
slots.remove(key) // detach a SlotMap entry and invalidate its key
```

Arbitrary-position `List.remove` / `List.swap_remove` and keyed `Map.remove`
are not present in the v1 standard library. They remain API proposals; examples
must not present them as implemented operations.

The user-facing ownership action vocabulary is:

| Action | Meaning |
| --- | --- |
| handoff | transfer a whole owned binding; the source becomes unavailable |
| `.clone()` | invoke the type's `Clone` implementation to create another value |
| borrow/view | grant temporary access without transferring cleanup responsibility |
| detach/remove | extract from a place with a defined post-state or from a container with a named removal policy |

The ownership operation matrix is:

| Place or value | Read/bind owned value | Independent duplicate | Temporary access | Detach/remove |
| --- | --- | --- | --- | --- |
| local owned binding | handoff; source becomes unavailable | `value.clone()` when `Clone` is implemented | `&value` or `value[..]` when supported | not a separate operation |
| owned field | projected handoff rejected | `root.field.clone()` when `Clone` is implemented | `&root.field` or `root.field[..]` when supported | `take root.field` when optional, or `root.field = next @ const old` to replace and capture |
| dense `[:]T` slot | scalar read or explicit clone; ownership handoff rejected | `dense[i].clone()` when supported | `&dense[i]` | named dense/container operation with an explicit replacement policy |
| sparse `[;]T` slot | optional-slot read | copy the present payload explicitly | alias the supported present place | `take sparse[i]` or `sparse.take(i)`; slot becomes empty |
| `List<T>` element | language-hook indexed read; ownership handoff rejected | `list[i].clone()` when supported | `&list[i]` | `list.pop()` for the last element; arbitrary-position removal is not implemented |
| `SlotMap<T>` entry | optional lookup | copy the present payload explicitly | use the supported lookup/capture surface | `slots.remove(key)`; the generation changes |
| `Map<K, V>` entry | language-hook indexed read; ownership handoff rejected | copy through the supported lookup surface | alias through the supported lookup surface | keyed removal is not implemented |

`take` therefore means optional-place detachment. Named container removal
means policy-bearing detachment: the container decides whether elements shift,
swap, or remove an entry by key. Neither spelling is a general-purpose move
from an arbitrary projection.

When a function only needs temporary range access rather than mutation of the
container object itself, programs should prefer a view such as `[]T` instead
of routing the operation through a container-object alias.

When mutation of one nested caller-owned subplace is required, the preferred
safe-v1 spelling is to create or pass the alias at the immediate use site, for
example `rename(&user.profile, "A")`, rather than relying on a broader
borrow-expression composition model.

### 17.2 New Binding

```cyna
var b = a;
```

creates a new binding. The meaning is determined by the assignment category
table above. In particular, owned values hand off to `b` and make `a`
unavailable, while plain values, shared values, views or addresses, and external
handles follow their listed category behavior.

### 17.3 Rebinding

```cyna
b = a;
```

reuses an existing binding. If `b` currently owns a live owned value, that
old value is dropped before `b` is rebound:

```text
evaluate right-hand side
drop old b if b owns a live resource
bind b to the new value
```

The source value `a` still follows its assignment category table entry. If `a`
is an owned value, the handoff occurs after the old `b` value is dropped.

This ordering is normative: for a live owned binding, the previous value is
cleaned up before the new value becomes the binding's current occupant.

```cyna
fn reset_local(xs: List<i32>): void {
    xs = []; // rebinds local xs only
}
```

Rebinding an owned value is cleanup of the old value plus binding of the new
value. It does not imply that heap memory is physically moved or recreated.

### 17.4 Alias Assignment

For an alias pointer, assignment writes through to the aliased storage:

```cyna
fn inc(x: &i32): void {
    x = x + 1; // writes caller's i32
}
```

Assignment cannot run user-defined code except builtin string bookkeeping.

No user-defined implicit copy constructors.

### 17.5 Explicit Clone

```cyna
var b = a.clone();
```

means:

```text
Create another value according to the type's Clone contract.
```

`Clone` is a prelude protocol with one method:

```cyna
protocol Clone {
    fn clone(self: &const Self): Self;
}
```

`value.clone()` evaluates its receiver once and borrows it without handing off
the source. The implementation defines duplication semantics: strings receive
independent backing, standard collections clone their elements, and `Arc<T>`
retains a shared claim. Structs do not automatically implement `Clone`.
Generic functions can declare `T: Clone` and call `value.clone()`.

Dense `[:]T` implements `Clone` only when its elements are safe for descriptor
copy. Values with unique-owned elements require an explicit elementwise clone
or mapping API.

### 17.6 Handoff

Ownership handoff is the assignment-category behavior for owned values:
cleanup responsibility moves to the destination, and the source becomes
unavailable. The same rule applies when a struct assignment hands off any
owned field.

### 17.7 Function Arguments

Parameters introduce local bindings. The parameter type decides what the binding
denotes:

```text
plain T parameter          local copied value binding
shared T parameter         local shared value binding
owned T parameter          local owned binding; caller's value is handed off
x.clone() argument         clone first, then pass the new value
&T parameter               fixed alias to an existing T place
[]T parameter              local view into a mutable range
```

Call-site clarity:

```cyna
f(x);        // copy or handoff according to parameter type
f(x.clone()); // explicitly clone before passing
f(&x);       // create fixed alias when &T is expected
```

Alias pointers:

```text
`&T` is not a rebindable pointer value.
Reading an alias reads the referent.
Assigning to an alias writes the referent.
Assigning one alias to another copies the referent value.
```

```cyna
fn inc(x: &i32): void {
    x = x + 1;
}

fn copy_into(dst: &i32, src: &i32): void {
    dst = src; // copies src's i32 value into dst's referent
}
```

## 18. Storage Lifetime and Cleanup

Cyna cleanup is structured and ownership-driven:

1. stack/value allocation by default
2. `new` for explicit heap allocation
3. explicit current allocator context
4. `defer` for cleanup
5. immutable strings and owned values
6. no hidden heap allocation in low-level APIs unless documented

The compiler tracks cleanup responsibility for owned values such as `^T`,
`[:]T`, `[;]T`, `List<T>`, `Map<K,V>`, and `Set<T>`. A live owned binding is
automatically dropped when its lexical scope exits. This includes early
`return`, `try` error propagation, `break`, `continue`, and normal fallthrough.

Explicit `drop` is therefore an early-release operation, not the normal way to
clean up every owned local.

External resources remain explicit protocol values:

```cyna
const handle = try resource_open(path);
defer resource_close(handle);
```

An external handle is not a language resource type by default. Copying such a
handle copies the handle value; closing it is an explicit library operation.

### 18.1 Defer

`defer` runs a statement at scope exit. Defers run in reverse order.

```cyna
fn use_handle(path: string): void!ResourceError {
    const handle = try resource_open(path);
    defer resource_close(handle);

    try resource_flush(handle);
    return;
}
```

This replaces C's `goto cleanup` pattern without user-defined hidden
destructors.

`defer` is a timing mechanism, not a cleanup kind:

```cyna
const handle = try resource_open(path);
defer resource_close(handle);
```

`defer` does not itself create ownership, transfer ownership, or suppress
ownership invalidation. It only schedules a statement to run on the relevant
control-flow exit path. Language-managed owned values still follow the
ordinary ownership rules for handoff, `take`, auto-drop, and `drop`.

### 18.2 Drop

`drop` ends the storage lifetime of a value early:

```cyna
drop user;
io.println(user.name); // error
```

Use `drop` for owned values such as `^T`, `List<T>`, `Map<K,V>`, and
`Set<T>`, and for aggregates containing owned values when the program needs
the release to happen before scope exit. `drop` is also allowed for `string` to
end the local string lifetime early.

After `drop x`, `x` is unavailable for later reads, writes, handoff, alias
formation, or cleanup. If a later program point is reachable from a path where
`x` was dropped, safe code must treat `x` as unavailable there as well.

Do not use `drop` for external resources such as files, sockets, mutexes, or
threads unless a library explicitly documents a resource wrapper type. Use
the resource API instead:

```cyna
const handle = try resource_open(path);
defer resource_close(handle);
```

Use `free` only for raw/manual allocation APIs:

```cyna
var p: *u8 = memory.alloc(1024);
defer memory.free(p);
```

Rule:

```text
defer = run this later
drop  = end this value's storage lifetime now, before its automatic cleanup point
free  = raw/manual memory release
```

### 18.3 Allocator Contexts

Allocation uses the current allocator context:

```cyna
using alloc = ui.heap {
    const label = $"score: {score}";
    ui.draw_text(label);
}
```

Scoped temporary allocators cannot leak allocated values:

```cyna
fn invalid_scoped_string_return(): string {
    using scoped alloc = frame.arena {
        return $"temporary"; // error
    }
}
```

Container creation remembers its allocator. Handing off a container does not
allocate; a clone that allocates uses the current allocator context.

Raw pointers are not part of the allocator-region ownership model. Allocator
and region checks apply to owned values; raw pointers remain unsafe
addresses used for FFI and low-level operations.

```cyna
fn ok(seed: *Holder): *Holder {
    using scoped alloc = frame.arena {
        var holder = new Holder { label: "" };
        return holder.ptr(); // allowed as raw-pointer flow
    }
}
```

Inside `unchecked`, dereferencing or mutating through a raw pointer remains the
programmer's responsibility even in a scoped allocator region:

```cyna
fn ok(): i32 {
    using scoped alloc = frame.arena {
        var holder = new Holder { label: "" };
        const ptr: *Holder = holder.ptr();
        unchecked {
            (*ptr).label = "temporary";
        }
        return 42;
    }
}
```

This is intentionally simpler than the owned-value model:

1. allocator-region escape checks track owned values
2. raw pointers do not preserve allocator provenance through locals or calls
3. converting an owned value to a raw pointer is an unsafe escape hatch rather
   than a region-tracked reference form
4. ordinary dangling-pointer, aliasing, and invalid-address hazards remain the
   programmer's responsibility under `unchecked`

Model note:

- `using alloc = ... {}` is an allocator-selection boundary. It chooses where
  allocations in the block come from.
- `using scoped alloc = ... {}` is a region boundary. Values allocated in that
  temporary region may be used locally, but they must not escape the block.
- Cyna does not implicitly promote scoped allocations into an outer allocator.
  If a value must outlive the scoped block, it must be created in a non-scoped
  allocator context or later copied into one explicitly.

This design is grounded in two established ideas:

1. region or arena allocation
2. allocator-aware container construction

The region side has strong theoretical precedent: many systems model temporary
allocation with lexical lifetime boundaries and reject values that outlive the
region they were allocated from. Cyna's `using scoped alloc = ... {}` follows
that shape directly.

The allocator-aware container side has strong practical precedent: systems
languages and runtime libraries commonly let containers remember which
allocator created them, and copies allocate in the current allocator. Cyna uses
that same rule for lists, maps, sets, strings, and storage-backed values.

What Cyna guarantees:

1. ordinary allocation uses the current allocator context
2. scoped allocator blocks are temporary regions
3. container creation captures allocator provenance
4. obvious scoped-region escapes are rejected conservatively
5. plain outward-flowing values that do not themselves capture allocator state,
   such as integers read from scoped-owned structs or containers, `none` of an
   optional owned type, or a non-owned active case of a union, may flow
   outward

This also applies when the outward-flowing value is projected from a
scoped-owned aggregate and the compiler can still see that the projected value
itself is non-capturing.

What Cyna does not claim yet:

1. full whole-program escape analysis
2. automatic promotion from scoped to non-scoped allocation
3. function-signature allocation effects in v1
4. a finalized standard-library API for explicit allocator promotion or cloning

## 19. Allocation Behavior

This chapter describes allocation-policy expectations rather than introducing a
separate ownership model. Ownership and cleanup rules still come from chapters
11 and 17-18.

Cyna v1 does not require allocation effects in function signatures. There is no
mandatory `alloc` or `noalloc` marker.

Allocation is controlled by ordinary language and library rules:

1. allocation uses the current allocator context
2. containers capture their allocator when created
3. APIs that may allocate should document that behavior
4. allocation-sensitive code should use preallocated storage and explicit
   assume-capacity operations
5. tooling may analyze or report allocations without requiring source-level
   effect annotations

Example:

```cyna
scores.reserve(1024);

fn update(scores: &Map<string, i32>): void {
    scores.set_assume_capacity("alice", 20);
}
```

Exact standard library names are provisional. The important rule is that Cyna
does not need a function-level allocation marker in v1.

Allocation exposed through ordinary v1 language and container operations is
infallible at the type level. `new T`, owned storage construction, interpolation,
container growth, and `.clone()` do not acquire optional or error-return types merely
because an allocator may be exhausted.

The current failure contract is:

1. hosted execution starts with the system root allocator installed
2. freestanding execution must install a root allocator before allocation
3. attempting allocation without an installed root allocator aborts
4. if the installed allocator returns no storage for a non-zero request,
   execution aborts
5. reallocating and failing to obtain the requested storage also aborts

Allocator-specific recoverable failure is not part of the v1 language surface.
Adding it would change the types and control flow of allocation expressions and
requires a separate language proposal.

# Part IV. Expressions and Execution

This part collects expression-level operational rules that are not primarily
about ownership: integer behavior, control flow, and generic surface rules.

## 20. Integer Behavior

Cyna should improve C's integer hazards.

Numeric literals are contextually shaped:

1. an integer literal with an expected builtin integer type takes that type
   when its value fits
2. a float literal with an expected builtin float type takes that type
3. without a numeric expected type, an integer literal has the compiler
   inference type `int`
4. without a numeric expected type, a float literal has the compiler inference
   type `float`
5. `int` and `float` are inference types, not source spellings for declaring
   storage
6. the v1 runtime carrier is signed 64-bit for `int` and 64-bit IEEE floating
   point for `float`
7. a value outside the inferred integer carrier requires an explicit fitting
   unsigned type

For a rounded coefficient at a `c_float` boundary, first give the literal an
`f32` context, then convert that already rounded value to `c_float`:

```cyna
const coefficient: f32 = 1.660491;
const c_coefficient = coefficient as c_float;
```

Casting the uncontexted decimal directly with `1.660491 as c_float` is a
checked conversion from the wider inferred float value. It can trap when the
decimal is not exactly representable as `c_float`.

There is no automatic `i32` default for an uncontexted integer binding.
Explicit public APIs and stored layout should continue to use named numeric
types.

Rules:

1. Fixed-width integer types are preferred.
2. C ABI integer types are used at C boundaries.
3. No implicit narrowing conversion.
4. No implicit signed/unsigned conversion.
5. No implicit enum/integer conversion.
6. Integer overflow is never undefined behavior.
7. Normal arithmetic traps on overflow.
8. Intentional wrapping uses explicit wrapping operators.
9. `uN` and `iN` are valid for `1 <= N <= 64` in v1.
10. Integer shift operators are `<<` and `>>`; both operands must be integers,
    and the result has the left operand's type.
11. Integer remainder is `%`; its operands must have the same integer type and
    its result has that type. Signed remainder follows truncating division, so
    the remainder has the sign of the dividend. A zero divisor traps.
12. Integer bitwise operators are `&`, `^`, and `|`, in increasing precedence
    order from OR to AND. Their operands must have the same integer type and
    their result has that type. Unary `~` computes the width-preserving bitwise
    complement. These operators also accept values of `flags` types where
    applicable.

```cyna
var x: i64 = 100;
var y: i32 = x;        // error
var z: i32 = x as i32; // checked conversion, traps if out of range
```

The `c_*` integer names are ordinary integer types whose width and signedness
come from the target C ABI. They are not aliases for the fixed-width `iN` /
`uN` family. Examples include `c_short`, `c_int`, `c_uint`, `c_long`,
`c_ulong`, `c_llong`, `c_ullong`, `c_char`, `c_schar`, `c_uchar`,
`c_size_t`, and `c_ptrdiff_t`.

Normal arithmetic is clean:

```cyna
count = count + 1; // traps on overflow
```

Intentional wrapping is visible:

```cyna
hash = hash *% 31 +% byte;
```

V1 wrapping operators:

```text
+%  wrapping add
-%  wrapping subtract
*%  wrapping multiply
```

Less common behavior belongs in library functions:

```cyna
i32.saturating_add(a, b)
i32.checked_add(a, b) // i32!OverflowStatus
```

### 20.1 Casts and Conversions

Cyna avoids C's implicit conversion traps.

No implicit:

1. narrowing numeric conversion
2. signed/unsigned conversion
3. pointer/integer conversion
4. enum/integer conversion
5. string/c_str conversion

Allowed implicit conversions are limited to safe ergonomic views and aliases:

```text
T -> ?T                     value to optional
^T -> &T                    fixed alias to heap value
List<T> -> []const T        read-only view when expected
[N]T -> []const T            read-only view when expected
[:]T -> []const T            read-only view when expected
```

`as` is a checked value conversion in safe code:

```cyna
const small = big as i32;   // traps if out of range
const color = raw as Color; // traps if raw is not a valid Color
```

The safety contract for `as` is:

1. it may change the value representation only through a checked conversion rule
2. it may trap if the source cannot be represented as the target
3. it never reinterprets storage bits as another safe-language type
4. it never forges pointers, aliases, tags, or ownership states

So `as` is for:

1. numeric checked conversion
2. checked enum conversion
3. additional checked value-level conversions with a well-defined validity rule

It is not for:

1. pointer reinterpretation
2. union punning
3. raw layout rebinding
4. ownership/value category changes that would bypass normal ownership rules

`as?` is the fallible checked form:

```cyna
const small = big as? i32;   // ?i32; none when out of range
const color = raw as? Color; // ?Color; none when invalid
```

`as?` follows the same conversion rules as `as`, but returns `?T` instead of
trapping.

`as!` is the explicit bit reinterpretation form:

```cyna
const raw: u8 = 53 as u8;
const reg = raw as! StatusReg;
const raw2 = reg as! u8;
const float_bits: u32 = 0x40400000;
const value = float_bits as! f32;
const back = value as! u32;
```

The safety contract for `as!` is:

1. it preserves the source bit pattern exactly
2. it changes interpretation, not value semantics
3. it requires compile-time proof that the source and target have the same bit width
4. it is never fallible; there is no `as!?`
5. it does not forge pointers, aliases, tags, or ownership states

There is no broad implicit coercion system. Inference is allowed, but implicit
conversion is deliberately narrow and predictable.

Current implicit behavior is:

1. identity
2. contextual shaping such as `T -> ?T`
3. literal shaping into the expected builtin numeric type
4. `char` literal shaping into `char` or a representable integer type
5. mixed numeric binary operators where `int` is promoted to the other
   operand's float type

Examples:

```cyna
const x: i32 = 42;   // integer literal shaped by context
const y: f32 = 1.5;  // float literal shaped by context
const ch: char = 'A'; // char literal shaped by context
const b: u8 = 'A';    // ok: U+0041 fits u8
const z = 1 + 1.5;   // int promoted to float, result is float
```

Mixed numeric promotion is intentionally narrow:

1. it applies only to arithmetic and numeric comparison operators
2. it promotes `int -> float` only when the other operand is already float
3. it does not create a general scalar coercion system

The following still require an explicit cast:

1. `i64` to `i32`, `u8`, `usize`, or any other different integer type
2. `c_short` to `c_int`, `c_int` to `c_short`, `c_uint` to `usize`, and other
   conversions between distinct C ABI integer types
3. `f64` to `f32`, or `f32` to `f64`
4. `enum` to `int`, and `int` to `enum`
5. optional unwraps
6. union payload extraction by target type
7. packed struct to integer reinterpretation
8. integer to packed struct reinterpretation

The following are rejected rather than implicitly coerced:

1. integer-width mixing such as `i32 + i64`
2. C ABI integer mixing such as `c_short + c_int` or `c_int + c_uint`
3. float-width mixing such as `f32 + f64`
4. numeric-to-enum conversion without `as` / `as?`
5. optional-to-payload conversion without `as` / `as?`
6. union-to-payload conversion without `as` / `as?`
7. pointer reinterpretation, union punning, and raw layout rebinding
8. packed/int representation rebinding without `as!`

### 20.1.1 Checked Cast Rules

`as` is an explicit checked conversion. It either succeeds or traps at runtime.

`as?` is the explicit fallible form. It follows the same conversion rules as
`as`, but returns `?T` and yields `none` on failure instead of trapping.

Integer casts are defined in terms of the source and target semantic widths,
not backend carrier widths. An implementation may widen values internally, but
cast success/failure and the resulting value must be exactly what the source
types require.

Allowed checked conversions are:

1. `int -> int`
   Rule: the source value must fit the target integer range exactly.
   This includes casts between fixed-width integer types and C ABI integer
   types such as `c_short`, `c_int`, `c_uint`, `c_long`, `c_ulong`,
   `c_size_t`, and `c_ptrdiff_t`.
   Widening casts that are statically known to fit are allowed:

```cyna
const a: c_short = 42;
const b = a as c_int;   // always succeeds
const c = a as? c_int;  // always returns some(42)
```

   Narrowing or signedness-sensitive casts remain checked:

```cyna
const raw: c_int = 100000;
const small = raw as? c_short; // none when raw does not fit
```
2. `int -> float`
   Rule: the source value must be exactly representable in the target float
   type.
3. `float -> int`
   Rule: the source value must be finite, integral, and in range.
4. `float -> float`
   Rule: the source value must be finite. Narrowing must be exact. Widening is
   allowed.
5. `int -> enum`
   Rule: the integer must satisfy the enum's validity rule.
   `enum`: must match a declared case exactly.
   `flags`: may only contain declared bits.
   `c enum`: any integer value is accepted.
6. `enum -> int`
   Rule: explicit only. This is part of the checked conversion surface even
   though every valid enum value can be represented by its backing integer type.
7. `?T -> T`
   Rule: allowed only when the optional payload type is exactly `T`.
8. `Union -> T`
   Rule: allowed only when the union has exactly one payload case of type `T`.

Conversions that must use `as?` rather than `as` are the ones where failure is
an expected control-flow outcome instead of a bug. Typical examples are:

1. narrowing integer casts from untrusted data
2. `float -> int` when fractional input is normal
3. `int -> enum` when the raw value may be invalid
4. optional unwraps that may legitimately see `none`
5. union payload extraction when multiple tags are expected in normal flow

Conversions rejected at compile time are:

1. casts not listed above
2. union payload casts when more than one payload case has the target type
3. pointer reinterpret casts
4. raw layout rebinding through `as` / `as?`
5. ownership or ownership-category changes through `as` / `as?`

### 20.1.2 Bitcast Rules

`as!` is the explicit bit reinterpretation operator.

Current allowed `as!` conversions are:

1. `int -> packed struct`
   Rule: the source integer type must have an explicit semantic width, the
   target must be a packed struct, and the widths must match exactly.
2. `packed struct -> int`
   Rule: the source must be a packed struct and the target integer type must
   have exactly the same semantic width.
3. `int -> raw pointer`
   Rule: this is an explicit unchecked address reinterpretation used for
   low-level code such as MMIO register bases. `*volatile T` is allowed here.
4. `raw pointer -> int`
   Rule: this is the explicit inverse address extraction form. The target
   integer type must be explicit.

Examples:

```cyna
packed struct StatusReg {
    ready: u1;
    mode: u3;
    error: u4;
}

const raw: u8 = 53 as u8;
const reg = raw as! StatusReg;
const roundtrip = reg as! u8;
```

Notes:

1. integer literals do not by themselves supply a bit width for `as!`
2. write an explicit integer type first when needed, such as `53 as u8`
3. `as!` is intentionally narrower than `as`; it is for representation-only
   rebinding

Current rejected `as!` conversions are:

1. pointer-to-pointer reinterpretation
2. alias pointer or owned pointer rebinding
3. string, container, error-return, optional, union, or owned-value bitcasts
4. any source/target pair whose semantic bit widths do not match exactly for
   packed-struct/int rebinding

Principle:

```text
implicit conversion only for safe views/aliases
explicit checked conversion for value changes
separate builtin intrinsics for exact-bit reinterpretation
unchecked for representation tricks beyond the safe model
```

## 21. Control Flow

Cyna uses modern C-like control flow with required braces and no mandatory
condition parentheses:

```cyna
if x > 0 {
    ...
} else if x == 0 {
    ...
} else {
    ...
}

while i < n {
    ...
}
```

Iterable values:

```cyna
for user in users {
    ...
}
```

`for item in xs` uses the iterable behavior of `xs`. Arrays, slices, and
standard containers are iterable. Custom struct types opt into the current
surface through the iterator language hooks specified in section 22.3.

`break;` exits the nearest enclosing `while` or `for` loop. `continue;`
starts its next iteration. Both require an enclosing loop in the same function;
a nested switch does not change their target. Exited scopes run their defers
and owned-value cleanup. Ownership and borrow facts from each break path join
the loop's normal exit, rather than its next-iteration state. Break labels and
break values are not supported.

`switch` over enums and unions should be exhaustive unless a final `_` arm is present.
Enum switch cases may use `.case` because the switch subject supplies the enum type;
`Enum.case` remains valid when the type is written explicitly.
An explicit empty `_ => {}` still counts as a wildcard arm and may be used when
the unlisted cases intentionally do nothing:

```cyna
switch color {
.red => {
    ...
}
.green => {
    ...
}
.blue => {
    ...
}
_ => {}
}
```

Every arm uses `pattern => { statements }` or `pattern => expression;`. The short
form yields its expression as the switch value. A block arm uses `yield value;`
to finish the nearest switch arm; `return` still exits the enclosing function.
An arm may also use `pattern => throw code;` or `pattern => return value;`
when it exits the enclosing function.
Direct `panic(message);` and `assert(false);` calls are also valid concise
arms because they terminate control flow.
`unreachable;` explicitly marks a path that must never execute. It terminates
control flow and traps if reached, including in a concise switch arm.
`yield;` finishes a void arm, including an arm in a statement-used switch.
An arm of a non-void switch expression must yield a compatible value or leave
through a guaranteed exit. `yield` can appear in an arm's nested `if` or loop;
a nested switch establishes its own yield target. A nested function cannot
yield to an outer switch.

```cyna
const label = switch status {
.ready => "ready";
.failed => {
    log_failure();
    yield "failed";
}
_ => "unknown";
};
```

Integer and `string` subjects are supported. Integer patterns accept literals,
constant arithmetic, and named compile-time integer constants; the resulting
value must fit the subject type. String patterns must be quoted literals and
compare by decoded contents. Runtime values cannot be patterns. Integer and
string switches require a final `_` arm, even when used as statements. `_`
must be last and may be the only arm.

Optional and named-union narrowing use `is`:

```cyna
if user is u {
    io.println(u.name);
}

if token is .key(key) {
    handle_key(key);
}
```

The `start..end` range is half-open. Additional range forms are outside the v1
surface.

### 21.1 Evaluation Order

Expressions with multiple evaluated children use a defined order. In
particular, a struct literal evaluates field initializer expressions in the
order in which fields are written at the construction site. Physical field
layout remains declaration-ordered; evaluation order and layout are separate
concepts.

```cyna
struct Pair {
    first: i32;
    second: i32;
}

const pair = Pair {
    second: record(2),
    first: record(1),
};
```

`record(2)` runs before `record(1)`. Each field initializer is evaluated
exactly once, then its result is placed into the layout slot for the named
field. This source-order rule also applies to ownership handoff performed by a
field initializer.

## 22. Generics and Polymorphism

Cyna has simple monomorphized generics:

```cyna
struct Pair<T, U> {
    first: T;
    second: U;
}

fn identity<T>(x: T): T {
    return x;
}
```

V1 generic rules:

1. generic functions and types are monomorphized
2. no specialization in v1
3. no arbitrary C++-style template metaprogramming in v1
4. generic behavior is passed explicitly unless a protocol is used
5. bare generic parameters are type parameters
6. `T: Protocol` is a protocol-constrained type parameter
7. `const N: usize` is the canonical spelling for a compile-time value
   parameter

Ownership requirements are inferred from use inside the generic body. `Clone`
is an explicit protocol bound: a generic function that calls `value.clone()`
on `T` declares `T: Clone`, and each concrete instantiation must conform.

Operator requirements are likewise checked from the generic body after
instantiation; they are not inferred as protocol constraints. `Set<T: Eq>` and
`Map<K: Eq, V>` declare their equality requirement explicitly and call
`.eq(...)`; this does not change the separate rule that `==` is compiler-known
and not protocol-backed in v1.

The compiler retains inferred operations and declared protocol method uses as
separate structured SIR facts, so the contract is reviewable without forcing an
instantiation. Running
`cyna build --emit-sir` emits deterministic entries of this form before the
lowered declarations:

```text
requires module::declaration<T>: copy @+source_offset
requires module::declaration<T>: eq @+source_offset
requires module::declaration<T>: copy @+source_offset [projection]
requires module::declaration<T>: hash @+source_offset [declared module::Hash]
```

Each distinct declaration/parameter/operation/origin-class/authority tuple appears once;
declared method authority includes the protocol identity. An inferred operator
`eq` and a declared protocol method `eq` therefore remain separate facts. The offset
identifies the body operation that introduced it. `[projection]` marks an
inferred operation on a generic-derived projection rather than on the parameter
itself; it does not transfer that parameter's declared protocol authority to
the projected type. Local aliases and resolved generic fields retain their
symbolic origin in both inferred-operation and declared-method inspection.
When an instantiation fails,
the compiler diagnoses the call site, links the generic declaration, and keeps
the operation-level body diagnostic as the concrete reason.

Example without protocol constraints:

```cyna
fn sort<T>(xs: []T, less: fn(a: T, b: T): bool): void {
    ...
}
```

### 22.1 Compile-Time Value Generics

Cyna's canonical compile-time value generic surface is intentionally narrow:
values that are part of type layout or static storage shape.

Value generic parameters are introduced with `const`:

```cyna
struct Pool<T, const N: usize> {
    storage: [N]T;
    len: usize;

    fn capacity(self: Pool<T, N>): usize {
        return N;
    }
}
```

The `const` marker distinguishes value parameters from protocol-constrained
type parameters:

```cyna
fn sort<T: Ord>(xs: []T): void { ... }          // T is a type parameter
struct Ring<T, const N: usize> { data: [N]T; }  // N is a value parameter
```

The initial value parameter type set is intentionally small:

```text
usize
```

Other integer widths, booleans, enums, arithmetic over generic values, and
const function evaluation are not part of this surface unless separately
specified.

Use value generics for static storage abstractions such as pools, ring buffers,
slot maps, and bit sets whose capacity is part of the type.

### 22.2 Protocols

Cyna supports simple explicit protocols for practical polymorphism. Prefer
adjective or capability names for protocols where the domain allows it:
`Readable`, `Writable`, `Seekable`, `Hashable`.

```cyna
protocol Writable {
    fn write(self: &Self, bytes: []const u8): IoStatus;
}
```

A source-defined conformance owns its protocol method bodies:

```cyna
struct FileWriter {
    file: File;
}

impl FileWriter: Writable {
    fn write(self: &FileWriter, bytes: []const u8): IoStatus {
        return fs.write(self.file, bytes);
    }
}
```

A generic implementation defines a family of concrete conformances for an
owned nominal generic type:

```cyna
impl<T: Eq> Box<T>: Eq {
    fn eq(self: &const Box<T>, other: &const Box<T>): bool {
        return self.value.eq(&other.value);
    }
}
```

This is a generic implementation of the ordinary, non-generic `Eq` protocol.
For each concrete `Box<X>` where `X: Eq`, the compiler materializes one
canonical `(Box<X>, Eq)` conformance and specializes its witness bodies with
`T = X`.

Generic impl parameters correspond directly to every parameter of the subject
type constructor. Type and `const N: usize` parameters are supported. Subject
arguments must be those parameters directly and in declaration order; partial
specialization such as `impl<T> Box<List<T>>: Eq` is invalid. Two family impls
for the same nominal subject and protocol are invalid even when their bounds
differ. There is no overlap ranking or specialization.

The declaring package must own the nominal subject. A conformance condition
that is not satisfied means that the concrete conformance does not exist; it
does not select a fallback implementation.

The methods in an `impl` are protocol witnesses, not inherent methods in the
type namespace. Every required protocol method must appear exactly once, and
the impl cannot contain methods absent from the protocol. A protocol method
name must not conflict with an inherent method of the subject type.

Protocols may declare shallow associated types, and every source impl binds
each one exactly once:

```cyna
protocol Source {
    type Item;
    fn get(self: &const Self): Self.Item;
}

impl<T> Box<T>: Source {
    type Item = T;
    fn get(self: &const Box<T>): T { return self.value; }
}
```

`T.Item` is valid when `T` has a unique protocol bound declaring `Item`.
Associated types may be exact reference or optional types. Recursive
projection chains, generic associated types, associated constants, defaults,
and projection-specific `where` clauses are not supported.

An explicit qualified call such as `Source.get(value)` chooses that protocol's
canonical witness. It is the ambiguity escape hatch; it does not introduce
overload ranking.

Generic constraints use protocol names. Multiple protocol constraints use `&`:

```cyna
fn copy_all<T: Readable & Writable>(stream: &T): IoStatus {
    ...
}
```

Noun names are still fine when the domain term is naturally a capability, but
the general convention is:

```cyna
protocol Readable { ... }        // behavior/capability
union Stream = FileStream | ...; // runtime category/value type
```

Protocols are static capability contracts for explicit conformance and generic
constraints. A `protocol` does not imply runtime protocol values, vtables,
object-safety rules, or class-style dynamic dispatch.

Type unions are the closed-runtime-dispatch path for v1. A type union is a
normal value type that can be switched exhaustively, and explicit derived
protocol implementations synthesize forwarding over concrete struct variants
when every variant implements the protocol.

V1 protocols are intentionally simple:

```text
protocol defines required functions
impl Type: Protocol { ... } defines explicit conformance witnesses
impl<T: Bound> Type<T>: Protocol { ... } defines conditional family witnesses
protocol may define shallow associated types bound exactly once by each impl
generic constraints reuse protocol names
multiple constraints use T: A & B
no generic protocols, specialization, or runtime protocol-object complexity in v1
```

Syntax capabilities use the compiler-owned prelude protocols documented in
22.3. The compiler resolves those declarations to identity; it does not
discover user methods by reserved spelling.

Standard protocol implementations for primitive and built-in types are
ordinary, source-visible implementations in compiler-owned modules:

```cyna
impl i32: Eq {
    fn eq(self: &const i32, other: &const i32): bool {
        return value_eq(self, other);
    }
}
```

When a core implementation needs an operation that ordinary Cyna cannot
express, a compiler-owned top-level declaration may name that operation with
`@intrinsic("stable.id")`. Intrinsic authority comes from loader-verified
compiler-package provenance; a module name, filename, or source attribute
alone cannot grant it. Intrinsic declarations have no body and user packages
cannot declare them. Protocol dispatch itself always selects an ordinary
source method witness.

For low-level C-style polymorphism, explicit function-table structs are still
allowed:

```cyna
struct RawWriter {
    ctx: *void;
    write: fn(ctx: *void, bytes: []const u8): IoStatus;
}
```

Callable rules:

- `fn(...)` is the Cyna function-pointer signature spelling
- `(...) => R` is the Cyna-native non-escaping callable parameter spelling
- `c fn(...)` is the C ABI function-pointer spelling
- a stored callable must be representable as a non-capturing function pointer
- a named function is always a non-capturing function pointer
- a non-capturing lambda may coerce to a function pointer
- a capturing lambda is allowed only for direct call arguments to Cyna-native
  non-escaping callable parameters
- a `fn(...)` value may adapt to a non-escaping callable argument
- a non-escaping callable value does not coerce back to `fn(...)`
- `c fn(...)` never captures

Lambda expressions:

```cyna
fn sort<T>(scores: []T, less: (T, T) => bool): void { ... }

sort(scores, |a, b| {
    return a < b;
});

const less: fn(i32, i32): bool = |a, b| {
    return a < b;
};

const explicit: fn(i32, i32): bool = |a: i32, b: i32|: bool {
    return a < b;
};

register(c fn(value: c_int): c_int {
    return value + 1;
});
```

A lambda expression is written `|params| { body }`. It has no independent
storable type in v1; it is target-typed by an expected `fn(...)` or
`(...) => R` signature. If the lambda is target-typed as `fn(...)`, it is a
function pointer and cannot capture locals. If it is target-typed as a
non-escaping callable, captured locals are copied into a call-local environment
at the call site.

Stored callable positions include local initializers, global initializers,
struct fields, array elements, and return expressions. In these positions, a
lambda must be non-capturing because the stored representation is a function
pointer.

Non-escaping callable types are argument types, not storable closure values. In
v1 they are parameter-position types:

```cyna
fn each<T>(items: []T, visit: (T) => void): void { ... }
fn transform<T, U>(item: T, map: (T) => U): U { ... }
```

Typing rules:

- `|a, b| { ... }` uses contextual typing from an expected Cyna `fn(...)` or
  non-escaping callable signature
- without an expected callable type, parameter types and the return type must be
  explicit enough to determine the full callable signature
- a lambda follows normal function return rules
- a lambda cannot be used where a `c fn(...)` type is expected
- `c fn(...) { ... }` remains the explicit C ABI non-capturing function-pointer
  expression form

Generic rules:

- A generic function call may infer type arguments from its parameter values
  and from an expected return type supplied by a typed binding, assignment,
  return, or argument position. Conflicting inferences are an error.
- Contextual call arguments are checked after generic arguments can be inferred
  from independent arguments and the expected return type. The expected payload
  type also flows through `try` to a result-returning call; its error type must
  still satisfy the enclosing function's result contract.
- lambda expressions do not introduce their own type parameters
- lambda expressions may use type parameters already in scope from an
  enclosing generic function, generic method, or generic owner type
- after generic instantiation, every lambda must have a concrete `fn(...)` or
  non-escaping callable signature

This is allowed:

```cyna
fn use_identity<T>(value: T): T {
    const id: fn(T): T = |x| {
        return x;
    };
    return id(value);
}
```

This is not allowed:

```cyna
const id = |x: T|: T {
    return x;
}; // error unless `T` is already in scope from an enclosing generic declaration
```

Capture rules:

- a lambda may reference its own parameters
- it may reference globals, constants, functions, types, imports, and generic
  type parameters already in scope
- if it is target-typed as `fn(...)`, it may not reference locals or parameters
  from the enclosing function body
- if it is passed directly to a Cyna-native non-escaping callable parameter, it may
  capture locals by value for the duration of the call

For example:

```cyna
const offset = 1;

fn apply_global_offset(xs: []i32): void {
    each(xs, |x| {
        return x + offset;
    }); // valid: `offset` is global
}

fn apply_local_bias(xs: []i32): void {
    const bias = 1;
    each(xs, |x| {
        return x + bias;
    }); // valid: direct non-escaping callable argument captures `bias`
}

fn invalid_stored_capture(): fn(i32): i32 {
    const bias = 1;
    return |x| {
        return x + bias;
    }; // error: stored function pointers cannot capture `bias`
}
```

Captured lambdas are non-escaping callable arguments, not storable closure
values. Low-level stored callback APIs must use explicit context values,
typically a `ctx` pointer plus a function pointer field.

This is an intentional refactor boundary:

```cyna
fn apply(value: i32, callback: (i32) => i32): i32 {
    return callback(value);
}

fn direct_capture(): i32 {
    const bias = 1;
    return apply(41, |value| {
        return value + bias;
    }); // accepted: the capture environment ends with apply
}
```

Naming that capturing lambda as an intermediate callback is not a semantics-
preserving refactor, because there is no storable closure representation:

```cyna
const callback: fn(i32): i32 = |value| {
    return value + bias;
}; // error: fn(...) is non-capturing
```

The supported alternatives are to keep the lambda as the direct argument to a
`(...) => R` parameter, use a named/non-capturing `fn(...)`, or store explicit
context beside a function pointer. The compiler diagnostic must state both the
call-local lifetime rule and these alternatives.

Example std-facing use:

```cyna
import std.io;

type WriterWriteFn = c fn(*c_char, c_llong, ?*c_void): void;

std.io.install_writer(sink_write, none);
```

`std.io` currently exposes the callback and context as separate arguments.
There is no public `Writer` wrapper in v1. User code should install writers
through this module rather than binding lower-level runtime symbols directly.

Here `ctx` is explicit callback state supplied by the caller. It replaces
closure capture for low-level callback APIs.

The allocator surface follows the same pattern. User-facing allocator
installation lives in `std.alloc`:

```cyna
import std.alloc;

struct RootAllocator {
    ctx: *c_void;
    alloc_fn: c fn(*c_void, c_size_t): *c_void;
    realloc_fn: c fn(*c_void, *c_void, c_size_t): *c_void;
    free_fn: c fn(*c_void, *c_void): void;
}

std.alloc.install_root_allocator(RootAllocator {
    ctx: 0 as! *c_void,
    alloc_fn: my_alloc,
    realloc_fn: my_realloc,
    free_fn: my_free,
});
```

`init_bump_root(heap: []u8)` is the convenience entry point over that same
root-allocator installation model rather than a separate allocator mechanism.

### 22.3 Syntax Attributes

User-defined indexing and iteration use explicit attributes on inherent instance
methods. The prelude no longer declares `Index`, `IndexSet`, or `Iterable`.
Ordinary method names and protocol conformances grant no syntax role.

| Attribute | Parameters after `self` | Receiver | Result |
| --- | --- | --- | --- |
| `@syntax.index` | `key: Key` | `&const Owner` | `Output` |
| `@syntax.index_set` | `key: Key, value: Input` | `&Owner` | `void` |
| `@syntax.iter` | none | `&const Owner` | `State` |
| `@syntax.iter_has_next` | `state: &const State` | `&const Owner` | `bool` |
| `@syntax.iter_next` | `state: &State` | `&const Owner` | `Cursor` |
| `@syntax.iter_item` | `cursor: Cursor` | `&const Owner` | `Item` |

Attributes take no arguments. Each role is unique per owner and cannot be
combined with other method attributes. Methods have explicit `self`, use their
owner's declared generic arguments, and add no method generic parameters.
Malformed declarations and duplicate roles are rejected even when unused.
`Output`, `State`, `Cursor`, and `Item` are non-void; their types come from
ordinary method signatures, not associated-type declarations. Iteration
requires all four roles, with matching state and cursor types. Alternative
iteration behavior uses nominal adapters, such as map `keys()` and `values()`.

`value[key]` invokes the accessible index role. An alias result forms an indexed
place with that alias's capability; a value result does not form an aliasable
place. Reading an owned value does not implicitly copy it. Indexed
assignment invokes the setter role using normal mutation, argument handoff,
and live-borrow rules. Native arrays, storage, slices, and strings keep their
intrinsic paths.

For `value[key]` and `value[key] = input`, an index hook with an integer `Key`
accepts any integer expression, as intrinsic indexing does. Before the hook is
called, the key is checked and converted to the hook's declared integer type;
the operation traps if the value cannot be represented. This rule applies only
to index syntax. An ordinary method call to the hook follows normal parameter
typing, and hooks with non-integer keys require their declared key type.

Receivers and arguments are evaluated once in source order. A library loop
initializes state once, checks for another cursor, advances state, and reads
its item; `break`, `continue`, and cleanup preserve ordinary loop rules.
Borrowed elements are observed without implicit ownership transfer. All roles
must be accessible at the use site. Renamed methods behave identically;
lowering carries declaration and syntax-role identities, not reserved names.

To migrate, move conformance methods into the owning struct, annotate each,
expose methods needed by importing modules, and remove the conformance and its
associated-type declarations. Explicit method calls remain ordinary calls.
`Eq` and `Hash` remain ordinary capability protocols.

`in` is not a language hook. It is a closed operation on `flags`: `bit in set`
tests whether every bit in `bit` is present in `set`. Collections use their
ordinary `contains` methods. This deliberately avoids introducing a generic
membership protocol, protocol parameters, or an associated item type solely
to save a method call.

`Clone` is a prelude protocol. Builtin `string` and eligible `[:]T` storage
have compiler-owned implementations; library types implement the protocol
through ordinary methods (see §17.5).

# Part V. Interoperability and Ecosystem

This part records how Cyna fits into real projects: ABI boundaries, low-level
escape hatches, standard-library expectations, tooling shape, and language
scope.

## 23. C Interop

`extern c`, `export c`, `c struct`, `c union`, and `c enum` are one unified C ABI
surface.

The rule is:

1. `extern c` imports declarations that follow the target platform's C ABI
2. `export c` exports declarations that follow the same target platform C ABI
3. C-layout declarations such as `c struct` must use that same target C ABI
   layout model
4. Cyna runtime carriers are not admitted merely because their implementation
   happens to have a C representation

The public `extern c` / `export c` contract is strict C ABI. Compiler-runtime
bridges may use a separately gated internal ABI, but that internal privilege
does not expand the source-level C boundary.

### Canonical Declaration Spellings

The semantic keywords `extern`, `export`, `c`, `asm`, and the type spelling
`c fn(...)` are permanent parts of the v1 language. They are the canonical
source spellings for the core C/assembly ABI concepts and are not scheduled for
deprecation.

The accepted declaration-attribute equivalents are:

| Canonical keyword form | Accepted attribute-equivalent form |
| --- | --- |
| `extern c("symbol") fn ...;` | `@abi("c") @link.import("symbol") fn ...;` |
| `export c("symbol") fn ... {}` | `@abi("c") @link.export("symbol") fn ... {}` |
| `export asm("symbol") const ...;` | `@asm.export("symbol") const ...;` |

Both forms lower to the same ABI kind, symbol identity, validation rules, and
backend contract. Attribute order does not change their meaning. A declaration
cannot combine conflicting import/export directions or combine keyword and
attribute forms into a different ABI. Formatters do not silently migrate one
accepted family into the other.

Attributes are canonical for compiler-known declaration metadata that has no
semantic keyword, including `@concurrency.isolated` and trusted std/compiler contracts.
Unknown attributes are errors. Parameter attributes, type attributes, and
alternative attribute spellings for `c fn(...)` are outside v1.

The concurrency attributes have distinct contracts:

| Attribute | Valid declaration | Meaning |
| --- | --- | --- |
| `@concurrency.isolated` | Cyna function or method with a body | The compiler checks reachable calls and access to mutable global state under the isolated function rules. Worker entrypoints do not need this attribute when the compiler can inspect their reachable calls. |
| `@concurrency.shareable` | Non-packed struct in a trusted std/core module | The type's implementation promises that values can cross a worker boundary and be shared across workers. The compiler accepts this promise without checking the struct's fields for those capabilities. |
| `@concurrency.trusted_extern` | Imported extern function | The declaration author promises that the opaque call is safe to use from isolated or worker code. The compiler cannot inspect the foreign body. |

`@ownership.owned` and `@ownership.shared` govern value handoff and backing
storage. They do not grant either concurrency capability. Application code
normally uses the `std.sync` types and inferred worker checks rather than these
trusted declarations. The former `@sync_resource`, `@unchecked_thread_safe`,
and `@isolated` spellings are no longer accepted.
`@concurrency.isolated` is a limited static check, not a proof that every
runtime effect or foreign function body is safe.

ABI boundary specifiers have an optional external-name override:

```cyna
c
c("external_symbol")
asm
asm("external_name")
```

When the override is omitted, the external name is the ABI's conventional Cyna
name for that boundary. For C ABI declarations, this is the compiler-generated
Cyna symbol name. Use `c("external_symbol")` when the declaration must bind an
exact external linker/C symbol. For assembly constants, the conventional name is
the constant declaration name.

C ABI import:

```cyna
extern c("strlen") fn strlen(text: c_str): c_size_t;
extern c("puts") fn puts(text: c_str): c_int;
extern c("malloc") fn malloc(size: c_size_t): ?*c_void;
extern c("free") fn free(ptr: ?*c_void): void;
```

Extern functions are private to their module by default. `pub extern c... fn`
makes the imported function visible to other Cyna modules through normal imports
while preserving the same C ABI symbol binding.

The canonical extern block form puts the ABI specifier on each member:

```cyna
extern {
    pub c("strlen") fn strlen(text: c_str): c_size_t;
    c("puts") fn puts(text: c_str): c_int;
    c("malloc") fn malloc(size: c_size_t): ?*c_void;
    c("free") fn free(ptr: ?*c_void): void;
}
```

Optional symbol aliases live on the ABI specifier:

```cyna
extern c("puts") fn platform_puts(text: c_str): c_int;
```

An `extern` block member without a `c("...")` override uses Cyna's conventional
generated C ABI name:

```cyna
extern {
    c fn internal_runtime_hook(): void;
}
```

Extern globals use the same surface:

```cyna
extern {
    c("errno") var errno_value: c_int;
    c("__bss_start") const __bss_start: *u8;
    c("__bss_end") const __bss_end: *u8;
}

extern c("errno") var errno_value: c_int;
```

Ordinary extern globals import external storage. Raw-pointer extern globals are
imported as symbol addresses, which makes linker-defined section markers and
startup boundaries usable directly from freestanding code.

The effective C symbol name must usually be unique across C ABI declarations in
the program, whether it comes from the Cyna function name or an explicit alias.
The exception is a declaration/definition pair: one `extern c... fn`
declaration may share a symbol with one matching `export c... fn` definition
when their C ABI signatures are identical. This supports freestanding and
kernel-style platform hooks where shared code declares a symbol and the selected
platform defines it.

```cyna
extern c("cycor_console_putc") fn platform_putc(ch: c_uchar): void;

export c("cycor_console_putc") fn qemu_putc(ch: c_uchar): void {
}
```

Duplicate definitions remain invalid, and an extern/export pair with different
parameter or return types is rejected.

C ABI export:

```cyna
export c fn cyna_add(a: c_int, b: c_int): c_int {
    return a + b;
}

pub export c("cyna_visible") fn visible(a: c_int): c_int {
    return a;
}
```

Exported C ABI functions are private to Cyna modules by default. `pub export c
fn` also makes the function visible through normal Cyna imports; the C ABI
exported symbol behavior is otherwise unchanged.

The older trailing string alias form is rejected. Use the ABI-specifier form
instead:

```cyna
export c("external_name") fn local_name(): void {
}
```

C-compatible structs:

```cyna
c struct Image {
    data: *u8;
    width: c_int;
    height: c_int;
}
```

C ABI rules:

1. `c_*` scalar names use the target C ABI width and signedness, not a fixed
   language-wide width.
2. C ABI declarations use those target widths in function signatures and
   `c struct` fields.
3. By-value `c struct` parameters and returns follow the target platform's C ABI
   passing rules, not a source-level field-by-field transport model.
4. This means small `c struct` values may be passed or returned through a
   coerced scalar/register form when the platform ABI requires it.
5. `export c` uses the same calling convention and aggregate passing rules as
   `extern c`.
6. Function pointers stored in `c struct` fields or passed through C ABI
   signatures must also use the C ABI.
7. Types without a specified C ABI representation are rejected at C boundaries.

Target-specific callable aggregate rules are part of Cyna's public C ABI
contract:

1. On `aarch64-none-elf` and `aarch64-apple-darwin`, C-layout aggregate
   boundary values larger than 16 bytes are passed indirectly and returned with
   an indirect return slot.
2. On those AArch64 targets, C-layout aggregate boundary values up to 16 bytes
   remain direct values.
3. On `x86_64-none-elf` and `riscv64-none-elf`, large `c struct` aggregate
   values remain direct unless a narrower platform rule is documented here.
4. On `aarch64-apple-darwin`, an 8-byte `c struct` boundary value may be coerced
   to the ABI scalar register form required by the platform ABI.
5. These rules apply equally to `extern c` and `export c`; a Cyna declaration
   must not require users to manually spell the ABI transport form in source.

Architecture-specific ABI behavior must be documented here before it is treated
as supported. It must also have target-specific compiler coverage, usually as a
backend or parity test that checks the emitted boundary shape.

For example, this is a normal by-value boundary:

```cyna
c struct Pair {
    left: c_int;
    right: c_short;
}

extern {
    c("sum_pair") fn sum_pair(pair: Pair): c_int;
    c("make_pair") fn make_pair(): Pair;
}

export c fn bounce_pair(pair: Pair): Pair {
    return pair;
}
```

The semantic type at the Cyna level is still `Pair`. Any ABI-specific coercion
needed to match the platform C calling convention belongs to the compiler, not
to user-written source.

This same rule applies in both directions:

1. `extern c` means Cyna is calling a C-defined symbol through the target C ABI
2. `export c` means external C code is calling a Cyna-defined symbol through
   the same target C ABI
3. `c struct` is the layout form used when a record must cross that ABI
   boundary by pointer or by value

The C interop model is intentionally split into three separate concerns:

1. `c_*` scalar types such as `c_int` and `c_uint` describe scalar mapping to
   the target platform's C type family
2. `c struct`, `c union`, and `c enum` describe aggregate or enum layout rules
   that follow the target C ABI
3. `extern c`, `export c`, and `extern c fn(...)` describe callable ABI
   boundary behavior

These concerns are related but distinct:

1. using `c_int` inside an ordinary `struct` does not make that `struct`
   C-layout-compatible
2. using a `c struct` field inside an ordinary `struct` does not make the outer
   `struct` C-layout-compatible
3. only declarations that explicitly use the C ABI forms participate in the C
   ABI contract

### 23.1 Boundary Type Classes

The public `extern c` / `export c` surface accepts only types with a direct,
specified target-C representation. A type is not allowed merely because the
compiler or runtime happens to represent it with C data internally. In
particular, `string`, slices, owned storage, containers, error-return carriers, and ordinary
Cyna aggregates are not C ABI types.

Representation and ownership remain independent. A raw pointer crossing the
boundary transfers an address, not ownership. An API that transfers ownership
must say so in its wrapper contract and use an explicit operation to adopt or
release that ownership.

### 23.2 C-Layout ABI Types

A type is C-layout-ABI-safe only when the compiler defines an exact target C
ABI representation for it.

This rule applies to:

1. `extern c` parameter and return types that use C-layout ABI types
2. `export c` parameter and return types that use C-layout ABI types
3. `c struct` field types
4. `c union` field types
5. `extern c fn(...)` function-pointer types stored inside ABI-visible data

The C-layout ABI-safe set is:

1. `void`
2. C ABI scalar types such as `c_char`, `c_short`, `c_int`, `c_uint`,
   `c_long`, `c_ulong`, `c_size_t`, and related `c_*` numeric forms
3. fixed-width Cyna scalars only in C-layout aggregate positions where the
   compiler defines their exact layout; direct callable scalar positions use
   the corresponding `c_*` type
4. pointers such as `*T` and `*const T`
5. nullable pointers such as `?*T` and `?*const T`
6. `extern c fn(...)` function pointers
7. fixed arrays `[N]T` when `T` is ABI-safe for layout, for aggregate layout
   positions rather than direct function parameters or returns
8. `c struct`
9. `c union`
10. `c enum`

These entries are subject to recursive validation:

1. a pointer type is ABI-safe only as a pointer carrier; it does not make the
   pointee type itself ABI-safe by value
2. a fixed array `[N]T` is ABI-safe only when `T` is ABI-safe for layout
3. a `c struct` is ABI-safe only when every field type is ABI-safe for layout
4. a `c union` is ABI-safe only when every field type is ABI-safe for layout
5. an `extern c fn(...)` function-pointer type is ABI-safe only when every
   parameter type and the return type are ABI-safe
6. C array parameter adjustment is not implicit in Cyna signatures; spell a
   raw pointer parameter explicitly, and wrap a by-value fixed array in a
   `c struct`

Notes:

1. `c_*` scalar types may also appear in ordinary non-ABI-facing Cyna types
2. that scalar use alone does not imply C layout or header-export eligibility
3. C-layout ABI safety matters only when a declaration actually crosses the C
   boundary or participates in an ABI-visible aggregate
4. use `c_float` / `c_double` rather than `f32` / `f64`, and `c_uchar` rather
   than `u8`, in direct callable signatures and generated-header surfaces

The non-C-layout-ABI-safe set includes at least:

1. `string`
2. slices such as `[]T` and `[]const T`
3. ordinary `struct`
4. ordinary `union`
5. language enums that are not `c enum`
6. containers such as `List<T>`, `Map<K, V>`, and `Set<T>`
7. `T!E`
8. general optionals `?T` other than nullable pointers
9. closures, captured callables, and other non-C-call-convention function
   values

The compiler must validate C-layout ABI safety by use site:

1. in `extern c` declarations, every parameter and return type must be
   C-layout-ABI-safe
2. in `export c` declarations, every parameter and return type must be
   C-layout-ABI-safe
3. in `c struct`, every field type must be C-layout-ABI-safe for layout
4. in `c union`, every field type must be C-layout-ABI-safe for layout
5. in `extern c fn(...)` function-pointer types, every parameter and return
   type must be C-layout-ABI-safe
6. if any nested component is not allowed for the relevant boundary class, the
   enclosing ABI-facing type or declaration is invalid and must be rejected

`c_str` is the one semantic boundary view: it is permitted in parameter
positions because it has the ABI representation `*const c_char` plus the
non-null/NUL-termination contract defined in section 14. It is not permitted as
a C return, aggregate field, union field, or global. Use `?*const c_char` or an
explicit raw pointer in those positions.

For `c struct` and `c union`, the field rule is:

1. every field must itself have a defined C-layout representation
2. unsized or high-level language-managed fields must be rejected
3. field order, padding, alignment, and overall size come from the target C
   ABI
4. nested `c struct`, `c union`, fixed arrays, pointers, and C ABI scalars are
   allowed when their own field or element rules are satisfied
5. placing a `c struct` inside an ordinary `struct` is allowed, but the outer
   ordinary `struct` does not thereby gain C layout guarantees

### C ABI Layout Metadata

Cyna exposes layout metadata only for types whose layout is part of the C ABI
contract. Ordinary Cyna structs, enums, unions, strings, slices, containers,
owned values, references, and other compiler-private representations do not
promise source-visible layout and must not expose layout metadata.

The compile-time evaluation operator is:

```cyna
comptime expr
```

`comptime expr` requires `expr` to be evaluated during compilation. Version 1
supports integer literals and C ABI layout metadata paths. The layout metadata
operand forms are:

```cyna
comptime T.size
comptime T.align
comptime T.field.name.offset
```

Rules:

1. `T` must be a concrete C-layout ABI type such as a C ABI scalar, raw pointer,
   fixed array with C-layout element type, `c enum`, or non-generic `c struct`
2. field metadata is available only for direct fields of `c struct`
3. metadata paths produce `usize` constants for the selected build target, so
   pointer-sized and C ABI scalar metadata follows the target triple rather than
   the host running the compiler
4. general constant folding, const function calls, deep nested field paths,
   generic type parameters, ordinary Cyna layout types, and runtime type objects
   are intentionally out of scope for v1

For a C array of `c_size_t`, use `comptime c_size_t.size` as the byte stride.
It evaluates to the selected target's pointer size, including 4 on supported
32-bit targets and 8 on supported 64-bit targets.

Example:

```cyna
pub c struct TrapFrame {
  pc: c_ulong;
  cause: c_ulong;
}

pub const frame_size = comptime TrapFrame.size;
pub const cause_offset = comptime TrapFrame.field.cause.offset;
```

This feature exists for FFI, kernel, and freestanding code that must keep Cyna
`c struct` declarations synchronized with external ABI layouts such as assembly
trap frames. It is not a general reflection facility for ordinary Cyna values.

This means, for example:

1. `c struct { ptr: *User }` is allowed because the field is a pointer carrier
2. `c struct { value: User }` is rejected because ordinary `struct` is not
   ABI-safe by value
3. `c struct { text: string }` is rejected because `string` is not ABI-safe
4. `c struct { items: List<i32> }` is rejected because library containers are
   not ABI-safe
5. `c struct { pair: [4]c_int }` is allowed because fixed arrays recurse
   through an ABI-safe element type
6. `c struct { pair: [4]string }` is rejected because the array element type is
   not ABI-safe

### 23.3 Assembly Constant Export

Assembly-time constants are a different boundary from linker symbols. Cyna uses
`export asm const` for compile-time integer constants that should be emitted as
assembler definitions.

```cyna
export asm const TF_SIZE: usize = comptime TrapFrame.size;

export asm("TF_ELR_EL1") const trap_frame_elr_el1_offset: usize =
    comptime TrapFrame.field.elr_el1.offset;
```

The default external assembler name is the Cyna constant name. An explicit
`asm("name")` override changes only the emitted assembler name.

Version 1 rules:

1. only top-level `export asm const` declarations are supported
2. the initializer must evaluate at compile time to an integer-like value
3. emitted assembly include files use assembler definitions such as
   `.equ NAME, value`
4. duplicate emitted assembler names are rejected
5. `export asm` does not create a linker symbol or runtime object
6. `extern asm` is not part of v1; assembly constants flow from Cyna to
   assembly, not from assembly back into Cyna
7. `pub export asm const` is rejected because the declaration is an emitted
   assembler boundary, not an importable Cyna module binding

The build command can emit these definitions explicitly with:

```text
cyna build app.cy --emit-asm-include
```

For native builds that contain assembly sources, Cyna also writes the
`<artifact>.asm.inc` file and injects it into assembly compilation with the
toolchain include mechanism. Source assembly should use the emitted names
directly rather than manually including an artifact-specific filename.

This keeps Cyna as the source of truth for typed C ABI layouts while letting
external assembly consume immediate constants without depending on linker
symbols.

### 23.4 Explicit Adapters

Ordinary Cyna code calls a raw C binding through an explicit wrapper whenever
the representations or ownership contracts differ. Typical adapters are:

1. `string` to scoped `c_str`
2. a slice to a raw pointer plus `c_size_t` length
3. `T!E` to an explicit status code and out parameter
4. an ordinary `struct` to a `c struct`
5. a returned raw pointer to an owned Cyna value, only through an API-specific
   adoption operation

The compiler may omit adapter syntax only for a conversion that is
failure-free, allocation-free, ownership-preserving, lifetime-safe,
information-preserving, and trivial in cost. The v1 safe contextual conversions
are:

1. `&T` to `&const T`
2. an owned `^T` used as a temporary `&T` or `&const T` call borrow
3. `*T` to `*const T` for the same pointee and volatility
4. a representable numeric literal to its expected `c_*` scalar type
5. a static, NUL-free string literal to `c_str` when the compiler emits stable
   NUL-terminated storage

Numeric narrowing, sign changes of non-literals, slice decomposition,
allocation, error/status mapping, aggregate reshaping, `^T` to `*T`, and raw
pointer adoption are explicit. An implicit conversion never transfers ownership
or extends a lifetime.

### 23.5 Boundary Ownership

Representation and ownership are separate parts of the boundary contract.

Rules:

1. pointer carriers are borrowed by default unless an API explicitly documents
   ownership transfer
2. C-layout ABI validation does not imply ownership transfer
3. C code may allocate memory, but allocation origin alone does not determine
   ownership; the API contract does
4. the compiler must not treat an allowed representation as permission to
   invent an implicit ownership transfer rule

For functions, the callable-boundary rule is:

1. every parameter type must be allowed by one of the boundary classes above
2. the return type must be allowed by one of the boundary classes above
3. C-layout aggregates passed or returned by value use the target C ABI rather
   than a source-level field transport model
4. `extern c fn(...)` function-pointer values are allowed only when every
   parameter type and the return type are C-layout-ABI-safe
5. non-C-call-convention function values or captured callables are never
   allowed at the callable boundary

This means the compiler must reject declarations such as:

```cyna
extern {
    c("invalid_slice") fn invalid_slice(bytes: []const u8): void;
    c("invalid_list") fn invalid_list(items: List<i32>): void;
}

c struct BadText {
    text: string;
}

c struct BadUser {
    user: User;
}

c struct BadList {
    items: List<i32>;
}
```

and require the programmer to spell an explicit boundary representation such
as a pointer-plus-length pair or a `c struct` wrapper with C-layout-ABI-safe
fields.

The toolchain supports:

1. importing C headers into Cyna modules
2. exporting C headers from Cyna declarations
3. using C ABI types at boundaries
4. explicit cleanup-responsibility and lifetime rules for C-facing APIs

Example:

```text
cyna build image.cy --emit-c-header
```

## 24. Low-Level Interop

### 24.1 Inline Assembly

Cyna supports a deliberately narrow inline-assembly surface for embedded
programming, kernels, runtime code, atomics, CPU instructions, and hardware
access that cannot be expressed portably.

Inline assembly is only allowed inside `unchecked`:

```cyna
fn halt(): void {
    unchecked {
        asm volatile {
            "wfi";
        }
    }
}
```

The v1 surface prefers structured named operands over positional or raw
constraint syntax.

```cyna
fn read_cycle_counter(): u64 {
    unchecked {
        return asm(u64) {
            "mrs {result}, cntvct_el0";
            out reg result;
        };
    }
}
```

Rules:

1. `asm` is target-specific and not portable
2. `asm` is only allowed inside `unchecked`
3. assembly templates use named placeholders such as `{value}` or `{result}`
4. every asm block must contain at least one template string
5. statement form supports `in reg name = expr;` plus clobbers
6. `in name = expr;` is shorthand for `in reg name = expr;`
7. expression form supports the implicit result placeholder `{out}` with no
   explicit output declaration
8. expression form also supports explicit output declaration `out reg name;`
9. `out name;` is shorthand for `out reg name;`
10. expression form supports explicit read-write result `inout reg name = expr;`
11. `inout name = expr;` is shorthand for `inout reg name = expr;`
12. expression form supports tied input `in tied reg name = expr;` when an
    explicit `out` is present
13. `in tied name = expr;` is shorthand for `in tied reg name = expr;`
14. clobbers are declared explicitly through `clobber memory;`,
    `clobber flags;`, or target register clobbers
15. `volatile` is the only v1 asm option
16. input and result values support integers, bools, and pointer-like values
17. expression form allows only one `out` or one `inout`
18. `out` and `inout` cannot be combined
19. tied inputs require an explicit `out`
20. tied inputs cannot be combined with `inout`
21. Cyna variables are referenced only through declared operands
22. `asm` is not a macro system and cannot generate declarations
23. the compiler rejects undeclared placeholders, unused declared inputs,
    missing closing `}`, and empty placeholder names
24. expression asm must use exactly one result placeholder source: `{out}` for
    the implicit result form, the declared `out` name for explicit output form,
    or the declared `inout` name for read-write form
25. the compiler treats `asm` as an optimization barrier according to its
    clobbers
26. assembly syntax is target-defined, usually the backend assembler syntax
27. safe wrappers should expose narrow typed APIs around assembly blocks

Deliberate v1 restrictions:

1. statement-form `asm { ... }` does not support outputs
2. options such as `nomem`, `readonly`, and `pure` are outside the v1 surface
3. raw constraint strings, fixed-register operand bindings, and alternate
   operand classes such as `mem` or `imm` are outside the v1 surface
4. AArch64 target register clobber names include `x0..x30`, `w0..w30`, `sp`,
   `lr`, and `fp`
5. non-AArch64 targets accept only `memory` and `flags` clobbers

Expression examples:

```cyna
fn add_regs(a: u64, b: u64): u64 {
    unchecked {
        return asm(u64) {
            "add {result}, {left}, {right}";
            out reg result;
            in reg left = a;
            in reg right = b;
        };
    }
}
```

```cyna
fn add_seed(seed: u64, rhs: u64): u64 {
    unchecked {
        return asm(u64) {
            "add {acc}, {rhs}";
            inout reg acc = seed;
            in reg rhs = rhs;
        };
    }
}
```

```cyna
fn double_seed(seed: u64): u64 {
    unchecked {
        return asm(u64) {
            "add {result}, {seed}";
            out reg result;
            in tied reg seed = seed;
        };
    }
}
```

Example wrapper:

```cyna
fn enable_interrupts(): void {
    unchecked {
        asm volatile {
            "cpsie i";
            clobber memory;
        }
    }
}
```

## 25. Standard Library Shape

The standard library is expected to be modular and systems-oriented.

Core module areas:

```text
std.io
std.fs
std.time
std.process
std.thread
std.sync
std.mem
std.json
std.alloc
std.string
std.c
std.prelude
```

The library should avoid hidden allocation in APIs that look low-level. APIs
that allocate should state allocator behavior clearly. The names below are a
mix of shipped modules and reserved module areas; the availability table is
the source of truth for the current distribution.

### Hosted concurrency

[CONCURRENCY.md](concurrency.md) is the authority for the current hosted
concurrency contract. It separates the task APIs for day-to-day work, the
low-level `Thread` handle API, and synchronization primitives. The task APIs
are stable within the owned-input and target limits in that document; see
`STATUS.md` for availability. The general ownership, alias, cleanup, and `unchecked` rules
in this specification still apply at concurrency boundaries.

Module availability should be explicit:

```text
core         available in hosted and freestanding targets
hosted       requires OS-facing services and is rejected for freestanding targets
freestanding board/bring-up oriented support for low-level environments
```

Standard-library availability in the current repository:

| Module | Status | Current target scope |
| --- | --- | --- |
| `std.prelude` | Implemented | core targets |
| `std.alloc` | Implemented, constrained | core targets |
| `std.testing` | Implemented, constrained | core targets; used by `cyna test` |
| `std.io` | Implemented, constrained | core targets; writer callback surface |
| `std.mem` | Implemented, constrained | core targets; byte-slice utilities |
| `std.json` | Implemented, constrained | core targets; strict RFC 8259 parse/stringify and ordered value tree |
| `std.fs` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.path` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.time` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.process` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.thread` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.sync` | Implemented, constrained | hosted; currently shipped for `aarch64-apple-darwin` |
| `std.string` | Reserved / planned | no shipped module yet |
| `std.c` | Reserved / planned | no shipped module yet |

“Core” and “hosted” are intended portability classes, not a promise that
every target in that class already has a distribution archive. The compiler
rejects a module when the selected package manifest does not provide it for
the target.

Core language-adjacent types such as `string`, `[:]T`, `[;]T`, `List<T>`,
`Map<K,V>`, and `Set<T>` should not force a second parallel family of
container modules in the standard library.

### 25.1 `std.prelude`

`std.prelude` is a core module that is available without an explicit import.
Prelude names are fallback names after local declarations, current-module
declarations, and explicit imports.

The public surface includes:

```cyna
pub fn panic(message: string): void
```

`panic(message)` writes a minimal panic line through the runtime writer and
then aborts. Source locations, stack traces, and typed panic payloads are
outside the v1 surface.

A direct `panic(message);` statement is terminal for control flow, including
in a function declared to return a value. A direct `assert(false);` statement
is terminal for the same reason. Both retain their `void` expression type;
this rule does not infer divergence through user-defined wrapper functions.

The prelude also provides the language-adjacent `List<T>`, `Map<K,V>`, and
`Set<T>` container types plus `print(...)` / `println(...)` debug output.

### 25.2 `std.mem`

`std.mem` contains byte-slice utilities. It is a core module: it does not assume
files, processes, clocks, environment variables, or other hosted services.

The `std.mem` surface is intentionally conservative and byte-oriented:

```cyna
pub enum MemError: i32 {
    destination_too_small = 0,
}

pub fn index_of(haystack: []const u8, needle: []const u8): ?usize
pub fn contains(haystack: []const u8, needle: []const u8): bool
pub fn starts_with(haystack: []const u8, prefix: []const u8): bool
pub fn ends_with(haystack: []const u8, suffix: []const u8): bool

pub fn fill(dest: []u8, value: u8): void
pub fn zero(dest: []u8): void
pub fn copy_into(dest: []u8, source: []const u8): void!MemError
```

Search functions operate on `[]const u8` and never allocate. `index_of` returns
`0` for an empty needle and `none` when the needle is not present.

Mutation functions operate on `[]u8`. `copy_into` copies `source.len()` bytes
into the beginning of `dest` and returns `MemError.destination_too_small` when
`dest.len() < source.len()`.

`std.mem` does not expose raw pointer copy/move/fill, uninitialized memory,
alignment helpers, or an overlapping-copy contract in v1. Those operations need
sharper safety rules before they belong in the safe standard-library surface.

`string` keeps its text-facing methods such as `contains`, `starts_with`,
`ends_with`, and `find`. Use `std.mem` when the value is byte data or a
`string.bytes()` view.

### 25.3 `std.json`

`std.json` is a core module for strict RFC 8259 JSON parsing and
serialization. It does not extend the grammar with comments, trailing commas,
NaN, Infinity, or JSON5 syntax.

Import the namespace for functions and import `Error` explicitly when naming
the error category:

```cyna
import std.json;
import { Error } from std.json;
```

The public value surface is:

```cyna
pub enum Error: i32 {
    unexpected_end = 0,
    invalid_token,
    invalid_escape,
    invalid_unicode,
    trailing_data,
    duplicate_key,
    depth_exceeded,
    invalid_utf8,
}

pub union Value {
    null_value;
    bool: bool;
    number: Number;
    string: string;
    array: Array;
    object: Object;
}

pub fn parse(text: string): Value!Error
pub fn parse_bytes(text: []const u8): Value!Error
pub fn validate(text: string): void!Error
pub fn validate_bytes(text: []const u8): void!Error
pub fn encode(value: &const Value): string
pub fn encode_pretty(value: &const Value): string
```

`parse` accepts Cyna's UTF-8 `string` invariant. `parse_bytes` and
`validate_bytes` first validate the bytes as UTF-8 and return
`Error.invalid_utf8` on malformed input. The `T!Error` error category is an
integer-backed enum, so callers receive a stable error category rather than a
rich error payload. A later detailed-diagnostic API may add byte positions
without changing the ordinary `T!Error` contract.

Parsed values own their string, number, array, and member storage. Allocation
follows the ordinary current-allocator and infallible-at-the-type-level rules
in chapter 19. `validate` and `validate_bytes` run the parser and discard the
resulting value, so validation uses the same allocation behavior as parsing.
Object members preserve source order, and `Number.spelling` preserves the
validated JSON number text exactly. This retains negative zero, exponents, and
integers outside the `i64` range without approximating them.

Object member names are compared by decoded string contents. Duplicate names
are rejected with `Error.duplicate_key`. Empty and non-empty objects and arrays
both preserve their order. Nesting is bounded to protect the parser from
hostile input; exceeding the limit returns `Error.depth_exceeded`. Encoding
applies the same bound before recursive descent.

`Object.find` and `Object.contains` provide non-trapping lookup. Object and
array index syntax return borrowed `&const Value` and trap when the key or
position is absent. `encode` emits compact JSON with deterministic member
order and normalizes string escapes. `encode_pretty` uses a two-space indent.

Typed struct encoding/decoding and incremental streaming are not part of the
initial module. They require separate design work around reflection or codec
protocols and a public reader/writer abstraction.

### 25.4 Naming Conventions

Cyna uses mixed naming:

```text
Types and protocols: PascalCase
Protocols: prefer adjective/capability names where practical
Type unions: prefer noun/category names
functions and methods: snake_case
variables: snake_case
modules: lowercase dot paths
enum cases: snake_case
union tags: snake_case
generic parameters: T, K, V
ordinary constants: snake_case
C imported constants: keep C spelling when useful
```

For C ABI surface names, keep one consistent split:

```text
C layout/declaration forms: c struct, c union, c enum
C primitive/scalar ABI types: c_int, c_uint, c_char, c_size_t, ...
```

Declaration keywords use the tight `cX` form. Concrete C primitive types use
the `c_*` form.

Example:

```cyna
struct UserProfile {
    display_name: string;

    pub fn from_json(text: string): UserProfile!JsonStatus {
        ...
    }

    pub fn normalize(self: &UserProfile): void {
        ...
    }
}

enum IoStatus: i32 {
    ok = 0,
    not_found,
    permission_denied,
}
```

### 25.5 Tests and Tooling

Tests are first-class:

```cyna
// parser.test.cy
import { parse_i32 } from .parser;

test "parse integer" {
    const value = try parse_i32("123");

    assert(value == 123);
}
```

Rules:

```text
test blocks are run by cyna test
test blocks are declared only in dedicated *.test.cy files
every test file is compiled independently as an import-tree root
foo.test.cy has friend visibility to sibling foo.cy
friend visibility changes access only; foo must still be imported explicitly
test modules cannot be imported and normal builds exclude them
foo.test.cy may exist without foo.cy
dots in import syntax always represent directory boundaries
assert is built in for tests
```

V1 tool commands:

```text
cyna build
cyna run
cyna test
cyna check
cyna fmt
cyna clean
cyna install
cyna package
cyna lsp
cyna version
```

`cyna fmt [paths...] [--check]` formats source and applies conservative syntax
normalization, including directly repeated simple struct construction types and
redundant checked integer casts used as a complete index-hook key expression.
It preserves comments and literal text; `--check` reports differences without
writing. See `BUILD.md` for traversal, normalization scope, and exit statuses.
`cyna doc` remains a reserved tooling direction, not an implemented v1 command.

## 26. Example Program

```cyna
import std.fs;
import { FsError } from std.fs;

fn load_config(path: string): string!FsError {
    return try fs.read_file(path);
}

fn main(): i32 {
    const text = load_config("data.txt") catch (code) { return 1; };
    println(text.len());
    return 0;
}
```

## 27. Language Scope Summary

The v1 language surface is:

1. modules, imports, `const`, `var`, and `fn`
2. primitive integer, float, bool, `char`, and string-facing types
3. type aliases, distinct types, `struct`, `c struct`, `packed struct`, nested
   type declarations, and field defaults
4. `enum`, `c enum`, `flags`, `union`, `c union`, and union narrowing
5. pointers, alias pointers, optionals, slices, fixed arrays, dense storage, and
   sparse storage
6. owned values, `^T`, `new T {}`, `take`, `Clone`, `drop`, `defer`, and
   allocator contexts
7. `T!E`, status enums, and `try`
8. `string`, `List<T>`, `Map<K,V>`, and `Set<T>`
9. generics, compile-time value generics, protocols, function pointers, lambdas, and
   non-escaping callable parameters
10. checked and unchecked casts, value equality, range loops, and `switch`
11. C ABI import/export, C-layout metadata, exported constants for asm, and
    inline asm inside `unchecked`
12. hosted `std.thread` and `std.sync` concurrency primitives

Features outside this surface require explicit design before becoming part of
the language or standard-library contract.
