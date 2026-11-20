// SHA-256 and HMAC-SHA-256 consume bytes and write a 32-byte digest.
extern {
    c fn sha256_raw(data: []const u8, output: []u8): void;
    c fn hmac_sha256_raw(key: []const u8, data: []const u8, output: []u8): void;
}

pub fn sha256(data: []const u8): [32]u8 {
    var digest: [32]u8 = [];
    sha256_raw(data, digest[..]);
    return digest;
}

pub fn hmac_sha256(key: []const u8, data: []const u8): [32]u8 {
    var digest: [32]u8 = [];
    hmac_sha256_raw(key, data, digest[..]);
    return digest;
}

// This compares all 32 bytes. Callers must keep the key secret.
pub fn verify_hmac_sha256(key: []const u8, data: []const u8, tag: []const u8): bool {
    if tag.len() != 32 {
        return false;
    }
    const expected = hmac_sha256(key, data);
    var difference: u8 = 0;
    var index: usize = 0;
    while index < 32 {
        difference = difference | (expected[index] ^ tag[index]);
        index = index + 1;
    }
    return difference == 0;
}
