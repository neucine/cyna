struct Sequence<T> {
    values: [:]T;
    @syntax.index pub fn fetch(self: &const Sequence<T>, key: usize): &const T {
        return &self.values[key];
    }
    @syntax.index_set pub fn replace(self: &Sequence<T>, key: usize, value: T): void {
        self.values[key] = value;
    }
    @syntax.iter pub fn begin(self: &const Sequence<T>): usize {
        return 0;
    }
    @syntax.iter_has_next pub fn more(self: &const Sequence<T>, state: &const usize): bool {
        return state < self.values.len();
    }
    @syntax.iter_next pub fn advance(self: &const Sequence<T>, state: &usize): usize {
        const cursor: usize = state;
        state = state + 1;
        return cursor;
    }
    @syntax.iter_item pub fn element(self: &const Sequence<T>, cursor: usize): &const T {
        return &self.values[cursor];
    }
}
fn observe(value: &Sequence<i32>, calls: &i32): &Sequence<i32> {
    calls = calls + 1;
    return value;
}
fn main(): i32 {
    var values = Sequence<i32> {
        values: [19, 22]
    };
    var calls: i32 = 0;
    observe(&values, &calls)[0] = 20;
    assert(observe(&values, &calls)[0] == 20);
    var total: i32 = 0;
    for value in observe(&values, &calls) {
        total = total + value;
    }
    assert(calls == 3);
    return total;
}
