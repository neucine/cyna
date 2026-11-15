pub extern c fn print_string(value: string): void;
pub extern c fn print_int(value: i64, signed: bool): void;
pub extern c fn print_bool(value: bool): void;
pub extern c fn print_newline(): void;
@unchecked_thread_safe
pub extern c fn panic(message: string): void;

pub protocol Eq {
    fn eq(self: &const Self, other: &const Self): bool;
}

pub protocol Hash {
    fn hash(self: &const Self): u64;
}

pub protocol Clone {
    fn clone(self: &const Self): Self;
}

impl string: Clone {
    fn clone(self: &const string): string {
        return string.from(self.bytes());
    }
}

impl i8: Clone {
    fn clone(self: &const i8): i8 {
        return self;
    }
}
impl i16: Clone {
    fn clone(self: &const i16): i16 {
        return self;
    }
}
impl i32: Clone {
    fn clone(self: &const i32): i32 {
        return self;
    }
}
impl i64: Clone {
    fn clone(self: &const i64): i64 {
        return self;
    }
}
impl u8: Clone {
    fn clone(self: &const u8): u8 {
        return self;
    }
}
impl u16: Clone {
    fn clone(self: &const u16): u16 {
        return self;
    }
}
impl u32: Clone {
    fn clone(self: &const u32): u32 {
        return self;
    }
}
impl u64: Clone {
    fn clone(self: &const u64): u64 {
        return self;
    }
}
impl isize: Clone {
    fn clone(self: &const isize): isize {
        return self;
    }
}
impl usize: Clone {
    fn clone(self: &const usize): usize {
        return self;
    }
}
impl f32: Clone {
    fn clone(self: &const f32): f32 {
        return self;
    }
}
impl f64: Clone {
    fn clone(self: &const f64): f64 {
        return self;
    }
}
impl bool: Clone {
    fn clone(self: &const bool): bool {
        return self;
    }
}
impl char: Clone {
    fn clone(self: &const char): char {
        return self;
    }
}

@intrinsic("value.eq")
fn value_eq<T>(left: &const T, right: &const T): bool;

impl i8: Eq {
    fn eq(self: &const i8, other: &const i8): bool {
        return value_eq(self, other);
    }
}
impl i16: Eq {
    fn eq(self: &const i16, other: &const i16): bool {
        return value_eq(self, other);
    }
}
impl i32: Eq {
    fn eq(self: &const i32, other: &const i32): bool {
        return value_eq(self, other);
    }
}
impl i64: Eq {
    fn eq(self: &const i64, other: &const i64): bool {
        return value_eq(self, other);
    }
}
impl u8: Eq {
    fn eq(self: &const u8, other: &const u8): bool {
        return value_eq(self, other);
    }
}
impl u16: Eq {
    fn eq(self: &const u16, other: &const u16): bool {
        return value_eq(self, other);
    }
}
impl u32: Eq {
    fn eq(self: &const u32, other: &const u32): bool {
        return value_eq(self, other);
    }
}
impl u64: Eq {
    fn eq(self: &const u64, other: &const u64): bool {
        return value_eq(self, other);
    }
}
impl isize: Eq {
    fn eq(self: &const isize, other: &const isize): bool {
        return value_eq(self, other);
    }
}
impl usize: Eq {
    fn eq(self: &const usize, other: &const usize): bool {
        return value_eq(self, other);
    }
}
impl f32: Eq {
    fn eq(self: &const f32, other: &const f32): bool {
        return value_eq(self, other);
    }
}
impl f64: Eq {
    fn eq(self: &const f64, other: &const f64): bool {
        return value_eq(self, other);
    }
}
impl bool: Eq {
    fn eq(self: &const bool, other: &const bool): bool {
        return value_eq(self, other);
    }
}
impl string: Eq {
    fn eq(self: &const string, other: &const string): bool {
        return value_eq(self, other);
    }
}
impl char: Eq {
    fn eq(self: &const char, other: &const char): bool {
        return value_eq(self, other);
    }
}

impl i8: Hash {
    fn hash(self: &const i8): u64 {
        return self as u64;
    }
}
impl i16: Hash {
    fn hash(self: &const i16): u64 {
        return self as u64;
    }
}
impl i32: Hash {
    fn hash(self: &const i32): u64 {
        return self as u64;
    }
}
impl i64: Hash {
    fn hash(self: &const i64): u64 {
        return self as u64;
    }
}
impl u8: Hash {
    fn hash(self: &const u8): u64 {
        return self as u64;
    }
}
impl u16: Hash {
    fn hash(self: &const u16): u64 {
        return self as u64;
    }
}
impl u32: Hash {
    fn hash(self: &const u32): u64 {
        return self as u64;
    }
}
impl u64: Hash {
    fn hash(self: &const u64): u64 {
        return self;
    }
}
impl isize: Hash {
    fn hash(self: &const isize): u64 {
        return self as u64;
    }
}
impl usize: Hash {
    fn hash(self: &const usize): u64 {
        return self as u64;
    }
}
impl bool: Hash {
    fn hash(self: &const bool): u64 {
        if self {
            return 1;
        }
        return 0;
    }
}
impl string: Hash {
    fn hash(self: &const string): u64 {
        var result: u64 = 14695981039346656037;
        for byte in self.bytes() {
            result = (result ^ (byte as u64)) *% 1099511628211;
        }
        return result;
    }
}

// Prelude-owned growable dense container layered over `[:]T`.
pub struct List<T> {
    pub storage: [:]T;
    pub capacity: usize;

    pub fn len(self: &const List<T>): usize {
        return self.storage.len();
    }

    pub fn clear(self: &List<T>): void {
        self.storage.clear();
    }

    fn grow_to(self: &List<T>, capacity: usize): void {
        if capacity <= self.capacity {
            return;
        }

        self.storage.reserve(capacity);
        self.capacity = capacity;
    }

    pub fn reserve(self: &List<T>, capacity: usize): void {
        self.grow_to(capacity);
    }

    pub fn push(self: &List<T>, value: T): void {
        if self.storage.len() == self.capacity {
            var next_capacity = self.capacity * 2;
            if next_capacity == 0 {
                next_capacity = 4;
            }
            self.grow_to(next_capacity);
        }
        self.storage.push(value);
    }

    pub fn pop(self: &List<T>): T {
        return self.storage.pop();
    }

    pub fn get_mut(self: &List<T>, index: usize): &T {
        return &self.storage[index];
    }

    @syntax.slice_view
    pub fn view(self: &const List<T>): []const T {
        return self.storage[..self.storage.len()];
    }

    @syntax.slice_view
    pub fn view_mut(self: &List<T>): []T {
        return self.storage[..self.storage.len()];
    }

    @syntax.index
    pub fn index(self: &const List<T>, index: usize): &const T {
        return &self.storage[index];
    }

    @syntax.index_set
    pub fn index_set(self: &List<T>, index: usize, value: T): void {
        self.storage[index] = value;
    }

    @syntax.iter
    pub fn iter(self: &const List<T>): ListIter<T> {
        return ListIter<T> {
            length: self.storage.len(),
            index: 0
        };
    }
    @syntax.iter_has_next
    pub fn iter_has_next(self: &const List<T>, state: &const ListIter<T>): bool {
        return state.index < state.length;
    }
    @syntax.iter_next
    pub fn iter_next(self: &const List<T>, state: &ListIter<T>): usize {
        const value = state.index;
        state.index = state.index + 1;
        return value;
    }
    @syntax.iter_item
    pub fn iter_item(self: &const List<T>, cursor: usize): &const T {
        return &self.storage[cursor];
    }

}

impl<T: Clone> List<T>: Clone {
    fn clone(self: &const List<T>): List<T> {
        var out = List<T> {
            storage: [:]T[],
            capacity: self.capacity
        };
        out.storage.reserve(self.capacity);
        var index: usize = 0;
        while index < self.storage.len() {
            out.storage.push(self.storage[index].clone());
            index = index + 1;
        }
        return out;
    }
}

pub fn list<T>(): List<T> {
    return List<T> {
        storage: [:]T[],
        capacity: 0
    };
}

@syntax.sequence_literal
pub fn list_from<T>(items: [:]T): List<T> {
    const capacity = items.len();
    return List<T> {
        storage: items,
        capacity: capacity
    };
}

pub struct ListIter<T> {
    pub length: usize;
    pub index: usize;
}

pub struct Set<T: Eq> {
    pub slots: [;]T;
    pub count: usize;
    pub capacity: usize;

    fn grow(self: &Set<T>): void {
        var new_capacity: usize = self.capacity * 2;
        if new_capacity == 0 {
            new_capacity = 4;
        }

        var grown = [; new_capacity]T;
        var next: usize = 0;
        for idx in self.slots.indices() {
            if take self.slots[idx] is current {
                grown.insert(next, current);
                next = next + 1;
            }
        }
        self.slots = grown;
        self.capacity = new_capacity;
    }

    pub fn len(self: &const Set<T>): usize {
        return self.count;
    }

    pub fn clear(self: &Set<T>): void {
        self.slots.clear();
        self.count = 0;
    }

    fn contains_ref(self: &const Set<T>, value: &const T): bool {
        for idx in self.slots.indices() {
            if &self.slots[idx] is current {
                if current.eq(value) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn contains(self: &const Set<T>, value: T): bool {
        var query = value;
        return self.contains_ref(&query);
    }

    fn insert_at(self: &Set<T>, index: usize, value: T): void {
        self.slots.insert(index, value);
        self.count = self.count + 1;
    }

    pub fn add(self: &Set<T>, value: T): void {
        var item = value;
        if self.contains_ref(&item) {
            return;
        }
        if self.count == self.capacity {
            self.grow();
        }
        var idx: usize = 0;
        while idx < self.capacity {
            if self.slots[idx] is none {
                self.insert_at(idx, item);
                return;
            }
            idx = idx + 1;
        }
    }

    @syntax.index
    pub fn index(self: &const Set<T>, index: usize): T {
        return self.slots[index] as T;
    }

    @syntax.iter
    pub fn iter(self: &const Set<T>): SetIter<T> {
        var positions = [: self.count]usize;
        for idx in self.slots.indices() {
            if self.slots[idx] is current {
                const ignored = current;
                positions.push(idx);
            }
        }
        return SetIter<T> {
            positions: positions,
            index: 0
        };
    }
    @syntax.iter_has_next
    pub fn iter_has_next(self: &const Set<T>, state: &const SetIter<T>): bool {
        return state.index < state.positions.len();
    }
    @syntax.iter_next
    pub fn iter_next(self: &const Set<T>, state: &SetIter<T>): usize {
        const value = state.positions[state.index];
        state.index = state.index + 1;
        return value;
    }
    @syntax.iter_item
    pub fn iter_item(self: &const Set<T>, cursor: usize): T {
        return self.slots[cursor] as T;
    }

}

impl<T: Eq & Clone> Set<T>: Clone {
    fn clone(self: &const Set<T>): Set<T> {
        var out = Set<T> {
            slots: [; self.capacity]T,
            count: self.count,
            capacity: self.capacity
        };
        for idx in self.slots.indices() {
            if &self.slots[idx] is current {
                out.slots.insert(idx, current.clone());
            }
        }
        return out;
    }
}

pub fn set<T: Eq>(): Set<T> {
    return Set<T> {
        slots: [; 0]T,
        count: 0,
        capacity: 0
    };
}

pub struct SetIter<T> {
    pub positions: [:]usize;
    pub index: usize;
}

pub struct SlotMapKey {
    pub index: usize;
    pub generation: usize;
}

pub struct SlotMap<T> {
    pub slots: [;]T;
    pub generations: [:]usize;
    pub count: usize;
    pub capacity: usize;

    fn grow_to(self: &SlotMap<T>, capacity: usize): void {
        if capacity <= self.capacity {
            return;
        }

        var grown = [; capacity]T;
        var move_index: usize = 0;
        while move_index < self.capacity {
            const idx = move_index;
            if take self.slots[idx] is current {
                grown.insert(idx, current);
            }
            move_index = move_index + 1;
        }
        self.slots = grown;
        self.generations.reserve(capacity);
        var idx = self.capacity;
        while idx < capacity {
            self.generations.push(0);
            idx = idx + 1;
        }
        self.capacity = capacity;
    }

    fn grow(self: &SlotMap<T>): void {
        var new_capacity = self.capacity * 2;
        if new_capacity == 0 {
            new_capacity = 4;
        }
        self.grow_to(new_capacity);
    }

    pub fn len(self: &const SlotMap<T>): usize {
        return self.count;
    }

    pub fn reserve(self: &SlotMap<T>, capacity: usize): void {
        self.grow_to(capacity);
    }

    pub fn clear(self: &SlotMap<T>): void {
        var idx: usize = 0;
        while idx < self.capacity {
            const generation = self.generations[idx];
            if take self.slots[idx] is value {
                drop value;
                self.generations[idx] = generation + 1;
            }
            idx = idx + 1;
        }
        self.count = 0;
    }

    pub fn contains(self: &const SlotMap<T>, key: SlotMapKey): bool {
        if key.index >= self.capacity {
            return false;
        }
        if self.generations[key.index] != key.generation {
            return false;
        }
        return self.slots.contains_index(key.index);
    }

    pub fn insert(self: &SlotMap<T>, value: T): SlotMapKey {
        if self.count == self.capacity {
            self.grow();
        }

        var pending: ?T = value;
        var idx: usize = 0;
        while idx < self.capacity {
            if not self.slots.contains_index(idx) {
                const generation = self.generations[idx];
                if take pending is item {
                    self.slots.insert(idx, item);
                }
                self.count = self.count + 1;
                return SlotMapKey {
                    index: idx,
                    generation: generation
                };
            }
            idx = idx + 1;
        }

        return SlotMapKey {
            index: self.capacity,
            generation: 0
        };
    }

    pub fn remove(self: &SlotMap<T>, key: SlotMapKey): ?T {
        if not self.contains(key) {
            return none;
        }

        const value = take self.slots[key.index];
        self.generations[key.index] = key.generation + 1;
        self.count = self.count - 1;
        return value;
    }
}

pub fn slot_map<T>(): SlotMap<T> {
    return SlotMap<T> {
        slots: [; 0]T,
        generations: [:]usize[],
        count: 0,
        capacity: 0
    };
}

pub struct MapEntry<K, V> {
    pub key: K;
    pub value: V;
}

fn clone_map_entry_part<T: Clone>(value: &const T): T {
    return value.clone();
}

impl<K: Clone, V: Clone> MapEntry<K, V>: Clone {
    fn clone(self: &const MapEntry<K, V>): MapEntry<K, V> {
        return MapEntry<K, V> {
            key: clone_map_entry_part<K>(&self.key),
            value: clone_map_entry_part<V>(&self.value),
        };
    }
}

pub struct MapKeys<K, V> {
    pub slots: [;]K;
    pub count: usize;
    pub capacity: usize;

    pub fn len(self: &const MapKeys<K, V>): usize {
        return self.count;
    }

    @syntax.index
    pub fn index(self: &const MapKeys<K, V>, index: usize): K {
        return self.slots[index] as K;
    }

    @syntax.iter
    pub fn iter(self: &const MapKeys<K, V>): MapKeysIter<K, V> {
        var positions = [: self.count]usize;
        for idx in self.slots.indices() {
            if self.slots[idx] is key {
                const ignored = key;
                positions.push(idx);
            }
        }
        return MapKeysIter<K, V> {
            positions: positions,
            index: 0
        };
    }
    @syntax.iter_has_next
    pub fn iter_has_next(self: &const MapKeys<K, V>, state: &const MapKeysIter<K, V>): bool {
        return state.index < state.positions.len();
    }
    @syntax.iter_next
    pub fn iter_next(self: &const MapKeys<K, V>, state: &MapKeysIter<K, V>): usize {
        const value = state.positions[state.index];
        state.index = state.index + 1;
        return value;
    }
    @syntax.iter_item
    pub fn iter_item(self: &const MapKeys<K, V>, cursor: usize): K {
        return self.slots[cursor] as K;
    }

}

pub struct MapKeysIter<K, V> {
    pub positions: [:]usize;
    pub index: usize;
}

pub struct MapValues<K, V> {
    pub slots: [;]V;
    pub count: usize;
    pub capacity: usize;

    pub fn len(self: &const MapValues<K, V>): usize {
        return self.count;
    }

    @syntax.index
    pub fn index(self: &const MapValues<K, V>, index: usize): V {
        return self.slots[index] as V;
    }

    @syntax.iter
    pub fn iter(self: &const MapValues<K, V>): MapValuesIter<K, V> {
        var positions = [: self.count]usize;
        for idx in self.slots.indices() {
            if self.slots[idx] is value {
                const ignored = value;
                positions.push(idx);
            }
        }
        return MapValuesIter<K, V> {
            positions: positions,
            index: 0
        };
    }
    @syntax.iter_has_next
    pub fn iter_has_next(self: &const MapValues<K, V>, state: &const MapValuesIter<K, V>): bool {
        return state.index < state.positions.len();
    }
    @syntax.iter_next
    pub fn iter_next(self: &const MapValues<K, V>, state: &MapValuesIter<K, V>): usize {
        const value = state.positions[state.index];
        state.index = state.index + 1;
        return value;
    }
    @syntax.iter_item
    pub fn iter_item(self: &const MapValues<K, V>, cursor: usize): V {
        return self.slots[cursor] as V;
    }

}

pub struct MapValuesIter<K, V> {
    pub positions: [:]usize;
    pub index: usize;
}

pub struct Map<K: Eq, V> {
    pub slots: [;]MapEntry<K, V>;
    pub count: usize;
    pub capacity: usize;

    fn grow(self: &Map<K, V>): void {
        var new_capacity: usize = self.capacity * 2;
        if new_capacity == 0 {
            new_capacity = 4;
        }

        var grown = [; new_capacity]MapEntry<K, V>;
        for idx in self.slots.indices() {
            if take self.slots[idx] is entry {
                grown.insert(idx, entry);
            }
        }
        self.slots = grown;
        self.capacity = new_capacity;
    }

    pub fn len(self: &const Map<K, V>): usize {
        return self.count;
    }

    pub fn clear(self: &Map<K, V>): void {
        self.slots.clear();
        self.count = 0;
    }

    fn find_index(self: &const Map<K, V>, key: &const K): ?usize {
        for idx in self.slots.indices() {
            if &self.slots[idx] is entry {
                if entry.key.eq(key) {
                    return idx;
                }
            }
        }
        return none;
    }

    pub fn contains(self: &const Map<K, V>, key: K): bool {
        var query = key;
        if self.find_index(&query) is idx {
            const ignored = idx;
            return true;
        }
        return false;
    }

    fn put(self: &Map<K, V>, key: K, value: V): void {
        var item_key = key;
        var item_value = value;
        if self.find_index(&item_key) is idx {
            self.slots.insert(idx, MapEntry<K, V> {
                key: item_key,
                value: item_value
            });
            return;
        }

        if self.count == self.capacity {
            self.grow();
        }

        var idx: usize = 0;
        while idx < self.capacity {
            if self.slots[idx] is none {
                self.slots.insert(idx, MapEntry<K, V> {
                    key: item_key,
                    value: item_value
                });
                self.count = self.count + 1;
                return;
            }
            idx = idx + 1;
        }
    }

    pub fn keys(self: &const Map<K, V>): MapKeys<K, V> {
        var snapshot = [; self.capacity]K;
        for idx in self.slots.indices() {
            if &self.slots[idx] is entry {
                snapshot.insert(idx, entry.key);
            }
        }
        return MapKeys<K, V> {
            slots: snapshot,
            count: self.count,
            capacity: self.capacity
        };
    }

    pub fn values(self: &const Map<K, V>): MapValues<K, V> {
        var snapshot = [; self.capacity]V;
        for idx in self.slots.indices() {
            if &self.slots[idx] is entry {
                snapshot.insert(idx, entry.value);
            }
        }
        return MapValues<K, V> {
            slots: snapshot,
            count: self.count,
            capacity: self.capacity
        };
    }

    @syntax.index
    pub fn index(self: &const Map<K, V>, key: K): V {
        var query = key;
        var result: ?V = none;
        if self.find_index(&query) is idx {
            if &self.slots[idx] is entry {
                result = entry.value;
            }
        }
        if result is value {
            return value;
        }
        return result as V;
    }

    @syntax.index_set
    pub fn index_set(self: &Map<K, V>, key: K, value: V): void {
        self.put(key, value);
    }

}

impl<K: Eq & Clone, V: Clone> Map<K, V>: Clone {
    fn clone(self: &const Map<K, V>): Map<K, V> {
        var out = Map<K, V> {
            slots: [; self.capacity]MapEntry<K, V>,
            count: self.count,
            capacity: self.capacity
        };
        for idx in self.slots.indices() {
            if &self.slots[idx] is entry {
                out.slots.insert(idx, entry.clone());
            }
        }
        return out;
    }
}

pub fn map<K: Eq, V>(): Map<K, V> {
    return Map<K, V> {
        slots: [; 0]MapEntry<K, V>,
        count: 0,
        capacity: 0
    };
}
