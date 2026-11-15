pub enum Error: i32 {
    unexpected_end = 0,
    invalid_token,
    invalid_escape,
    invalid_unicode,
    trailing_data,
    duplicate_key,
    depth_exceeded,
    invalid_utf8,
}

pub struct Number {
    pub spelling: string;

    pub fn text(self: &const Number): string {
        return self.spelling;
    }

    pub fn is_integer(self: &const Number): bool {
        const bytes = self.spelling.bytes();
        var index: usize = 0;
        while index < bytes.len() {
            const byte = bytes[index];
            if byte == 46 or byte == 101 or byte == 69 {
                return false;
            }
            index = index + 1;
        }
        return true;
    }
}

pub struct Member {
    pub key: string;
    pub value: Value;
}

pub struct Object {
    pub members: List<Member>;

    pub fn len(self: &const Object): usize {
        return self.members.len();
    }

    pub fn find(self: &const Object, key: string): ?usize {
        var index: usize = 0;
        while index < self.members.len() {
            if self.members[index].key == key {
                return index;
            }
            index = index + 1;
        }
        return none;
    }

    pub fn contains(self: &const Object, key: string): bool {
        return self.find(key) != none;
    }

    @syntax.index
    pub fn index(self: &const Object, key: string): &const Value {
        if self.find(key) is index {
            return &self.members[index].value;
        }
        panic("std.json object key not found");
    }
}

pub struct Array {
    pub items: List<Value>;

    pub fn len(self: &const Array): usize {
        return self.items.len();
    }

    @syntax.index
    pub fn index(self: &const Array, index: usize): &const Value {
        if index >= self.items.len() {
            panic("std.json array index out of bounds");
        }
        return &self.items[index];
    }
}

pub union Value {
    null_value;
    bool: bool;
    number: Number;
    string: string;
    array: Array;
    object: Object;
}

const max_depth: usize = 256;
const quote: u8 = 34;
const backslash: u8 = 92;

fn is_json_whitespace(byte: u8): bool {
    return byte == 32 or byte == 9 or byte == 10 or byte == 13;
}

fn is_digit(byte: u8): bool {
    return byte >= 48 and byte <= 57;
}

fn is_hex_digit(byte: u8): bool {
    return (byte >= 48 and byte <= 57) or
    (byte >= 65 and byte <= 70) or
    (byte >= 97 and byte <= 102);
}

fn hex_value(byte: u8): u8 {
    if byte >= 48 and byte <= 57 {
        return byte - 48;
    }
    if byte >= 65 and byte <= 70 {
        return (byte - 65) + 10;
    }
    return (byte - 97) + 10;
}

fn is_utf8_continuation(byte: u8): bool {
    return byte >= 128 and byte <= 191;
}

fn validate_utf8_sequence(text: []const u8, offset: usize): ?usize {
    const first = text[offset];
    if first <= 127 {
        return offset + 1;
    }

    if first >= 194 and first <= 223 {
        if offset + 1 >= text.len() or not is_utf8_continuation(text[offset + 1]) {
            return none;
        }
        return offset + 2;
    }

    if first >= 224 and first <= 239 {
        if offset + 2 >= text.len() or not is_utf8_continuation(text[offset + 2]) {
            return none;
        }
        const second = text[offset + 1];
        if first == 224 {
            if second < 160 or second > 191 {
                return none;
            }
        } else if first == 237 {
            if second < 128 or second > 159 {
                return none;
            }
        } else if not is_utf8_continuation(second) {
            return none;
        }
        return offset + 3;
    }

    if first >= 240 and first <= 244 {
        if offset + 3 >= text.len() or
        not is_utf8_continuation(text[offset + 2]) or
        not is_utf8_continuation(text[offset + 3]) {
            return none;
        }
        const second = text[offset + 1];
        if first == 240 {
            if second < 144 or second > 191 {
                return none;
            }
        } else if first == 244 {
            if second < 128 or second > 143 {
                return none;
            }
        } else if not is_utf8_continuation(second) {
            return none;
        }
        return offset + 4;
    }

    return none;
}

fn validate_utf8_bytes(text: []const u8): void ! Error {
    var offset: usize = 0;
    while offset < text.len() {
        const next = validate_utf8_sequence(text, offset);
        if next is end {
            offset = end;
        } else {
            throw Error.invalid_utf8;
        }
    }
    return;
}

struct Parser {
    text: string;
    pos: usize;

    fn skip_whitespace(self: &Parser): void {
        const bytes = self.text.bytes();
        while self.pos < bytes.len() and is_json_whitespace(bytes[self.pos]) {
            self.pos = self.pos + 1;
        }
    }

    fn consume_literal(self: &Parser, literal: string): bool {
        const source = self.text.bytes();
        const expected = literal.bytes();
        if self.pos + expected.len() > source.len() {
            return false;
        }

        var index: usize = 0;
        while index < expected.len() {
            if source[self.pos + index] != expected[index] {
                return false;
            }
            index = index + 1;
        }
        self.pos = self.pos + expected.len();
        return true;
    }

    fn parse_hex_quad(self: &Parser): u32 ! Error {
        const source = self.text.bytes();
        if self.pos + 4 > source.len() {
            throw Error.invalid_unicode;
        }

        var value: u32 = 0;
        var index: usize = 0;
        while index < 4 {
            const byte = source[self.pos + index];
            if not is_hex_digit(byte) {
                throw Error.invalid_unicode;
            }
            value = value * 16 + (hex_value(byte) as u32);
            index = index + 1;
        }
        self.pos = self.pos + 4;
        return value;
    }

    fn append_byte(self: &const Parser, bytes: &List<u8>, value: u8): void {
        const ignored = self;
        bytes.push(value);
    }

    fn append_codepoint(self: &const Parser, bytes: &List<u8>, codepoint: u32): void {
        const ignored = self;
        if codepoint <= 127 {
            bytes.push(codepoint as u8);
        } else if codepoint <= 2047 {
            bytes.push((192 + (codepoint >> 6)) as u8);
            bytes.push((128 + (codepoint & 63)) as u8);
        } else if codepoint <= 65535 {
            bytes.push((224 + (codepoint >> 12)) as u8);
            bytes.push((128 + ((codepoint >> 6) & 63)) as u8);
            bytes.push((128 + (codepoint & 63)) as u8);
        } else {
            bytes.push((240 + (codepoint >> 18)) as u8);
            bytes.push((128 + ((codepoint >> 12) & 63)) as u8);
            bytes.push((128 + ((codepoint >> 6) & 63)) as u8);
            bytes.push((128 + (codepoint & 63)) as u8);
        }
    }

    fn parse_string(self: &Parser): string ! Error {
        const source = self.text.bytes();
        if self.pos >= source.len() or source[self.pos] != quote {
            throw Error.invalid_token;
        }

        self.pos = self.pos + 1;
        var decoded: List<u8> = list<u8>();
        while self.pos < source.len() {
            const byte = source[self.pos];
            if byte == quote {
                self.pos = self.pos + 1;
                return string.from(decoded.view());
            }

            if byte == backslash {
                self.pos = self.pos + 1;
                if self.pos >= source.len() {
                    throw Error.unexpected_end;
                }

                const escaped = source[self.pos];
                self.pos = self.pos + 1;
                if escaped == quote {
                    self.append_byte(&decoded, quote);
                } else if escaped == backslash {
                    self.append_byte(&decoded, backslash);
                } else if escaped == 47 {
                    self.append_byte(&decoded, 47);
                } else if escaped == 98 {
                    self.append_byte(&decoded, 8);
                } else if escaped == 102 {
                    self.append_byte(&decoded, 12);
                } else if escaped == 110 {
                    self.append_byte(&decoded, 10);
                } else if escaped == 114 {
                    self.append_byte(&decoded, 13);
                } else if escaped == 116 {
                    self.append_byte(&decoded, 9);
                } else if escaped == 117 {
                    var codepoint = try self.parse_hex_quad();
                    if codepoint >= 55296 and codepoint <= 56319 {
                        if self.pos + 2 > source.len() or source[self.pos] != backslash or source[self.pos + 1] != 117 {
                            throw Error.invalid_unicode;
                        }
                        self.pos = self.pos + 2;
                        const low = try self.parse_hex_quad();
                        if low < 56320 or low > 57343 {
                            throw Error.invalid_unicode;
                        }
                        codepoint = 65536 + ((codepoint - 55296) << 10) + (low - 56320);
                    } else if codepoint >= 56320 and codepoint <= 57343 {
                        throw Error.invalid_unicode;
                    }
                    self.append_codepoint(&decoded, codepoint);
                } else {
                    throw Error.invalid_escape;
                }
            } else {
                if byte < 32 {
                    throw Error.invalid_escape;
                }
                self.append_byte(&decoded, byte);
                self.pos = self.pos + 1;
            }
        }

        throw Error.unexpected_end;
    }

    fn parse_number(self: &Parser): Number ! Error {
        const source = self.text.bytes();
        const start = self.pos;
        if self.pos < source.len() and source[self.pos] == 45 {
            self.pos = self.pos + 1;
        }
        if self.pos >= source.len() {
            throw Error.invalid_token;
        }

        if source[self.pos] == 48 {
            self.pos = self.pos + 1;
            if self.pos < source.len() and is_digit(source[self.pos]) {
                throw Error.invalid_token;
            }
        } else if source[self.pos] >= 49 and source[self.pos] <= 57 {
            while self.pos < source.len() and is_digit(source[self.pos]) {
                self.pos = self.pos + 1;
            }
        } else {
            throw Error.invalid_token;
        }

        if self.pos < source.len() and source[self.pos] == 46 {
            self.pos = self.pos + 1;
            if self.pos >= source.len() or not is_digit(source[self.pos]) {
                throw Error.invalid_token;
            }
            while self.pos < source.len() and is_digit(source[self.pos]) {
                self.pos = self.pos + 1;
            }
        }

        if self.pos < source.len() and (source[self.pos] == 101 or source[self.pos] == 69) {
            self.pos = self.pos + 1;
            if self.pos < source.len() and (source[self.pos] == 43 or source[self.pos] == 45) {
                self.pos = self.pos + 1;
            }
            if self.pos >= source.len() or not is_digit(source[self.pos]) {
                throw Error.invalid_token;
            }
            while self.pos < source.len() and is_digit(source[self.pos]) {
                self.pos = self.pos + 1;
            }
        }

        return Number {
            spelling: string.from(source[start..self.pos])
        };
    }

    fn parse_array(self: &Parser, depth: usize): Array ! Error {
        self.pos = self.pos + 1;
        self.skip_whitespace();
        var items: List<Value> = list<Value>();

        if self.pos < self.text.len() and self.text.bytes()[self.pos] == 93 {
            self.pos = self.pos + 1;
            return Array {
                items: items
            };
        }

        while true {
            const value = try self.parse_value(depth + 1);
            items.push(value);
            self.skip_whitespace();
            if self.pos >= self.text.len() {
                throw Error.unexpected_end;
            }

            const separator = self.text.bytes()[self.pos];
            if separator == 93 {
                self.pos = self.pos + 1;
                return Array {
                    items: items
                };
            }
            if separator != 44 {
                throw Error.invalid_token;
            }
            self.pos = self.pos + 1;
            self.skip_whitespace();
        }
        throw Error.invalid_token;
    }

    fn has_member(self: &const Parser, members: &const List<Member>, key: string): bool {
        const ignored = self;
        var index: usize = 0;
        while index < members.len() {
            if members[index].key == key {
                return true;
            }
            index = index + 1;
        }
        return false;
    }

    fn parse_object(self: &Parser, depth: usize): Object ! Error {
        self.pos = self.pos + 1;
        self.skip_whitespace();
        var members: List<Member> = list<Member>();

        if self.pos < self.text.len() and self.text.bytes()[self.pos] == 125 {
            self.pos = self.pos + 1;
            return Object {
                members: members
            };
        }

        while true {
            const key = try self.parse_string();
            if self.has_member(&members, key) {
                throw Error.duplicate_key;
            }
            self.skip_whitespace();
            if self.pos >= self.text.len() or self.text.bytes()[self.pos] != 58 {
                throw Error.invalid_token;
            }
            self.pos = self.pos + 1;
            self.skip_whitespace();

            const value = try self.parse_value(depth + 1);
            members.push(Member {
                key: key,
                value: value
            });
            self.skip_whitespace();
            if self.pos >= self.text.len() {
                throw Error.unexpected_end;
            }

            const separator = self.text.bytes()[self.pos];
            if separator == 125 {
                self.pos = self.pos + 1;
                return Object {
                    members: members
                };
            }
            if separator != 44 {
                throw Error.invalid_token;
            }
            self.pos = self.pos + 1;
            self.skip_whitespace();
        }
        throw Error.invalid_token;
    }

    fn parse_value(self: &Parser, depth: usize): Value ! Error {
        if depth > max_depth {
            throw Error.depth_exceeded;
        }
        if self.pos >= self.text.len() {
            throw Error.unexpected_end;
        }

        const byte = self.text.bytes()[self.pos];
        if byte == 123 {
            const object = try self.parse_object(depth);
            const value: Value = .object(object);
            return value;
        }
        if byte == 91 {
            const array = try self.parse_array(depth);
            const value: Value = .array(array);
            return value;
        }
        if byte == quote {
            const text = try self.parse_string();
            const value: Value = .string(text);
            return value;
        }
        if byte == 45 or is_digit(byte) {
            const number = try self.parse_number();
            const value: Value = .number(number);
            return value;
        }
        if self.consume_literal("true") {
            const value: Value = .bool(true);
            return value;
        }
        if self.consume_literal("false") {
            const value: Value = .bool(false);
            return value;
        }
        if self.consume_literal("null") {
            const value: Value = .null_value;
            return value;
        }
        throw Error.invalid_token;
    }
}

pub fn parse(text: string): Value ! Error {
    var parser = Parser {
        text: text,
        pos: 0
    };
    parser.skip_whitespace();
    const value = try parser.parse_value(0);
    parser.skip_whitespace();
    if parser.pos != text.len() {
        throw Error.trailing_data;
    }
    return value;
}

pub fn parse_bytes(text: []const u8): Value ! Error {
    try validate_utf8_bytes(text);
    return try parse(string.from(text));
}

pub fn validate(text: string): void ! Error {
    const ignored = try parse(text);
    return;
}

pub fn validate_bytes(text: []const u8): void ! Error {
    const ignored = try parse_bytes(text);
    return;
}

struct Encoder {
    out: List<u8>;
    pretty: bool;

    fn append_byte(self: &Encoder, byte: u8): void {
        self.out.push(byte);
    }

    fn append_text(self: &Encoder, text: string): void {
        const bytes = text.bytes();
        var index: usize = 0;
        while index < bytes.len() {
            self.out.push(bytes[index]);
            index = index + 1;
        }
    }

    fn newline(self: &Encoder, depth: usize): void {
        if not self.pretty {
            return;
        }
        self.append_byte(10);
        var index: usize = 0;
        while index < depth * 2 {
            self.append_byte(32);
            index = index + 1;
        }
    }

    fn append_hex_escape(self: &Encoder, byte: u8): void {
        const digits = "0123456789ABCDEF".bytes();
        self.append_byte(92);
        self.append_byte(117);
        self.append_byte(48);
        self.append_byte(48);
        self.append_byte(digits[(byte >> 4) as usize]);
        self.append_byte(digits[(byte & 15) as usize]);
    }

    fn emit_string(self: &Encoder, text: string): void {
        const bytes = text.bytes();
        self.append_byte(quote);
        var index: usize = 0;
        while index < bytes.len() {
            const byte = bytes[index];
            if byte == quote {
                self.append_byte(92);
                self.append_byte(quote);
            } else if byte == backslash {
                self.append_byte(92);
                self.append_byte(backslash);
            } else if byte == 8 {
                self.append_byte(92);
                self.append_byte(98);
            } else if byte == 12 {
                self.append_byte(92);
                self.append_byte(102);
            } else if byte == 10 {
                self.append_byte(92);
                self.append_byte(110);
            } else if byte == 13 {
                self.append_byte(92);
                self.append_byte(114);
            } else if byte == 9 {
                self.append_byte(92);
                self.append_byte(116);
            } else if byte < 32 {
                self.append_hex_escape(byte);
            } else {
                self.append_byte(byte);
            }
            index = index + 1;
        }
        self.append_byte(quote);
    }

    fn emit_array(self: &Encoder, array: &const Array, depth: usize): void {
        self.append_byte(91);
        var index: usize = 0;
        while index < array.items.len() {
            if index != 0 {
                self.append_byte(44);
            }
            self.newline(depth + 1);
            self.emit_value(&array.items[index], depth + 1);
            index = index + 1;
        }
        if array.items.len() != 0 {
            self.newline(depth);
        }
        self.append_byte(93);
    }

    fn emit_object(self: &Encoder, object: &const Object, depth: usize): void {
        self.append_byte(123);
        var index: usize = 0;
        while index < object.members.len() {
            if index != 0 {
                self.append_byte(44);
            }
            self.newline(depth + 1);
            self.emit_string(object.members[index].key);
            self.append_byte(58);
            if self.pretty {
                self.append_byte(32);
            }
            self.emit_value(&object.members[index].value, depth + 1);
            index = index + 1;
        }
        if object.members.len() != 0 {
            self.newline(depth);
        }
        self.append_byte(125);
    }

    fn emit_value(self: &Encoder, value: &const Value, depth: usize): void {
        if depth > max_depth {
            panic("std.json maximum depth exceeded");
        }
        switch value {
            .null_value => {
                self.append_text("null");
            }
            .bool(flag) => {
                if flag {
                    self.append_text("true");
                } else {
                    self.append_text("false");
                }
            }
            .number(number) => {
                self.append_text(number.spelling);
            }
            .string(text) => {
                self.emit_string(text);
            }
            .array(array) => {
                self.emit_array(&array, depth);
            }
            .object(object) => {
                self.emit_object(&object, depth);
            }
        }
    }
}

pub fn encode(value: &const Value): string {
    var encoder = Encoder {
        out: list<u8>(),
        pretty: false
    };
    encoder.emit_value(value, 0);
    return string.from(encoder.out.view());
}

pub fn encode_pretty(value: &const Value): string {
    var encoder = Encoder {
        out: list<u8>(),
        pretty: true
    };
    encoder.emit_value(value, 0);
    return string.from(encoder.out.view());
}
