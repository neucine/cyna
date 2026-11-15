pub enum MemError: i32 {
    destination_too_small = 0,
}

pub fn index_of(haystack: []const u8, needle: []const u8): ?usize {
    if needle.len() == 0 {
        return 0;
    }
    if needle.len() > haystack.len() {
        return none;
    }

    const limit = haystack.len() - needle.len();
    var index: usize = 0;
    while index <= limit {
        var offset: usize = 0;
        var matches = true;
        while offset < needle.len() {
            if haystack[index + offset] != needle[offset] {
                matches = false;
            }
            offset = offset + 1;
        }
        if matches {
            return index;
        }
        index = index + 1;
    }

    return none;
}

pub fn contains(haystack: []const u8, needle: []const u8): bool {
    return index_of(haystack, needle) != none;
}

pub fn starts_with(haystack: []const u8, prefix: []const u8): bool {
    if prefix.len() > haystack.len() {
        return false;
    }
    var index: usize = 0;
    while index < prefix.len() {
        if haystack[index] != prefix[index] {
            return false;
        }
        index = index + 1;
    }
    return true;
}

pub fn ends_with(haystack: []const u8, suffix: []const u8): bool {
    if suffix.len() > haystack.len() {
        return false;
    }
    const start = haystack.len() - suffix.len();
    var index: usize = 0;
    while index < suffix.len() {
        if haystack[start + index] != suffix[index] {
            return false;
        }
        index = index + 1;
    }
    return true;
}

pub fn fill(dest: []u8, value: u8): void {
    var index: usize = 0;
    while index < dest.len() {
        dest[index] = value;
        index = index + 1;
    }
}

pub fn zero(dest: []u8): void {
    fill(dest, 0);
}

pub fn copy_into(dest: []u8, source: []const u8): void ! MemError {
    if dest.len() < source.len() {
        throw MemError.destination_too_small;
    }

    var index: usize = 0;
    while index < source.len() {
        dest[index] = source[index];
        index = index + 1;
    }

    return;
}
