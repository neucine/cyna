# Language and prelude

These APIs are part of the language or the automatically loaded
`std.prelude`. They need no explicit import.

Available on all bundled targets.

## Types

### `string`

An immutable UTF-8 value with shared backing storage.

### `List<T>`

A growable sequence with indexed access.

### `Set<T: Eq>` and `Map<K: Eq, V>`

Hash-based collections. Set elements and map keys must implement `Eq`.

### `SlotMap<T>` and `SlotMapKey`

A sparse map that returns stable keys. A key stays meaningful until its value
is removed.

### `Chars`

Unicode scalar-value iteration over a string.

### Iterator types

`ListIter<T>`, `SetIter<T>`, `MapKeys<K, V>`, `MapValues<K, V>`, and the
corresponding iterator structs are returned by the collection `iter` methods.

## Static functions

The first four entries are language builtins. The rest are prelude
constructors and associated functions.

| Function | Signature | Description |
| --- | --- | --- |
| `print` | `print(value): void` | Writes a value without a trailing newline. |
| `println` | `println(value): void` | Writes a value followed by a newline. |
| `assert` | `assert(condition: bool): void` | Stops the program when the condition is false. |
| `panic` | `panic(message: string): void` | Writes a panic message and aborts. |
| `string.from` | `fn from(bytes: []const u8): string` | Creates owned string backing from bytes. |
| `list` | `fn list<T>(): List<T>` | Creates an empty list. |
| `list_from` | `fn list_from<T>(items: [:]T): List<T>` | Creates a list from dense storage. |
| `set` | `fn set<T: Eq>(): Set<T>` | Creates an empty set. |
| `map` | `fn map<K: Eq, V>(): Map<K, V>` | Creates an empty map. |
| `slot_map` | `fn slot_map<T>(): SlotMap<T>` | Creates an empty slot map. |

`print` and `println` are debug output helpers. [std.io](IO.md) can redirect
their output.

## Instance methods

### `string`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const string): usize` | Returns the byte length. |
| `is_empty` | `fn is_empty(self: &const string): bool` | Reports whether the byte length is zero. |
| `bytes` | `fn bytes(self: &const string): []const u8` | Borrows the UTF-8 bytes. |
| `chars` | `fn chars(self: string): Chars` | Iterates Unicode scalar values. |
| `starts_with` | `fn starts_with(self: &const string, prefix: string): bool` | Checks a byte prefix. |
| `ends_with` | `fn ends_with(self: &const string, suffix: string): bool` | Checks a byte suffix. |
| `contains` | `fn contains(self: &const string, needle: string): bool` | Reports whether the needle occurs. |
| `find` | `fn find(self: &const string, needle: string): ?usize` | Returns the first byte offset, or `none`. |
| `rfind` | `fn rfind(self: &const string, needle: string): ?usize` | Returns the last byte offset, or `none`. |
| `slice` | `fn slice(self: &const string, start: usize, end: usize): string` | Slices by byte offsets. |

### `List<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const List<T>): usize` | Returns the element count. |
| `clear` | `fn clear(self: &List<T>): void` | Removes all elements. |
| `reserve` | `fn reserve(self: &List<T>, capacity: usize): void` | Grows capacity without adding elements. |
| `push` | `fn push(self: &List<T>, value: T): void` | Appends one element. |
| `pop` | `fn pop(self: &List<T>): T` | Removes and returns the last element. |
| `get_mut` | `fn get_mut(self: &List<T>, index: usize): &T` | Borrows one element for mutation. |
| `view` | `fn view(self: &const List<T>): []const T` | Borrows all elements as a read-only slice. |
| `view_mut` | `fn view_mut(self: &List<T>): []T` | Borrows all elements as a mutable slice. |
| `index` | `fn index(self: &const List<T>, index: usize): &const T` | Index syntax for reading. |
| `index_set` | `fn index_set(self: &List<T>, index: usize, value: T): void` | Index syntax for assignment. |

### `Set<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const Set<T>): usize` | Returns the element count. |
| `clear` | `fn clear(self: &Set<T>): void` | Removes all elements. |
| `contains` | `fn contains(self: &const Set<T>, value: T): bool` | Checks membership. |
| `add` | `fn add(self: &Set<T>, value: T): void` | Adds an element. |
| `index` | `fn index(self: &const Set<T>, index: usize): T` | Returns an element by iteration position. |

### `Map<K, V>`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const Map<K, V>): usize` | Returns the entry count. |
| `clear` | `fn clear(self: &Map<K, V>): void` | Removes all entries. |
| `contains` | `fn contains(self: &const Map<K, V>, key: K): bool` | Checks whether a key exists. |
| `keys` | `fn keys(self: &const Map<K, V>): MapKeys<K, V>` | Returns keys in iteration order. |
| `values` | `fn values(self: &const Map<K, V>): MapValues<K, V>` | Returns values in iteration order. |
| `index` | `fn index(self: &const Map<K, V>, key: K): V` | Returns a value by key. |
| `index_set` | `fn index_set(self: &Map<K, V>, key: K, value: V): void` | Inserts or replaces through index syntax. |

`Map.keys()` and `Map.values()` expose copies, not references into storage.

### `SlotMap<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const SlotMap<T>): usize` | Returns the value count. |
| `reserve` | `fn reserve(self: &SlotMap<T>, capacity: usize): void` | Grows capacity. |
| `clear` | `fn clear(self: &SlotMap<T>): void` | Removes all values. |
| `contains` | `fn contains(self: &const SlotMap<T>, key: SlotMapKey): bool` | Checks whether a key is live. |
| `insert` | `fn insert(self: &SlotMap<T>, value: T): SlotMapKey` | Stores a value and returns its key. |
| `remove` | `fn remove(self: &SlotMap<T>, key: SlotMapKey): ?T` | Removes a value, or returns `none`. |

## Protocols

| Protocol | Meaning |
| --- | --- |
| `Eq` | Defines value equality for collection keys. |
| `Hash` | Defines a hash for types used by hash-based APIs. |
| `Clone` | Defines how a type produces another value with the same contents. |

`Clone` is what makes `.clone()` available. For `string`, cloning creates
independent backing. For standard collections, cloning follows the element
type's clone behavior.

## Example

```cyna
var names: List<string> = list<string>();
names.push("Ada");
names.push("Ken");

if names.len() == 2 and names[0] == "Ada" {
    names[1] = "Grace";
}

const text = "Cyna API";
const first_space = text.find(" ");
assert(first_space == 4);
```
