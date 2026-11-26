pub fn equal(left: &const List<u8>, right: &const List<u8>): bool {
    if left.len() != right.len() {
        return false;
    }
    var index: usize = 0;
    while index < left.len() {
        if left[index] != right[index] {
            return false;
        }
        index = index + 1;
    }
    return true;
}
