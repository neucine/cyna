const std = @import("std");

const helpers = @import("../../helpers.zig");

test "explicit generic tuple argument receives substituted member types" {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_tuple_literal", "generic_tuple_literal.cy",
        \\fn swap<T>(value: (T, i32)): (i32, T) { return (value.1, value.0); }
        \\fn main(): i32 {
        \\    const result = swap<i32>((2, 40));
        \\    return result.0 + result.1;
        \\}
    , 42);
}

test "generic tuple resource argument retains one owner across return" {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_tuple_resource", "generic_tuple_resource.cy",
        \\fn forward<T>(value: (T, i32)): (T, i32) { return value; }
        \\fn main(): i32 {
        \\    const result = forward<[:]i32>(([40, 2], 0));
        \\    const first = result.0;
        \\    return first[0] + first[1];
        \\}
    , 42);
}

test "generic parameter is inferred from a tuple member" {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_tuple_inferred", "generic_tuple_inferred.cy",
        \\fn swap<T>(value: (T, i32)): (i32, T) { return (value.1, value.0); }
        \\fn main(): i32 {
        \\    const input: (i32, i32) = (2, 40);
        \\    const result = swap(input);
        \\    return result.0 + result.1;
        \\}
    , 42);
}

test "sequence literal factories execute standard List and renamed resource factories" {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "sequence_factory_resources", "sequence_factory_resources.cy",
        \\struct Batch<T> { storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn gather<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
        \\fn words(): List<string> { return ["answer", "ready"]; }
        \\fn main(): i32 {
        \\    var empty: List<i32> = [];
        \\    empty.push(21);
        \\    const numbers: List<i32> = [21, 7];
        \\    const digit = 1;
        \\    var text = $"a{digit}";
        \\    const batch: Batch<string> = [text, $"c{digit}"];
        \\    assert(batch.storage[0] == "a1");
        \\    assert(batch.storage[1] == "c1");
        \\    var resource: [:]i32 = [42];
        \\    const resources: Batch<[:]i32> = [resource, [7]];
        \\    assert(resources.storage[0][0] == 42);
        \\    assert(resources.storage[1][0] == 7);
        \\    const messages = words();
        \\    assert(messages[0] == "answer");
        \\    return empty[0] + numbers[0];
        \\}
    , 42);
}

test "sequence literal factories preserve evaluation order and clean up early errors" {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "sequence_factory_order_cleanup", "sequence_factory_order_cleanup.cy",
        \\var trace: i32 = 0;
        \\enum Failure { failed }
        \\struct Batch<T> { storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn gather<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
        \\fn item(value: i32, fail: bool): [:]i32!Failure {
        \\    trace = trace * 10 + value;
        \\    if fail { throw Failure.failed; }
        \\    return [value];
        \\}
        \\fn build(fail: bool): Batch<[:]i32>!Failure {
        \\    const batch: Batch<[:]i32> = [try item(1, false), try item(2, fail), try item(3, false)];
        \\    return batch;
        \\}
        \\fn must_fail(): i32 {
        \\    const batch = build(true) catch (problem) { return 0; };
        \\    const ignored = batch;
        \\    return 2;
        \\}
        \\fn main(): i32 {
        \\    const first = build(false) catch (problem) { return 1; };
        \\    const ignored = first;
        \\    assert(trace == 123);
        \\    trace = 0;
        \\    if must_fail() != 0 { return 2; }
        \\    assert(trace == 12);
        \\    return 42;
        \\}
    , 42);
}

test "generic method admission retains declared repeated and keyed element contracts" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const repeated: [2]T = [value] ** 2;
        \\    var slots = [;]T { 0: value };
        \\    if &slots[0] is item { return item.read() + repeated[1].read(); }
        \\    return 0;
        \\}
        \\fn main(): i32 { return inspect<Value>(Value { number: 21 }); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_constructor_contracts", "generic_constructor_contracts.cy", source, 42);
}

test "generic method admission keeps named callback inference in its declaration namespace" {
    const source =
        \\struct T { fn answer(self: &const T): i32 { return 42; } }
        \\fn seed(): T { return T {}; }
        \\fn choose<U>(action: fn(): U, fallback: U): U { return action(); }
        \\fn inspect<T>(value: T): i32 { const selected = choose(seed, value); return selected.answer(); }
        \\fn main(): i32 { return inspect<T>(T {}); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_named_callback_namespace", "generic_named_callback_namespace.cy", source, 42);
}

test "generic method admission uses contextual callback parameter protocols" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const action: fn(T): i32 = fn(item) { return item.read(); };
        \\    return action(value);
        \\}
        \\fn main(): i32 { return inspect<Value>(Value { number: 42 }); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_contextual_callback_protocol", "generic_contextual_callback_protocol.cy", source, 42);
}

test "contextual generic callback dispatches the declared protocol witness" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\protocol OtherRead { fn read(self: &const Self): i32; }
        \\struct Value {}
        \\impl Value: Readable { fn read(self: &const Value): i32 { return 42; } }
        \\impl Value: OtherRead { fn read(self: &const Value): i32 { return 99; } }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const action: fn(T): i32 = fn(item) { return item.read(); };
        \\    return action(value);
        \\}
        \\fn main(): i32 { return inspect<Value>(Value {}); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_callback_declared_witness", "generic_callback_declared_witness.cy", source, 42);
}

test "separate contextual callbacks retain declared protocol witnesses" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\protocol OtherRead { fn read(self: &const Self): i32; }
        \\struct Value {}
        \\impl Value: Readable { fn read(self: &const Value): i32 { return 42; } }
        \\impl Value: OtherRead { fn read(self: &const Value): i32 { return 99; } }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const first: fn(T): i32 = fn(item) { return item.read(); };
        \\    const second: fn(T): i32 = fn(item) { return item.read(); };
        \\    return first(value) + second(value);
        \\}
        \\fn main(): i32 { return inspect<Value>(Value {}); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_callbacks_declared_witnesses", "generic_callbacks_declared_witnesses.cy", source, 84);
}

test "generic method admission infers callback argument protocols through generic calls" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn apply<U>(value: U, action: fn(U): i32): i32 { return action(value); }
        \\fn apply_first<U>(action: fn(U): i32, value: U): i32 { return action(value); }
        \\fn inspect<T: Readable>(value: T): i32 { return apply(value, fn(item) { return item.read(); }); }
        \\fn inspect_first<T: Readable>(value: T): i32 { return apply_first(fn(item) { return item.read(); }, value); }
        \\fn main(): i32 { return inspect<Value>(Value { number: 21 }) + inspect_first<Value>(Value { number: 21 }); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_callback_argument_protocol", "generic_callback_argument_protocol.cy", source, 42);
}

test "generic method admission retains attributed index and iteration element contracts" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn indexed<T: Readable>(values: &const List<T>): i32 { return values[0].read(); }
        \\fn iterated<T: Readable>(values: &const List<T>): i32 { for item in values { return item.read(); } return 0; }
        \\fn main(): i32 { var values = list<Value>(); values.push(Value { number: 21 }); return indexed<Value>(&values) + iterated<Value>(&values); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_associated_elements", "generic_associated_elements.cy", source, 42);
}

test "generic method admission retains declared generic impl method return contracts" {
    const source =
        \\protocol Project { type Item; fn project(self: &const Self): Self.Item; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Holder<Stored> { item: Stored; }
        \\impl<Element> Holder<Element>: Project { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\fn inspect<T: Readable>(holder: &const Holder<T>): i32 { const item = holder.project(); return item.read(); }
        \\fn main(): i32 { const holder = Holder<Value> { item: Value { number: 42 } }; return inspect<Value>(&holder); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_impl_return_contract", "generic_impl_return_contract.cy", source, 42);
}

test "generic method admission resolves qualified associated returns from the selected impl" {
    const source =
        \\protocol Project { type Item; fn project(self: &const Self): Self.Item; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Holder<Stored> { item: Stored; }
        \\impl<Element> Holder<Element>: Project { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\fn inspect<T: Readable>(holder: &const Holder<T>): i32 { const item = Project.project(holder); return item.read(); }
        \\fn main(): i32 { const holder = Holder<Value> { item: Value { number: 42 } }; return inspect<Value>(&holder); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_qualified_associated_return", "generic_qualified_associated_return.cy", source, 42);
}

test "generic method admission preserves qualified protocol Self returns" {
    const source =
        \\protocol CopyValue { fn duplicate(self: &const Self): Self; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\protocol OtherRead { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: CopyValue { fn duplicate(self: &const Value): Value { return Value { number: self.number }; } }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\impl Value: OtherRead { fn read(self: &const Value): i32 { return 99; } }
        \\fn inspect<T: CopyValue & Readable & OtherRead>(value: &const T): i32 { const duplicated = CopyValue.duplicate(value); return Readable.read(&duplicated); }
        \\fn main(): i32 { const value = Value { number: 42 }; return inspect<Value>(&value); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_qualified_protocol_self", "generic_qualified_protocol_self.cy", source, 42);
}

test "generic method admission retains checked success payload contracts" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\enum Failure { bad, }
        \\fn produce<T>(value: T): T!Failure { return value; }
        \\fn inspect<T: Readable>(value: T): i32 {
        \\    const item = produce<T>(value) catch (reason) { return 0; };
        \\    return item.read();
        \\}
        \\fn loop<T: Readable>(value: T): i32 {
        \\    var once = true;
        \\    while once { once = false; const item = produce<T>(value) catch (reason) { return 0; }; return item.read(); }
        \\    return 0;
        \\}
        \\fn main(): i32 { const value = Value { number: 21 }; return inspect<Value>(value) + loop<Value>(value); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_result_payloads", "generic_declared_result_payloads.cy", source, 42);
}

test "generic method admission retains declared optional and iteration payload contracts" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn optional<T: Readable>(value: ?T): i32 { if value is item { return item.read(); } return 0; }
        \\fn iterate<T: Readable>(values: []const T): i32 { for item in values { return item.read(); } return 0; }
        \\fn loop<T: Readable>(value: ?T): i32 { var once = true; while once { once = false; if value is item { return item.read(); } } return 0; }
        \\fn main(): i32 { const values: [1]Value = [Value { number: 14 }]; return optional<Value>(values[0]) + iterate<Value>(values[..]) + loop<Value>(values[0]); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_payloads", "generic_declared_payloads.cy", source, 42);
}

test "generic method admission keeps explicit C scalar inference concrete" {
    const source =
        \\fn first<U>(left: U, right: U): U { return left; }
        \\fn inspect<T>(fixed: c_int, value: T): bool {
        \\    const selected = first(fixed, value);
        \\    return selected == fixed;
        \\}
        \\fn main(): i32 { if inspect<c_int>(21, 21) { return 42; } return 0; }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_concrete_c_scalar_inference", "generic_concrete_c_scalar_inference.cy", source, 42);
}

test "generic method admission uses declared protocol through reference aliases" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Readable>(value: T): i32 { const alias = &value; return alias.read(); }
        \\fn main(): i32 { return inspect<Value>(Value { number: 42 }); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_method_alias", "generic_declared_method_alias.cy", source, 42);
}

test "generic method admission preserves unrelated concrete receiver with equal type argument" {
    const source =
        \\struct Value { fn answer(self: &const Value): i32 { return 42; } }
        \\fn inspect<T>(input: T): i32 { const concrete = Value {}; return concrete.answer(); }
        \\fn main(): i32 { return inspect<Value>(Value {}); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_concrete_receiver", "generic_concrete_receiver.cy", source, 42);
}

test "generic method admission preserves declared authority through renamed alias fields" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Holder<Stored> { item: Stored; }
        \\type Container<Element> = Holder<Element>;
        \\fn inspect<T: Readable>(value: &const Container<T>): i32 { const item = &value.item; return item.read(); }
        \\fn main(): i32 { const value = Holder<Value> { item: Value { number: 42 } }; return inspect<Value>(&value); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_alias_field", "generic_declared_alias_field.cy", source, 42);
}

test "generic method admission does not reinterpret concrete field type in caller namespace" {
    const source =
        \\struct T { fn answer(self: &const T): i32 { return 42; } }
        \\struct Box { value: T; }
        \\fn inspect<T>(input: T, box: &const Box): i32 { return box.value.answer(); }
        \\fn main(): i32 { const box = Box { value: T {} }; return inspect<i32>(0, &box); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_concrete_field_namespace", "generic_concrete_field_namespace.cy", source, 42);
}

test "generic method admission retains declared authority through inferred returns and callbacks" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn identity<U>(value: U): U { return value; }
        \\fn inspect<T: Readable>(value: T): i32 { const result = identity(value); return result.read(); }
        \\fn invoke<T: Readable>(action: fn(T): T, value: T): i32 { const result = action(value); return result.read(); }
        \\fn keep(value: Value): Value { return value; }
        \\fn main(): i32 { const value = Value { number: 21 }; return inspect<Value>(value) + invoke<Value>(keep, value); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_return_and_callback", "generic_declared_return_and_callback.cy", source, 42);
}

test "generic method admission retains declared authority through nominal method returns" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Holder<Stored> { item: Stored; fn get(self: Holder<Stored>): Stored { return self.item; } }
        \\fn inspect<T: Readable>(value: Holder<T>): i32 { const result = value.get(); return result.read(); }
        \\fn main(): i32 { return inspect<Value>(Holder<Value> { item: Value { number: 42 } }); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_declared_nominal_method_return", "generic_declared_nominal_method_return.cy", source, 42);
}

test "generic method admission retains Self return protocol sets" {
    const source =
        \\protocol Duplicate { fn duplicate(self: &const Self): Self; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Duplicate { fn duplicate(self: &const Value): Value { return Value { number: self.number }; } }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\fn inspect<T: Duplicate & Readable>(value: &const T): i32 { const duplicated = value.duplicate(); return duplicated.read(); }
        \\fn main(): i32 { const value = Value { number: 42 }; return inspect<Value>(&value); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_self_return_protocols", "generic_self_return_protocols.cy", source, 42);
}

test "generic method admission preserves inferred arithmetic and fixed boolean results" {
    const source =
        \\fn doubled<T: Eq>(value: T, expected: T): bool { const sum = value + value; return sum.eq(&expected); }
        \\fn compared<T>(value: T): bool { const result = value == value; const expected = true; return result.eq(&expected); }
        \\fn seed(): i32 { return 21; }
        \\fn fixed<T>(value: T): bool { const sum = seed() + value; const expected: i32 = 42; return sum.eq(&expected); }
        \\fn main(): i32 { if doubled<i32>(21, 42) and compared<i32>(21) and fixed<i32>(21) { return 42; } return 0; }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_arithmetic_authority", "generic_arithmetic_authority.cy", source, 42);
}

test "generic method admission accepts explicit associated result behavior contracts" {
    const source =
        \\protocol Source { type Item; fn project(self: &const Self): Self.Item; }
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\struct Value { number: i32; }
        \\impl Value: Readable { fn read(self: &const Value): i32 { return self.number; } }
        \\struct Box { item: Value; }
        \\impl Box: Source { type Item = Value; fn project(self: &const Box): Value { return self.item; } }
        \\fn consume<T: Source>(value: &const T, action: fn(T.Item): i32): i32 { const item = value.project(); return action(item); }
        \\fn typed<T: Source, Item: Readable>(value: &const T): i32 { const item: Item = value.project(); return item.read(); }
        \\fn read_value(value: Value): i32 { return value.number; }
        \\fn main(): i32 { const box = Box { item: Value { number: 21 } }; return consume<Box>(&box, read_value) + typed<Box, Value>(&box); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_associated_explicit_behavior", "generic_associated_explicit_behavior.cy", source, 42);
}

test "generic forwarding composes nested free function bindings" {
    const source =
        \\fn inner<V>(value: V): V { return value; }
        \\fn middle<U>(value: U): U { return inner<U>(value); }
        \\fn outer<T>(value: T): T { return middle<T>(value); }
        \\fn main(): i32 { return outer<i32>(42); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_forwarding_free", "generic_forwarding_free.cy", source, 42);
}

test "generic forwarding preserves reference identity through summary composition" {
    const source =
        \\fn inner<T>(value: &const T): &const T { return value; }
        \\fn outer<T>(value: &const T): &const T { return inner<T>(value); }
        \\fn main(): i32 {
        \\    var value: i32 = 42;
        \\    const observed = outer<i32>(&value);
        \\    return observed;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_forwarding_reference", "generic_forwarding_reference.cy", source, 42);
}

test "generic forwarding composes generic method and free function bindings" {
    const source =
        \\fn identity<V>(value: V): V { return value; }
        \\struct Box<T> {
        \\    value: T;
        \\    fn forward<U>(self: &const Box<T>, value: U): U { return identity<U>(value); }
        \\}
        \\fn outer<T>(value: T): T {
        \\    var box = Box<i32> { value: 0 };
        \\    return box.forward<T>(value);
        \\}
        \\fn main(): i32 { return outer<i32>(42); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_forwarding_method", "generic_forwarding_method.cy", source, 42);
}

test "generic forwarding resolves impl witnesses and associated projections" {
    const source =
        \\fn identity<V>(value: V): V { return value; }
        \\protocol Source {
        \\    type Item;
        \\    fn get(self: &const Self): Self.Item;
        \\}
        \\struct Box<T> { value: T; }
        \\impl<T> Box<T>: Source {
        \\    type Item = T;
        \\    fn get(self: &const Box<T>): T { return identity<T>(self.value); }
        \\}
        \\fn read<S: Source>(source: &const S): S.Item {
        \\    return identity<S.Item>(Source.get(source));
        \\}
        \\fn forward<S: Source>(source: &const S): S.Item { return read<S>(source); }
        \\fn main(): i32 { var box = Box<i32> { value: 42 }; return forward<Box<i32>>(&box); }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_forwarding_associated", "generic_forwarding_associated.cy", source, 42);
}

test "core Eq implementations are callable for primitive and char values" {
    const source =
        \\fn same<T: Eq>(left: &T, right: &T): bool {
        \\    return left.eq(right);
        \\}
        \\
        \\fn main(): i32 {
        \\    var left_int: i32 = 7;
        \\    var right_int: i32 = 7;
        \\    if not same(&left_int, &right_int) {
        \\        return 1;
        \\    }
        \\
        \\    var left_string: string = "cyna";
        \\    var right_string: string = "cyna";
        \\    if not same(&left_string, &right_string) {
        \\        return 2;
        \\    }
        \\
        \\    var left_rune: char = 'A';
        \\    var right_rune: char = 'A';
        \\    if not same(&left_rune, &right_rune) {
        \\        return 3;
        \\    }
        \\
        \\    var runes: Set<char> = set<char>();
        \\    runes.add('A');
        \\    if not runes.contains('A') {
        \\        return 4;
        \\    }
        \\
        \\    var rune_scores: Map<char, i32> = map<char, i32>();
        \\    rune_scores['A'] = 42;
        \\    if rune_scores['A'] != 42 {
        \\        return 5;
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "core_eq_calls",
        "native_core_eq_calls.cy",
        source,
        42,
    );
}

test "collection keys outside explicit Eq are rejected at instantiation" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "collection_enum_requires_eq",
            .source =
            \\enum Color { red, blue, }
            \\fn main(): i32 {
            \\    var colors: Set<Color> = set<Color>();
            \\    return colors.len() as i32;
            \\}
            ,
        },
        .{
            .name = "collection_flags_requires_eq",
            .source =
            \\flags Mode: i32 { read = 2, write = 4, }
            \\fn main(): i32 {
            \\    var scores: Map<Mode, i32> = map<Mode, i32>();
            \\    return scores.len() as i32;
            \\}
            ,
        },
        .{
            .name = "collection_raw_pointer_requires_eq",
            .source =
            \\struct Bag { value: i32; }
            \\fn main(): i32 {
            \\    var owner = new Bag { value: 7 };
            \\    const ptr: *Bag = owner.ptr();
            \\    var pointers: Set<*Bag> = set<*Bag>();
            \\    pointers.add(ptr);
            \\    return pointers.len() as i32;
            \\}
            ,
        },
        .{
            .name = "collection_fixed_array_requires_eq",
            .source =
            \\fn main(): i32 {
            \\    var scores: Map<[2]i32, i32> = map<[2]i32, i32>();
            \\    return scores.len() as i32;
            \\}
            ,
        },
    };

    for (cases) |case| {
        try helpers.expectLoadedSemanticFailedMessage(
            std.testing.allocator,
            case.name,
            case.source,
            "does not implement protocol `std.prelude.Eq`",
        );
    }
}

test "borrowed sparse capture supports Eq for a resource-bearing value" {
    const source =
        \\struct Bag {
        \\    values: List<i32>;
        \\    tag: i32;
        \\}
        \\
        \\impl Bag: Eq {
        \\    fn eq(self: &const Bag, other: &const Bag): bool {
        \\        return self.tag == other.tag;
        \\    }
        \\}
        \\
        \\fn scan<T: Eq>(slots: &[;]T, value: T): bool {
        \\    var query = value;
        \\    for idx in slots.indices() {
        \\        if &slots[idx] is current {
        \\            if current.eq(&query) {
        \\                return true;
        \\            }
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(7);
        \\    var slots = [; 1]Bag;
        \\    slots.insert(0, Bag { values: values, tag: 1 });
        \\
        \\    var query_values: List<i32> = list<i32>();
        \\    query_values.push(8);
        \\    if scan(&slots, Bag { values: query_values, tag: 1 }) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "borrowed_sparse_resource_eq",
        "native_borrowed_sparse_resource_eq.cy",
        source,
        42,
    );
}

test "Set and Map use Eq through resource-safe growth and replacement" {
    const source =
        \\struct Key {
        \\    id: i32;
        \\    values: List<i32>;
        \\}
        \\
        \\impl Key: Eq {
        \\    fn eq(self: &const Key, other: &const Key): bool {
        \\        return self.id == other.id;
        \\    }
        \\}
        \\
        \\fn key(id: i32): Key {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(id);
        \\    return Key { id: id, values: values };
        \\}
        \\
        \\fn main(): i32 {
        \\    var keys: Set<Key> = set<Key>();
        \\    keys.add(key(1));
        \\    keys.add(key(2));
        \\    keys.add(key(3));
        \\    keys.add(key(4));
        \\    keys.add(key(5));
        \\    keys.add(key(6));
        \\    keys.add(key(3));
        \\    if keys.len() != 6 or not keys.contains(key(5)) or keys.contains(key(9)) {
        \\        return 1;
        \\    }
        \\
        \\    var scores: Map<Key, i32> = map<Key, i32>();
        \\    scores[key(1)] = 10;
        \\    scores[key(2)] = 20;
        \\    scores[key(3)] = 30;
        \\    scores[key(4)] = 40;
        \\    scores[key(5)] = 50;
        \\    scores[key(6)] = 60;
        \\    scores[key(3)] = 42;
        \\    if scores.len() != 6 or not scores.contains(key(3)) or scores.contains(key(9)) {
        \\        return 2;
        \\    }
        \\    return scores[key(3)];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "resource_collection_eq_growth",
        "native_resource_collection_eq_growth.cy",
        source,
        42,
    );
}

test "resource Eq collections support literals value snapshots clear and reuse" {
    const source =
        \\struct Key {
        \\    id: i32;
        \\    values: List<i32>;
        \\}
        \\
        \\impl Key: Eq {
        \\    fn eq(self: &const Key, other: &const Key): bool {
        \\        return self.id == other.id;
        \\    }
        \\}
        \\impl Key: Clone {
        \\    fn clone(self: &const Key): Key {
        \\        return Key { id: self.id, values: self.values.clone() };
        \\    }
        \\}
        \\
        \\fn key(id: i32): Key {
        \\    var values: List<i32> = list_from<i32>([:]i32 [id]);
        \\    return Key { id: id, values: values };
        \\}
        \\
        \\fn main(): i32 {
        \\    var keys: Set<Key> = set<Key>();
        \\    keys.add(key(1));
        \\    keys.add(key(2));
        \\    keys.add(key(1));
        \\    var copied_keys = keys.clone();
        \\    keys.clear();
        \\    keys.add(key(3));
        \\    if keys.len() != 1 or not keys.contains(key(3)) {
        \\        return 1;
        \\    }
        \\    if copied_keys.len() != 2 or not copied_keys.contains(key(1)) {
        \\        return 2;
        \\    }
        \\
        \\    var scores: Map<Key, i32> = map<Key, i32>();
        \\    scores[key(1)] = 10;
        \\    scores[key(2)] = 20;
        \\    var copied_scores = scores.clone();
        \\    const value_snapshot = scores.values();
        \\    scores.clear();
        \\    scores[key(3)] = 30;
        \\    if scores.len() != 1 or scores[key(3)] != 30 {
        \\        return 3;
        \\    }
        \\    if copied_scores.len() != 2 or not copied_scores.contains(key(2)) or copied_scores[key(2)] != 20 {
        \\        return 4;
        \\    }
        \\    if value_snapshot.len() != 2 {
        \\        return 5;
        \\    }
        \\
        \\    var value_total: i32 = 0;
        \\    for value in value_snapshot {
        \\        value_total = value_total + value;
        \\    }
        \\    if value_total != 30 {
        \\        return 6;
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "resource_eq_collection_supported_surface",
        "native_resource_eq_collection_supported_surface.cy",
        source,
        42,
    );
}

test "by-value collection indexing rejects resource reads before lowering" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        message: []const u8,
    }{
        .{
            .name = "resource_set_iteration_requires_borrowed_index",
            .source =
            \\struct Key {
            \\    id: i32;
            \\    values: List<i32>;
            \\}
            \\impl Key: Eq {
            \\    fn eq(self: &const Key, other: &const Key): bool {
            \\        return self.id == other.id;
            \\    }
            \\}
            \\fn main(): i32 {
            \\    var keys: Set<Key> = set<Key>();
            \\    for key in keys {
            \\        const ignored = key.id;
            \\    }
            \\    return 42;
            \\}
            ,
            .message = "cannot iterate resource item type `Key` through a by-value index hook",
        },
        .{
            .name = "resource_set_index_requires_borrowed_index",
            .source =
            \\struct Key {
            \\    id: i32;
            \\    values: List<i32>;
            \\}
            \\impl Key: Eq {
            \\    fn eq(self: &const Key, other: &const Key): bool {
            \\        return self.id == other.id;
            \\    }
            \\}
            \\fn main(): i32 {
            \\    var keys: Set<Key> = set<Key>();
            \\    const key = keys[0];
            \\    return key.id;
            \\}
            ,
            .message = "cannot read resource item type `Key` through a by-value index hook",
        },
        .{
            .name = "resource_map_value_index_requires_borrowed_index",
            .source =
            \\struct Payload {
            \\    values: List<i32>;
            \\}
            \\fn main(): i32 {
            \\    var payload: List<i32> = list_from<i32>([:]i32 [42]);
            \\    var values: Map<i32, Payload> = map<i32, Payload>();
            \\    values[1] = Payload { values: payload };
            \\    const found = values[1];
            \\    return found.values[0];
            \\}
            ,
            .message = "cannot read resource item type `Payload` through a by-value index hook",
        },
        .{
            .name = "resource_map_key_snapshot_requires_copyable_key",
            .source =
            \\struct Key {
            \\    id: i32;
            \\    values: List<i32>;
            \\}
            \\impl Key: Eq {
            \\    fn eq(self: &const Key, other: &const Key): bool {
            \\        return self.id == other.id;
            \\    }
            \\}
            \\fn main(): i32 {
            \\    var scores: Map<Key, i32> = map<Key, i32>();
            \\    const keys = scores.keys();
            \\    return 42;
            \\}
            ,
            .message = "cannot hand off a projected owned value via sparse storage insertion",
        },
        .{
            .name = "resource_map_value_snapshot_requires_copyable_value",
            .source =
            \\struct Payload {
            \\    values: List<i32>;
            \\}
            \\fn main(): i32 {
            \\    var values: Map<i32, Payload> = map<i32, Payload>();
            \\    const snapshot = values.values();
            \\    return 42;
            \\}
            ,
            .message = "cannot hand off a projected owned value via sparse storage insertion",
        },
    };

    for (cases) |case| {
        try helpers.expectLoadedSemanticFailedMessage(
            std.testing.allocator,
            case.name,
            case.source,
            case.message,
        );
    }
}

test "generic collection iterator hook symbols remain stable through lowering" {
    const source =
        \\fn main(): i32 {
        \\    var values: Set<i32> = set<i32>();
        \\    values.add(8);
        \\    values.add(8);
        \\    values.add(10);
        \\
        \\    var total: i32 = 24;
        \\    for value in values {
        \\        total = total + value;
        \\    }
        \\    return total;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "stable_generic_collection_iterator_hooks",
        "native_stable_generic_collection_iterator_hooks.cy",
        source,
        42,
    );
}

test "alias pointer collection items are rejected by their missing Eq bound" {
    const source =
        \\fn main(): i32 {
        \\    var value: i32 = 7;
        \\    var alias: &i32 = &value;
        \\    var aliases: Set<&i32> = set<&i32>();
        \\    aliases.add(alias);
        \\    if aliases.contains(alias) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "alias_pointer_set_requires_eq",
        source,
        "does not implement protocol `std.prelude.Eq`",
    );
}

test "owned sequence Set key is rejected by its missing Eq bound" {
    const source =
        \\fn main(): i32 {
        \\    var first: [:]i32 = [1, 2];
        \\    var values: Set<[:]i32> = set<[:]i32>();
        \\    values.add(first);
        \\    var query: [:]i32 = [1, 2];
        \\    if values.contains(query) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "owned_sequence_set_requires_eq",
        source,
        "type `[:]i32` does not implement protocol `std.prelude.Eq`",
    );
}

test "owned sequence Map key is rejected by its missing Eq bound" {
    const source =
        \\fn main(): i32 {
        \\    var key: [:]i32 = [1, 2];
        \\    var scores: Map<[:]i32, i32> = map<[:]i32, i32>();
        \\    scores[key] = 42;
        \\    var query: [:]i32 = [1, 2];
        \\    return scores[query];
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "owned_sequence_map_requires_eq",
        source,
        "type `[:]i32` does not implement protocol `std.prelude.Eq`",
    );
}

test "enum declarations cannot provide explicit Eq conformance" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\
        \\impl Color: Eq;
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "enum_cannot_explicitly_implement_eq",
        source,
        "impl target must name a struct or type union owned by this package",
    );
}

test "Eq conformance enables generic Set equality" {
    const source =
        \\struct UserId {
        \\    value: i32;
        \\}
        \\
        \\impl UserId: Eq {
        \\    fn eq(self: &const UserId, other: &const UserId): bool {
        \\        return self.value == other.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var ids: Set<UserId> = set<UserId>();
        \\    ids.add(UserId { value: 7 });
        \\    if ids.contains(UserId { value: 7 }) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "generic_set_eq_conformance",
        "native_generic_set_eq_conformance.cy",
        source,
        42,
    );
}

test "Eq conformance enables generic Map key equality" {
    const source =
        \\struct UserId {
        \\    value: i32;
        \\}
        \\
        \\impl UserId: Eq {
        \\    fn eq(self: &const UserId, other: &const UserId): bool {
        \\        return self.value == other.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var scores: Map<UserId, i32> = map<UserId, i32>();
        \\    scores[UserId { value: 7 }] = 42;
        \\    return scores[UserId { value: 7 }];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "generic_map_eq_conformance",
        "native_generic_map_eq_conformance.cy",
        source,
        42,
    );
}

test "generic cstruct structs instantiate concrete C-layout fields" {
    const source =
        \\c struct Pair<T> {
        \\    left: T;
        \\    right: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair = Pair<i32> { left: 40, right: 2 };
        \\    return pair.left + pair.right;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_cstruct_values", "native_generic_cstruct_values.cy", source, 42);
}

test "protocols validate explicit impl conformance" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {
        \\    total: i32;
        \\}
        \\
        \\impl FileWriter: Writer {
        \\    fn write(self: &FileWriter, bytes: string): i32 {
        \\        return self.total + (bytes.len() as i32);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var writer: FileWriter = FileWriter { total: 40 };
        \\    return writer.write("hi");
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "protocol_impl_conformance", "native_protocol_impl_conformance.cy", source, 42);
}

test "generic impl materializes a canonical conformance for each subject instance" {
    const source =
        \\protocol Scored {
        \\    fn score(self: &const Self): i32;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\    points: i32;
        \\}
        \\
        \\impl<T> Box<T>: Scored {
        \\    fn score(self: &const Box<T>): i32 {
        \\        return self.points;
        \\    }
        \\}
        \\
        \\fn read_score<T: Scored>(value: &const T): i32 {
        \\    return value.score();
        \\}
        \\
        \\fn main(): i32 {
        \\    var left = Box<i32> { value: 7, points: 40 };
        \\    var right = Box<bool> { value: true, points: 2 };
        \\    return read_score(&left) + read_score(&right);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_impl_conformance", "native_generic_impl_conformance.cy", source, 42);
}

test "generic protocol impl materializes associated types and supports qualified dispatch" {
    const source =
        \\protocol Source {
        \\    type Item;
        \\    fn get(self: &const Self): Self.Item;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\impl<T> Box<T>: Source {
        \\    type Item = T;
        \\    fn get(self: &const Box<T>): T { return self.value; }
        \\}
        \\
        \\fn read<S: Source>(source: &const S): S.Item {
        \\    return Source.get(source);
        \\}
        \\
        \\fn main(): i32 {
        \\    var box = Box<i32> { value: 42 };
        \\    return read(&box);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_impl_associated_type", "native_generic_impl_associated_type.cy", source, 42);
}

test "const-generic impl binds the concrete subject value parameters" {
    const source =
        \\protocol Capacity {
        \\    fn capacity(self: &const Self): usize;
        \\}
        \\
        \\struct Ring<T, const N: usize> {
        \\    value: T;
        \\}
        \\
        \\impl<T, const N: usize> Ring<T, N>: Capacity {
        \\    fn capacity(self: &const Ring<T, N>): usize {
        \\        return N;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var ring = Ring<i32, 42> { value: 7 };
        \\    return ring.capacity() as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_generic_impl", "native_const_generic_impl.cy", source, 42);
}

test "conditional generic impl body uses its declared protocol bound" {
    const source =
        \\protocol Same {
        \\    fn same(self: &const Self, other: &const Self): bool;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\impl<T: Eq> Box<T>: Same {
        \\    fn same(self: &const Box<T>, other: &const Box<T>): bool {
        \\        return self.value.eq(&other.value);
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var left = Box<i32> { value: 42 };
        \\    var right = Box<i32> { value: 42 };
        \\    if left.same(&right) { return 42; }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "conditional_generic_impl_body", "native_conditional_generic_impl_body.cy", source, 42);
}

test "conditional generic impl exists only when its bound is satisfied" {
    const source =
        \\protocol Scored {
        \\    fn score(self: &const Self): i32;
        \\}
        \\
        \\struct Plain {
        \\    value: i32;
        \\}
        \\
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\impl<T: Eq> Box<T>: Scored {
        \\    fn score(self: &const Box<T>): i32 {
        \\        return 42;
        \\    }
        \\}
        \\
        \\fn accepts<T: Scored>(value: T): i32 {
        \\    const ignored = value;
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    return accepts(Box<Plain> { value: Plain { value: 7 } });
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "conditional_generic_impl_bound",
        source,
        "does not implement protocol",
    );
}

test "type unions synthesize protocol dispatch independent of impl source order" {
    const source =
        \\protocol Score {
        \\    fn score(self: Self): i32;
        \\}
        \\
        \\struct Fast {
        \\    value: i32;
        \\}
        \\
        \\struct Slow {
        \\    value: i32;
        \\}
        \\
        \\union Work = Fast | Slow;
        \\impl Work: Score;
        \\
        \\impl Fast: Score {
        \\    fn score(self: Fast): i32 {
        \\        return self.value + 1;
        \\    }
        \\}
        \\impl Slow: Score {
        \\    fn score(self: Slow): i32 {
        \\        return self.value + 2;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const work: Work = Fast { value: 41 };
        \\    return work.score();
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "type_union_protocol_dispatch", "native_type_union_protocol_dispatch.cy", source, 42);
}

test "generic declarations validate protocol constraints without instantiation" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\fn consume<T: Writer>(value: T): i32 {
        \\    const copied = value;
        \\    const again = copied;
        \\    return again.count;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_decls_validate", "native_generic_decls_validate.cy", source, 42);
}

test "generic functions enforce protocol constraints at instantiation" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {
        \\    count: i32;
        \\}
        \\
        \\impl FileWriter: Writer {
        \\    fn write(self: &FileWriter, bytes: string): i32 {
        \\        return self.count + (bytes.len() as i32);
        \\    }
        \\}
        \\
        \\fn take<T: Writer>(value: T): i32 {
        \\    return value.count + 41;
        \\}
        \\
        \\fn main(): i32 {
        \\    return take(FileWriter { count: 1 });
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_constraint_function_instantiate", "native_generic_constraint_function_instantiate.cy", source, 42);
}

test "generic structs enforce protocol constraints at instantiation" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {
        \\    count: i32;
        \\}
        \\
        \\impl FileWriter: Writer {
        \\    fn write(self: &FileWriter, bytes: string): i32 {
        \\        return self.count + (bytes.len() as i32);
        \\    }
        \\}
        \\
        \\struct Box<T: Writer> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box<FileWriter> { value: FileWriter { count: 1 } };
        \\    return box.value.count + 41;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_constraint_struct_instantiate", "native_generic_constraint_struct_instantiate.cy", source, 42);
}

test "generic methods enforce protocol constraints at instantiation" {
    const source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {
        \\    count: i32;
        \\}
        \\
        \\impl FileWriter: Writer {
        \\    fn write(self: &FileWriter, bytes: string): i32 {
        \\        return self.count + (bytes.len() as i32);
        \\    }
        \\}
        \\
        \\struct Box {
        \\    base: i32;
        \\
        \\    fn wrap<T: Writer>(self: Box, value: T): i32 {
        \\        const copied = value;
        \\        const again = copied;
        \\        if self.base == 42 {
        \\            const final = again;
        \\            return final.count + 41;
        \\        }
        \\        return self.base;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { base: 42 };
        \\    return box.wrap(FileWriter { count: 1 });
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_constraint_method_instantiate", "native_generic_constraint_method_instantiate.cy", source, 42);
}

test "generic functions enforce protocol set constraints" {
    const source =
        \\protocol Readable {
        \\    fn read(self: &Self): i32;
        \\}
        \\
        \\protocol Writable {
        \\    fn write(self: &Self, value: i32): i32;
        \\}
        \\
        \\struct Buffer {
        \\    value: i32;
        \\}
        \\
        \\impl Buffer: Readable {
        \\    fn read(self: &Buffer): i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Buffer: Writable {
        \\    fn write(self: &Buffer, value: i32): i32 {
        \\        return self.value + value;
        \\    }
        \\}
        \\
        \\fn round_trip<T: Readable & Writable>(value: &T): i32 {
        \\    return value.write(value.read());
        \\}
        \\
        \\fn main(): i32 {
        \\    var buffer = Buffer { value: 21 };
        \\    return round_trip(&buffer);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_protocol_set_constraints", "native_generic_protocol_set_constraints.cy", source, 42);
}

test "autoloaded Eq protocol accepts core primitive impl" {
    const source =
        \\fn accepts<T: Eq>(value: T): i32 {
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: i32 = 7;
        \\    return accepts(value);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "autoloaded_eq_protocol_primitive_impl", "native_autoloaded_eq_protocol_primitive_impl.cy", source, 42);
}

test "escaped identifiers can use keywords as field names" {
    const source =
        \\struct Packet {
        \\    `protocol`: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const packet = Packet { `protocol`: 42 };
        \\    return packet.`protocol`;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "escaped_identifier_keyword_field", "native_escaped_identifier_keyword_field.cy", source, 42);
}

test "generic structs instantiate concrete field layouts" {
    const source =
        \\struct Pair<T, U> {
        \\    first: T;
        \\    second: U;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair: Pair<i32, string> = Pair<i32, string> { first: 40, second: "hi" };
        \\    return pair.first + (pair.second.len() as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_struct_instantiate", "native_generic_struct_instantiate.cy", source, 42);
}

test "const value generic structs bind length and element" {
    const source =
        \\struct Pool<T, const N: usize> {
        \\    storage: [N]T;
        \\    used: usize;
        \\
        \\    fn capacity(self: Pool<T, N>): usize {
        \\        return N;
        \\    }
        \\
        \\    fn get(self: Pool<T, N>, index: usize): T {
        \\        return self.storage[index];
        \\    }
        \\
        \\    fn set(self: &Pool<T, N>, index: usize, value: T): void {
        \\        self.storage[index] = value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var pool: Pool<i32, 4> = Pool<i32, 4> { storage: [4]i32 [10, 20, 30, 0], used: 0 };
        \\    pool.set(3, 8);
        \\    return pool.get(2) + pool.get(3) + (pool.capacity() as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_value_generic_struct", "native_const_value_generic_struct.cy", source, 42);
}

test "const value generic structs reuse length for metadata arrays" {
    const source =
        \\struct StaticPool<T, const N: usize> {
        \\    values: [N]T;
        \\    occupied: [N]bool;
        \\    count: usize;
        \\
        \\    fn capacity(self: StaticPool<T, N>): usize {
        \\        return N;
        \\    }
        \\
        \\    fn insert(self: &StaticPool<T, N>, value: T): ?usize {
        \\        const cap = self.capacity();
        \\        var index: usize = 0;
        \\        while index < cap {
        \\            if not self.occupied[index] {
        \\                self.values[index] = value;
        \\                self.occupied[index] = true;
        \\                self.count = self.count + 1;
        \\                return index;
        \\            }
        \\            index = index + 1;
        \\        }
        \\        return none;
        \\    }
        \\
        \\    fn remove(self: &StaticPool<T, N>, index: usize): ?T {
        \\        const cap = self.capacity();
        \\        if index >= cap {
        \\            return none;
        \\        }
        \\        if self.occupied[index] {
        \\            self.occupied[index] = false;
        \\            self.count = self.count - 1;
        \\            return self.values[index];
        \\        }
        \\        return none;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    var pool: StaticPool<i32, 3> = StaticPool<i32, 3> {
        \\        values: [3]i32 [0, 0, 0],
        \\        occupied: [3]bool [false, false, false],
        \\        count: 0,
        \\    };
        \\    if pool.insert(42) is index {
        \\        if pool.remove(index) is value {
        \\            return value;
        \\        }
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_value_generic_metadata_arrays", "native_const_value_generic_metadata_arrays.cy", source, 42);
}

test "sequence repeat initializes fixed arrays and lists" {
    const source =
        \\fn main(): i32 {
        \\    const a: [4]i32 = [0] ** 4;
        \\    const b: [6]i32 = [1, 2] ** 3;
        \\    const repeated: [:]i32 = [1, 2] ** 3;
        \\    var xs: List<i32> = list_from<i32>(repeated);
        \\    if xs.len() == 6 {
        \\        return a[0] + a[3] + b[0] + b[1] + b[4] + b[5] + xs[0] + xs[1] + xs[4] + xs[5] + 30;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "sequence_repeat_arrays_and_lists", "native_sequence_repeat_arrays_and_lists.cy", source, 42);
}

test "sequence repeat uses const value generic length in generic structs" {
    const source =
        \\struct StaticPool<T, const N: usize> {
        \\    values: [N]T;
        \\    occupied: [N]bool;
        \\    count: usize;
        \\
        \\    fn capacity(self: StaticPool<T, N>): usize {
        \\        return N;
        \\    }
        \\}
        \\
        \\fn fill_pool<T, const N: usize>(seed: [N]T, value: T): StaticPool<T, N> {
        \\    return StaticPool<T, N> {
        \\        values: [value] ** N,
        \\        occupied: [false] ** N,
        \\        count: 0,
        \\    };
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [4]i32 = [];
        \\    const pool = fill_pool(seed, 42);
        \\    if pool.capacity() == 4 and pool.values[3] == 42 and not pool.occupied[0] {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "sequence_repeat_const_value_generic_length", "native_sequence_repeat_const_value_generic_length.cy", source, 42);
}

test "generic functions instantiate from call arguments" {
    const source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_function_instantiate", "native_generic_function_instantiate.cy", source, 42);
}

test "const value generic functions infer length and element" {
    const source =
        \\fn count<T, const N: usize>(value: [N]T): usize {
        \\    return N;
        \\}
        \\
        \\fn first<T, const N: usize>(value: [N]T): T {
        \\    return value[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    const values: [4]i32 = [4]i32 [40, 1, 1, 1];
        \\    return first(values) + (count(values) as i32) - 2;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "const_value_generic_function", "native_const_value_generic_function.cy", source, 42);
}

test "generic struct methods specialize on instantiated receivers" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn get(self: Box<T>): T {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 42 };
        \\    return box.get();
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_struct_method", "native_generic_struct_method.cy", source, 42);
}

test "generic functions infer through instantiated generic structs" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn unwrap<T>(box: Box<T>): T {
        \\    return box.value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 42 };
        \\    return unwrap(box);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_struct_arg_infer", "native_generic_struct_arg_infer.cy", source, 42);
}

test "generic functions infer through nested generic struct shapes" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\struct Wrapper<T> {
        \\    inner: Box<T>;
        \\}
        \\
        \\fn unwrap<T>(value: Wrapper<T>): T {
        \\    return value.inner.value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const wrapped: Wrapper<i32> = Wrapper<i32> { inner: Box<i32> { value: 42 } };
        \\    return unwrap(wrapped);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_nested_struct_arg_infer", "native_generic_nested_struct_arg_infer.cy", source, 42);
}

test "generic functions accept explicit type arguments" {
    const source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity<i32>(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_function_explicit_type_args", "native_generic_function_explicit_type_args.cy", source, 42);
}

test "explicit generic call parsing preserves ordinary comparisons" {
    const source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const identity: i32 = 1;
        \\    if identity < 2 {
        \\        return identity<i32>(42);
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_call_parse_vs_compare", "native_generic_call_parse_vs_compare.cy", source, 42);
}

test "generic methods accept explicit type arguments" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\
        \\    fn wrap<T>(self: Box, value: T): T {
        \\        return value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: 1 };
        \\    return box.wrap<i32>(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_method_explicit_type_args", "native_generic_method_explicit_type_args.cy", source, 42);
}

test "generic methods infer type arguments from arguments" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\
        \\    fn wrap<T>(self: Box, value: T): T {
        \\        return value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: 1 };
        \\    return box.wrap(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_method_infer_type_args", "native_generic_method_infer_type_args.cy", source, 42);
}

test "generic methods on generic structs accept explicit type arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn pair<U>(self: Box<T>, other: U): U {
        \\        return other;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 1 };
        \\    return box.pair<i32>(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_struct_method_explicit_type_args", "native_generic_struct_method_explicit_type_args.cy", source, 42);
}

test "generic methods on generic structs infer type arguments from arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn pair<U>(self: Box<T>, other: U): U {
        \\        return other;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 1 };
        \\    return box.pair(42);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_struct_method_infer_type_args", "native_generic_struct_method_infer_type_args.cy", source, 42);
}

test "generic methods infer through instantiated generic struct arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\struct Wrapper {
        \\    fn unwrap<T>(self: Wrapper, value: Box<T>): T {
        \\        return value.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const wrapper = Wrapper {};
        \\    const value: Box<i32> = Box<i32> { value: 42 };
        \\    return wrapper.unwrap(value);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_method_nested_arg_infer", "native_generic_method_nested_arg_infer.cy", source, 42);
}

test "generic method return provenance tracks only returned parameter" {
    const source =
        \\struct Picker<T> {
        \\    value: T;
        \\
        \\    fn choose<U>(self: Picker<T>, first: []const i32, second: U): U {
        \\        return second;
        \\    }
        \\}
        \\
        \\fn pass(second: []const i32): []const i32 {
        \\    const picker: Picker<i32> = Picker<i32> { value: 1 };
        \\    const fixed: [1]i32 = [1]i32 [7];
        \\    return picker.choose(fixed[..], second);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [42];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_method_return_provenance_tracks_only_returned_parameter", "native_generic_method_return_provenance_tracks_only_returned_parameter.cy", source, 42);
}

test "generic method return provenance tracks receiver without unrelated arg pollution" {
    const source =
        \\struct Holder<T> {
        \\    view: T;
        \\
        \\    fn get<U>(self: Holder<T>, extra: U): T {
        \\        return self.view;
        \\    }
        \\}
        \\
        \\fn pass(view: []const i32): []const i32 {
        \\    const holder: Holder<[]const i32> = Holder<[]const i32> { view: view };
        \\    const fixed: [1]i32 = [1]i32 [7];
        \\    return holder.get(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [42];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_method_return_provenance_tracks_receiver_without_arg_pollution", "native_generic_method_return_provenance_tracks_receiver_without_arg_pollution.cy", source, 42);
}

test "transitive generic method return provenance tracks receiver without unrelated arg pollution" {
    const source =
        \\struct Holder<T> {
        \\    view: T;
        \\
        \\    fn get<U>(self: Holder<T>, extra: U): T {
        \\        return self.view;
        \\    }
        \\
        \\    fn forward<U>(self: Holder<T>, extra: U): T {
        \\        return self.get(extra);
        \\    }
        \\}
        \\
        \\fn pass(view: []const i32): []const i32 {
        \\    const holder: Holder<[]const i32> = Holder<[]const i32> { view: view };
        \\    const fixed: [1]i32 = [1]i32 [7];
        \\    return holder.forward(fixed[..]);
        \\}
        \\
        \\fn main(): i32 {
        \\    const seed: [1]i32 = [1]i32 [42];
        \\    return pass(seed[..])[0];
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "transitive_generic_method_return_provenance_tracks_receiver_without_arg_pollution", "native_transitive_generic_method_return_provenance_tracks_receiver_without_arg_pollution.cy", source, 42);
}

test "generic method explicit callback preserves conservative unknown-effect borrow rejection" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\struct Holder<T> {
        \\    view: T;
        \\
        \\    fn sink_len(self: Holder<T>, sink: &Sink, measure: fn(T): usize): void {
        \\        sink.value = measure(self.view) as i32;
        \\    }
        \\
        \\    fn forward(self: Holder<T>, sink: &Sink, measure: fn(T): usize): void {
        \\        self.sink_len(sink, measure);
        \\    }
        \\}
        \\
        \\fn measure_view(view: []const i32): usize { return view.len(); }
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [42];
        \\    const holder: Holder<[]const i32> = Holder<[]const i32> { view: fixed[..] };
        \\    holder.forward(sink, measure_view);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    // A scalar return type does not prove absence of callback side effects.
    // This ordinary fn parameter erases the target's borrow effects; preserving
    // that conservative boundary must not be confused with the known .len()
    // intrinsic tested below.
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_callback_unknown_effect.cy", source, "borrowed values cannot escape via function call side effects");
}

test "transitive generic method scalar-derived args do not taint side-effect borrow summaries" {
    // Keep the direct slice.len() oracle as well as the explicit behavior
    // callback above. A bare T no longer discovers .len() by substitution;
    // declaring the known slice shape preserves this method/borrow contract.
    const source =
        \\struct Sink { value: i32; }
        \\struct Holder<T> {
        \\    view: []const T;
        \\    fn sink_len(self: Holder<T>, sink: &Sink): void { sink.value = self.view.len() as i32; }
        \\    fn forward(self: Holder<T>, sink: &Sink): void { self.sink_len(sink); }
        \\}
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [42];
        \\    const holder = Holder<i32> { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\fn main(): i32 { var sink = Sink { value: 0 }; run(&sink); return sink.value; }
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "transitive_generic_known_slice_scalar", "transitive_generic_known_slice_scalar.cy", source, 1);
}

test "generic indexed scalar-derived args do not taint side-effect borrow summaries" {
    const source =
        \\struct Sink {
        \\    value: i32;
        \\}
        \\
        \\struct Holder<T> {
        \\    view: T;
        \\
        \\    fn sink_first(self: Holder<T>, sink: &Sink): void {
        \\        sink.value = self.view[0];
        \\    }
        \\
        \\    fn forward(self: Holder<T>, sink: &Sink): void {
        \\        self.sink_first(sink);
        \\    }
        \\}
        \\
        \\fn run(sink: &Sink): void {
        \\    const fixed: [1]i32 = [1]i32 [42];
        \\    const holder: Holder<[]const i32> = Holder<[]const i32> { view: fixed[..] };
        \\    holder.forward(sink);
        \\}
        \\
        \\fn main(): i32 {
        \\    var sink = Sink { value: 0 };
        \\    run(&sink);
        \\    return sink.value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_indexed_scalar_derived_args_do_not_taint_side_effect_borrow_summaries", "native_generic_indexed_scalar_derived_args_do_not_taint_side_effect_borrow_summaries.cy", source, 42);
}
