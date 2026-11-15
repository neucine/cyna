# Cyna Semantics

This document is the canonical semantic companion to `SPEC.md`. It includes
the core invariants and the proof-oriented model in one place. `SPEC.md`
defines the normative language contract; this document explains that contract
through places, ownership, provenance, and checker rules. Architecture
decisions and historical designs live in the central daydream repository.

The goal of this file is not to replace the spec with formal notation. The
goal is to make the language semantics small, explicit, and proof-complete
enough that later implementation work can be judged against one stable model.

## Core Invariants

- A value is data; a place identifies storage. Assignment changes a place.
- `&T` permits observation and mutation of its place; `&const T` permits
  observation. A mutable alias may narrow to a const alias, never the reverse.
- An ownership-bearing value has one active owner. Handoff makes the source
  unavailable; projection alone does not remove ownership from a field or slot.
- Borrow validity follows the roots and projections that produced the borrow.
  Cyna does not ask users to write lifetime parameters.
- `take` removes ownership only from supported optional places. Method calls
  follow ordinary call, protocol, and ownership rules.
- Function arguments, sequence items, and binary operands evaluate left to
  right unless a more specific rule applies. Struct layout follows declaration
  order; field initializers evaluate in written order.
- Contextual sequence literals use a visible `@syntax.sequence_literal`
  factory for library targets. Direct library slicing uses the accessible
  `@syntax.slice_view` method; the ordinary call determines provenance.
- Assignment, calls, returns, and aggregate construction apply the ordinary
  ownership rules to their inputs. Cleanup follows ownership state on every
  exit, including early return and error propagation.
- Generic code is monomorphized. Inferred ownership and operator requirements
  and declared protocol requirements are distinct compiler facts.

The detailed rules and limits of these statements are in the sections below
and in `SPEC.md`. The executable implementation may have narrower coverage;
see `STATUS.md` for known gaps.

## How To Read This Document

This document now has three different jobs, and they are separated on purpose:

1. conceptual guide
2. formal semantic core
3. proof and implementation alignment

Use the parts this way:

- Part I explains the semantic ideas in normal language and examples
- Part II introduces the formal objects, judgments, and rule schemata
- Part III explains proof targets, worked examples, and how the current
  implementation should align with the model

If a section feels more formal than you need, it is safe to skip ahead to the
worked examples and come back later.

Quick reader map:

- Language/design readers: Part I, then `Worked Examples`
- Compiler/runtime implementers: Part II, then `Implementation Alignment`
- Proof/formalization work: Part II, then Part III

# Part I. Conceptual Guide

## Goal

The model should explain, with one connected theory:

- value behavior and borrowed access
- places and projections
- borrow and alias formation
- provenance and escape
- mutation and invalidation
- dense and sparse storage
- `take`, handoff, ordinary calls, and `drop`
- aggregates and recursive cleanup
- interprocedural borrow effects
- the finite abstract domains needed for a practical static checker

The central claims are:

> ownership belongs to places, not to syntax shapes

and:

> projection does not silently detach ownership

Those two ideas are the semantic center of Cyna.

## Semantic Layers

The semantics are easiest to understand in three layers:

1. dynamic/runtime meaning
2. abstract static checker model
3. interprocedural summary model

The static model does not need to reconstruct one exact runtime history. It
must instead soundly over-approximate all relevant runtime possibilities.

## Runtime Versus Static Provenance

At runtime, a borrow or view depends on one concrete source history.

Examples:

- `&x` depends on local `x`
- `pair.left[..]` depends on the storage denoted by `pair.left`
- `text.bytes()` depends on the `string` value `text`
- `if cond { a } else { b }` picks exactly one concrete source at runtime

The checker therefore tracks an abstract set of possible sources rather than
one exact source.

The soundness requirement is:

> every runtime borrow source must be represented in the static model

Extra possibilities are allowed. Missing possibilities are unsound.

## Conceptual Vocabulary

The language model is stated in terms of these objects.
Use the [terminology glossary](GLOSSARY.md) for the same public terms used by
the spec. Formal judgments retain short labels where they identify a distinct
abstract value form.

The intended semantic pipeline is:

1. identify a place or derived view
2. identify the access mode requested at this use site
3. determine the resulting value form
4. apply provenance, invalidation, escape, and cleanup rules to that result

Most ownership confusion happens when step 2 and step 3 are left implicit.

The formal versions of these same objects appear in Part II. Part I is
deliberately lighter-weight and focuses on how to read ownership behavior.

### Value Behavior And Borrowed Access

A value has one of three assignment and cleanup behaviors:

- `plain`
- `shared`
- `owned`

An alias or view is borrowed access to storage held elsewhere. Borrowed access
carries provenance. Its carrier can be copied as a plain value without copying
the source storage. That dependency is tracked separately from value behavior.

### Place

A binding is a name attached to a value. Its root place is the storage
location named by that binding. A place is any storage-bearing location that
may own or expose a value, including a projected subplace.

Examples:

- `x`
- `pair.left`
- `items[i]`
- `token.ident`

Ownership belongs to places, not to syntax nodes.

A place may be:

- a root place such as `x`
- a projected subplace such as `user.name`
- a detachable place such as an optional slot that supports `take`

Two different "root" ideas matter here:

- binding root: a local/global binding name such as `x` or `a`
- ownership root: the existing owner/place that still carries cleanup responsibility

These do not always coincide.

For example, with an explicit alias borrow:

```cyna
const a = &xs[i].f.g;
```

`a` is a new binding root as a local name, but its alias still has provenance
rooted in `xs`. A local `const` can now name an owned indexed element when its
place has a tracked owner dependency. Nested owned paths use successive
projected bindings so each step retains that dependency. A local `const`
destructuring pattern creates those steps for positional indices and fields;
an owned initializer moves as a whole, while its leaves remain projections.
Value-returning indexing hooks and roots without a tracked dependency do not
qualify. See [SPEC §4](SPEC.md#4-declarations) and [§9](SPEC.md#93-narrowing-and-projection).

### Projection

A projection is navigation from a base place or value to a subplace or derived
view.

Projection steps include:

- field
- index
- payload
- view-producing step such as `[..]` or `bytes()`

Projection identifies a subplace. It does not by itself authorize handoff or
detachment.

The important distinction is:

- root place: the whole ownership-bearing place such as `x` or `user`
- projected place: a subplace such as `user.name`, `items[i]`, or `slot.some`
- projected view: a non-owning derived access such as `text.bytes()` or `xs[..]`

This is where confusion often starts, so the intended reading is:

- a root handoff passes the owned subtree rooted at the whole place
- a projection borrow creates non-owning access to part of that place
- a projection does not by itself permit subobject handoff
- subobject removal must go through an explicit detach/removal operation
  supported for that place shape, such as `take` on an optional place

Examples:

```cyna
var other = user;          // root handoff or copy, depending on user's type
const name = &user.name;   // projection borrow
const bytes = text.bytes(); // projection borrow/view
```

and, importantly:

```cyna
var p = user.profile;      // not "projection borrow"; this is ordinary read,
                           // copy, or whole-field handoff by the assignment rules
const old = take user.profile; // explicit projection detach, only where allowed
```

### Access Mode

Every use of a place asks for one access mode.

The core access modes are:

- read
- borrow
- mutate
- root handoff
- detach

They answer different questions:

- read: "what value does this place currently expose?"
- borrow: "can I form a non-owning access path to this place or view?"
- mutate: "can I update this place without violating live borrows?"
- root handoff: "can ownership of the whole rooted value leave here?"
- detach: "can ownership of a subplace be explicitly removed with a defined
  post-state?"

These modes are intentionally separate. In particular:

- borrow is not handoff
- read is not automatically borrow
- projection is not automatically detach
- detach is never implicit

### Place Access Capability

Place access is a separate axis from value type and provenance:

```text
Access ::= read_only | writable
read_only <= writable
```

The value type answers what a place contains. Access answers which operations
the current path authorizes. Provenance answers which storage roots a borrowed
result may depend on. None of these three substitutes for another.

Root access is determined by the carrier used to reach the place:

- a `const x: T` binding exposes read-only access through `x`
- a `var x: T` binding and ordinary parameters expose writable access
- `&const T` and `[]const T` expose read-only referent or element access
- `&T` and `[]T` expose writable referent or element access
- a const binding containing `&T` or `[]T` retains the carrier's writable
  referent or element access; a const binding containing `*T` likewise permits
  writable pointee access inside `unchecked`
- `&const T`, `[]const T`, and `*const T` are the spellings that restrict the
  accessed referent, elements, or pointee

Ordinary projection is capability-preserving:

```text
Access(project(base, step)) <= Access(base)
```

Therefore a field, index, or slice reached through read-only access cannot
produce writable access. Address formation reflects the resulting place:
`&place` has type `&T` for a writable place and `&const T` for a read-only
place. A writable alias or slice may narrow to its read-only form, never widen.

This rule is shallow. If an ordinary field value is itself an alias, reading
that field preserves the capability stored in the alias value. For example, a
read-only `View` containing `target: &T` may yield that stored `&T`; it does not
turn the referent into a deep-const object.

At control-flow joins, access uses the conservative meet: the result is
writable only when every incoming capability is writable. Root/projection
provenance is joined independently. Function, method, generic, protocol, and
aggregate boundaries all preserve the same rule through their declared types;
no body-based receiver-mutability inference or protocol-specific upgrade is
permitted.

### Resulting Value Form

A successful read or borrow produces a value in one of these semantic forms:

- plain value
- shared value
- owned value
- borrowed projection value

The key case is borrowed projection value.

This means:

- the use site reads through a place or projection
- the result does not own detached storage
- the result still depends on an existing owner/root
- the result therefore carries provenance and participates in invalidation

Examples:

- reading `x: i32` yields a plain value
- reading `text: string` yields a shared value
- reading a whole owned root in a handoff position yields an owned value
- explicitly borrowing `&xs[i]` or `&root.b[2].d` yields a borrowed
  projection value without detaching the owned element or subfield

An explicit borrow may be bound to a standalone local name while still
depending on its source:

```cyna
const a = &xs[i].f.g;
```

Here:

- `a` is the root place for the local binding itself
- the value stored in `a` may still depend on ownership rooted in `xs`
- that dependence remains while the alias is live

The borrow-carrying result differs from:

- "plain copied value"
- "ownership handoff"

Plain `xs[i].f.g` in a handoff-shaped position is rejected when `g` is an
owned value. It does not silently create this borrowed result.

Part II will formalize this as `ValueForm`, `Provenance`, and `Escapes(...)`.

### Provenance

`Provenance` is the abstract possible-source information carried by a value.

It answers:

- does this value depend on borrowed storage?
- which roots may that storage come from?
- may that dependence escape to the target context?

### Borrowed Place

`BorrowedPlace` is the abstract dependency used for mutation and invalidation
reasoning.

It contains:

- normalized roots
- a projection path
- a borrow mode

Borrow mode distinguishes:

- alias-style borrow: overlap-sensitive
- view-style borrow: invalidation-sensitive

### Borrow Escape Relation

Call boundaries use an explicit relation describing where input-originated
borrow provenance may flow:

- return position
- global state
- sink parameter state

This is the interprocedural summary layer.

### Control-Flow State

At each program point, the checker has an abstract state over live locals,
including:

- type/ownership facts
- provenance facts
- borrowed-place dependencies
- any recoverable projection-origin facts

# Part II. Formal Core

## Formal Core Objects

This section names the minimal mathematical objects the proof-oriented model
should use. The goal is not maximal notation. The goal is that later semantic
rules can refer to one small vocabulary rather than restating intuition.

Part I introduced these ideas conceptually. Part II gives them sharper formal
shapes. It intentionally avoids re-explaining all of the motivation from the
guide sections above.

### Root

A `Root` is a top-level ownership/provenance origin tracked by the model.

Typical root kinds include:

- local binding root
- parameter binding root
- global binding root
- temporary root introduced by an expression result

A root is not just a source-level name. It is an abstract identity used to say
which storage or owner a value may still depend on.

### Projection Path

A `ProjectionPath` is an ordered sequence of projection steps applied from a
root.

The core step forms are:

- `field(name)`
- `index(i)`
- `payload(case_name)`
- `view(kind)`

where `view(kind)` stands for view-producing projections such as slice or
byte-view formation.

The exact index expression need not always stay symbolic in the abstract model.
When exact identity is too expensive, the path may widen to a less precise form
such as "some index of this root".

### Place

A `Place` is:

```text
Place = Root × ProjectionPath
```

where the path may be empty.

So:

- `x` is a place with root `x` and empty path
- `user.profile` is a place with root `user` and path `.profile`
- `xs[i].f.g` is a place with root `xs` and path `[i].f.g`

The formal model cares about this distinction because ownership and mutation
reasoning happen over places, not over syntax trees directly.

### Value Form

A `ValueForm` classifies the semantic result produced by a read or borrow:

- `plain`
- `shared`
- `owned`
- `borrowed_projection`

`borrowed_projection` records an access dependency in this judgment. It is not
a fourth assignment or cleanup behavior.

The important case is `borrowed_projection`, which means the result:

- came from an explicit borrow/view operation through a place or projection
- is not detached owned storage
- still carries dependence on an ownership/provenance root

This is the formal slot for expressions such as:

```cyna
const a = &xs[i].f.g;
const v = xs[i].f.g[..];
```

when the operation is an explicit alias or view borrow. It is not the meaning
of plain `xs[i].f.g` in a handoff-shaped context.

### Provenance

A `Provenance` value records the possible roots a non-detached result may still
depend on.

A useful core shape is:

```text
Provenance = set of (Root, dependency_kind)
```

where `dependency_kind` distinguishes cases such as:

- alias-style dependence
- view-style dependence
- projected owned-value dependence

The exact set may be widened when control flow merges or when exact projection
identity is too expensive to preserve.

### Borrowed Place

A `BorrowedPlace` is the abstract dependency used for invalidation checks.

A useful core shape is:

```text
BorrowedPlace = (roots, projection_path, borrow_mode)
```

where:

- `roots` is a normalized root set
- `projection_path` identifies the borrowed subplace or view origin
- `borrow_mode` distinguishes alias-style and view-style invalidation

This is more precise than raw provenance alone because mutation checks need to
know not only "which root?" but also "which part of which root?".

### Detachability

`Detachability(place)` is the predicate that says whether a place supports
explicit ownership-removing detach in safe code.

In v1:

- writable `?T` places are detachable
- sparse slots `[;]T[i]` are detachable because they have optional-slot semantics
- dense element places `[:]T[i]` are not detachable
- ordinary projected fields are not detachable unless their place shape is
  itself detachable

This predicate is what separates:

- projected read
- projected borrow
- explicit projected detach

### Overlap

`Overlaps(p, q)` is the relation used by mutation and invalidation rules.

It should conservatively answer whether two places may refer to the same
storage or to storage whose mutation/drop would invalidate the other.

Write:

```text
p = (rp, pathp)
q = (rq, pathq)
```

Then the conservative core definition is:

1. if `rp ≠ rq`, then `Overlaps(p, q)` is false unless prior analysis has
   already unified the roots conservatively
2. if `pathp = pathq`, then `Overlaps(p, q)` is true
3. if one path is a strict prefix of the other, then `Overlaps(p, q)` is true
4. if the paths first differ at two `field(name)` steps with different field
   names of the same aggregate object, then `Overlaps(p, q)` is false
5. if the paths first differ at two `payload(case)` steps of the same union and
   the cases are known distinct, then `Overlaps(p, q)` is false
6. if the paths first differ at two `index(i)` steps:
   - exact same index means overlap
   - proven distinct exact indices may be treated as non-overlapping for fixed
     disjoint element places
   - unknown or widened index identity must conservatively overlap
7. if either path contains a widened or unknown projection component, overlap
   may be conservatively forced to true
8. if either path contains a `view(kind)` step, overlap is checked against the
   underlying root/path region conservatively; unless a stronger disjointness
   fact is available, views overlap the storage they are derived from

Useful intuition:

- ancestor/descendant places overlap
- sibling fields of the same struct do not overlap
- sibling union payload cases do not overlap when the active case distinction is
  known
- uncertain index identity collapses toward overlap, not away from it
- views are invalidation-sensitive aliases of underlying storage, not detached values

The model may widen overlap to remain sound; it must never narrow unsafely.

### Escape Relation

`Escapes(v, target)` is the semantic question "may the provenance carried by
value `v` flow into target context `target`?"

Core target contexts include:

- return position
- outer/local assignment target
- field or index write target
- global state
- sink parameter at a call

Write:

```text
v = (vf, π)
π = {(r1, k1), ..., (rn, kn)}
```

Then the conservative core definition is:

1. if `π` is empty, `Escapes(v, target)` is true
2. if `vf` is `plain` or `shared` and the language-level copy/share rule
   severs borrow dependence, `Escapes(v, target)` is true
3. if `vf` is `borrowed_projection`, `Escapes(v, target)` is true only when
   every provenance root in `π` outlives `target`
4. if `vf` is `owned` because cleanup responsibility was explicitly detached or handed off,
   escape is governed by ordinary ownership rules rather than borrowed
   provenance
5. if any provenance source in `π` may be invalid before or during the lifetime
   of `target`, `Escapes(v, target)` is false

The core target cases are:

- `return_position`
  Allowed only when the carried provenance may outlive the callee frame.

- `assignment_target(dst)`
  Allowed only when the destination lifetime does not outlive every provenance
  source carried by `v`. Rebinding a short-lived local from another short-lived
  local may be legal; storing into a longer-lived destination may not be.

- `write_target(p)`
  Allowed only when the place being written does not outlive the provenance
  roots carried by `v`.

- `global_state`
  Requires that the provenance be valid for the entire global lifetime; in
  practice this means borrowed local/view provenance usually cannot escape here.

- `sink_parameter(i)`
  Allowed only when the callee's summary permits that provenance to flow into
  parameter `i`'s destination lifetime.

Useful intuition:

- returning a view into a dead local frame fails `Escapes`
- returning a view derived from a parameter may succeed if the parameter root
  outlives the return destination
- assigning a projected borrowed result to a fresh local does not automatically
  fail; the question is whether the destination outlives the provenance roots
- storing borrowed provenance into longer-lived state is rejected unless the
  source roots are known to outlive that state

Escape is therefore a lifetime/provenance comparison between the value being
placed and the destination context, not merely a syntactic check on whether the
expression contains `&`.

## Value Behavior And Borrowed Access

Plain, shared, and owned classify assignment and cleanup of values. Borrowed
access is a separate dependence on an existing place; it does not create
another holder of that place's cleanup responsibility.

### Plain

Examples:

- integers
- `bool`
- enums
- structs and arrays composed only of plain values

Semantics:

- assignment copies
- field/index reads are ordinary value reads
- no ownership bookkeeping

### Shared

Examples:

- `string`
- `Arc<T>`

Semantics:

- assignment shares backing or retains another shared claim
- values are immutable at the language level
- `.clone()` requests distinct backing for strings or another claim for `Arc<T>`
- `drop` is runtime-defined shared release logic

Important:

- `string` itself is not a borrow
- `string.bytes()` returns `[]const u8`, which is a borrow

### Owned

Examples:

- `[:]T`
- `[;]T`
- `List<T>`
- `Map<K, V>`
- `Set<T>`
- `^T`
- aggregates containing owned fields

Semantics:

- assignment hands off ownership unless an explicit `Clone` call creates another value
- `.clone()` duplicates according to the type's `Clone` contract
- `drop` recursively releases owned structure

### Borrowed Access

Examples:

- `&T`
- `[]T`
- `[]const T`
- view results such as `string.bytes()`

Semantics:

- value is non-owning
- lifetime depends on source provenance
- escape is legal only if source storage outlives destination

## Storage Foundations

The language-level ownership-bearing storage foundations are:

- `[:]T` for dense storage
- `[;]T` for sparse storage

Higher-level containers should be explained in terms of these foundations,
not as separate ownership species.

### `[:]T` Dense Storage

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

Key semantic rule:

> dense initialized slots always hold real `T`

So a dense place may be read, written, borrowed, or copied, but safe code does
not silently move out of it because that would create a hole in initialized
dense storage.

### `[;]T` Sparse Storage

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

Key semantic rule:

> sparse slots have an explicit empty state

So sparse places support explicit detach through `take`, because the post-state
can be validly represented as empty.

### Why The Split Matters

This gives a small proof-friendly rule:

- dense place: no ordinary move-out
- optional or sparse place: explicit `take` may transition to empty

In particular:

- `take sparse[i]` is allowed because a `[;]T` slot has optional-slot semantics
- `take dense[i]` for `dense: [:]T` is not part of safe v1 because a dense
  element place has type `T` and no language-defined empty post-state

That is enough to explain removal without introducing container-specific
ownership magic.

## Library Containers

`List<T>`, `Map<K: Eq, V>`, and `Set<T: Eq>` are ordinary library containers.

They are not separate storage primitives in the language model. Construction
uses ordinary prelude functions (`list`, `list_from`, `set`, `map`, and
`slot_map`) followed by ordinary container methods. Collection literals remain
closed syntax for compiler-defined storage forms; no construction hook or
protocol changes their meaning.

The intended semantic explanation is:

- `List<T>` is a growable dense container layered on `[:]T`
- `Set<T>` is a library container layered on sparse storage semantics
- `Map<K, V>` is a library container layered on sparse entry storage semantics

Set membership and Map key lookup use the declared `Eq` capability through
borrowed keys. This is ordinary static generic dispatch and does not make `==`
protocol-backed.

Current limitation note:

- while borrow-carrying iterator/view structs are still restrictive, iteration
  may be modeled through a lightweight iterator state plus a container-relative
  locator
- in that temporary model, the iterator advances traversal state and the item
  read still happens through the container's ordinary indexing/projection rules
- this keeps ownership reasoning concentrated in projection semantics instead
  of hiding borrowed item access inside iterator return values
- the locator may be an integer slot today for dense and sparse storage, but
  the semantic role is intentionally broader than "every iterable is an array"
- when a container's `Index.Output` is an ownership-bearing item by value,
  direct indexed reads and iteration are rejected before lowering; v1 requires
  a borrowed-index or explicit owned-copy/removal surface for that operation

## Formal Projection And Access

Part I already introduced the intuition for projection. This section keeps only
the distinctions that the later rule schemata rely on.

### Root Handoff

Root handoff passes cleanup responsibility for the whole owned subtree rooted
at a place.
After root handoff, the source root is unavailable because its ownership has
left that root.

### Projection Borrow

Projection borrow creates a non-owning path into an existing root. After
projection borrow, the owner still owns the storage. What changes is
that later mutation, drop, handoff, or overwrite of the relevant root or
overlapping subplace may now be rejected while the borrow is live.

Borrow may be spelled explicitly, such as `&root.leaf`, but the semantic model
must also be able to represent read results that are borrow-carrying
projection values. Otherwise common nested/container reads become artificially
forced into either handoff or rejection.

### Projection Detach

Projection detach removes ownership from a subplace while leaving the outer
root itself still present in some updated state. It is not the default meaning
of projection syntax; it requires an explicit removal operation with a defined
post-state, such as `take` on a detachable place.

### The Core Question For A Use Site

For an expression such as:

```cyna
root.b[2].d
```

the semantic question is not simply:

- "is this projected?"

The correct sequence is:

1. identify the place: root `root`, projection path `.b[2].d`
2. identify the access mode demanded by the context
3. determine the result form

Examples:

```cyna
const p = &root.b[2].d;
```

- place: projected subplace `.b[2].d`
- access mode: borrow
- result form: borrowed projection value / alias

```cyna
const old = take root.profile;
```

- place: detachable projected subplace `.profile`
- access mode: detach
- result form: detached owned value plus source post-state `none`

```cyna
var a = root.b[2].d;
```

- place: projected subplace `.b[2].d`
- access mode: read
- result form depends on the projected type

For that last example:

- if `d` is plain, the result is a plain copied value
- if `d` is shared, the result is a shared value
- if `d` is borrow/view-shaped, the result is a borrowed value
- if `d` has an owned type, the plain projected read is rejected in this
  binding context; spell `.clone()`, `take` on a detachable place, `&`, or `[..]`
  to state the intended operation

So the semantic invariant is:

> projection path selection and ownership-removal are different decisions

## Formal Rule Schemata

This section states the minimal rule shapes that later proofs should refine.
They are intentionally lightweight. The purpose is to connect the formal core
objects to the operations programmers actually write.

Part I explained the semantic ideas in prose. This section recasts the same
ideas as compact judgments and side-condition-driven schemata.

### Rule Form

For a use site involving expression `e`, the semantic pipeline is:

1. resolve `e` to a place or non-place expression source
2. determine the requested access mode from context
3. determine the resulting value form
4. update abstract provenance / borrowed-place / root-availability state

Most ownership questions are answered by those four steps.

The individual rules below intentionally avoid re-explaining the conceptual
motivation from Part I; they assume that guide material and focus on the formal
shape.

For proof-oriented discussion, it is useful to name a lightweight judgment form:

```text
Γ ; Σ ⊢ e ⇓ (vf, π, Σ')
```

Read this as:

- under static typing/context facts `Γ`
- and abstract checker state `Σ`
- expression `e` evaluates in the semantic model
- to result form `vf`
- carrying provenance `π`
- and producing updated abstract state `Σ'`

This notation is intentionally abstract. It does not force one exact concrete
machine representation. It is only a compact way to state the rule shape.

For place-resolving expressions, it is also useful to name a companion judgment:

```text
Γ ; Σ ⊢ e ⇝ p
```

meaning:

- expression `e` resolves to place `p`

where `p` is a `Place = Root × ProjectionPath`.

When an operation is only valid for detachable places, we write:

```text
Detachability(p)
```

as a side condition.

When an operation must respect live borrows or views, we write:

```text
Overlaps(p, q)
```

and:

```text
Escapes((vf, π), target)
```

as side conditions describing:

- possible place overlap for invalidation
- possible provenance escape into the target context

The intent is that later rules can be stated as small judgments plus side
conditions instead of restating the full prose each time.

### Read Rule

If a context requests an ordinary read from place `p`, then:

1. resolve the place `p = (root, path)`
2. classify the type at `p`
3. choose the resulting `ValueForm`

The result form is:

- `plain` for plain types
- `shared` for shared types
- `owned` only when the read is a whole-root handoff-position read
- `borrowed_projection` when the expression explicitly forms a borrow or view
  through a projection, such as `&x.y` or `x.y[..]`

Plain projected owned value access is handoff-shaped in safe v1. Without an
explicit `.clone()` call, `take`, `&`, or `[..]`, it is rejected in
handoff-shaped contexts:

```text
Γ ; Σ ⊢ e ⇝ (r, path)
path ≠ ε
value_behavior(projected_type(e)) = owned
no explicit detach/removal applies
context is handoff-shaped
────────────────────────────────────────────────────────────── Read-Projected-Handoff-Reject
Γ ; Σ ⊢ e ⇓ invalid
```

A narrow declaration rule admits `const field = owner.owned_field` when
`owner` is a live owning local of an ordinary unpacked struct. The resulting
binding has projected mode and a checked owner-field path. Transitive
`const same = field` and eligible nested field bindings retain that path.
Its read is a borrowed projection; it carries no cleanup or ownership handoff.
Overlapping mutation, detach, replacement, or owner movement is rejected while
the binding is live. Owned sinks still reject it. This rule does not apply to
indexed places, checked payloads, temporary roots, packed fields, or `var`.

Outside this declaration rule, plain projected owned value access does not
become an implicit borrow.

So for:

```cyna
const a = xs[i].f.g;
```

if `g` has an owned type and the read is not an explicit supported duplication
operation, `take`, alias borrow, or view borrow, the binding is rejected as
attempted projected handoff.

### Explicit Borrow Rule

If a context requests borrow formation from place `p`, such as:

```cyna
&x
&user.name
xs[..]
text.bytes()
```

then the result is non-owning and records:

- provenance rooted in the source place
- a `BorrowedPlace` for invalidation

The owner/root remains available, but later mutation, overwrite, drop, or
handoff of overlapping storage may be rejected while that borrow is live.

### Ordinary Method Calls

A method call follows its declared receiver, arguments, return type, and
protocol requirements. For example, `p.clone()` requires `p`'s type to
implement `Clone`, borrows `p` through `&const Self`, and returns the value
produced by that implementation. Its result and provenance follow the method's
contract; cloning is not a separate language ownership operation.

### Take Rule

If a context requests `take p`, then `Detachability(p)` must hold.

If it does not hold, the operation is invalid in safe code.

If it does hold, then:

1. the current occupant/result is produced
2. the place is rewritten to its defined empty post-state
3. later state observes the post-`take` place, not the old occupant

In v1 this means:

- optional places `?T` support `take`
- sparse slots `[;]T[i]` support `take`
- dense element places `[:]T[i]` do not support `take`

One useful rule schema is:

```text
Γ ; Σ ⊢ e ⇝ p
Detachability(p)
occupant_provenance(p, Σ) = π
Σ' = rewrite_to_empty_post_state(p, Σ)
────────────────────────────────────────────────────────────── Take-Detach
Γ ; Σ ⊢ take e ⇓ (value_form(type_of(e)), π, Σ')
```

The result has the optional-place type. Its value form depends on that type;
`take` is not limited to resource payloads.

And the corresponding rejection shape is:

```text
Γ ; Σ ⊢ e ⇝ p
¬Detachability(p)
────────────────────────────────────────────────────────────── Take-Reject
Γ ; Σ ⊢ take e ⇓ invalid
```

For optional and sparse-slot places, the dynamic source-level result may still
be represented as an optional-shaped value at the language surface. The core
point of the rule is that `take` is the explicit ownership-removing operation
and that it rewrites the source place to its empty post-state.

### Assignment Rule

For `dst = src`, determine both:

1. the access mode used to read `src`
2. the update mode used to write `dst`

Then:

- plain assignment copies plain values
- shared assignment shares according to shared-value rules
- whole-root owned assignment hands off ownership when the source read is a
  root-handoff read
- assigning an explicit `borrowed_projection` result does not silently detach
  the source; the target receives a value whose legality still depends on
  escape and provenance rules

Assignment therefore does not erase provenance just because the destination now
has a standalone binding name.

One useful whole-root handoff rule schema is:

```text
Γ ; Σ ⊢ src ⇝ (r, ε)
owned_root_available(r, Σ)
read_mode(src) = root_handoff
Σ1 = mark_root_unavailable(r, Σ)
Σ2 = bind_owned_root(dst, r, Σ1)
────────────────────────────────────────────────────────────── Assign-Root-Handoff
Γ ; Σ ⊢ dst = src ⇓ Σ2
```

This is the assignment shape where ownership really leaves the source root and
the source becomes unavailable afterward.

The contrasting explicit projected-borrow rule shape is:

```text
Γ ; Σ ⊢ src ⇓ (borrowed_projection, π, Σ1)
Escapes((borrowed_projection, π), assignment_target(dst))
Σ2 = bind_value_with_provenance(dst, borrowed_projection, π, Σ1)
──────────────────────────────────────────────────────────── Assign-Explicit-Projected-Borrow
Γ ; Σ ⊢ dst = src ⇓ Σ2
```

This captures the important non-rule:

- naming the result at `dst` does not convert it into detached ownership
- the destination binding may still carry provenance rooted elsewhere
- later escape and invalidation checks still consult that provenance

So for:

```cyna
const a = &xs[i].f.g;
```

the local `a` is a binding root in the local environment while holding an alias
whose provenance is rooted in `xs`. A plain projected owned value read remains
rejected in a handoff-shaped binding context.

### Return Rule

`return e` is a read of `e` in escape position.

So the model must:

1. determine the result form of reading `e`
2. compute the provenance carried by that result
3. check `Escapes(result, return_position)`

Consequences:

- returning a whole owned root in a handoff position is allowed when ordinary
  ownership rules allow that handoff
- returning a plain or shared value follows its ordinary rules
- returning a borrowed-projection result is allowed only if its provenance
  sources outlive the return destination

One useful rule schema is:

```text
Γ ; Σ ⊢ e ⇓ (vf, π, Σ')
Escapes((vf, π), return_position)
────────────────────────────────────────────────────────────── Return-Ok
Γ ; Σ ⊢ return e ⇓ ok
```

and the rejecting counterpart:

```text
Γ ; Σ ⊢ e ⇓ (vf, π, Σ')
¬Escapes((vf, π), return_position)
────────────────────────────────────────────────────────────── Return-Reject
Γ ; Σ ⊢ return e ⇓ invalid
```

This is why:

```cyna
return xs[i].f.g;
```

is rejected in safe v1 when `g` has an owned type unless the program spells a
supported explicit duplication operation, `take`, alias borrow, or view borrow
that is valid in return position.

### Mutation Rule

A mutation of place `p` is legal only if it is compatible with every live
`BorrowedPlace`.

Concretely, for each live borrowed place `b`:

- if `Overlaps(p, b)` is false, mutation may proceed with respect to `b`
- if `Overlaps(p, b)` is true, the checker consults `borrow_mode`
- if the mode says mutation could invalidate the borrowed access, the mutation
  is rejected

One useful acceptance rule schema is:

```text
Γ ; Σ ⊢ target ⇝ p
for every live borrowed place b in Σ:
    Overlaps(p, b) = false
    or borrow_mode_allows_mutation(p, b)
Σ' = perform_mutation_effects(p, Σ)
────────────────────────────────────────────────────────────── Mutate-Ok
Γ ; Σ ⊢ mutate(target) ⇓ Σ'
```

And the rejecting counterpart is:

```text
Γ ; Σ ⊢ target ⇝ p
b is live in Σ
Overlaps(p, b)
borrow_mode_blocks_mutation(p, b)
────────────────────────────────────────────────────────────── Mutate-Reject
Γ ; Σ ⊢ mutate(target) ⇓ invalid
```

This same rule shape covers:

- overwriting through assignment
- mutation through alias/view-sensitive APIs
- root handoff that would invalidate a live borrow
- `drop` of storage still needed by a live borrow
- `take` from a detachable subplace that overlaps a live borrow

This is the core shape behind alias invalidation, view invalidation, and live
borrow checks during overwrite, drop, handoff, and `take`.

## Worked Examples

These examples sit immediately after the formal rule schemata on purpose. They
are intended as the fastest way to connect the judgments above back to concrete
source forms.

### 1. Projected Owned-Value Read Into A Local

Source:

```cyna
const a = xs[i].f.g;
```

Assume `g` has an owned type and no explicit detach/removal is involved.

Semantic reading:

1. resolve `xs[i].f.g` to place `(xs, [i].f.g)`
2. the read is projected, not whole-root handoff
3. the binding context is handoff-shaped
4. `Read-Projected-Handoff-Reject` applies unless the program spells `.clone()`,
   `take`, `&`, or `[..]`

Important consequence:

- plain `const a = xs[i].f.g` does not create a borrowed local
- the user must choose explicit cloning, detachable removal, alias borrow, or
  view borrow explicitly

### 2. Returning A Projected Owned-Value Read

Source:

```cyna
return xs[i].f.g;
```

Assume again that `g` has an owned type and is not explicitly detached.

Semantic reading:

1. resolve `xs[i].f.g` to place `(xs, [i].f.g)`
2. the return context is handoff-shaped
3. `Read-Projected-Handoff-Reject` applies unless the program spells `.clone()`,
   `take`, `&`, or `[..]`

Important consequence:

- this is not an implicit projected borrow
- if an explicit borrow/view is returned, the carried provenance must outlive
  the return destination, otherwise the return
  is rejected

### 3. Taking From A Sparse Slot

Source:

```cyna
const item = take sparse[i];
```

Semantic reading:

1. resolve `sparse[i]` to place `(sparse, [i])`
2. `Detachability((sparse, [i]))` holds because sparse slots have optional-slot
   semantics
3. `Take-Detach` applies
4. the source place is rewritten to its empty post-state
5. the result carries the former occupant rather than leaving ownership behind

Important consequence:

- this is an explicit detach/removal operation
- later reads observe the emptied slot, not the old occupant

### 4. Escaping A Borrowed View Into Longer-Lived State

Source shape:

```cyna
views.push(text.bytes());
```

Assume `views` stores view values beyond the immediate expression and `text` is
not known to outlive that destination context.

Semantic reading:

1. `text.bytes()` forms a borrowed/view result with provenance rooted in `text`
2. storing that result into `views` is an escape into a destination context
3. `Escapes((vf, π), sink_parameter(i))` or the corresponding write-target form
   is checked
4. if the destination may outlive `text`, the escape is rejected

Important consequence:

- the failure is not because `bytes()` is special syntax
- the failure is because ordinary borrowed provenance cannot legally outlive
  the destination context

These examples are intentionally small. They are the kind of cases a future
mechanized model or executable reference checker should be able to derive
directly from the core judgments and side conditions in this document.

## Primitive Ownership Operations

The language can be understood in terms of a small set of primitive ownership
operations:

1. handoff
2. copy
3. borrow / alias
4. attach
5. drop
6. take from optional place

### Handoff

Handoff passes cleanup responsibility for a whole owned subtree from one
holder to another.

Ordinary assignment of an owned value is handoff. A preceding method call may
produce another value for assignment.

Root handoff is a place-to-place ownership operation, not a generic synonym for
"obtain a value from an expression". A projected value requires an explicit
detach or removal operation with a defined source post-state.

### Borrow / Alias

Borrowing creates a non-owning access path into a place.

The resulting value carries provenance derived from the source place.

Borrowing a projection does not detach the projected value from its owner. It
adds an alias/view dependency against the existing owner.

The same provenance/invalidation machinery is also what should justify
borrow-carrying projection results from ordinary reads when the language
chooses not to detach ownership from the projected place.

### Attach

Attach writes an owned value into a place that remains valid after the update.

This matters especially for optional and sparse storage, where empty-to-full
transitions are part of the model.

### Drop

`drop` recursively ends the storage lifetime of an owned subtree.

After `drop x`, the binding is unavailable on all reachable later paths.

### Take

`take` is the explicit detach operation.

It is allowed only on writable optional places, including sparse-slot shapes
that semantically behave like optional places.

This is why sparse and dense indexing differ:

- sparse indexing `[;]T[i]` behaves like an optional place and supports `take`
- dense indexing `[:]T[i]` names a dense element place and does not support
  `take` in safe v1

Its meaning is:

1. produce the current owned value
2. leave the place in its explicit empty state

So `take` is not merely "a special read of a projection". It is the language's
spelled-out projected handoff/removal operation for those supported places.

`take` exists precisely so that projected reads and projected borrows do not
have to double as implicit ownership-removing operations.

## Escape Rule

Borrow escape is checked with one principle:

> a value may escape only if every borrowed provenance source in its abstract
> provenance outlives the destination

This covers:

- return
- assignment into outer state
- field/index mutation into outer state
- storage in sink parameters
- global escape

## Invalidation Rule

Mutation safety is checked with one principle:

> a mutation is legal only if it does not invalidate any live borrowed place
> that may overlap or depend on the mutated place

This requires:

- normalized roots
- projection paths
- borrow mode

Alias-style and view-style borrows may use different invalidation predicates,
but they operate on the same borrowed-place abstraction.

## Join And Widen

Exact provenance is often unavailable after control-flow merges.

The checker therefore defines explicit join and widening behavior.

### Join

A join merges abstract state from multiple predecessor paths.

Examples:

- `if/else`
- loop back-edge
- recursion summary

For normalized root sets, join is set union until the precision cap is
reached. After the cap, the affected root kind widens to an imprecise summary.

For borrowed-place dependencies, join combines:

- roots by the root-set join
- projection paths by equality when both sides agree
- otherwise a conservative truncated or root-level dependence
- borrow mode by the conservative mode needed for invalidation

### Widen

When the checker cannot retain exact source precision cheaply or soundly, it
widens.

Common widening shapes:

- exact projection to less precise projection
- projected subplace to root-level dependence
- exact field/index identity to unknown projected overlap

Widening is acceptable if it preserves sound over-approximation.

## Interprocedural Summaries

Calls are modeled in two steps:

1. compute caller-side abstract provenance for each argument
2. substitute those provenances through the callee's escape relation

At minimum, a useful callable summary shape records:

- `return_escapes[i]`
- `global_escapes[i]`
- `param_escapes[i][j]`

Meaning:

- parameter `i` may contribute borrowed provenance to the return value
- parameter `i` may escape into longer-lived global state
- parameter `i` may be forwarded into sink parameter `j`

Methods do not need a separate theory. A receiver is just another summary
input.

## Soundness Invariant

The core invariant is:

> for every accepted program point, the static provenance and borrowed-place
> state over-approximate all runtime provenance and invalidation possibilities
> reachable at that point

Consequences:

- under-approximation is forbidden
- widening is allowed
- conservative rejection is allowed

## Proof Obligations

The model should be strong enough to justify these obligations:

1. borrowed provenance cannot outlive its source
2. dense places remain valid after update
3. projection cannot silently detach ownership
4. mutation respects existing aliases and views
5. call summaries are sound under substitution

These are the core proof obligations that implementation work should preserve.

# Part III. Proof And Alignment

## What Proof-Complete Means Here

"Proof-complete" in this context does not mean a finished mechanized theorem
prover artifact.

It means:

1. the language has one small semantic center
2. every safety-relevant rule can be reduced to that center
3. the intentional widening points are explicit
4. interprocedural effects fit the same provenance model
5. implementation gaps are visible as gaps, not hidden semantic forks

If new language features cannot be expressed in this model without inventing a
second ownership theory, the model is incomplete.

## Formalization Roadmap

The practical route to a solid formal semantics is to prove a small core first
and then treat richer surface features as desugarings or conservative
extensions of that core.

### 1. Freeze A Small Core Language

The first proof target should not be full surface Cyna. It should be a reduced
core with:

- locals and assignments
- structs and field projection
- optionals
- dense storage `[:]T`
- sparse storage `[;]T`
- indexing
- ordinary method calls
- `take`
- `drop`
- function calls and returns
- explicit borrow/view formation such as `&x` and `[..]`

Everything else should be understood either as:

- desugaring into this core
- library surface layered on this core
- future work outside the current proof target

### 2. Define Two Semantics

The core language needs two connected semantics:

- a concrete dynamic semantics describing runtime step behavior
- a static abstract semantics describing checker state and transfer rules

The proof goal is not that the static model predicts one exact execution. The
goal is that it soundly over-approximates all relevant executions.

### 3. Make Core Objects Fully Explicit

The following objects must be defined as first-class mathematical entities:

- places
- roots
- projection paths
- detachable places
- borrowed places
- provenance
- overlap / invalidation
- value forms

In particular, the formal model must make precise:

- when a projected read yields a plain/shared/owned/borrowed-projection result
- when two places overlap
- when a value may escape
- when `take` is legal
- what post-state `take` installs

### 4. State The Main Invariants Up Front

The core invariants should be stated as theorem targets rather than scattered
intuition. At minimum:

1. owned cleanup responsibility is unique at each reachable point
2. projection does not silently detach ownership
3. borrowed provenance does not outlive its source roots
4. mutation cannot invalidate a live borrowed place in accepted programs
5. `take` applies only to places with a defined empty post-state
6. sparse occupancy matches slot initialization state

### 5. Prove Runtime Preservation Lemmas

For the dynamic semantics, prove lemmas that each step preserves the relevant
well-formedness invariants, especially:

- store well-formedness
- root ownership uniqueness
- sparse occupancy/initialization agreement
- validity of post-`take` empty state
- cleanup/drop consistency

This is the Cyna-specific analogue of preservation.

### 6. Prove Checker Soundness As Abstract Interpretation

The static checker should be modeled as an abstract interpreter over:

- abstract provenance state
- abstract borrowed-place state
- join and widening
- callable summaries

Then prove:

- each abstract transfer function over-approximates the corresponding concrete step
- each join/widen remains sound
- accepted programs cannot reach runtime states that violate the ownership and
  invalidation rules represented by the model

### 7. Separate Language Meaning From Runtime Representation

The proof target must not depend on accidental runtime layout choices.

For example:

- `[;]T` means explicit occupancy semantics
- the runtime may implement that with a byte array today
- it could later use a bitmap without changing the language proof target

This separation prevents the semantics from being tied to current ABI details.

### 8. Track Conservative Rejection Explicitly

The formalization should distinguish:

- programs rejected because they are truly unsafe
- programs rejected because the current analysis is intentionally conservative

This matters because soundness allows conservative rejection, but proof-complete
docs should not hide that tradeoff.

### 9. Require Proof Obligations For New Features

Each new ownership-relevant feature should come with explicit answers to:

1. what is its runtime meaning?
2. what abstract state does it read or change?
3. what provenance can it create?
4. what invalidation can it cause?
5. can it detach ownership?
6. can it cause escape?
7. does it add a new root or place shape?

If a feature cannot be explained without introducing a second ownership theory,
the semantic model needs revision before the feature is considered complete.

### 10. Recommended Order Of Attack

The smallest useful staged plan is:

1. formalize the reduced core syntax
2. define concrete runtime semantics
3. define abstract checker semantics
4. prove the core invariants for locals, structs, optionals, dense/sparse
   indexing, `.clone()`, `take`, and `drop`
5. prove soundness of borrow-carrying projected reads
6. prove soundness of escape and invalidation checks
7. extend to interprocedural summaries

That is enough to cover the semantic center of v1 without waiting for every
surface feature to be formalized first.

## Implementation Alignment

The formal model in this document is intended to align with three different
implementation layers in the current compiler/runtime:

1. semantic analysis (`src/compiler/sema/sema.zig`)
2. lowering/backend-facing representation (`src/compiler/lower/lower.zig`)
3. runtime support (`src/runtime/runtime.c`, `src/runtime/cyna.h`)

The purpose of this section is not to restate implementation details. It is to
make clear which layer is responsible for preserving which part of the model.

### Semantic Analysis Responsibilities

The semantic-analysis layer should be the primary implementation of the static
abstract semantics described here. In particular, it should be where the
implementation justifies:

- place resolution
- provenance formation and propagation
- borrow escape checks
- invalidation / overlap checks
- root handoff availability rules
- detachability checks for `take`

Current implementation hooks that correspond to this role include the families
of checks around:

- borrowed provenance escape rejection
- live borrow invalidation / mutation conflict rejection
- implicit handoff lowering decisions
- borrow-escape summary construction for calls

If the implementation accepts or rejects a program for ownership reasons, the
semantic explanation should primarily live at this layer.

### Lowering Responsibilities

The lowering layer should preserve the semantic distinctions established by
semantic analysis rather than inventing new ownership meaning.

In particular, lowering is responsible for:

- preserving whether an operation is a read, copy, handoff, or detach
- lowering sparse reads and sparse `take` into distinct storage operations
- preserving optional-slot behavior for sparse indexing
- preserving dense-vs-sparse differences in generated lowering

Examples in the current implementation include lowering paths for:

- sparse index reads through direct occupancy/value checks
- sparse detach through direct slot take lowering
- sparse mutation through direct occupancy/value update lowering

If a semantic distinction exists in this document but disappears during
lowering, that is a semantic bug even if the generated code still "works" on
some examples.

### Runtime Responsibilities

The runtime is responsible for implementing the dynamic/storage behavior that
the language model assumes, but not for defining the meaning on its own.

In particular, runtime support should preserve:

- dense storage invariants
- sparse occupancy invariants
- post-`take` empty-state behavior
- copy/drop behavior required by lowered operations

For example:

- sparse `get`-style operations must not detach
- sparse `take` must both produce the prior occupant and clear occupancy
- sparse clear/drop must respect occupied-slot cleanup only

The runtime may change representation details, such as how sparse occupancy is
stored, without changing the semantic model, as long as these invariants remain
true.

### Alignment Checklist

When adding or reviewing an ownership-relevant feature, the implementation
should be checked against this document in this order:

1. does `sema` classify the feature using the core objects here?
2. does `sema` enforce `Escapes`, `Overlaps`, detachability, and root
   availability in the right cases?
3. does lowering preserve the semantic operation kind rather than collapsing
   distinct cases together?
4. does the runtime implement the post-state and cleanup behavior assumed by
   the lowered operation?
5. if the implementation is conservative, is that conservatism explicit in the
   docs and tests?

### Current Gaps To Watch

The most likely semantic drift points are:

- a checker decision that depends on implicit implementation intuition rather
  than one of the named objects/rules in this document
- lowering that treats projected read, detach, and copy as though they were the
  same operation kind
- runtime representation details leaking back into the language contract
- tests that prove behavior but do not yet name the underlying semantic rule

When one of those happens, the right fix is usually to update the semantic
model and the implementation together, rather than letting one silently outrun
the other.

### Current Audit Findings

The current `sema` implementation already has substantial machinery for
provenance propagation, borrow escape rejection, and mutation/invalidation
checks. The remaining alignment gaps are real, but they are narrower than an
initial audit pass suggested.

The most important current findings are:

- `take` already supports the intended ref-root shapes such as `&?T`,
  `&[:]?T`, and `&[;]T`. The semantic checker still starts from a local-name
  root and then walks field/index steps, but that local may itself have `ref`
  type, so the current implementation is broader than a superficial reading of
  the helper structure suggests. The still-important restriction is the place
  kind at the end of the path: dense `[:]T[i]` remains rejected unless the slot
  type itself is optional.

- projected owned value reads in handoff positions remain rejected. A narrow
  declaration exception admits `const field = owner.owned_field` for a stable
  owned field of an ordinary struct under a live owning local. That binding is
  non-owning and read-only. Indexed examples such as `const a = xs[i].f.g`,
  returns, assignments, and owned-value call arguments still require an
  explicit `.clone()`, `take`, `&`, or `[..]` where applicable.

- this projected-owned-value rejection is not only a surface-checker policy.
  The restricted struct-field binding uses an owner-field pointer with no
  owning slot or cleanup. Other ordinary projected reads can still materialize
  by-value `extract/load` operations, so removing their rejection without a
  place-preserving lowering path risks duplicate cleanup.

- the implementation is no longer uniform across all projection families.
  Borrowed struct-field and index-based container paths now have dedicated
  place-first lowering hooks, and many dense/sparse container operations route
  through those hooks. Borrowed union payload projection now also has an
  addressable place path through LIR `union_payload_ptr`, so the main remaining
  non-uniformity is not "union payloads vs everything else" but the broader
  conservative boundary around ordinary projected ownership handoff.

- sparse detach behavior is substantially aligned with the document. Sparse
  indexing is treated as optional-slot shaped for `take`, while dense indexing
  is not detachable and therefore fails the optional-place requirement.

- the escape side of the model remains useful for explicit borrowed/view
  projections and projected struct-field bindings. Other plain projected owned
  reads are rejected before escape reasoning as attempted implicit handoff.

These findings should currently be classified as:

- audit correction for `take` root-shape support, because the implementation
  already accepts the supported ref-root forms described by the current spec
- conservative safe-v1 rule for projected ownership handoff: direct projected
  access is rejected at owning sinks; stable owned struct fields may be named
  by `const` without creating a new owner
- partial alignment for sparse-vs-dense `take`
- internal representation note for places where the document names
  `borrowed_projection`: that classification is for explicit non-owning
  projection flows, not implicit plain projected ownership handoff

The practical consequence is:

1. keep the current conservative boundary well tested: plain projected
   handoff stays rejected, while owner-linked `const` struct-field bindings
   remain non-owning
2. keep explicit duplication through `Clone`, detachable operations such as `take`,
   alias borrows with `&`, and sequence view borrows with `[..]` as the
   supported escape hatches
3. use `borrowed_projection` internally for explicit non-owning projection
   flows, projected struct-field bindings, and borrowed receiver/place-first
   lowering, without granting implicit projected ownership handoff

### Internal Role Of `borrowed_projection`

`borrowed_projection` is an internal value-form classification for explicit
non-owning projection flows. It is useful for:

1. alias borrows such as `&x.y`
2. view borrows such as `x.y[..]`
3. borrowed receiver paths for container operations
4. place-first lowering that must avoid treating a projection as detached
   ownership

It is not a user-visible third meaning for plain `x.y`. For owned
projected values in safe v1:

- `x.y` in a handoff-shaped position is rejected as attempted handoff
- `x.y.clone()` asks for another owned value
- `take x.y` asks for detachable ownership removal where supported
- `&x.y` asks for alias borrow
- `x.y[..]` asks for a slice from a compiler-defined sequence storage type
- `x.y.view()` is an ordinary method call when a library type exposes a view

### First-Class `&T` and `&const T` Fields

Alias pointers are modeled as the single-place form of borrowed access,
symmetric with slices as the many-element borrowed view. The forms differ in
capability:

- `&T` aliases one complete place of type `T` and may support assignment,
  field mutation, method calls, or detachable-place operations that are valid
  for that place
- `&const T` aliases one complete place for observation and rejects mutation
  through that carrier; `&T` narrows to it but not conversely
- `[]T` views a contiguous range of element places and supports range and
  element operations, but it is not an alias to the original container object

All forms are non-owning and provenance-carrying. An aggregate containing any
of them is borrow-carrying. Handing off such an aggregate passes only the
borrowed capability and never passes cleanup responsibility for the source.
Read-only capability is local to the carrier and does not freeze mutation
through a separate valid mutable capability.

The ownership proof obligation for a stored `&T` field is the same as for a
stored slice field:

1. field initialization must attach provenance from the borrowed source
2. aggregate construction must combine provenance from all borrow-carrying
   fields
3. assignment, return, container insertion, global storage, and sink parameters
   must reject the aggregate unless every provenance root outlives the
   destination
4. mutation, handoff, detach, and drop of a source place must reject when they
   would invalidate a live borrowed-place dependency
5. aggregate drop must not drop through `&T`; cleanup responsibility remains
   with the original owner

This means `struct View { user: &User; }` has ordinary value movement for the
small reference carrier, but it is not an owned `User` and cannot erase the
borrow lifetime by being wrapped in another struct or generic container.

Proof sketch:

- Non-ownership: `&T` contributes no cleanup edge to the containing aggregate.
  Recursive cleanup therefore cannot double-drop the referent.
- Non-escape: every constructor for a value whose type may carry borrowed
  provenance combines field provenance into the result. Every escape target
  checks the result provenance with `Escapes`, so wrapping a borrow in any
  finite aggregate cannot hide a source root from the checker.
- Mutation safety: storing `&T` records a borrowed-place dependency. Any later
  mutation, handoff, detach, or drop of an overlapping source root must satisfy
  the borrowed-place invalidation rule. Alias-mode dependencies use overlap;
  view-mode dependencies use invalidation, and aggregate fallback may
  conservatively widen to the root rather than under-approximate.
- Generic preservation: generic instantiation substitutes type arguments before
  ownership classification. Therefore `Box<&T>` and `Box<View<T>>` inherit the
  same borrow-carrying classification as their substituted fields.

The invariant is:

> If a well-typed program point contains a live value whose type may carry
> borrowed provenance, then every runtime source that value may reference is
> represented in its static provenance or borrowed-place dependency.

Combined with the escape and invalidation rules above, this invariant implies
that accepted programs neither use borrowed storage after its source lifetime
nor mutate/drop a source in a way that invalidates a live borrowed aggregate.

### Classifying Mismatches Carefully

Not every mismatch found during an audit means the implementation is wrong.
This document may move ahead of the current implementation vocabulary as the
formal model becomes sharper. Future audits should classify mismatches before
deciding what to change.

Useful categories are:

- implementation drift
  The implementation no longer matches an already-established language contract
  in `SPEC.md` or an already-stable semantic commitment in this document.

- formalization lead
  The proof-oriented model has introduced a clearer or more expressive semantic
  object than the current implementation explicitly represents. This is a sign
  that the formalization is ahead of the implementation, not necessarily that
  behavior is wrong today.

- representation mismatch
  The implementation realizes the same semantic idea, but spreads it across
  different helpers or data structures rather than one object with the same
  name/shape used in the formal model.

- documentation overclaim
  The docs have accidentally promoted an intended direction or formal
  convenience into a claim that sounds already implemented.

The recommended decision order is:

1. check whether `SPEC.md` already commits to the behavior
2. check whether current tests already depend on that behavior
3. decide whether the mismatch changes user-visible meaning or only internal
   representation
4. only then choose between:
   - changing implementation
   - weakening or clarifying docs
   - marking future alignment work explicitly

This discipline is especially important while the formal model is still being
tightened. The goal is to reduce ambiguity without accidentally converting every
new formal distinction into an immediate implementation bug report.

## Relationship To Runtime

This document is about language semantics, not hidden ABI details.

Runtime code may implement:

- string sharing/release
- descriptor-driven copy/drop/equality/hash helpers
- dense and sparse storage primitives

But runtime representation does not define the language meaning by itself.
Language meaning is the place/projection/provenance model described here.

## Practical Rule

When docs disagree:

1. `SPEC.md` defines general language rules and `CONCURRENCY.md` defines the
   current concurrency contract
2. `SEMANTICS.md` defines the proof-oriented semantic model
3. design records in daydream explain proposals and implementation history;
   they do not change the public contract until incorporated here and in `SPEC.md`
