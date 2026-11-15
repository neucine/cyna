struct Batch<T> {
    storage: [:]T;
}

@syntax.sequence_literal
pub fn gather<T>(items: [:]T): Batch<T> {
    return Batch<T> {
        storage: items
    };
}

fn main(): i32 {
    const empty: List<i32> = [];
    const values: List<i32> = [21, 7];
    const batch: Batch<i32> = [21, 8];
    assert(empty.len() == 0);
    return values[0] + batch.storage[0];
}
