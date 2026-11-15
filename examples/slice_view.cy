struct Buffer<T> {
    storage: [:]T;

    @syntax.slice_view
    pub fn inspect(self: &const Buffer<T>): []const T {
        return self.storage[..];
    }

    @syntax.slice_view
    pub fn edit(self: &Buffer<T>): []T {
        return self.storage[..];
    }
}

fn main(): i32 {
    var buffer = Buffer<i32> {
        storage: [1, 2, 3]
    };
    var middle: []i32 = buffer[1..3];
    middle[0] = 21;
    const values: List<i32> = [21, 7];
    const read: []const i32 = values[..];
    return middle[0] + read[0];
}
