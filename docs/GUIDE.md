# Cyna Programming Guide

This guide describes the recommended Cyna style for data, ownership, pointers,
arrays, containers, and low-level code. The goal is simple: write systems code
that is honest about memory without becoming pointer-heavy by default.
Use the [terminology glossary](GLOSSARY.md) for the names of ownership actions
and storage forms.

## Core Rule

Use the simplest shape that matches the ownership and access pattern:

```text
value       data owned directly by its binding or containing value
container   owner of many values
id/index    relationship to a value owned somewhere else
&T          temporary alias pointer for caller mutation
[]T         temporary range view
^T          unique owned pointer to one heap value
*T          raw pointer for unchecked/foreign/low-level code
```

Most application data should be values stored in containers. Pointers are tools
for address-oriented cases, not the default way to model objects.

## Prefer Values For Data

Use structs as real values:

```cyna
struct User {
    id: UserId;
    name: string;
    age: i32;
}

var user = User { id: id, name: "A", age: 30 };
```

Prefer values when:

1. the data has one clear owner
2. identity is not important
3. relationships can be expressed with IDs or indexes
4. the value is naturally copied or handed off as a whole
5. layout and locality matter

Avoid making ordinary domain data pointer-shaped by habit:

```cyna
// Usually not the first choice.
var user = new User { id: id, name: "A", age: 30 };
```

## Use Containers To Own Many Values

Use containers as owners of groups of data:

```cyna
var users = list<User>();
var products = map<ProductId, Product>();
var seen = set<UserId>();
```

Canonical module homes:

```text
List<T>      -> std.prelude
Map<K, V>    -> std.prelude
Set<T>       -> std.prelude
```

Prefer:

```cyna
List<User>
Map<UserId, User>
```

over:

```cyna
List<^User>
Map<UserId, ^User>
```

unless object identity or independent heap lifetime is required.

Containers make ownership obvious:

```text
the List owns the User values
the Map owns the Product values
the Set owns its keys
```

This usually gives better locality and fewer tiny heap allocations than a graph
of owned pointers.

## Use IDs Or Indexes For Relationships

When one object refers to another object owned by a collection, prefer an ID or
index:

```cyna
type UserId = distinct u64;

struct Order {
    user_id: UserId;
    items: List<OrderItem>;
}
```

For container-local relationships:

```cyna
type NodeId = distinct usize;

struct Node {
    value: i32;
    parent: ?NodeId;
    first_child: ?NodeId;
    next_sibling: ?NodeId;
}

struct Tree {
    nodes: List<Node>;
    root: ?NodeId;
}
```

This style is often faster than pointer-heavy structures because nodes can live
in contiguous storage.

## Use Generational Handles When Deleting And Reusing Slots

Plain indexes are fine when elements are never deleted or when stale indexes
cannot escape. If deletion and slot reuse are possible, use a generational
handle:

```cyna
struct NodeId {
    index: usize;
    generation: u32;
}
```

A slot map stores a generation beside each slot:

```cyna
struct Slot<T> {
    generation: u32;
    value: ?T;
    next_free: ?usize;
}

struct SlotMap<T> {
    slots: List<Slot<T>>;
    free_head: ?usize;
}
```

Lookup checks both fields:

```text
id.index selects the slot
id.generation must match the slot generation
slot.value must be present
```

This prevents an old handle from accidentally referring to a new value after a
slot is reused.

The standard library provides `SlotMap<T>` and `SlotMapKey` for this pattern.
Store values in the map and pass keys between objects. A key preserves logical
identity across changes to the map's storage and lets lookup reject a removed
object. It does not promise a stable memory address for the stored value.

## Use Fixed Arrays For Inline Storage

Use `[N]T` when the element count is part of the type and the storage should be
inline:

```cyna
struct Packet {
    bytes: [64]u8;
}

var rgba = [4]u8 [ 255, 128, 0, 255 ];
```

Good uses:

1. protocol and ABI layout
2. embedded/register data
3. small fixed buffers
4. stack scratch space
5. matrices/vectors with fixed dimensions

Do not use fixed arrays for growable collections.

For reusable static-storage containers, make the capacity an explicit
compile-time value parameter:

```cyna
struct Pool<T, const N: usize> {
    storage: [N]T;
    len: usize;
}

var tasks: Pool<Task, 64>;
```

Here `T` is a type parameter and `N` is a compile-time value parameter. The
fixed array type `[N]T` still carries inline storage, but the generic parameter
list no longer hides `N` inside the array shape.

Use sequence repeat when the initializer is regular:

```cyna
struct StaticPool<T, const N: usize> {
    values: [N]T;
    occupied: [N]bool;
}

fn fill_pool<T, const N: usize>(seed: [N]T, value: T): StaticPool<T, N> {
    return StaticPool<T, N> {
        values: [value] ** N,
        occupied: [false] ** N,
    };
}
```

`[item] ** N` keeps the capacity attached to the value parameter. Full array
literals remain available when each element needs to be written explicitly.

## Use `[:]T` For Dense Owned Storage

Use `[:]T` when you need owned, indexed storage with runtime capacity. An
application can keep its initialized length fixed:

```cyna
var pixels: [:]Color = [: width * height] [];
```

`[:]T` owns its initialized elements and tracks unused capacity. `push` can
extend the initialized prefix and grow storage. `List<T>` supplies the
general-purpose growable collection API on top of dense storage.

Use it when:

1. capacity is chosen at runtime
2. only an initialized prefix of the storage is in use
3. random indexing is important
4. direct control of the dense storage shape is useful

Use `List<T>` when the program needs a collection API rather than direct
dense-storage operations.

## Use Slices For Temporary Range Access

Use `[]T` for a temporary mutable view into contiguous elements:

```cyna
fn normalize(samples: []f32): void {
    var i = 0;
    while i < samples.len() {
        samples[i] = samples[i] * 0.5;
        i = i + 1;
    }
}

normalize(buffer[..]);
```

A slice does not own storage. It should not be stored for long-lived ownership.

Use slices for:

1. function parameters over arrays, storage, and `List.view()` results
2. temporary subranges
3. algorithms that operate on contiguous data

Prefer `[]const T` for read-only range access when available.

## Use Alias Pointers For Caller Mutation

Use `&T` when a function needs to mutate one caller-owned value:

```cyna
fn rename(user: &User, name: string): void {
    user.name = name;
}

rename(&user, "A");
```

Use `&T` for:

1. mutating a single caller-owned value
2. methods with explicit mutable receiver style
3. avoiding handoff when the callee only needs temporary access

Do not store `&T` in structs, arrays, maps, lists, or returned values in safe
code. Alias pointers are temporary non-owning access.

For a range of elements, prefer `[]T` over `&List<T>` when the callee does not
need to change the container itself:

```cyna
fn clear_values(values: []i32): void {
    var i = 0;
    while i < values.len() {
        values[i] = 0;
        i = i + 1;
    }
}
```

Use `&List<T>` only when the function mutates the list object itself, such as
push, pop, clear, reserve, or replacing elements by container operation.

Alias parameters are best treated as immediate mutation access, not as a
general place that you can keep projecting ownership operations through. Nested
field aliases such as `&user.profile.name` are supported for normal aligned
fields at the immediate use site. In particular:

1. `take` works on writable optional places rooted in locals, fields, and
   `[:]?T` paths, including ref roots like `&[:]?T` when the
   final place is still writable and optional
2. matching ref locals can be forwarded to another `&T`-taking function, but
   this is still a narrow local-name rule rather than a general borrow
   expression system

When a broader convenience form is rejected, prefer these spellings:

1. last-list-element removal: `ls.pop()` instead of `take ls[i]`
2. slot-map removal: `slots.remove(key)` instead of `take slots[key]`
3. read-only range access: `[]const T` instead of `&List<T>` when the callee does
   not mutate the container object
4. focused mutation of one nested caller-owned value: pass the field path
   directly, such as `&user.profile.name`, at the immediate call site instead
   of building longer ref-forwarding chains

The current standard library does not yet provide arbitrary-position
`List.remove` / `List.swap_remove` or keyed `Map.remove`. Do not substitute
`take` on their indexed sugar; use an API whose removal policy is explicit, or
retain/rebuild the container until such an API is approved.

## Use Owned Pointers Sparingly

Use `^T` when one value genuinely needs its own heap allocation and unique
cleanup owner. It is not the default way to give a struct an owner: a struct
field or container element already has one. For relationships between objects
in a collection, use IDs or `SlotMapKey` instead.

Recursive shapes are one reason to use heap indirection:

```cyna
struct Node {
    value: i32;
    left: ?^Node;
    right: ?^Node;
}
```

Good uses:

1. recursive data where inline values would make the type infinitely large
2. a stable heap address that must survive movement of the owning value
3. C or OS APIs that transfer ownership of an object
4. intrusive structures
5. future dynamic protocol objects, if the language ever adds them

`^T` keeps the pointed-to object at one address while its owner moves, but it
does not provide a reusable, checked handle. If objects can be removed while
other objects retain references, prefer a generational key and validate it on
lookup. Use `^T` for address stability only when the address itself matters.

Avoid `^T` when:

1. a container clearly owns the values
2. an ID or index expresses the relationship
3. you only want to avoid copying a large value
4. many small heap allocations would harm locality
5. many owners need shared access, because `^T` is an owned pointer

Rule of thumb:

```text
If the value belongs to a collection, store it in the collection and refer to it
with an ID/index.
```

## Use Optional Owned Pointers For Empty Pointer Slots

`^T` is non-null. If a pointer slot may be empty, use `?^T`:

```cyna
struct Node {
    next: ?^Node;
}
```

For arrays of maybe-present owned objects:

```cyna
var users: [:]?^User = [: count] [];
```

This is honest: each slot may be `none` until filled.

## Use Raw Pointers Only At Boundaries

Use `*T` for raw address-oriented code:

```text
C interop
memory-mapped IO
custom allocators
intrusive structures
unchecked low-level operations
```

Raw pointers are not ownership. They are addresses. Prefer slices, alias
pointers, owned pointers, containers, or handles in safe code.

### Shape C Boundaries Explicitly

Treat an `extern c` declaration as a raw C surface and put ordinary Cyna
ergonomics in a wrapper. Public `extern c` and `export c` signatures are
strict: use C ABI scalars, raw pointers, C function pointers, fixed arrays where
legal, and `c struct` / `c union` / `c enum`. Do not expose `string`, slices,
containers, `result`, owned pointers, or ordinary Cyna aggregates directly.

Pointer meaning does not change at the boundary:

```text
^T          Cyna owns one heap T; never becomes a C pointer implicitly
&T          checked temporary Cyna borrow
&const T    checked read-only Cyna borrow
*T          raw non-null pointer
*const T    raw non-null pointer with read-only pointee access
?*const T   nullable raw pointer
```

Access is shallow. Const bindings holding `&T`, `[]T`, or `*T` freeze the
carrier but not the referent, elements, or pointee. Their `const` carrier forms
restrict that access. For ordinary values, a const `T` binding has the same
value type as a mutable `T` binding but exposes read-only access through that
name. Projections never increase the access granted by their base.

`c_str` is a non-owning, non-null, NUL-terminated parameter view with ABI shape
`*const c_char`. It is not `string`, a general raw pointer, or an owning
`CString`. A static string literal safely adapts when `c_str` is expected:

```cyna
extern c("puts") fn puts(text: c_str): c_int;

const ignored = puts("hello");
```

A dynamic `string` requires a scoped adapter that validates or constructs
terminated storage and keeps it alive for the call. Use `?*const c_char` for a
nullable C string pointer or for returned/stored pointers whose lifetime is
defined by the foreign API; `c_str` cannot be returned or stored.

## Use Handles For External Resources

Do not model every external resource as `^T`. File descriptors, sockets,
windows, GPU buffers, and OS handles are often ordinary handle values with
explicit APIs:

```cyna
const file = try fs.open(path);
defer fs.close(file);
```

Use a resource wrapper only when the library intentionally wants compiler-
tracked cleanup responsibility.

## Copy, Handoff, And Mutation

For repeated observation of an owned field in a live, ordinary struct, bind a
`const` name to the field:

```cyna
struct Box { items: [:]i32; }
var box = Box { items: [1, 2] };
const items = box.items;
println(items.len());
```

`items` names the same storage and carries no cleanup responsibility; `box`
remains the owner. Nested owned-field and indexed bindings through tracked
storage keep that owner. The checker rejects an overlapping replacement or
owner move while a binding is live. Clone explicitly when another owner is
required. Checked union/result payloads, direct field reads from temporaries,
and `var` bindings do not acquire this projected binding rule.

Use local `const` destructuring when several fields or positional elements
belong in one declaration:

```cyna
struct Bundle { items: [:]i32; count: i32; }
fn sum_items(): i32 {
    var bundle = Bundle { items: [40, 2], count: 2 };
    const { items, count: total } = bundle;
    const [first, second] = items;
    return first + second + total;
}
```

`count: total` renames a field, and `[first, second]` selects positions zero
and one. Unnamed fields and elements stay with their owner. An owned local used
as the initializer, such as `bundle`, moves into the pattern's owner and cannot
be used afterward. Owned leaves are read-only projections; they do not split
cleanup responsibility or move individual fields. Use an ordinary
`const item = entries[index];` binding for a dynamic index. Destructuring has
no `var` form. See [SPEC §4](SPEC.md#4-declarations) for the full rule.

For a small fixed group of different values, use a tuple. Its type and
positions are structural:

```cyna
fn split(): (i32, bool) { return (42, true); }

const result = split();
const same_number = result.0;
const (number, enabled) = result;
```

Use `(value,)` and `(T,)` for a one-element tuple; `()` is an empty tuple.
Tuple patterns can nest with struct and indexed patterns. Resource-bearing
positions remain projections into the tuple owner. The owner is cleaned up
after its final use, and a live projection prevents moving or dropping it.

```cyna
const pair: ([:]i32, i32) = ([40, 2], 0);
const items = pair.0;
const sum = items[0] + items[1];
```

Know what each operation means:

```text
var b = a      copy or hand off according to a's type
b = a          replace b; drop old b if needed
a.clone()      duplicate according to the type's Clone contract
drop a         end cleanup responsibility now
f(&a)          temporary alias pointer for mutation
f(a[..])       temporary slice view
```

For owned values such as `[:]T`, `List<T>`, `Map<K,V>`, `Set<T>`, and
`^T`, assignment hands off cleanup responsibility:

```cyna
var b = a;
// a is unavailable if a was an owned value
```

Use `a.clone()` when you need another value under the type's `Clone` contract.
`string.clone()` creates independent backing; `Arc<T>.clone()` retains another
shared claim. Collection
`Clone` implementations clone their elements according to each element's
`Clone` contract. Generic code can request `T: Clone` explicitly.

## Choosing A Shape

Use this checklist:

```text
Is it just data?                         Use a value.
Do you own many of them?                 Use List/Map/Set.
Is it a relationship to owned data?       Use ID/index/handle.
Can deletion reuse slots?                Use generational handles or SlotMap.
Is the count compile-time fixed?          Use [N]T.
Need owned indexed storage with runtime capacity? Use [:]T.
Does a function mutate one caller value?  Use &T.
Does a function mutate a range?           Use []T.
Does it need unique heap identity?        Use ^T.
Is it C/hardware/raw memory?              Use *T, usually in unchecked code.
```

## Common Anti-Patterns

Avoid Java-style pointer graphs:

```cyna
struct Order {
    user: ^User;
    items: List<^OrderItem>;
}
```

Prefer ownership plus relationships:

```cyna
struct Order {
    user_id: UserId;
    items: List<OrderItem>;
}
```

Avoid storing aliases:

```cyna
struct Bad {
    user: &User;
}
```

Prefer IDs, indexes, owned values, or owned pointers depending on the actual
ownership model.

Avoid raw pointers in normal APIs:

```cyna
fn parse(ptr: *u8, len: usize): Packet;
```

Prefer slices:

```cyna
fn parse(bytes: []const u8): Packet;
```

For MMIO and device registers, prefer a packed layout type plus a volatile raw
pointer rather than trying to push hardware access through ordinary aliases:

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

That keeps the model honest:

- `packed struct` describes layout
- `*volatile T` describes volatile device-memory access
- `&T` stays for safe aliasing of ordinary program-owned memory

Prefer whole-register volatile reads and writes first. Be cautious with packed
bitfield mutation on MMIO registers, because a field update may require a
read-modify-write sequence that is correct for some registers and wrong for
others.

## Guiding Principle

Cyna should be honest about pointers without making pointer-heavy programming
the default.

```text
Values compose.
Containers own.
IDs relate.
Pointers point.
Some pointers own.
Some pointers only view.
```
