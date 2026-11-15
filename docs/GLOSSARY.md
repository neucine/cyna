# Cyna terminology

Use these names throughout Cyna documentation, diagnostics, and explanatory
code comments. [The spec](SPEC.md) defines behavior; this glossary fixes the
names. [Semantics](SEMANTICS.md) gives the checker model.

## How to read this glossary

The headings group different questions about the *same expression*; they are
not categories of Cyna syntax or names for compiler IR nodes. Code in backticks
shows source spelling when there is one. Terms such as **value behavior**,
**borrow**, **place**, and **projection** describe the language's semantics and
the rules the compiler checks. You do not write those words as operators.
An operation may have a source spelling (`&`, `take`, `.clone()`), while its
semantic name covers more than that one spelling.

## Value behavior

Value behavior is a property of a type's values. It answers what assignment
does and who performs cleanup. These are the three behavior classes, not
source keywords or separate kinds of expression:

| Class | Assignment | Cleanup | Examples |
| --- | --- | --- | --- |
| plain | copies the value | no compiler-tracked cleanup | `i32`, `bool`, plain structs |
| shared | shares backing or another claim | releases each claim according to the type's contract | `string`, `Arc<T>` |
| owned | hands off cleanup responsibility; the source becomes unavailable | one active holder ends the value's lifetime | `^T`, `[:]T`, `List<T>` |

**Composite value** describes a value's structure, not a fourth behavior class.
A struct is a composite value: assignment applies each field's behavior
recursively. A struct of plain fields copies. Shared fields preserve another
claim according to their types. If any field is owned, assignment hands off
that field and makes the source struct unavailable as a whole. Alias and view
fields copy their carriers while retaining their dependence on source storage.
The same rules apply through nested structs.

**Owned value** names the broad class. **Owned pointer** names only `^T`.
Use **plain value** for the class; “copy value” can describe an operation but
should not name a competing class. Avoid “resource value” as another name for
the owned class; *resource* remains an ordinary word for external resources.

`@ownership.owned` and `@ownership.shared` are trusted std/core declaration
attributes that assign owned or shared behavior to particular structs. They
do not add behavior classes or let ordinary user packages declare new cleanup
contracts.

## Access forms

Access answers whether an expression's result depends on storage held
elsewhere. It is separate from the result's value behavior: an alias or view
carrier can be copied while its referent remains borrowed.

| Term | Meaning |
| --- | --- |
| direct value | A value used through its own binding or place. |
| alias pointer | `&T` or `&const T`: non-owning access to one existing place. |
| slice | `[]T` or `[]const T`: a non-owning pointer-and-length range view. |
| view | General non-owning access to existing storage; a slice is a range view. |
| raw pointer | `*T` and qualified forms: an address used at low-level or foreign boundaries, outside safe provenance checks. |

**Borrow** is a semantic operation: forming non-owning access to existing
storage. The source expression `&place` explicitly forms an alias borrow;
slice and other view-producing expressions can also form borrowed access.
Thus “borrow” in this table is not an additional pointer type or a Cyna
keyword. **Borrowed** describes an alias or view's dependency on its source
storage; it is not a fourth value behavior class. Copying an alias or view
copies the carrier, not its source.

## Operations

| Operation | Meaning |
| --- | --- |
| copy | Duplicate a plain value, address, alias, or view according to its type; copying a view does not copy storage. |
| share | Preserve another claim or shared backing according to the shared type's contract. |
| handoff | Pass an owned value's cleanup responsibility to a new holder; the source becomes unavailable. |
| clone | Call `.clone()` to create another value according to `Clone`; the result follows its type's behavior. |
| borrow | Form non-owning access without passing cleanup responsibility. |
| detach | Extract from a place with a defined valid post-state; `take` detaches from a writable optional place. |
| remove | Use a named container operation with its own detachment policy, such as `pop()` or `remove(key)`. |
| drop | End the current holder's compiler-tracked cleanup responsibility. |

The compiler's internal IR `move` may consume shared claims or temporaries as
well as owned values, so it is broader than a source-language handoff.
**Transfer function** means a checker state transition, not an ownership
operation.

## Places and projections

These terms distinguish data from the storage an expression accesses. A
binding is a source-level name; its root place is the storage named by that
binding. A projection is a semantic path through a field, index, payload, or
view-producing step. Source syntax such as `.field`, `[i]`, and `[..]` can
express those steps. Choosing a path alone does not borrow or detach a value.

| Term | Meaning |
| --- | --- |
| binding | A name attached to a value, such as `x` in `var x = ...`. |
| value | The data an expression produces or a place holds; it may refer to heap storage. A value is not the location holding it. |
| place | A semantic storage location that an expression identifies, such as the location denoted by `x`, `x.field`, or `xs[i]`. Whether it can be written depends on access and context. |
| projection | A semantic step from a base place or value to a subplace or derived view, expressed by syntax such as `.field`, `[i]`, or `[..]`. |

For `var xs = ...`, `xs` is the binding and its root place. In `xs[i].field`,
`[i].field` is the projection and `xs[i].field` is the projected place.
`&xs[i].field` borrows that place. `xs[..]` instead produces a borrowed view;
the result is not an owned subplace. A projected read may also supply a
non-owning binding under the rules in the spec, without spelling `&`. Using
an owned projected value in a handoff position is rejected unless the program
spells a supported operation such as `.clone()` or `take` on a detachable
place.

## Storage forms

| Term | Meaning |
| --- | --- |
| fixed array | `[N]T`: inline storage whose length is known at compile time. |
| dense storage | `[:]T`: owned storage with runtime capacity and an initialized prefix. |
| sparse storage | `[;]T`: owned storage with runtime capacity and explicit slot occupancy. |
| container | A library type such as `List<T>`, `Map<K, V>`, `Set<T>`, or `SlotMap<T>` built on storage foundations. |
| external handle | A copied token such as an OS handle, cleaned up by an explicit API protocol. |

`[:]T` may have unused capacity, and `push` may grow it. Choose `List<T>` for
the general-purpose growable collection API.

## Document roles

- [Spec](SPEC.md): normative source-language behavior and syntax.
- [Semantics](SEMANTICS.md): place, access, provenance, and checker rules.
- [Status](STATUS.md): implemented features and known limitations.
- [Guide](GUIDE.md) and [cheatsheet](CHEATSHEET.md): recommended style and
  quick syntax, respectively.
