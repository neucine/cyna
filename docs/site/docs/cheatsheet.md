# Cyna Syntax Cheat Sheet

This is a quick reference for common Cyna syntax and the preferred Cyna style
when more than one spelling or modeling choice exists. It is not normative;
`SPEC.md` wins for language rules and `GUIDE.md` explains the style rationale.
The [glossary](glossary.md) names the ownership actions and storage forms.

## Syntax Roles

Library syntax uses annotated inherent methods, not reserved names or syntax
protocols: `@syntax.index`, `@syntax.index_set`, `@syntax.iter`,
`@syntax.iter_has_next`, `@syntax.iter_next`, and `@syntax.iter_item`.
Iteration requires all four roles with matching state and cursor signatures.
See SPEC §22.3 for signatures and `examples/syntax_roles.cy` for renamed methods.
`Eq` and `Hash` remain ordinary protocols.

## Source Shape

```cyna
import std.io;
import std.fs as filesystem;
import { basename, join } from std.path;
import { dirname as parent_dir } from std.path;

const max_users: usize = 1024;
var count: usize = 0;

fn main(): i32 {
    return 0;
}
```

Preferred forms:

```text
file extension                 .cy
module path                    package-rooted path, no `module ...;` line
function return type           fn name(args): Return
visibility                     private by default, add `pub`
top-level setup                declarative globals only; runtime setup in main/init functions
```

Avoid older or non-canonical spellings:

```text
fn name(...) -> Return         older sketch; use `: Return`
importing everything           import module namespaces or selected declarations explicitly
top-level effectful init       put it behind explicit startup code
```

## Names

```text
Types and protocols            PascalCase
protocols                      adjective/capability names when practical
type unions                    noun/category names
functions and methods          snake_case
variables                      snake_case
modules                        lowercase dot paths
enum cases and union tags       snake_case
generic parameters             T, K, V
ordinary constants             snake_case
C imported constants           keep C spelling when useful
```

Use backticks only when a generated or foreign name would otherwise be illegal
or collide with a keyword:

```cyna
packed struct Fmt {
    pub `protocol`: u2;
}

const bits = fmt.`protocol`;
```

## Bindings And Types

```cyna
const name: string = "Cyna";
var retries: i32 = 3;

const inferred = 10;
var mutable_name = "guest";

const { x, y: vertical } = point;  // fields; rename y
const [first, second] = entries;  // positions 0 and 1
const { rows: [{ title }] } = document; // nested field and position

type Bytes = []u8;
type UserId = distinct u64;
```

Preferred style:

```text
const          binding cannot be changed
var            binding can be rebound or mutated
type A = B     alias
type A = distinct B
               new nominal type
public APIs    spell types explicitly
locals         use inference when it improves readability
```

Destructuring is local and `const` only. Omitted fields and elements stay with
the source owner; `..` is not required. An owned local used as the initializer
is handed off as a whole. Owned leaves are read-only projected bindings, so
they cannot be handed off independently. Use `const item = entries[index];`
for a dynamic index. See [SPEC §4](spec.md#4-declarations).

Primitive families:

```text
i8 i16 i32 i64, u8 u16 u32 u64
isize usize
f32 f64
bool void
c_int c_uint c_char c_size_t ...
```

Use fixed-width and semantic Cyna types in normal code. Use `c_*` scalar types
at C ABI boundaries.

## Functions And Methods

```cyna
fn add(a: i32, b: i32): i32 {
    return a + b;
}

pub fn parse_i32(text: string): i32!ParseStatus {
    ...
}
```

Structs define a data layout plus a namespace:

```cyna
struct Buffer {
    data: *u8;
    len: usize;
    cap: usize;

    fn init(data: *u8, cap: usize): Buffer {
        return Buffer { data: data, len: 0, cap: cap };
    }

    fn clear(self: &Buffer): void {
        self.len = 0;
    }
}

var buf = Buffer.init(memory, 4096);
buf.clear();
```

Cyna style:

```text
self is explicit       fn clear(self: &Buffer): void
namespace function     Buffer.init(...)
method call sugar      buf.clear() lowers to Buffer.clear(&buf)
constructors           ordinary functions such as Type.init or Type.new
hidden destructors     not part of the model
inheritance/classes    not part of the model
```

Use `Type { ... }` for plain data whose public fields the caller can supply.
Use `Type.init(...)` for canonical reusable setup, defaults, validation, or
hidden representation. Name distinct construction routes descriptively, such
as `Type.from_bytes(...)`; reserve `Type.new(...)` for an owned heap result.
Module functions such as `json.parse(...)` name operations or module workflow
entry points. A type that relies on an `init` invariant should keep its
relevant fields private.

## Data Types

```cyna
struct User {
    pub name: string;
    age: i32 = 0;
}

c struct CPoint {
    x: c_int;
    y: c_int;
}

packed struct StatusReg {
    ready: u1;
    mode: u3;
    error: u4;
}
```

Use:

```text
struct          ordinary Cyna data
c struct         C ABI layout
packed struct   byte/bit-exact protocol, wire, or register layout
```

Enums, flags, and unions:

```cyna
enum Color: u8 {
    red = 0,
    green,
    blue,
}

flags FileMode: u32 {
    read  = 1 << 0,
    write = 1 << 1,
}

union Token {
    ident: string;
    int_lit: i64;
    eof;
}

union Event = KeyEvent | MouseEvent | ResizeEvent;

c union CValue {
    i: c_int;
    f: f32;
}
```

Use:

```text
enum            one closed named value
flags           set of named bits
union Name      safe named-case tagged union
union Name = A | B
                type union where payload type is the tag
c union          raw C-compatible union; reads require unchecked
```

## Construction Literals

Delimiter rule:

```text
{ ... }         keyed initialization
[ ... ]         positional sequence initialization
```

Common forms:

```cyna
var user = User { name: "Ada", age: 42 };
var user2: User = { name: "Ada", age: 42 };

var fixed = [3]i32 [1, 2, 3];
var fixed2: [3]i32 = [1, 2, 3];
var zeros: [3]i32 = [];

var dense = [:]i32 [1, 2, 3];
var reserved: [:]i32 = [: 8] [1, 2, 3];

var sparse: [;]i32 = [1, none, 3];
var sparse_reserved = [; 16]i32 [1, none, 3];
var sparse2: [;]i32 = { 3: 42, 10: 99 };
var sparse2_reserved: [;]i32 = [; 16] { 3: 42, 10: 99 };

var xs: List<i32> = [1, 2, 3];
var empty: List<i32> = [];
var counts = map<string, i32>();
counts["ok"] = 1;
counts["err"] = 2;
var names = set<string>();
names.add("Ada");
names.add("Lin");
```

Contextual library sequence literals select a visible public top-level factory
marked `@syntax.sequence_literal`, such as `list_from<T>(items: [:]T): List<T>`.
The factory name is ordinary; its signature and generic arguments are checked
by the compiler. Native array/storage construction keeps its intrinsic path.

Cyna style:

```text
structs         use keyed fields, never positional fields
library containers use named constructors and methods
fixed arrays    name [N]T when context is missing
dense storage   use [:]T for runtime-sized owned contiguous storage
sparse storage  use [;]T when slots may be empty
```

Rejected or non-Cyna forms:

```cyna
var xs = List<i32> { 1, 2, 3 };      // braces are keyed only
var counts = Map<string, i32> [1, 2]; // maps are keyed
var u = User [1, 2];                  // structs are keyed
```

## Ownership Shapes

Choose the simplest shape that matches ownership:

```text
value       data owned directly by its binding or containing value
List<T>     growable owner of many values
Map<K, V>   keyed owner of values
Set<T>      owner of keys
id/index    relationship to data owned somewhere else
&T          temporary alias for caller mutation
&const T    temporary read-only alias
[]T         temporary mutable range view
[]const T   temporary read-only range view
^T          unique owned pointer to one heap value
*T          raw pointer for unchecked, foreign, or low-level code
```

Preferred modeling:

```cyna
struct Order {
    user_id: UserId;
    items: List<OrderItem>;
}
```

Prefer that over pointer-heavy ownership graphs:

```cyna
struct Order {
    user: ^User;
    items: List<^OrderItem>;
}
```

Use `^T` when heap identity or recursive shape is part of the model:

```cyna
struct Node {
    value: i32;
    left: ?^Node;
    right: ?^Node;
}
```

Use `*T` for raw addresses and usually keep operations inside `unchecked`.

## Assignment, Copy, Handoff

```cyna
var b = a;       // copy or hand off according to type
b = a;           // drop old b if needed, then rebind
var c = a.clone(); // request another value under Clone
drop a;          // end this value's lifetime now
```

Owned values hand off cleanup responsibility:

```cyna
var users: List<User> = list<User>();
var moved = users;
// users is unavailable here
```

Use an ordinary named API for resource duplication when the original must
remain usable:

```cyna
var users2 = users.clone();
```

`Clone` has `clone(self: &const Self): Self`. Strings clone independent
backing; dense storage clones descriptor-copy-safe elements; collections
clone their elements; `Arc<T>` retains another shared claim.

An owned field of a live local struct can have a read-only projected name:

```cyna
struct Box { items: [:]i32; }
var box = Box { items: [1, 2] };
const items = box.items;
const same = items;
println(same.len());
```

`box` remains the owner and performs cleanup. The projected names cannot be
dropped, returned as owned values, or used to replace `box.items`. Use
`items.clone()` when an independent owner is needed.

`take` removes from optional places:

```cyna
var x: ?i32 = 42;
const old = take x;          // old: ?i32, x becomes none

const item = take slots[i];  // [;]T slot behaves like ?T
```

Cyna style:

```text
take optional field/local/sparse slot
               extract occupant and write none
list last item use ls.pop(), not take ls[i]
slot-map item  use slots.remove(key), not take slots[key]
list/map arbitrary removal
               not implemented; do not use take on indexed sugar
external handle cleanup
               use explicit APIs with defer, not drop unless wrapped as a language resource
```

## Parameters By Intent

```text
T              copy value or hand off owned value
x.clone()      clone before passing, when available
&T             mutate one caller-owned value
[]const T      read a contiguous range
[]T            mutate elements in a contiguous range
&List<T>       mutate the list object itself
```

Examples:

```cyna
fn print_all(users: []const User): void {
    for user in users {
        io.println(user.name);
    }
}

fn zero(xs: []i32): void {
    var i: usize = 0;
    while i < xs.len {
        xs[i] = 0;
        i = i + 1;
    }
}

fn rename(user: &User, name: string): void {
    user.name = name;
}

fn set_age(age: &i32): void {
    age = 42;
}

fn add_default(users: &List<User>): void {
    users.push(User { name: "new" });
}
```

Call-site forms:

```cyna
print_all(users);     // read-only view when expected
zero(scores[..]);     // explicit mutable slice
rename(&user, "Ada"); // explicit alias
set_age(&user.inner.age);
consume(users);       // may hand off if the parameter type is owned
consume(users.clone()); // duplicate through the List API first
```

Prefer `[]const T` for read-only sequence APIs and `[]T` for element mutation.
Use `&List<T>` only when the callee mutates the container object itself.
For `List<T>`, `xs[i]`, iteration, and `xs.view()` are read-only. Use indexed
assignment, `xs.get_mut(i)`, or `xs.view_mut()` for explicit element mutation.

## Slices And Ranges

```cyna
xs[..]
xs[a..b]
xs[..b]
xs[a..]
```

Rules:

```text
slice creation does not allocate
slice creation does not transfer ownership
[]T can mutate elements
[]const T is read-only
source owner must outlive the view
container mutations that may relocate storage are rejected while a view is live
```

Library containers expose direct views through annotated ordinary methods:

```cyna
@syntax.slice_view
pub fn inspect(self: &const Buffer): []const T
@syntax.slice_view
pub fn edit(self: &Buffer): []T
```

Method names are not reserved. Direct slices select the receiver's available
access; a writable receiver prefers the mutable role:

```cyna
var middle = buffer[1..3];
```

`cyna fmt` normalizes equivalent zero-argument annotated calls to `[..]` when
semantic analysis proves the selection unchanged. Explicit `view()` stays when
it forces a const view from a writable List.

Use indexes or ranges for long-lived relationships instead of storing slices.

## Optionals, Results, And Narrowing

```cyna
var maybe_user: ?User = none;
var maybe_count: ?i32 = 3;

if maybe_user {                    // narrow maybe_user in this branch
    io.println(maybe_user.name);
}
if maybe_user is user {            // declare a new payload binding
    io.println(user.name);
}
if maybe_user is none {            // test absence
    io.println("missing user");
}
```

Use `?T` when absence is the only information. Use a `T!E` return when
failure has an enum code (or a closed union of enum codes):

```cyna
enum ParseStatus: i32 {
    invalid = 0,
    overflow,
}

fn parse_i32(text: string): i32!ParseStatus {
    if text == "" { throw ParseStatus.invalid; }
    return 123;
}

fn main(): i32 {
    return parse_i32("") catch (code) {
        if code == ParseStatus.invalid { yield 0; }
        yield 1;
    };
}
```

`try` propagates an admitted error from an error-returning function. An
ordinary `catch (code) { ... }` block handles it locally; `yield` supplies the
catch expression's value. For one fallback expression, write
`call() catch (code) => fallback(code)`.

Named union construction, checked projection, and narrowing:

```cyna
const token: Token = .ident("name");

const name = token.ident; // checked; traps unless .ident is active

if token is .ident(name) {
    io.println(name);
}
```

Type union switching and checked projection:

```cyna
switch event {
KeyEvent(key) => {
    handle_key(key);
}
MouseEvent(mouse) => {
    handle_mouse(mouse);
}
}

const key = event as KeyEvent;        // checked; traps on another variant
const maybe_key = event as? KeyEvent; // ?KeyEvent
```

## Control Flow

```cyna
if x > 0 {
    ...
} else if x == 0 {
    ...
} else {
    ...
}

while i < n {
    i = i + 1;
}

for user in users {
    ...
}

switch color {
.red => {
    ...
}
.green => {
    ...
}
_ => {}
}
```

Style:

```text
braces are required
condition parentheses are not required
Boolean negation is `not flag`; use `value is none` for optional absence
prefix `!` is not negation; `T!E` and `as!` have separate meanings
switch over enums/unions should be exhaustive unless final _ is present
integer/string switches require final _
arms use pattern => expression; or pattern => { statements }
yield value; completes the nearest switch arm; return exits the function
explicit empty wildcard arm is spelled _ => {}
range inclusivity beyond start..end remains open
```

## Testing Helpers

```cyna
import { TestError, expect, expect_eq_bool, expect_eq_bytes, expect_eq_i32, expect_eq_i64, expect_eq_string, expect_eq_u8, expect_eq_usize } from std.testing;
```

`std.testing` helpers return `void!TestError` so test blocks can use
`try` for assertion flow.

## Casts And Conversions

```cyna
const small = big as i32;    // checked conversion, traps on failure
const maybe = big as? i32;   // checked conversion, returns ?i32
const reg = raw as! StatusReg; // exact-bit reinterpretation
```

Use:

```text
as       checked value conversion
as?      fallible checked value conversion
as!      exact-bit reinterpretation with same bit width
unchecked
         raw pointer dereference, C union reads, low-level operations
```

No implicit narrowing, signed/unsigned, enum/integer, pointer/integer, or
dynamic `string`/`c_str` conversion. A static NUL-free literal may adapt to an
expected `c_str`; other string adapters are explicit. Arithmetic traps on
overflow; use wrapping operators when wrapping is intentional:

```cyna
hash = hash *% 31 +% byte;
```

Wrapping operators:

```text
+%        wrapping add
-%        wrapping subtract
*%        wrapping multiply
x = x + 1  ordinary increment style
```

## Cleanup

```cyna
const handle = try resource_open(path);
defer resource_close(handle);

var users: List<User> = list<User>();
drop users;
```

Use:

```text
defer       run a statement at scope exit, reverse order
drop        end an owned value's lifetime early
free        raw/manual memory release through an API
```

External resources such as file descriptors and sockets should usually be
closed with explicit library APIs and `defer`.

## C Interop

```cyna
extern c("puts") fn puts(text: c_str): c_int;

extern {
    c("strlen") fn strlen(text: c_str): c_size_t;
    c("malloc") fn malloc(size: c_size_t): ?*c_void;
}

export c("cyna_add") fn add(a: c_int, b: c_int): c_int {
    return a + b;
}

c struct Pair {
    left: c_int;
    right: c_int;
}
```

Preferred forms:

```text
extern c("symbol") fn ...
export c("symbol") fn ...
extern { c("symbol") fn ...; }
c struct/c union/c enum for C layout
c_* scalar types at C boundaries
```

Boundary types and ownership:

```text
extern c / export c
             strict target-C representations only
c_str        borrowed, non-null, NUL-terminated parameter view
             ABI shape: *const c_char
"literal"    safely adapts when c_str is expected
string       dynamic Cyna string; use a scoped explicit adapter
^T           Cyna ownership; never implicitly becomes *T
*T           raw address; crossing C never transfers ownership by itself
```

Use `?*const c_char`, not `?c_str`, for nullable, returned, or stored C string
pointers whose lifetime is specified by the foreign API.

Avoid older trailing string aliases:

```cyna
export c fn greet(name: c_str): c_int = "greet" { // old/rejected
    ...
}
```

Use the ABI specifier instead:

```cyna
export c("greet") fn greet(name: c_str): c_int {
    ...
}
```

## Generics And Protocols

```cyna
struct Pair<T, U> {
    first: T;
    second: U;
}

fn identity<T>(x: T): T {
    return x;
}

protocol Writable {
    fn write(self: &Self, bytes: []const u8): IoStatus;
}

impl FileWriter: Writable {
    fn write(self: &FileWriter, bytes: []const u8): IoStatus {
        return fs.write(self.file, bytes);
    }
}
```

Cyna style:

```text
generics are monomorphized
ownership rules remain compiler-defined
protocols are explicit capability contracts
type unions are the closed runtime dispatch path for v1
```

Function values:

```text
fn(...)       Cyna calling convention
c fn(...)     C ABI function pointer
```

## Tests And Tools

```cyna
test "parse integer" {
    const value = try parse_i32("123");
    assert(value == 123);
}
```

```sh
cyna build
cyna run
cyna test
cyna check
```

Tests in a module can access private declarations in that module. `assert` is
built in for tests.

## Quick Style Defaults

```text
Use values for ordinary data.
Use containers to own many values.
Use IDs, indexes, or handles for relationships to owned data.
Use []const T for read-only range APIs.
Use []T for element-mutating range APIs.
Use &T for mutating one caller-owned value.
Use ^T only when unique heap identity is part of the model.
Use *T at C, hardware, allocator, and unchecked boundaries.
Use T!E returns for failures with enum reasons.
Use ?T for absence.
Use c struct/c enum/c union and c_* at C ABI boundaries.
Keep startup work explicit in main or init functions.
```
