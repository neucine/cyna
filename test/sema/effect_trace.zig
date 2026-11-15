const std = @import("std");
const compiler = @import("cyna").compiler;
const compat = @import("cyna").compat;
const sir = compiler.sir;
const trace = compiler.effect_flow;

test "reference and slice construction borrow checked places" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    var value: i32 = 1;
        \\    const alias: &i32 = &value;
        \\    var values: [:]i32 = [1, 2];
        \\    const slice: []i32 = values[0..2];
        \\    return slice[0] + value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_ref_slice.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_ref_slice.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    var references: usize = 0;
    var slices: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        switch (entry.expr.*) {
            .ref_local => references += 1,
            .slice_range => slices += 1,
            else => continue,
        }
        const place = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow and record.effect.borrow == .place);
        try std.testing.expect(std.meta.eql(place, record.effect.borrow.place));
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(references > 0 and slices > 0);
}

test "field reference borrows its typed projected place" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = Box { value: 7 };
        \\    const field: &i32 = &box.value;
        \\    var owned = new Box { value: 8 };
        \\    const owned_field: &i32 = &owned.value;
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_ref_field.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_ref_field.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    var seen: [2]bool = .{ false, false };
    for (@constCast(module.expr_metadata)) |*entry| {
        const kind: usize = switch (entry.expr.*) {
            .ref_field_local => 0,
            .ref_field_owned_local => 1,
            else => continue,
        };
        seen[kind] = true;
        const path = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), path.projections.?.len);
        const projection = &@constCast(entry.metadata.checked_place_projections.?)[0];
        const field_name = projection.step.field.name;
        projection.step.field.name = "forged";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projection.step.field.name = field_name;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "indexed references borrow checked fixed and dynamic slots" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item {
        \\    value: i32;
        \\    fn total(self: &Item): i32 { return self.value; }
        \\}
        \\fn main(): i32 {
        \\    var values: [2]Item = [Item { value: 1 }, Item { value: 2 }];
        \\    const position: i32 = 1;
        \\    return values[0].total() + values[position].total();
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_ref_index.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_ref_index.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    var seen: [2]bool = .{ false, false };
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_index_local) continue;
        const path = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), path.projections.?.len);
        const index = path.projections.?[0].step.index;
        seen[if (index == .fixed) 0 else 1] = true;
        const projection = &@constCast(entry.metadata.checked_place_projections.?)[0];
        projection.step.index = .{ .fixed = 999 };
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projection.step.index = index;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "multi-step references borrow checked field and index paths" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Bag { values: [2]i32; }
        \\struct Outer { bag: Bag; }
        \\fn fields(outer: &Outer): &[2]i32 { return &outer.bag.values; }
        \\fn indexed(outer: &Outer): &i32 { return &outer.bag.values[0]; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_ref_path.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_ref_path.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    var seen: [2]bool = .{ false, false };
    for (@constCast(module.expr_metadata)) |*entry| {
        const kind: usize = switch (entry.expr.*) {
            .ref_path_local => 0,
            .ref_index_path_local => 1,
            else => continue,
        };
        seen[kind] = true;
        const path = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, if (kind == 0) 2 else 3), path.projections.?.len);
        entry.metadata.checked_place_root = null;
        try std.testing.expectError(error.MissingPlaceIdentity, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = path.root;
        const projection = &@constCast(entry.metadata.checked_place_projections.?)[0];
        const owner = projection.step.field.owner_decl_id;
        projection.step.field.owner_decl_id = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projection.step.field.owner_decl_id = owner;
        if (kind == 1) {
            const last = &@constCast(entry.metadata.checked_place_projections.?)[2];
            const index = last.step.index;
            last.step.index = .{ .fixed = 999 };
            try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
            last.step.index = index;
        }
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "global field references borrow a checked projected place" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\const global: Box = Box { value: 7 };
        \\fn borrow(): &const i32 { return &global.value; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_global_field_ref.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_global_field_ref.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_field_expr) continue;
        found = true;
        const place = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expect(place.root == .global);
        try std.testing.expectEqual(@as(usize, 1), place.projections.?.len);
        const projection = &@constCast(entry.metadata.checked_place_projections.?)[0];
        const name = projection.step.field.name;
        projection.step.field.name = "forged";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projection.step.field.name = name;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        var ordered = false;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate or event.evaluate != entry.expr) continue;
                try std.testing.expect(index + 1 < function.effect_flow.len);
                try std.testing.expect(function.effect_flow[index + 1] == .effect and
                    std.meta.eql(function.effect_flow[index + 1].effect, record));
                ordered = true;
            }
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .global = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(found);
}

test "raw field references evaluate the pointer before the unrooted reference" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item { value: i32; }
        \\fn expose(ptr: *Item): &i32 {
        \\    unchecked { return &(*ptr).value; }
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_raw_field_ref.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_raw_field_ref.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_field_expr) continue;
        found = true;
        try std.testing.expect(entry.expr.ref_field_expr.object.* == .ref_raw_deref);
        try std.testing.expect(entry.metadata.checkedPlacePath() == null);
        try std.testing.expect(entry.metadata.checked_effect == null);
        const pointer = entry.expr.ref_field_expr.object.ref_raw_deref.expr;
        const dereference = module.metadataForExpr(entry.expr.ref_field_expr.object) orelse return error.TestUnexpectedResult;
        try std.testing.expect(dereference.checked_raw_deref != null);
        var pointer_site: ?usize = null;
        var reference_site: ?usize = null;
        for (module.functions[0].effect_flow, 0..) |event, index| {
            if (event != .evaluate) continue;
            if (event.evaluate == pointer) pointer_site = index;
            if (event.evaluate == entry.expr) reference_site = index;
        }
        try std.testing.expect(pointer_site.? < reference_site.?);
    }
    try std.testing.expect(found);
}

test "inline assembly evaluates inputs without inventing an ownership effect" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    const input = 42;
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "mov {result}, {source}";
        \\            out reg result;
        \\            in reg source = input;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_asm_expr.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_asm_expr.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .asm_expr) continue;
        found = true;
        try std.testing.expect(entry.metadata.checked_effect == null);
        const input = entry.expr.asm_expr.inputs[0].value;
        const input_metadata = module.metadataForExpr(input) orelse return error.TestUnexpectedResult;
        const read = input_metadata.checked_effect orelse return error.TestUnexpectedResult;
        var input_at: ?usize = null;
        var asm_at: ?usize = null;
        for (module.functions[0].effect_flow, 0..) |event, index| {
            if (event != .evaluate) continue;
            if (event.evaluate == input) input_at = index;
            if (event.evaluate == entry.expr) asm_at = index;
        }
        try std.testing.expect(input_at.? < asm_at.?);
        entry.metadata.checked_effect = read;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = null;
    }
    try std.testing.expect(found);
}

test "named-union payload method receiver produces a reference" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box {
        \\    value: i32;
        \\    fn total(self: &Box): i32 { return self.value; }
        \\}
        \\union Choice { value: Box; empty; }
        \\fn read(choice: &Choice): i32 { return choice.value.total(); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_union_receiver.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_union_receiver.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_union_field_local) continue;
        found = true;
        const place = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), place.projections.?.len);
        try std.testing.expect(place.projections.?[0].step == .union_payload);
        const projection = &@constCast(entry.metadata.checked_place_projections.?)[0];
        const name = projection.step.union_payload.name;
        projection.step.union_payload.name = "forged";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        projection.step.union_payload.name = name;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        var ordered = false;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate or event.evaluate != entry.expr) continue;
                try std.testing.expect(index + 1 < function.effect_flow.len);
                try std.testing.expect(function.effect_flow[index + 1] == .effect and
                    std.meta.eql(function.effect_flow[index + 1].effect, record));
                ordered = true;
            }
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(found);
}

test "reference loads from index hooks are visible in the trace" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Bag { values: [:]i32;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &const i32 {
        \\        return &self.values[index];
        \\    }
        \\}
        \\fn read(bag: &const Bag): i32 { return bag[0]; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_ref_load.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_ref_load.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_load) continue;
        found = true;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .read and record.effect.read == .reference_target);
        try std.testing.expect(record.effect.read.reference_target.reference == entry.expr.ref_load);
        try std.testing.expectEqual(entry.metadata.type_id, record.effect.read.reference_target.target_type_id);
        var child_index: ?usize = null;
        var load_index: ?usize = null;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate) continue;
                if (event.evaluate == entry.expr.ref_load) child_index = index;
                if (event.evaluate == entry.expr) {
                    load_index = index;
                    try std.testing.expect(index + 1 < function.effect_flow.len);
                    try std.testing.expect(function.effect_flow[index + 1] == .effect and
                        std.meta.eql(function.effect_flow[index + 1].effect, record));
                }
            }
        }
        try std.testing.expect(child_index.? < load_index.?);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.read.reference_target.target_type_id = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(found);
}

test "string byte views borrow checked places and temporaries" {
    const allocator = std.testing.allocator;
    const source =
        \\fn count(): i32 {
        \\    const text = "hello";
        \\    const local_view = text.bytes();
        \\    const literal_view = "hi".bytes();
        \\    return (local_view.len() + literal_view.len()) as i32;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_string_bytes.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_string_bytes.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var seen: [2]bool = .{ false, false };
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .string_bytes) continue;
        const child = entry.expr.string_bytes;
        const child_metadata = module.metadataForExpr(child) orelse return error.TestUnexpectedResult;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        const kind: usize = if (child_metadata.checkedPlacePath() != null) 0 else 1;
        seen[kind] = true;
        try std.testing.expect(if (kind == 0) record.effect.borrow == .place else record.effect.borrow == .temporary);
        var child_index: ?usize = null;
        var view_index: ?usize = null;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate) continue;
                if (event.evaluate == child) child_index = index;
                if (event.evaluate == entry.expr) {
                    view_index = index;
                    try std.testing.expect(index + 1 < function.effect_flow.len);
                    try std.testing.expect(function.effect_flow[index + 1] == .effect and
                        std.meta.eql(function.effect_flow[index + 1].effect, record));
                }
            }
        }
        try std.testing.expect(child_index.? < view_index.?);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "field aliases over index hook references carry a projected borrow" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item { value: i32; }
        \\struct Bag { items: [:]Item;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &const Item {
        \\        return &self.items[index];
        \\    }
        \\}
        \\fn expose(bag: &const Bag): &const i32 { return &bag[0].value; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_hook_field_ref.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_hook_field_ref.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_field_expr) continue;
        if (entry.expr.ref_field_expr.object.* != .call) continue;
        found = true;
        try std.testing.expect(entry.metadata.checkedPlacePath() == null);
        const receiver = entry.expr.ref_field_expr.object.call.args[0].value;
        const receiver_metadata = module.metadataForExpr(receiver) orelse return error.TestUnexpectedResult;
        entry.metadata.checked_place_root = receiver_metadata.checked_place_root;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        entry.metadata.checked_place_root = null;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow and record.effect.borrow == .reference_projection);
        const projection = record.effect.borrow.reference_projection;
        try std.testing.expect(projection.reference == entry.expr.ref_field_expr.object);
        try std.testing.expect(std.mem.eql(u8, projection.projection.step.field.name, "value"));
        var call_index: ?usize = null;
        var field_index: ?usize = null;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate) continue;
                if (event.evaluate == projection.reference) call_index = index;
                if (event.evaluate == entry.expr) {
                    field_index = index;
                    try std.testing.expect(index + 1 < function.effect_flow.len);
                    try std.testing.expect(function.effect_flow[index + 1] == .effect and
                        std.meta.eql(function.effect_flow[index + 1].effect, record));
                }
            }
        }
        try std.testing.expect(call_index.? < field_index.?);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.borrow.reference_projection.projection.step.field.name = "forged";
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(found);
}

test "SIR verifies checked read identities for local and global places" {
    var local: sir.Expr = .{ .local = "item" };
    var global: sir.Expr = .{ .global_ref = .{ .module_name = "sample", .name = "item" } };
    var metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &local, .metadata = .{
            .type_id = @fromBackingInt(@intCast(1)),
            .semantics = .plainValue(),
            .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
            .checked_effect = .{ .effect = .{ .read = .{ .place = .{ .root = .{ .binding = @fromBackingInt(@intCast(1)) }, .projections = null, .non_owning = false } } } },
        } },
        .{ .expr = &global, .metadata = .{
            .type_id = @fromBackingInt(@intCast(1)),
            .semantics = .plainValue(),
            .checked_place_root = .{ .global = @fromBackingInt(@intCast(2)) },
            .checked_effect = .{ .effect = .{ .read = .{ .place = .{ .root = .{ .global = @fromBackingInt(@intCast(2)) }, .projections = null, .non_owning = false } } } },
        } },
    };
    const module: sir.Module = .{ .expr_metadata = &metadata, .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &.{} };
    try module.verifyValueActions();
    metadata[0].metadata.checked_place_root = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    metadata[0].metadata.checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) };
    const saved = metadata[0].metadata.checked_effect;
    metadata[0].metadata.checked_effect = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    metadata[0].metadata.checked_effect = saved;
    metadata[1].metadata.checked_effect.?.effect.read.place.root = .{ .global = @fromBackingInt(@intCast(3)) };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "straight-line trace retains nested argument order and rejects a lost child" {
    var owner: sir.Expr = .{ .local = "owner" };
    var scalar: sir.Expr = .{ .int = .{ .value = 4, .type_name = null } };
    var nested: sir.Expr = .{ .binary = .{ .op = .add, .left = &owner, .right = &scalar } };
    const args = [_]sir.CallArg{.{ .value = &nested }};
    var call: sir.Expr = .{ .call = .{ .module_name = "sample", .owner = null, .callee = "use", .args = &args } };
    const metadata = [_]sir.ExprMetadataEntry{
        .{ .expr = &owner, .metadata = .{ .type_id = @fromBackingInt(@intCast(1)), .semantics = .{ .category = .place, .ownership = .owned, .cleanup = .full_expression }, .consumption = .{ .transfer = .move }, .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) } } },
        .{ .expr = &scalar, .metadata = .{ .type_id = @fromBackingInt(@intCast(2)), .semantics = .plainValue() } },
        .{ .expr = &nested, .metadata = .{ .type_id = @fromBackingInt(@intCast(2)), .semantics = .plainValue() } },
        .{ .expr = &call, .metadata = .{ .type_id = @fromBackingInt(@intCast(2)), .semantics = .plainValue() } },
    };
    const sites = [_]trace.Site{
        .{ .expr = &owner, .action = .{ .effect = .{ .effect = .{ .move = .{
            .source = .{ .place = .{ .root = .{ .binding = @fromBackingInt(@intCast(1)) }, .projections = null, .non_owning = false } },
            .destination = .{ .temporary = @fromBackingInt(@intCast(5)) },
        } } } } },
        .{ .expr = &scalar, .action = .neutral },
        .{ .expr = &nested, .action = .neutral },
        .{ .expr = &call, .action = .neutral },
    };
    try trace.verifyLinearExpr(&call, &metadata, &sites);
    try std.testing.expectError(error.WrongEvaluationOrder, trace.verifyLinearExpr(&call, &metadata, sites[1..]));
    var corrupted = sites;
    corrupted[0].action = .neutral;
    try std.testing.expectError(error.MissingOwnershipEffect, trace.verifyLinearExpr(&call, &metadata, &corrupted));
    corrupted[0] = sites[0];
    corrupted[0].action.effect.effect.move.source.place.root = .{ .binding = @fromBackingInt(@intCast(99)) };
    try std.testing.expectError(error.InvalidEffectIdentity, trace.verifyLinearExpr(&call, &metadata, &corrupted));
    nested.binary.op = .@"and";
    try std.testing.expectError(error.UnsupportedControlFlow, trace.verifyLinearExpr(&call, &metadata, &sites));
}

test "SIR verifier rejects a missing or forged handoff effect" {
    var handoff: sir.Expr = .{ .handoff_local = "owner" };
    var metadata = [_]sir.ExprMetadataEntry{.{ .expr = &handoff, .metadata = .{
        .type_id = @fromBackingInt(@intCast(1)),
        .semantics = .{ .category = .value, .ownership = .owned, .cleanup = .transferred },
        .consumption = .{ .transfer = .move },
        .temporary_id = @fromBackingInt(@intCast(5)),
        .checked_place_root = .{ .binding = @fromBackingInt(@intCast(1)) },
    } }};
    const module: sir.Module = .{ .expr_metadata = &metadata, .globals = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &.{} };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    metadata[0].metadata.checked_effect = .{ .effect = .{ .move = .{
        .source = .{ .place = .{ .root = .{ .binding = @fromBackingInt(@intCast(1)) }, .projections = null, .non_owning = false } },
        .destination = .{ .temporary = @fromBackingInt(@intCast(5)) },
    } } };
    try module.verifyValueActions();
    metadata[0].metadata.checked_effect.?.effect.move.source.place.root = .{ .binding = @fromBackingInt(@intCast(2)) };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "sema emits a checked effect for TaskGroup local handoff" {
    const allocator = std.testing.allocator;
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const group = TaskGroup.init(1 as u32) catch (init_problem) { const ignored = init_problem; return 1; };
        \\    const moved = group; moved.finish(); return 0;
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_handoff.cy", loaded.program);
    defer module.deinit(allocator);
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr.* != .handoff_local) continue;
        try std.testing.expect(entry.metadata.checked_effect != null);
        try module.verifyValueActions();
        const saved = entry.metadata.checked_effect;
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = saved;
        const functions = @constCast(module.functions);
        for (functions) |*function| {
            const moved = findLocal(function.body, "moved") orelse continue;
            const local_effect = moved.checked_effect orelse return error.TestUnexpectedResult;
            try std.testing.expect(local_effect.effect == .move);
            try std.testing.expect(local_effect.effect.move.source == .temporary);
            try std.testing.expect(local_effect.effect.move.destination == .place);
            moved.checked_effect = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            moved.checked_effect = local_effect;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "nested call availability uses its argument handoff identity" {
    const allocator = std.testing.allocator;
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn relay(group: TaskGroup): TaskGroup { return group; }
        \\fn consume(group: TaskGroup): void {}
        \\fn run(group: TaskGroup): void { consume(relay(group)); }
        \\fn main(): i32 { return 0; }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "nested_call_handoff.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();

    const run_param = for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, "run")) break function.params[0].binding_id orelse return error.TestUnexpectedResult;
    } else return error.TestUnexpectedResult;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .call or !std.mem.eql(u8, entry.expr.call.callee, "relay")) continue;
        const call = &@constCast(entry.expr).call;
        const argument = call.args[0].value;
        try std.testing.expect(argument.* == .handoff_local);
        const metadata = module.metadataForExpr(argument) orelse return error.TestUnexpectedResult;
        const handoff = metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(handoff.effect == .move and handoff.effect.move.source == .place);
        try std.testing.expectEqual(run_param, handoff.effect.move.source.place.root.binding);
        try std.testing.expectEqual(@as(usize, 1), call.checked_arguments.len);
        const call_effect = call.checked_arguments[0];
        try std.testing.expect(call_effect.effect == .call_argument);
        try std.testing.expect(call_effect.effect.call_argument.mode == .move);
        try std.testing.expect(call_effect.effect.call_argument.source == .temporary);
        try std.testing.expectEqual(metadata.temporary_id.?, call_effect.effect.call_argument.source.temporary);
        for (@constCast(module.expr_metadata)) |*checked| {
            if (checked.expr != argument) continue;
            checked.metadata.checked_effect = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            checked.metadata.checked_effect = handoff;
            checked.metadata.checked_effect.?.effect.move.source.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            checked.metadata.checked_effect = handoff;
            break;
        }
        return;
    }
    return error.TestUnexpectedResult;
}

test "hosted Arc construction transfers its resource payload and result" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.own;
        \\struct State { values: [:]i32; }
        \\fn main(): i32 {
        \\    const arc = own.arc(State { values: [7] });
        \\    const ignored = arc;
        \\    return 0;
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_hosted_arc.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .sync_share_boxed or entry.expr.sync_share_boxed.intrinsic_id != .std_own_arc) continue;
        const share = &@constCast(entry.expr).sync_share_boxed;
        const payload = share.checked_payload_transfer orelse return error.TestUnexpectedResult;
        const result = share.checked_result_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(payload.effect == .move and payload.effect.move.destination == .call_slot);
        try std.testing.expectEqual(@as(u32, 0), payload.effect.move.destination.call_slot.index);
        try std.testing.expect(result.effect == .move and result.effect.move.source == .return_slot);
        share.checked_payload_transfer = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        share.checked_payload_transfer = payload;
        share.checked_result_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        share.checked_result_effect = result;
        return;
    }
    return error.TestUnexpectedResult;
}

test "hosted thread and TaskGroup spawns check shared payload copies" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, tag: std.meta.Tag(sir.Expr), index: u32 }{
        .{ .source =
        \\import std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\fn worker(value: Arc<i32>): void { const ignored = value; }
        \\fn main(): i32 {
        \\    var value = own.arc(1 as i32);
        \\    const handle = thread.spawn(worker, value) catch (spawn_problem) { const ignored = spawn_problem; return 1; };
        \\    const ignored = handle; return 0;
        \\}
        , .tag = .thread_spawn_boxed, .index = 1 },
        .{ .source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\fn worker(value: Arc<i32>): i32 { const ignored = value; return 1; }
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus {
        \\    var value = own.arc(1 as i32);
        \\    return group.spawn(worker, value);
        \\}
        \\fn main(): i32 { return 0; }
        , .tag = .task_group_spawn_boxed, .index = 3 },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = case.source });
        const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
        defer allocator.free(root_path);
        var loaded = try compiler.loader.loadProgram(allocator, root_path);
        defer loaded.deinit(allocator);
        const module = try compiler.sema.buildSir(allocator, "effect_hosted_spawn_copy.cy", loaded.program);
        defer module.deinit(allocator);
        try module.verifyValueActions();
        try trace.verifyModule(allocator, &module);
        var found = false;
        for (module.expr_metadata) |entry| {
            if (std.meta.activeTag(entry.expr.*) != case.tag) continue;
            found = true;
            const expr = @constCast(entry.expr);
            const record: *?sir.Record = switch (expr.*) {
                .thread_spawn_boxed => |*spawn| &spawn.checked_payload_transfer,
                .task_group_spawn_boxed => |*spawn| &spawn.checked_payload_transfer,
                else => unreachable,
            };
            const saved = record.* orelse return error.TestUnexpectedResult;
            try std.testing.expect(saved.effect == .copy and saved.effect.copy.destination == .call_slot);
            try std.testing.expectEqual(case.index, saved.effect.copy.destination.call_slot.index);
            record.* = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
            var forged = saved;
            forged.effect.copy.destination.call_slot.index = 99;
            record.* = forged;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            record.* = saved;
        }
        try std.testing.expect(found);
    }
}

test "Task result extraction takes a shared payload from its checked raw box" {
    const allocator = std.testing.allocator;
    const source =
        \\import { Task, TaskStatus } from std.thread;
        \\import { Arc } from std.own;
        \\fn take(task: Task<Arc<i32>>): Arc<i32>!TaskStatus { return task.join(); }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_task_result_probe.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .task_result_take) continue;
        try std.testing.expect(entry.metadata.semantics.ownership == .shared);
        try std.testing.expect(entry.metadata.temporary_id != null);
        const take = &@constCast(entry.expr).task_result_take;
        const saved = take.checked_payload_take orelse return error.TestUnexpectedResult;
        try std.testing.expect(saved.effect == .take);
        try std.testing.expect(saved.effect.take.source == .raw_pointee);
        try std.testing.expect(saved.effect.take.source.raw_pointee.pointer == take.pointer);
        try std.testing.expect(saved.effect.take.destination == .temporary_payload);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, saved.effect.take.destination.temporary_payload.root);
        var ordered = false;
        for (module.functions) |function| {
            var pointer_at: ?usize = null;
            var take_at: ?usize = null;
            var result_at: ?usize = null;
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == take.pointer) pointer_at = index;
                if (event == .effect and std.meta.eql(event.effect, saved)) take_at = index;
                if (event == .evaluate and event.evaluate == entry.expr) result_at = index;
            }
            if (pointer_at != null and take_at != null and result_at != null) {
                try std.testing.expect(pointer_at.? < take_at.? and take_at.? < result_at.?);
                ordered = true;
            }
        }
        try std.testing.expect(ordered);
        take.checked_payload_take = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        take.checked_payload_take = saved;
        take.checked_payload_take.?.effect.take.source.raw_pointee.pointee_type_id = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "closure capture effects distinguish retained shared and borrowed owned values" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.own;
        \\struct Box { value: i32; }
        \\fn apply(f: (i32) => i32): i32 { return f(1); }
        \\fn main(): i32 {
        \\    var arc = own.arc(2 as i32);
        \\    var box = new Box { value: 41 };
        \\    return apply(|x| {
        \\        const valid = arc.is_valid();
        \\        const ignored = valid;
        \\        return x + box.value;
        \\    });
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_closure_capture.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .closure or entry.expr.closure.captures.len != 2) continue;
        const closure = &@constCast(entry.expr).closure;
        const records = closure.checked_transfers orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), records.len);
        var closure_flow: ?[]const sir.EffectFlowEvent = null;
        for (module.functions) |function| {
            for (function.effect_flow) |event| if (event == .evaluate and event.evaluate == entry.expr) {
                closure_flow = function.effect_flow;
                break;
            };
            if (closure_flow != null) break;
        }
        const flow = closure_flow orelse return error.TestUnexpectedResult;
        var last_effect: ?usize = null;
        for (closure.captures, records, 0..) |capture, maybe_record, index| {
            const record = maybe_record orelse return error.TestUnexpectedResult;
            var evaluated: ?usize = null;
            var effected: ?usize = null;
            for (flow, 0..) |event, event_index| {
                if (event == .evaluate and event.evaluate == capture) evaluated = event_index;
                if (event == .effect and std.meta.eql(event.effect, record)) effected = event_index;
            }
            try std.testing.expect(evaluated != null and effected != null and evaluated.? < effected.?);
            if (last_effect) |previous| try std.testing.expect(previous < evaluated.?);
            last_effect = effected;
            const name = if (capture.* == .local) capture.local else return error.TestUnexpectedResult;
            if (std.mem.eql(u8, name, "arc")) {
                try std.testing.expect(record.effect == .copy);
                try std.testing.expect(record.effect.copy.destination == .closure_slot);
                try std.testing.expectEqual(closure.env_decl_id.?, record.effect.copy.destination.closure_slot.environment_decl_id);
                try std.testing.expectEqual(@as(u32, @intCast(index)), record.effect.copy.destination.closure_slot.field_index);
            } else if (std.mem.eql(u8, name, "box")) {
                try std.testing.expect(record.effect == .borrow);
            } else return error.TestUnexpectedResult;
            const saved = records[index];
            records[index] = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
            records[index] = saved;
        }
        var closure_evaluated: ?usize = null;
        for (flow, 0..) |event, event_index| if (event == .evaluate and event.evaluate == entry.expr) {
            closure_evaluated = event_index;
        };
        try std.testing.expect(last_effect.? < (closure_evaluated orelse return error.TestUnexpectedResult));
        for (records) |*record| {
            if (record.* == null or record.*.?.effect != .copy) continue;
            const saved = record.*;
            record.*.?.effect.copy.destination.closure_slot.field_index = 99;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            record.* = saved;
            break;
        }
        return;
    }
    return error.TestUnexpectedResult;
}

test "borrowed closure capture records a borrow after evaluation" {
    const allocator = std.testing.allocator;
    const source =
        \\fn apply(f: (i32) => i32): i32 { return f(1); }
        \\fn main(): i32 {
        \\    var number = 41;
        \\    const view = &number;
        \\    return apply(|x| { return x + view; });
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_borrowed_closure.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .closure or entry.expr.closure.captures.len != 1) continue;
        const closure = &@constCast(entry.expr).closure;
        const capture = closure.captures[0];
        const metadata = module.metadataForExpr(capture) orelse return error.TestUnexpectedResult;
        try std.testing.expect(metadata.semantics.ownership == .borrowed);
        const records = closure.checked_transfers orelse return error.TestUnexpectedResult;
        const record = records[0] orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow);
        var found_order = false;
        for (module.functions) |function| {
            var evaluated: ?usize = null;
            var effected: ?usize = null;
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == capture) evaluated = index;
                if (event == .effect and std.meta.eql(event.effect, record)) effected = index;
            }
            if (evaluated != null and effected != null and evaluated.? < effected.?) found_order = true;
        }
        try std.testing.expect(found_order);
        records[0] = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        records[0] = record;
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned optional casts hand off the carrier and take the active payload" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(): ^Box {
        \\    var slot: ?^Box = new Box { value: 7 };
        \\    return slot as ^Box;
        \\}
        \\fn maybe(): ?^Box {
        \\    var slot: ?^Box = new Box { value: 9 };
        \\    return slot as? ^Box;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_owned_optional_cast.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_owned_optional_cast.cy", program);
    defer module.deinit(allocator);
    var cast_count: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .cast) continue;
        cast_count += 1;
        const cast = entry.expr.cast;
        try std.testing.expect(cast.subject.* == .handoff_local);
        const carrier = module.metadataForExpr(cast.subject) orelse return error.TestUnexpectedResult;
        try std.testing.expect(carrier.consumption.transfer == .move);
        const carrier_effect = carrier.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(carrier_effect.effect == .move);
        try std.testing.expect(carrier_effect.effect.move.source == .place);
        try std.testing.expect(carrier_effect.effect.move.source.place.root == .binding);
        try std.testing.expect(carrier_effect.effect.move.source.place.projections == null);
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.edge == .active_case and record.edge.active_case == .optional_some);
        try std.testing.expect(record.effect == .take);
        try std.testing.expectEqual(carrier.temporary_id.?, record.effect.take.source.temporary_payload.root);
        if (cast.fallible) {
            try std.testing.expect(record.effect.take.destination == .temporary_payload);
            try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.take.destination.temporary_payload.root);
        } else {
            try std.testing.expect(record.effect.take.destination == .temporary);
            try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.take.destination.temporary);
        }
        var ordered = false;
        for (module.functions) |function| {
            var carrier_index: ?usize = null;
            var effect_index: ?usize = null;
            var cast_index: ?usize = null;
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == cast.subject) carrier_index = index;
                if (event == .effect and std.meta.eql(event.effect, record)) effect_index = index;
                if (event == .evaluate and event.evaluate == entry.expr) cast_index = index;
            }
            if (carrier_index != null and effect_index != null and cast_index != null and
                carrier_index.? < cast_index.? and cast_index.? < effect_index.?) ordered = true;
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.take.source.temporary_payload.root = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expectEqual(@as(usize, 2), cast_count);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
}

test "owned union casts take the resolved active payload" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Payload { box: ^Box; }
        \\union Choice { item: Payload; empty: i32; }
        \\union Either = Payload | i32;
        \\fn make(): Payload {
        \\    var choice: Choice = .item(Payload { box: new Box { value: 7 } });
        \\    return choice as Payload;
        \\}
        \\fn maybe(): ?Payload {
        \\    var choice: Choice = .item(Payload { box: new Box { value: 9 } });
        \\    return choice as? Payload;
        \\}
        \\fn make_type_union(): Payload {
        \\    var choice: Either = Payload { box: new Box { value: 11 } };
        \\    return choice as Payload;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_owned_union_cast.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_owned_union_cast.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var cast_count: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .cast) continue;
        cast_count += 1;
        const cast = entry.expr.cast;
        try std.testing.expect(cast.subject.* == .handoff_local);
        const carrier = module.metadataForExpr(cast.subject) orelse return error.TestUnexpectedResult;
        try std.testing.expect(carrier.consumption.transfer == .move);
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.edge == .active_case and record.edge.active_case == .union_field);
        try std.testing.expectEqual(cast.source_union_decl_id.?, record.edge.active_case.union_field.owner_decl_id);
        try std.testing.expectEqual(@as(u32, 0), record.edge.active_case.union_field.ordinal);
        try std.testing.expect(record.effect == .take);
        try std.testing.expectEqual(carrier.temporary_id.?, record.effect.take.source.temporary_payload.root);
        try std.testing.expectEqual(cast.source_union_decl_id.?, record.effect.take.source.temporary_payload.owner_decl_id.?);
        try std.testing.expect(std.mem.eql(u8, cast.union_case_name.?, record.effect.take.source.temporary_payload.case_name));
        if (cast.fallible) {
            try std.testing.expect(record.effect.take.destination == .temporary_payload);
        } else {
            try std.testing.expect(record.effect.take.destination == .temporary);
        }
        var ordered = false;
        for (module.functions) |function| {
            var carrier_index: ?usize = null;
            var cast_index: ?usize = null;
            var effect_index: ?usize = null;
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == cast.subject) carrier_index = index;
                if (event == .evaluate and event.evaluate == entry.expr) cast_index = index;
                if (event == .effect and std.meta.eql(event.effect, record)) effect_index = index;
            }
            if (carrier_index != null and cast_index != null and effect_index != null and
                carrier_index.? < cast_index.? and cast_index.? < effect_index.?) ordered = true;
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.edge.active_case.union_field.ordinal = 1;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expectEqual(@as(usize, 3), cast_count);
}

test "indirect calls check resource arguments and owner results" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn identity(value: ^Box): ^Box { return value; }
        \\fn read(value: &const Box): i32 { return value.value; }
        \\fn forward(a: i32, b: i32, c: i32, d: i32, value: ^Box): ^Box { return value; }
        \\fn owning(): i32 {
        \\    const callback: fn(^Box): ^Box = identity;
        \\    var box = new Box { value: 42 };
        \\    const result = callback(box);
        \\    return result.value;
        \\}
        \\fn borrowing(): i32 {
        \\    const callback: fn(&const Box): i32 = read;
        \\    var box = new Box { value: 7 };
        \\    return callback(box);
        \\}
        \\fn many(): i32 {
        \\    const callback: fn(i32, i32, i32, i32, ^Box): ^Box = forward;
        \\    var box = new Box { value: 8 };
        \\    const result = callback(1, 2, 3, 4, box);
        \\    return result.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_indirect_call.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_indirect_call.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var call_count: usize = 0;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .indirect_call) continue;
        call_count += 1;
        const call = &@constCast(entry.expr).indirect_call;
        const records = call.checked_arguments orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(call.args.len, records.len);
        const active_index = records.len - 1;
        for (records[0..active_index]) |maybe_record| try std.testing.expect(maybe_record == null);
        const record = records[active_index] orelse return error.TestUnexpectedResult;
        const moving = record.effect == .move;
        if (moving) {
            try std.testing.expect(record.effect.move.destination == .indirect_call_slot);
            try std.testing.expect(record.effect.move.destination.indirect_call_slot.call == entry.expr);
            try std.testing.expectEqual(@as(u32, @intCast(active_index)), record.effect.move.destination.indirect_call_slot.index);
            try std.testing.expect(call.checked_result_effect != null);
            try std.testing.expect(call.checked_result_effect.?.effect == .move);
            try std.testing.expect(call.checked_result_effect.?.effect.move.source == .indirect_return_slot);
        } else {
            try std.testing.expect(record.effect == .borrow);
            try std.testing.expect(call.checked_result_effect == null);
        }
        var ordered = false;
        for (module.functions) |function| {
            var callee_index: ?usize = null;
            var argument_index: ?usize = null;
            var effect_index: ?usize = null;
            var call_index: ?usize = null;
            var result_index: ?usize = null;
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == call.callee) callee_index = index;
                if (event == .evaluate and event.evaluate == call.args[active_index].value) argument_index = index;
                if (event == .effect and std.meta.eql(event.effect, record)) effect_index = index;
                if (event == .evaluate and event.evaluate == entry.expr) call_index = index;
                if (call.checked_result_effect) |result| {
                    if (event == .effect and std.meta.eql(event.effect, result)) result_index = index;
                }
            }
            if (callee_index != null and argument_index != null and effect_index != null and call_index != null and
                callee_index.? < argument_index.? and argument_index.? < effect_index.? and effect_index.? < call_index.? and
                (!moving or (result_index != null and call_index.? < result_index.?))) ordered = true;
        }
        try std.testing.expect(ordered);
        records[active_index] = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        records[active_index] = record;
        if (moving) {
            records[active_index].?.effect.move.destination.indirect_call_slot.index = 99;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            records[active_index] = record;
        }
        if (moving) {
            const result = call.checked_result_effect;
            call.checked_result_effect = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
            call.checked_result_effect = result;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), call_count);
}

test "clone indices and string conversion materialize owner results" {
    const allocator = std.testing.allocator;
    const source =
        \\fn duplicate(): i32 {
        \\    var values: [:]i32 = [1, 2];
        \\    const copy = values.clone();
        \\    return copy.len() as i32;
        \\}
        \\fn index_count(): i32 {
        \\    var slots: [;]i32 = [; 2] { 0: 7 };
        \\    const indices = slots.indices();
        \\    return indices.len() as i32;
        \\}
        \\fn text_count(): i32 {
        \\    const text = string.from("hi".bytes());
        \\    return text.len() as i32;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_fresh_builtins.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_fresh_builtins.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var count: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        const target = switch (entry.expr.*) {
            .sparse_indices, .string_from => true,
            .unary => |unary| unary.op == .copy_list,
            else => false,
        };
        if (!target) continue;
        count += 1;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .materialize);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.materialize.temporary);
        var ordered = false;
        for (module.functions) |function| {
            var child_index: ?usize = null;
            var result_index: ?usize = null;
            var effect_index: ?usize = null;
            const child = switch (entry.expr.*) {
                .sparse_indices => |expr| expr,
                .string_from => |expr| expr,
                .unary => |unary| unary.expr,
                else => unreachable,
            };
            for (function.effect_flow, 0..) |event, index| {
                if (event == .evaluate and event.evaluate == child) child_index = index;
                if (event == .evaluate and event.evaluate == entry.expr) result_index = index;
                if (event == .effect and std.meta.eql(event.effect, record)) effect_index = index;
            }
            if (child_index != null and result_index != null and effect_index != null and
                child_index.? < result_index.? and result_index.? < effect_index.?) ordered = true;
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "owner aggregate constructors materialize after child transfers" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\union Carrier { some: Holder; empty: i32; }
        \\fn main(): i32 {
        \\    const holder = Holder { box: new Box { value: 1 } };
        \\    const carrier: Carrier = .some(holder);
        \\    const fixed: [1]Holder = [Holder { box: new Box { value: 2 } }];
        \\    const dense: [:]Holder = [Holder { box: new Box { value: 3 } }];
        \\    const sparse: [;]Holder = [; 2] [Holder { box: new Box { value: 4 } }];
        \\    const keyed: [;]Holder = [; 2] { 0: Holder { box: new Box { value: 5 } } };
        \\    const defaults: [2]string = [];
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_aggregate_materialize.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_aggregate_materialize.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var seen: [6]bool = @splat(false);
    var saw_child_transfer_order = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        const kind: usize = switch (entry.expr.*) {
            .struct_literal => 0,
            .union_case => 1,
            .array_literal => 2,
            .dense_array_literal => 3,
            .sparse_literal, .sparse_keyed_literal => 4,
            .array_default => 5,
            else => continue,
        };
        if (entry.metadata.semantics.ownership != .owned and entry.metadata.semantics.ownership != .shared) continue;
        seen[kind] = true;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .materialize);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.materialize.temporary);
        if (entry.expr.* == .struct_literal and entry.expr.struct_literal.fields.len != 0) {
            const field = entry.expr.struct_literal.fields[0];
            if (field.checked_transfer) |transfer| {
                const flow = module.functions[0].effect_flow;
                var child_index: ?usize = null;
                var transfer_index: ?usize = null;
                var parent_index: ?usize = null;
                var materialize_index: ?usize = null;
                for (flow, 0..) |event, index| {
                    if (event == .evaluate and event.evaluate == field.value) child_index = index;
                    if (event == .effect and std.meta.eql(event.effect, transfer)) transfer_index = index;
                    if (event == .evaluate and event.evaluate == entry.expr) parent_index = index;
                    if (event == .effect and std.meta.eql(event.effect, record)) materialize_index = index;
                }
                if (child_index != null and transfer_index != null and parent_index != null and materialize_index != null and
                    child_index.? < transfer_index.? and transfer_index.? < parent_index.? and parent_index.? < materialize_index.?)
                    saw_child_transfer_order = true;
            }
        }
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
    try std.testing.expect(saw_child_transfer_order);
}

test "string literals slices and interpolation materialize shared results" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    const base = "hello";
        \\    const part = base.slice(1, 3);
        \\    const formatted = $"part={part}";
        \\    return formatted.len() as i32;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_string_materialize.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_string_materialize.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var seen: [3]bool = @splat(false);
    for (@constCast(module.expr_metadata)) |*entry| {
        const kind: usize = switch (entry.expr.*) {
            .string => 0,
            .string_slice => 1,
            .interpolated_string => 2,
            else => continue,
        };
        seen[kind] = true;
        try std.testing.expect(entry.metadata.semantics.ownership == .shared);
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .materialize);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.materialize.temporary);
        if (entry.expr.* == .string_slice) {
            const slice = entry.expr.string_slice;
            const flow = @constCast(module.functions[0].effect_flow);
            var object_at: ?usize = null;
            var start_at: ?usize = null;
            var end_at: ?usize = null;
            var result_at: ?usize = null;
            var effect_at: ?usize = null;
            for (flow, 0..) |event, index| switch (event) {
                .evaluate => |value| {
                    if (value == slice.object) object_at = index;
                    if (value == slice.start) start_at = index;
                    if (value == slice.end) end_at = index;
                    if (value == entry.expr) result_at = index;
                },
                .effect => |effect| if (std.meta.eql(effect, record)) {
                    effect_at = index;
                },
                else => {},
            };
            try std.testing.expect(object_at.? < start_at.?);
            try std.testing.expect(start_at.? < end_at.?);
            try std.testing.expect(end_at.? < result_at.?);
            try std.testing.expect(result_at.? < effect_at.?);
            const saved = flow[start_at.?];
            flow[start_at.?] = flow[end_at.?];
            try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
            flow[start_at.?] = saved;
        }
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "raw owner views borrow while explicit leaks detach the owner" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn raw(): i32 {
        \\    var box = new Box { value: 7 };
        \\    const ptr = box.ptr();
        \\    const ignored = ptr;
        \\    return box.value;
        \\}
        \\fn leak(): *Box {
        \\    var box = new Box { value: 8 };
        \\    return box.leak();
        \\}
        \\fn main(): i32 { return raw(); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_raw_owner.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_raw_owner.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var saw_raw = false;
    var saw_leak = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .raw_owned_local and entry.expr.* != .leak_owned_local) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        if (entry.expr.* == .raw_owned_local) {
            try std.testing.expect(record.effect == .borrow);
            saw_raw = true;
        } else {
            try std.testing.expect(record.effect == .leak);
            saw_leak = true;
        }
        try std.testing.expect(record.effect == .borrow or record.effect == .leak);
        const source_subject = if (record.effect == .borrow) record.effect.borrow else record.effect.leak;
        try std.testing.expect(source_subject == .place);
        try std.testing.expectEqual(entry.metadata.checked_place_root.?.binding, source_subject.place.root.binding);
        var ordered = false;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate or event.evaluate != entry.expr) continue;
                try std.testing.expect(index + 1 < function.effect_flow.len);
                try std.testing.expect(function.effect_flow[index + 1] == .effect and
                    std.meta.eql(function.effect_flow[index + 1].effect, record));
                ordered = true;
            }
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(saw_raw and saw_leak);
}

fn findLocal(statements: []const sir.Stmt, name: []const u8) ?*sir.Local {
    for (@constCast(statements)) |*statement| switch (statement.*) {
        .local => |*local| if (std.mem.eql(u8, local.name, name)) return local,
        .unchecked => |body| if (findLocal(body, name)) |local| return local,
        .using_alloc => |using_alloc| if (findLocal(using_alloc.body, name)) |local| return local,
        .@"if" => |if_stmt| {
            if (findLocal(if_stmt.then_body, name)) |local| return local;
            if (findLocal(if_stmt.else_body, name)) |local| return local;
        },
        .@"while" => |loop| if (findLocal(loop.body, name)) |local| return local,
        .@"for" => |loop| if (findLocal(loop.body, name)) |local| return local,
        .@"switch" => |switch_stmt| {
            for (switch_stmt.cases) |case| if (findLocal(case.body, name)) |local| return local;
            if (findLocal(switch_stmt.else_body, name)) |local| return local;
        },
        else => {},
    };
    return null;
}

test "sema emits checked replacement and transfer for owned local assignment" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = new Box { value: 1 };
        \\    box = new Box { value: 2 };
        \\    return box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const body = @constCast(module.functions[0].body);
    const assignment = &body[1].assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace);
    try std.testing.expect(transfer.effect == .move);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    assignment.checked_replace = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_replace = replacement;
    assignment.checked_non_owning_target = true;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "sema keys a writable alias replacement to its pointee" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var holder = Holder { box: new Box { value: 1 } };
        \\    const alias: &Holder = &holder;
        \\    alias = Holder { box: new Box { value: 2 } };
        \\    return holder.box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_alias_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_alias_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(module.functions[0].body)[2].assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace and replacement.effect.replace == .alias_pointee);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .alias_pointee);
    assignment.checked_replace = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_replace = replacement;
    assignment.checked_non_owning_target = false;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "sema keys a writable alias field replacement to its pointee path" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var holder = Holder { box: new Box { value: 1 } };
        \\    const alias: &Holder = &holder;
        \\    alias.box = new Box { value: 2 };
        \\    return holder.box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_alias_field_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_alias_field_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(module.functions[0].body)[2].field_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace and replacement.effect.replace == .alias_pointee);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .alias_pointee);
    try std.testing.expectEqual(@as(usize, 1), transfer.effect.move.destination.alias_pointee.projections.?.len);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    assignment.checked_evaluation_sites_len = 1;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "sema keys a writable alias index replacement to its pointee slot" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { values: [:]i32; }
        \\fn main(): i32 {
        \\    var items: [:]Holder = [Holder { values: [1] }, Holder { values: [2] }];
        \\    const alias: &[:]Holder = &items;
        \\    alias[0] = Holder { values: [3] };
        \\    return items[0].values[0] + alias[0].values[0];
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_alias_index_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_alias_index_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    var index_reads: usize = 0;
    var borrowed_reads: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.metadata.checkedPlacePath() == null) continue;
        switch (entry.expr.*) {
            .index => index_reads += 1,
            .borrowed_field, .borrowed_index => borrowed_reads += 1,
            else => continue,
        }
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        if (entry.expr.* == .borrowed_field or entry.expr.* == .borrowed_index) {
            try std.testing.expect(record.effect == .borrow);
        } else {
            try std.testing.expect(record.effect == .read);
        }
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        if (entry.expr.* == .borrowed_field or entry.expr.* == .borrowed_index) {
            entry.metadata.checked_effect.?.effect.borrow.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        } else {
            entry.metadata.checked_effect.?.effect.read.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        }
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(index_reads > 0 and borrowed_reads > 0);
    const assignment = &@constCast(module.functions[0].body)[2].index_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace and replacement.effect.replace == .alias_pointee);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .alias_pointee);
    try std.testing.expectEqual(@as(usize, 1), transfer.effect.move.destination.alias_pointee.projections.?.len);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
}

test "sema keys raw pointer replacement to evaluated pointee" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { values: [:]i32; }
        \\fn main(): i32 {
        \\    var holder = new Holder { values: [1] };
        \\    const ptr: *Holder = holder.ptr();
        \\    unchecked { *ptr = Holder { values: [2] }; }
        \\    return holder.values[0];
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_raw_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_raw_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(@constCast(module.functions[0].body)[2].unchecked)[0].deref_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace and replacement.effect.replace == .raw_pointee);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .raw_pointee);
    try std.testing.expect(transfer.effect.move.destination.raw_pointee.pointer == assignment.pointer);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    assignment.checked_replace = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
}

test "sema keys raw pointer field replacement to typed pointee path" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var holder = new Holder { box: new Box { value: 1 } };
        \\    const ptr: *Holder = holder.ptr();
        \\    unchecked { (*ptr).box = new Box { value: 2 }; }
        \\    return holder.box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_raw_field_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_raw_field_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(@constCast(module.functions[0].body)[2].unchecked)[0].deref_field_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace and replacement.effect.replace == .raw_pointee);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .raw_pointee);
    try std.testing.expectEqual(@as(usize, 1), transfer.effect.move.destination.raw_pointee.projections.?.len);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    const projections = @constCast(assignment.checked_projections.?);
    const saved_type = projections[0].result_type_id;
    projections[0].result_type_id = @fromBackingInt(@intCast(@backingInt(saved_type) + 1));
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    projections[0].result_type_id = saved_type;
}

test "sema emits a binding-keyed drop effect into the function flow" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn main(): i32 {
        \\    var box = new Box { value: 1 };
        \\    drop box;
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_drop.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_drop.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const function = &@constCast(module.functions)[0];
    const drop = &@constCast(function.body)[1].drop;
    const record = drop.checked_effect orelse return error.TestUnexpectedResult;
    try std.testing.expect(record.effect == .drop);
    try std.testing.expectEqual(drop.binding_id.?, record.effect.drop.place.root.binding);
    var flow_index: ?usize = null;
    for (function.effect_flow, 0..) |event, index| {
        if (event == .effect and event.effect.effect == .drop) {
            flow_index = index;
            break;
        }
    }
    const index = flow_index orelse return error.TestUnexpectedResult;
    drop.checked_effect = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEvaluationSites, trace.verifyModule(allocator, &module));
    drop.checked_effect = record;
    drop.checked_effect.?.effect.drop.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    drop.checked_effect = record;
    const flow = @constCast(function.effect_flow);
    flow[index] = .{ .effect = .{ .effect = .{ .drop = .{ .temporary = @fromBackingInt(@intCast(999)) } } } };
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
}

test "sema verifies an owned field replacement at its projected place" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var holder = Holder { box: new Box { value: 1 } };
        \\    holder.box = new Box { value: 2 };
        \\    return holder.box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_field_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_field_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    var checked_fields: usize = 0;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .field or entry.metadata.checkedPlacePath() == null) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .read);
        checked_fields += 1;
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.read.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(checked_fields > 0);
    const assignment = &@constCast(module.functions[0].body)[1].field_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace);
    try std.testing.expect(transfer.effect == .move);
    try std.testing.expectEqual(@as(usize, 1), transfer.effect.move.destination.place.projections.?.len);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    assignment.checked_replace = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_replace = replacement;
    assignment.checked_transfer.?.effect.move.destination.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    const projections = @constCast(assignment.checked_projections.?);
    const saved_type = projections[0].result_type_id;
    projections[0].result_type_id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    projections[0].result_type_id = saved_type;
    const field_sites = assignment.checked_evaluation_sites;
    try std.testing.expectEqual(@as(u8, 3), assignment.checked_evaluation_sites_len);
    assignment.checked_evaluation_sites[1] = field_sites[2];
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_evaluation_sites = field_sites;
    assignment.checked_evaluation_sites_len = 1;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_evaluation_sites_len = 3;
}

test "sema verifies an owned indexed replacement at its projected place" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { values: [:]i32; }
        \\fn main(): i32 {
        \\    var items: [:]Holder = [Holder { values: [1] }, Holder { values: [2] }];
        \\    items[0] = Holder { values: [3] };
        \\    return items[0].values[0];
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_index_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_index_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(module.functions[0].body)[1].index_assign;
    const replacement = assignment.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = assignment.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replacement.effect == .replace);
    try std.testing.expect(transfer.effect == .move);
    try std.testing.expectEqual(@as(i64, 0), transfer.effect.move.destination.place.projections.?[0].step.index.fixed);
    assignment.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_transfer = transfer;
    assignment.checked_replace = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_replace = replacement;
    const projections = @constCast(assignment.checked_projections.?);
    projections[0].step.index.fixed = 1;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    projections[0].step.index.fixed = 0;
    const index_sites = assignment.checked_evaluation_sites;
    try std.testing.expectEqual(@as(u8, 5), assignment.checked_evaluation_sites_len);
    assignment.checked_evaluation_sites[0] = index_sites[1];
    assignment.checked_evaluation_sites[1] = index_sites[0];
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_evaluation_sites = index_sites;
    assignment.checked_evaluation_sites[4] = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    assignment.checked_evaluation_sites = index_sites;
}

test "indexed replacement preserves a checked field prefix" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { values: [:]i32; }
        \\struct Pool { items: [:]Holder; }
        \\fn main(): i32 {
        \\    var pool = Pool { items: [Holder { values: [1] }] };
        \\    pool.items[0] = Holder { values: [3] };
        \\    return pool.items[0].values[0];
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_nested_index_assign.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_nested_index_assign.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const assignment = &@constCast(module.functions[0].body)[1].index_assign;
    const projections = @constCast(assignment.checked_projections orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 2), projections.len);
    try std.testing.expect(projections[0].step == .field);
    try std.testing.expect(projections[1].step == .index);
    const saved = projections[0];
    projections[0].step.field.owner_decl_id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    projections[0] = saved;
}

test "module effect flow orders short circuit view effects" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): bool {
        \\    return false or "abc".bytes().len() > 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_short_circuit.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_short_circuit.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    const flow = @constCast(module.functions[0].effect_flow);
    var rhs_at: ?usize = null;
    var join_at: ?usize = null;
    var borrow_at: ?usize = null;
    for (flow, 0..) |event, index| switch (event) {
        .short_circuit_rhs => rhs_at = index,
        .short_circuit_join => join_at = index,
        .effect => |record| if (record.effect == .borrow) {
            borrow_at = index;
        },
        else => {},
    };
    try std.testing.expect(rhs_at.? < borrow_at.?);
    try std.testing.expect(borrow_at.? < join_at.?);
    const saved = flow[rhs_at.?];
    flow[rhs_at.?] = flow[join_at.?];
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    flow[rhs_at.?] = saved;
}

test "module effect flow orders a view borrow through loop branch and defer" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    const text = "abc";
        \\    var once = true;
        \\    while once and text.bytes().len() > 0 {
        \\        defer assert(text.len() > 0);
        \\        if text.starts_with("a") { once = false; }
        \\        else { once = false; }
        \\    }
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_nested_flow.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_nested_flow.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    const flow = @constCast(module.functions[0].effect_flow);
    var header: ?usize = null;
    var rhs: ?usize = null;
    var borrow: ?usize = null;
    var join: ?usize = null;
    var body: ?usize = null;
    var defer_register: ?usize = null;
    var defer_end: ?usize = null;
    var then_enter: ?usize = null;
    var else_enter: ?usize = null;
    var branch_join: ?usize = null;
    var defer_invoke: ?usize = null;
    var loop_back: ?usize = null;
    var loop_exit: ?usize = null;
    for (flow, 0..) |event, index| switch (event) {
        .short_circuit_rhs => rhs = index,
        .short_circuit_join => join = index,
        .effect => |record| if (record.effect == .borrow) {
            borrow = index;
        },
        .control => |control| switch (control.phase) {
            .loop_header => header = index,
            .loop_body => body = index,
            .defer_register => defer_register = index,
            .defer_end => defer_end = index,
            .then_enter => then_enter = index,
            .else_enter => else_enter = index,
            .branch_join => branch_join = index,
            .defer_invoke => defer_invoke = index,
            .loop_back => loop_back = index,
            .loop_exit => loop_exit = index,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(header.? < rhs.?);
    try std.testing.expect(rhs.? < borrow.?);
    try std.testing.expect(borrow.? < join.?);
    try std.testing.expect(join.? < body.?);
    try std.testing.expect(body.? < defer_register.?);
    try std.testing.expect(defer_register.? < defer_end.?);
    try std.testing.expect(defer_end.? < then_enter.?);
    try std.testing.expect(then_enter.? < else_enter.?);
    try std.testing.expect(else_enter.? < branch_join.?);
    try std.testing.expect(branch_join.? < defer_invoke.?);
    try std.testing.expect(defer_invoke.? < loop_back.?);
    try std.testing.expect(loop_back.? < loop_exit.?);
    const saved = flow[defer_invoke.?];
    flow[defer_invoke.?] = flow[defer_register.?];
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    flow[defer_invoke.?] = saved;
}

test "scalar helper results reject fabricated checked effects" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): bool {
        \\    const text = "abc";
        \\    return text.len() > 0 and text.starts_with("a") and not text.is_empty();
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_neutral_helpers.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_neutral_helpers.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    var helpers: usize = 0;
    var borrowed: ?sir.Record = null;
    for (module.expr_metadata) |entry| {
        if (entry.metadata.checked_effect) |record| {
            if (record.effect == .read) borrowed = record;
        }
    }
    const forged = borrowed orelse return error.TestUnexpectedResult;
    for (@constCast(module.expr_metadata)) |*entry| {
        switch (entry.expr.*) {
            .string_len, .string_starts_with, .string_is_empty => {},
            else => continue,
        }
        try std.testing.expect(entry.metadata.checked_effect == null);
        entry.metadata.checked_effect = forged;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = null;
        helpers += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), helpers);
}

test "ordinary scalar expressions reject fabricated checked effects" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    const value = 1;
        \\    assert(value + 2 == 3);
        \\    return -value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_neutral_scalar.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_neutral_scalar.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    var forged: ?sir.Record = null;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* == .local and entry.metadata.checked_effect != null) {
            forged = entry.metadata.checked_effect;
            break;
        }
    }
    const record = forged orelse return error.TestUnexpectedResult;
    var seen: [3]bool = @splat(false);
    for (@constCast(module.expr_metadata)) |*entry| {
        const kind: usize = switch (entry.expr.*) {
            .unary => 0,
            .binary => 1,
            .test_assert => 2,
            else => continue,
        };
        seen[kind] = true;
        try std.testing.expect(entry.metadata.checked_effect == null);
        entry.metadata.checked_effect = record;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = null;
    }
    for (seen) |found| try std.testing.expect(found);
}

test "is tests evaluate their subject and remain effect-neutral" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(value: ?i32): bool {
        \\    return value is none;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_is_test.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_is_test.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .is_test) continue;
        found = true;
        const subject = entry.expr.is_test.subject;
        _ = module.metadataForExpr(subject) orelse return error.TestUnexpectedResult;
        var subject_at: ?usize = null;
        var test_at: ?usize = null;
        for (module.functions[0].effect_flow, 0..) |event, index| {
            if (event != .evaluate) continue;
            if (event.evaluate == subject) subject_at = index;
            if (event.evaluate == entry.expr) test_at = index;
        }
        try std.testing.expect(subject_at.? < test_at.?);
        try std.testing.expect(entry.metadata.checked_effect == null);
        entry.metadata.checked_effect = .{ .effect = .{ .materialize = .{ .temporary = @fromBackingInt(@intCast(999)) } } };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = null;
    }
    try std.testing.expect(found);
}

test "module effect flow preserves branch and loop order and rejects a missing event" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Holder { values: [:]i32; }
        \\fn main(): i32 {
        \\    var items: [:]Holder = [Holder { values: [1] }];
        \\    var once = true;
        \\    while once {
        \\        if once { items[0] = Holder { values: [2] }; }
        \\        else { items[0] = Holder { values: [3] }; }
        \\        once = false;
        \\    }
        \\    return items[0].values[0];
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_flow.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_flow.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    const function = &@constCast(module.functions)[0];
    const flow = @constCast(function.effect_flow);
    var header: ?usize = null;
    var then_enter: ?usize = null;
    var else_enter: ?usize = null;
    var branch_join: ?usize = null;
    var loop_back: ?usize = null;
    var loop_exit: ?usize = null;
    var replacement_count: usize = 0;
    var first_effect: ?usize = null;
    for (flow, 0..) |event, index| switch (event) {
        .control => |control| switch (control.phase) {
            .loop_header => header = index,
            .then_enter => then_enter = index,
            .else_enter => else_enter = index,
            .branch_join => branch_join = index,
            .loop_back => loop_back = index,
            .loop_exit => loop_exit = index,
            else => {},
        },
        .effect => |record| {
            if (first_effect == null) first_effect = index;
            if (record.effect == .replace) replacement_count += 1;
        },
        else => {},
    };
    try std.testing.expect(header.? < then_enter.?);
    try std.testing.expect(then_enter.? < else_enter.?);
    try std.testing.expect(else_enter.? < branch_join.?);
    try std.testing.expect(branch_join.? < loop_back.?);
    try std.testing.expect(loop_back.? < loop_exit.?);
    try std.testing.expectEqual(@as(usize, 2), replacement_count);
    const saved = flow[first_effect.?];
    flow[first_effect.?] = .{ .evaluate = module.functions[0].body[0].local.init };
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    flow[first_effect.?] = saved;
}

test "module effect flow orders global initializers and rejects a forged global site" {
    const allocator = std.testing.allocator;
    const source =
        \\const base: i32 = 1;
        \\const answer: i32 = base + 2;
        \\fn main(): i32 { return answer; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_globals.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_globals.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    var checked_global_reads: usize = 0;
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .global_ref or entry.metadata.checkedPlacePath() == null) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .read);
        checked_global_reads += 1;
    }
    try std.testing.expect(checked_global_reads > 0);
    const flow = @constCast(module.global_effect_flow);
    var base: ?usize = null;
    var answer: ?usize = null;
    for (flow, 0..) |event, index| {
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.name, "base")) base = index;
        if (std.mem.eql(u8, event.global.name, "answer")) answer = index;
    }
    try std.testing.expect(base.? < answer.?);
    try std.testing.expect(flow[base.? + 1] == .evaluate);
    const saved = flow[base.?];
    flow[base.?] = flow[answer.?];
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    flow[base.?] = saved;
}

test "module effect flow marks deferred evaluation as an exit template" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    defer assert(true);
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_defer_flow.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_defer_flow.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    const function = &@constCast(module.functions)[0];
    const flow = @constCast(function.effect_flow);
    var registration: ?usize = null;
    var body: ?usize = null;
    var end: ?usize = null;
    var invocation: ?usize = null;
    var returned: ?usize = null;
    for (flow, 0..) |event, index| if (event == .control) {
        switch (event.control.phase) {
            .defer_register => registration = index,
            .defer_body => body = index,
            .defer_end => end = index,
            .defer_invoke => if (invocation == null) {
                invocation = index;
            },
            .return_exit => returned = index,
            else => {},
        }
    };
    try std.testing.expect(registration.? < body.?);
    try std.testing.expect(body.? < end.?);
    try std.testing.expect(end.? < invocation.?);
    try std.testing.expect(invocation.? < returned.?);
    const saved = flow[registration.?];
    flow[registration.?] = flow[body.?];
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    flow[registration.?] = saved;
}

test "module effect flow routes defers to continue and nested try error edges" {
    const allocator = std.testing.allocator;
    const source =
        \\enum E { no; }
        \\fn fail(): i32!E { throw E.no; }
        \\fn probe(): i32!E {
        \\    defer assert(true);
        \\    const value = try fail();
        \\    return value;
        \\}
        \\fn main(): i32 {
        \\    defer assert(true);
        \\    var once = true;
        \\    while once {
        \\        defer assert(true);
        \\        once = false;
        \\        continue;
        \\    }
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_defer_edges.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_defer_edges.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    var found_probe = false;
    var found_main = false;
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, "probe")) {
            found_probe = true;
            var saw_try_error = false;
            var saw_error_defer = false;
            for (function.effect_flow, 0..) |event, index| {
                if (event != .try_error) continue;
                saw_try_error = true;
                try std.testing.expect(index + 2 < function.effect_flow.len);
                const invocation = function.effect_flow[index + 1];
                try std.testing.expect(invocation == .control and invocation.control.phase == .defer_invoke);
                try std.testing.expect(function.effect_flow[index + 2] == .try_success);
                saw_error_defer = true;
            }
            try std.testing.expect(saw_try_error and saw_error_defer);
        } else if (std.mem.eql(u8, function.name, "main")) {
            found_main = true;
            const outer_defer = &function.body[0];
            const inner_defer = &function.body[2].@"while".body[0];
            try std.testing.expect(outer_defer.* == .@"defer" and inner_defer.* == .@"defer");
            var saw_continue = false;
            var saw_return = false;
            for (function.effect_flow, 0..) |event, index| {
                if (event != .control) continue;
                if (event.control.phase == .continue_exit) {
                    saw_continue = true;
                    try std.testing.expect(index > 0);
                    const invocation = function.effect_flow[index - 1];
                    try std.testing.expect(invocation == .control and invocation.control.phase == .defer_invoke and
                        invocation.control.statement == inner_defer);
                    const mutable_flow = @constCast(function.effect_flow);
                    mutable_flow[index - 1].control.statement = outer_defer;
                    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
                    mutable_flow[index - 1] = invocation;
                } else if (event.control.phase == .return_exit) {
                    saw_return = true;
                    try std.testing.expect(index > 0);
                    const invocation = function.effect_flow[index - 1];
                    try std.testing.expect(invocation == .control and invocation.control.phase == .defer_invoke and
                        invocation.control.statement == outer_defer);
                }
            }
            try std.testing.expect(saw_continue and saw_return);
        }
    }
    try std.testing.expect(found_probe and found_main);
}

test "sema emits a declaration-keyed return effect for an owned value" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(value: i32): ^Box { return new Box { value: value }; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_return.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_return.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const function = module.functions[0];
    const returned = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr != returned) continue;
        const record = entry.metadata.checked_sink_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .@"return");
        try std.testing.expectEqual(function.decl_id.?, record.effect.@"return".destination.return_slot);
        entry.metadata.checked_sink_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_sink_effect = record;
        entry.metadata.checked_sink_effect.?.effect.@"return".destination.return_slot = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "new owned construction materializes its temporary before return" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(): ^Box { return new Box { value: 7 }; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_materialize.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_materialize.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr.* != .new_owned) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .materialize);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.materialize.temporary);
        const flow = module.functions[0].effect_flow;
        var evaluated: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .evaluate and event.evaluate == entry.expr) evaluated = index;
        }
        const index = evaluated orelse return error.TestUnexpectedResult;
        try std.testing.expect(flow[index + 1] == .effect and flow[index + 1].effect.effect == .materialize);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.materialize = .{ .temporary = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned literal field moves into its parent temporary in evaluation order" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn make(): ^Holder { return new Holder { box: new Box { value: 7 } }; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_literal_field.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_literal_field.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .new_owned or entry.expr.new_owned.fields.len != 1 or
            !std.mem.eql(u8, entry.expr.new_owned.fields[0].name, "box")) continue;
        const field = &@constCast(@constCast(entry.expr).new_owned.fields)[0];
        const record = field.checked_transfer orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.move.destination.temporary_projection.root);
        const flow = module.functions[0].effect_flow;
        var moved: ?usize = null;
        var parent_evaluated: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .effect and std.meta.eql(event.effect, record)) moved = index;
            if (event == .evaluate and event.evaluate == entry.expr) parent_evaluated = index;
        }
        try std.testing.expect(moved.? < parent_evaluated.?);
        field.checked_transfer = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        field.checked_transfer = record;
        field.checked_transfer.?.effect.move.destination.temporary_projection.root = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned fixed array items move into checked temporary slots" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var boxes: [2]Holder = [Holder { box: new Box { value: 1 } }, Holder { box: new Box { value: 2 } }];
        \\    return boxes[0].box.value + boxes[1].box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_array_items.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_array_items.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const literal = &@constCast(module.functions[0].body)[0].local.init.array_literal;
    const records = literal.checked_transfers orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), records.len);
    for (records, 0..) |maybe_record, index| {
        const record = maybe_record orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move and record.effect.move.destination == .temporary_projection);
        try std.testing.expectEqual(@as(i64, @intCast(index)), record.effect.move.destination.temporary_projection.projection.step.index.fixed);
    }
    const flow = module.functions[0].effect_flow;
    var item_positions = [_]?usize{ null, null };
    var transfer_positions = [_]?usize{ null, null };
    var parent_position: ?usize = null;
    for (flow, 0..) |event, position| {
        if (event == .evaluate) {
            if (event.evaluate == literal.items[0]) item_positions[0] = position;
            if (event.evaluate == literal.items[1]) item_positions[1] = position;
            if (event.evaluate == module.functions[0].body[0].local.init) parent_position = position;
        }
        if (event == .effect) {
            for (records, 0..) |maybe_record, index| {
                if (maybe_record) |record| {
                    if (std.meta.eql(event.effect, record)) transfer_positions[index] = position;
                }
            }
        }
    }
    try std.testing.expect(item_positions[0].? < transfer_positions[0].? and
        transfer_positions[0].? < item_positions[1].? and
        item_positions[1].? < transfer_positions[1].? and
        transfer_positions[1].? < parent_position.?);
    const saved = records[1];
    records[1] = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    records[1] = saved;
    literal.checked_transfers = records[0..1];
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEvaluationSites, trace.verifyModule(allocator, &module));
    literal.checked_transfers = records;
}

test "owned dense array items move into checked temporary slots" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var boxes: [:]Holder = [Holder { box: new Box { value: 1 } }, Holder { box: new Box { value: 2 } }];
        \\    return boxes[0].box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_dense_array_items.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_dense_array_items.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const literal = &@constCast(module.functions[0].body)[0].local.init.dense_array_literal;
    const records = literal.checked_transfers orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), records.len);
    for (records, 0..) |maybe_record, index| {
        const record = maybe_record orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move and record.effect.move.destination == .temporary_projection);
        try std.testing.expectEqual(@as(i64, @intCast(index)), record.effect.move.destination.temporary_projection.projection.step.index.fixed);
    }
    const saved = records[0];
    records[0] = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    records[0] = saved;
}

test "named owned items in explicit dense and keyed sparse literals carry checked handoffs" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, sparse: bool }{
        .{ .source =
        \\struct Box { value: i32; }
        \\fn forward(box: ^Box): [:]^Box {
        \\    const boxes = [:]^Box [box];
        \\    return boxes;
        \\}
        \\fn main(): i32 { return 0; }
        , .sparse = false },
        .{ .source =
        \\struct Box { value: i32; }
        \\fn forward(box: ^Box): [;]^Box {
        \\    const boxes: [;]^Box = [; 1] { 0: box };
        \\    return boxes;
        \\}
        \\fn main(): i32 { return 0; }
        , .sparse = true },
    };
    for (cases) |case| {
        const tokens = try compiler.lexer.lexAll(allocator, case.source);
        defer allocator.free(tokens);
        const program = try compiler.parser.parse(allocator, "effect_named_storage_items.cy", case.source, tokens);
        defer program.deinit(allocator);
        const module = try compiler.sema.buildSir(allocator, "effect_named_storage_items.cy", program);
        defer module.deinit(allocator);
        try module.verifyValueActions();
        try trace.verifyModule(allocator, &module);
        const literal = module.functions[0].body[0].local.init;
        const item = if (case.sparse)
            literal.sparse_keyed_literal.entries[0].value
        else
            literal.dense_array_literal.items[0];
        try std.testing.expect(item.* == .handoff_local);
        const metadata = module.metadataForExpr(item) orelse return error.TestUnexpectedResult;
        const effect = metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(effect.effect == .move and effect.effect.move.source == .place);
        const transfer = if (case.sparse)
            literal.sparse_keyed_literal.checked_transfers.?[0].?
        else
            literal.dense_array_literal.checked_transfers.?[0].?;
        try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .temporary_projection);
    }
}

test "named optional owned items in positional sparse literals carry checked handoffs" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        \\struct Box { value: i32; }
        \\fn forward(box: ?^Box): [;]^Box {
        \\    const boxes: [;]^Box = [; 1] [box];
        \\    return boxes;
        \\}
        \\fn main(): i32 { return 0; }
        ,
        \\struct Box { value: i32; }
        \\fn forward(box: ?^Box): [;]^Box {
        \\    const boxes: [;]^Box = [box];
        \\    return boxes;
        \\}
        \\fn main(): i32 { return 0; }
        ,
    };
    for (sources) |source| {
        const tokens = try compiler.lexer.lexAll(allocator, source);
        defer allocator.free(tokens);
        const program = try compiler.parser.parse(allocator, "effect_named_sparse_item.cy", source, tokens);
        defer program.deinit(allocator);
        const module = try compiler.sema.buildSir(allocator, "effect_named_sparse_item.cy", program);
        defer module.deinit(allocator);
        try module.verifyValueActions();
        try trace.verifyModule(allocator, &module);
        const literal = module.functions[0].body[0].local.init.sparse_literal;
        const item = literal.items[0];
        try std.testing.expect(item.* == .handoff_local);
        const metadata = module.metadataForExpr(item) orelse return error.TestUnexpectedResult;
        const effect = metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(effect.effect == .move and effect.effect.move.source == .place);
        const transfer = literal.checked_transfers.?[0].?;
        try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .temporary_projection);
    }
}

test "owned positional sparse items move into checked slots" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn main(): i32 {
        \\    var slots: [;]Profile = [; 3] [Profile { scores: [7] }, Profile { scores: [8] }];
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_sparse_items.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_sparse_items.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const literal = &@constCast(module.functions[0].body)[0].local.init.sparse_literal;
    const records = literal.checked_transfers orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), records.len);
    for (records, 0..) |maybe_record, index| {
        const record = maybe_record orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move and record.effect.move.destination == .temporary_projection);
        try std.testing.expectEqual(@as(i64, @intCast(index)), record.effect.move.destination.temporary_projection.projection.step.index.fixed);
    }
    const saved = records[0];
    records[0] = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    records[0] = saved;
}

test "owned keyed sparse item transfers after key and value" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn main(): i32 {
        \\    const index: i32 = 1;
        \\    var slots: [;]Profile = [; 3] { index: Profile { scores: [7] } };
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_sparse_keyed_items.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_sparse_keyed_items.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const literal_expr = module.functions[0].body[1].local.init;
    const literal = &@constCast(literal_expr).sparse_keyed_literal;
    const records = literal.checked_transfers orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), records.len);
    const record = records[0] orelse return error.TestUnexpectedResult;
    try std.testing.expect(record.effect == .move and record.effect.move.destination == .temporary_projection);
    try std.testing.expect(record.effect.move.destination.temporary_projection.projection.step.index == .dynamic);
    try std.testing.expect(record.effect.move.destination.temporary_projection.projection.step.index.dynamic == literal.entries[0].index);
    var key_position: ?usize = null;
    var value_position: ?usize = null;
    var transfer_position: ?usize = null;
    for (module.functions[0].effect_flow, 0..) |event, position| {
        if (event == .evaluate and event.evaluate == literal.entries[0].index) key_position = position;
        if (event == .evaluate and event.evaluate == literal.entries[0].value) value_position = position;
        if (event == .effect and std.meta.eql(event.effect, record)) transfer_position = position;
    }
    try std.testing.expect(key_position.? < value_position.? and value_position.? < transfer_position.?);
    records[0] = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    records[0] = record;
}

test "dense push transfers an owned payload into the append slot" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var items: [:]Holder = [];
        \\    items.push(Holder { box: new Box { value: 7 } });
        \\    return items[0].box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_dense_push.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_dense_push.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const push = &@constCast(module.functions[0].body)[1].expr.sequence_push;
    const record = push.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(record.effect == .move and record.effect.move.destination == .container_slot);
    try std.testing.expect(record.effect.move.destination.container_slot.position == .append);
    try std.testing.expect(record.effect.move.destination.container_slot.object == push.object);
    push.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
    push.checked_transfer = record;
}

test "dense pop takes its last checked slot into the result temporary" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var items: [:]Holder = [Holder { box: new Box { value: 7 } }];
        \\    const item = items.pop();
        \\    return item.box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_dense_pop.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_dense_pop.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const pop = module.functions[0].body[1].local.init;
    try std.testing.expect(pop.* == .sequence_pop);
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr != pop) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .take and record.effect.take.source == .container_slot);
        try std.testing.expect(record.effect.take.source.container_slot.position == .last);
        try std.testing.expect(record.effect.take.source.container_slot.object == pop.sequence_pop);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        return;
    }
    return error.TestUnexpectedResult;
}

test "dense and sparse clear carry checked container-wide effects" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    var dense: [:]Holder = [Holder { box: new Box { value: 1 } }];
        \\    dense.clear();
        \\    var sparse: [;]Holder = [; 2] { 0: Holder { box: new Box { value: 2 } } };
        \\    sparse.clear();
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_container_clear.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_container_clear.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const metadata = @constCast(module.expr_metadata);
    var seen: usize = 0;
    for (metadata) |*entry| {
        if (entry.expr.* != .sequence_clear and entry.expr.* != .sparse_clear) continue;
        const object = if (entry.expr.* == .sequence_clear) entry.expr.sequence_clear else entry.expr.sparse_clear;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .clear and record.effect.clear == .container_slot);
        try std.testing.expect(record.effect.clear.container_slot.position == .all);
        try std.testing.expect(record.effect.clear.container_slot.object == object);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.clear.container_slot.item_type_id = @fromBackingInt(@intCast(999999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "sparse insert replaces a checked slot after key and payload" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\struct Holder { box: ^Box; }
        \\fn main(): i32 {
        \\    const key: i32 = 1;
        \\    var slots: [;]Holder = [; 3];
        \\    slots.insert(key, Holder { box: new Box { value: 7 } });
        \\    return 0;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_sparse_insert.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_sparse_insert.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const insert = &@constCast(module.functions[0].body)[2].expr.sparse_insert;
    const replace = insert.checked_replace orelse return error.TestUnexpectedResult;
    const transfer = insert.checked_transfer orelse return error.TestUnexpectedResult;
    try std.testing.expect(replace.effect == .replace and replace.effect.replace == .container_slot);
    try std.testing.expect(transfer.effect == .move and transfer.effect.move.destination == .container_slot);
    try std.testing.expect(transfer.effect.move.destination.container_slot.position.indexed == .dynamic);
    try std.testing.expect(transfer.effect.move.destination.container_slot.position.indexed.dynamic == insert.index);
    var key_position: ?usize = null;
    var value_position: ?usize = null;
    var replace_position: ?usize = null;
    var transfer_position: ?usize = null;
    for (module.functions[0].effect_flow, 0..) |event, position| {
        if (event == .evaluate and event.evaluate == insert.index) key_position = position;
        if (event == .evaluate and event.evaluate == insert.value) value_position = position;
        if (event == .effect and std.meta.eql(event.effect, replace)) replace_position = position;
        if (event == .effect and std.meta.eql(event.effect, transfer)) transfer_position = position;
    }
    try std.testing.expect(key_position.? < value_position.? and value_position.? < replace_position.? and replace_position.? < transfer_position.?);
    insert.checked_transfer = null;
    try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
    insert.checked_transfer = transfer;
}

test "owned result payload moves into its carrier temporary" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn make(): ^Box!Error { return new Box { value: 7 }; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_carrier_payload.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_carrier_payload.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .union_case or entry.expr.union_case.result_case != .ok) continue;
        const case = &@constCast(entry.expr).union_case;
        const record = case.checked_transfer orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.move.destination.temporary_payload.root);
        const flow = module.functions[0].effect_flow;
        var moved: ?usize = null;
        var evaluated: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .effect and std.meta.eql(event.effect, record)) moved = index;
            if (event == .evaluate and event.evaluate == entry.expr) evaluated = index;
        }
        try std.testing.expect(moved.? < evaluated.?);
        case.checked_transfer = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        case.checked_transfer = record;
        case.checked_transfer.?.effect.move.destination.temporary_payload.root = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned local payloads hand off before result and union construction" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        \\struct Box { value: i32; }
        \\enum E { failed, }
        \\fn wrap(box: ^Box): ^Box!E { return box; }
        ,
        \\struct Box { value: i32; }
        \\union Choice { active: ^Box; }
        \\fn wrap(box: ^Box): Choice { return .active(box); }
    };
    for (sources) |source| {
        const tokens = try compiler.lexer.lexAll(allocator, source);
        defer allocator.free(tokens);
        const program = try compiler.parser.parse(allocator, "effect_local_carrier.cy", source, tokens);
        defer program.deinit(allocator);
        const module = try compiler.sema.buildSir(allocator, "effect_local_carrier.cy", program);
        defer module.deinit(allocator);
        try module.verifyValueActions();
        try trace.verifyModule(allocator, &module);
        const entries = @constCast(module.expr_metadata);
        var found = false;
        for (entries) |entry| {
            if (entry.expr.* != .union_case) continue;
            const payload = entry.expr.union_case.value orelse continue;
            if (payload.* != .handoff_local) continue;
            found = true;
            const carrier_transfer = entry.expr.union_case.checked_transfer orelse return error.TestUnexpectedResult;
            try std.testing.expect(carrier_transfer.effect == .move);
            for (entries) |*child| {
                if (child.expr != payload) continue;
                const handoff = child.metadata.checked_effect orelse return error.TestUnexpectedResult;
                try std.testing.expect(handoff.effect == .move);
                try std.testing.expectEqual(child.metadata.temporary_id.?, carrier_transfer.effect.move.source.temporary);
                const flow = for (module.functions) |function| {
                    if (std.mem.eql(u8, function.name, "wrap")) break function.effect_flow;
                } else return error.TestUnexpectedResult;
                var handoff_at: ?usize = null;
                var carrier_at: ?usize = null;
                var construction_at: ?usize = null;
                for (flow, 0..) |event, index| {
                    if (event == .effect and std.meta.eql(event.effect, handoff)) handoff_at = index;
                    if (event == .effect and std.meta.eql(event.effect, carrier_transfer)) carrier_at = index;
                    if (event == .evaluate and event.evaluate == entry.expr) construction_at = index;
                }
                try std.testing.expect(handoff_at.? < carrier_at.? and carrier_at.? < construction_at.?);
                child.metadata.checked_effect = null;
                try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
                child.metadata.checked_effect = handoff;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "owned try payload takes the success carrier after its branch" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn make(): ^Box!Error { return new Box { value: 7 }; }
        \\fn probe(): i32!Error {
        \\    const box = try make();
        \\    return box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_try_payload.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_try_payload.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        if (entry.expr.* != .@"try") continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.edge == .active_case and record.edge.active_case == .result);
        try std.testing.expect(record.edge.active_case.result == .ok and record.effect == .take);
        try std.testing.expect(record.effect.take.source == .temporary_payload);
        try std.testing.expect(record.effect.take.destination == .temporary);
        const flow = module.functions[1].effect_flow;
        var success_position: ?usize = null;
        var transfer_position: ?usize = null;
        for (flow, 0..) |event, position| {
            if (event == .try_success and event.try_success == entry.expr) success_position = position;
            if (event == .effect and std.meta.eql(event.effect, record)) transfer_position = position;
        }
        try std.testing.expect(success_position.? < transfer_position.?);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.edge = .always;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
        return;
    }
    return error.TestUnexpectedResult;
}

test "named owned try carrier moves from its checked binding" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\enum Error { failed, }
        \\fn make(): ^Box!Error { return new Box { value: 7 }; }
        \\fn probe(): i32!Error {
        \\    const carrier = make();
        \\    const box = try carrier;
        \\    return box.value;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_named_try_carrier.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_named_try_carrier.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .@"try") continue;
        const carrier = entry.expr.@"try".expr;
        try std.testing.expect(carrier.* == .handoff_local);
        const moved = for (module.expr_metadata) |inner| {
            if (inner.expr == carrier) break inner.metadata.checked_effect orelse return error.TestUnexpectedResult;
        } else return error.TestUnexpectedResult;
        try std.testing.expect(moved.effect == .move and moved.effect.move.source == .place);
        try std.testing.expect(moved.effect.move.source.place.root == .binding);
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned union payload moves into its carrier temporary" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\union Holder { box: ^Box; empty; }
        \\fn make(): Holder { return .box(new Box { value: 7 }); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_union_payload.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_union_payload.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .union_case or !std.mem.eql(u8, entry.expr.union_case.case_name, "box")) continue;
        const case = &@constCast(entry.expr).union_case;
        const record = case.checked_transfer orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .move);
        try std.testing.expectEqual(case.decl_id.?, record.effect.move.destination.temporary_payload.owner_decl_id.?);
        const flow = module.functions[0].effect_flow;
        var moved: ?usize = null;
        var evaluated: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .effect and std.meta.eql(event.effect, record)) moved = index;
            if (event == .evaluate and event.evaluate == entry.expr) evaluated = index;
        }
        try std.testing.expect(moved.? < evaluated.?);
        case.checked_transfer = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        case.checked_transfer = record;
        case.checked_transfer.?.effect.move.destination.temporary_payload.owner_decl_id = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "root take transfers the optional place into its result temporary" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(): ?^Box { var slot: ?^Box = new Box { value: 7 }; return take slot; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_root_take.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_root_take.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .take_path_local or entry.expr.take_path_local.steps.len != 0) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .take);
        try std.testing.expectEqual(entry.metadata.temporary_id.?, record.effect.take.destination.temporary);
        const flow = module.functions[0].effect_flow;
        var evaluated: ?usize = null;
        for (flow, 0..) |event, index| if (event == .evaluate and event.evaluate == entry.expr) {
            evaluated = index;
        };
        const index = evaluated orelse return error.TestUnexpectedResult;
        try std.testing.expect(flow[index + 1] == .effect and std.meta.eql(flow[index + 1].effect, record));
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        entry.metadata.checked_effect.?.effect.take.destination.temporary = @fromBackingInt(@intCast(999));
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned field take carries its checked projected source" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\struct User { profile: ?Profile; }
        \\fn pull(): ?Profile { var user = User { profile: Profile { scores: [7] } }; return take user.profile; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_field_take.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_field_take.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .take_path_local or entry.expr.take_path_local.steps.len != 1) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .take);
        const projections = record.effect.take.source.place.projections orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projections.len);
        try std.testing.expect(projections[0].step == .field);
        try std.testing.expect(std.mem.eql(u8, projections[0].step.field.name, "profile"));
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        @constCast(entry.metadata.checked_place_projections.?)[0].step.field.name = "scores";
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        return;
    }
    return error.TestUnexpectedResult;
}

test "owned indexed take evaluates its index before checked transfer" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn pull(): ?Profile { var slots: [:]?Profile = [Profile { scores: [7] }]; return take slots[0]; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_index_take.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_index_take.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .take_index_local) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .take);
        const projections = record.effect.take.source.place.projections orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projections.len);
        try std.testing.expect(projections[0].step == .index and projections[0].step.index == .fixed);
        try std.testing.expectEqual(@as(i64, 0), projections[0].step.index.fixed);
        const flow = module.functions[0].effect_flow;
        var index_eval: ?usize = null;
        var take_eval: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .evaluate and event.evaluate == entry.expr.take_index_local.index) index_eval = index;
            if (event == .evaluate and event.evaluate == entry.expr) take_eval = index;
        }
        try std.testing.expect(index_eval.? < take_eval.?);
        try std.testing.expect(flow[take_eval.? + 1] == .effect and std.meta.eql(flow[take_eval.? + 1].effect, record));
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        @constCast(entry.metadata.checked_place_projections.?)[0].step.index.fixed = 1;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        return;
    }
    return error.TestUnexpectedResult;
}

test "nested owned take paths retain every checked projection" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, indexed: bool }{
        .{ .source =
        \\struct Profile { scores: [:]i32; }
        \\struct User { profile: ?Profile; }
        \\struct Outer { user: User; }
        \\fn pull(): ?Profile { var outer = Outer { user: User { profile: Profile { scores: [7] } } }; return take outer.user.profile; }
        , .indexed = false },
        .{ .source =
        \\struct Profile { scores: [:]i32; }
        \\struct Outer { slots: [:]?Profile; }
        \\fn pull(): ?Profile { var outer = Outer { slots: [Profile { scores: [7] }] }; return take outer.slots[0]; }
        , .indexed = true },
    };
    for (cases) |case| {
        const tokens = try compiler.lexer.lexAll(allocator, case.source);
        defer allocator.free(tokens);
        const program = try compiler.parser.parse(allocator, "effect_nested_take.cy", case.source, tokens);
        defer program.deinit(allocator);
        const module = try compiler.sema.buildSir(allocator, "effect_nested_take.cy", program);
        defer module.deinit(allocator);
        try module.verifyCompilerIdentities();
        try module.verifyValueActions();
        try trace.verifyModule(allocator, &module);
        var found = false;
        for (@constCast(module.expr_metadata)) |*entry| {
            if (case.indexed) {
                if (entry.expr.* != .take_index_path_local) continue;
            } else {
                if (entry.expr.* != .take_path_local or entry.expr.take_path_local.steps.len != 2) continue;
            }
            const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
            const projections = record.effect.take.source.place.projections orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 2), projections.len);
            try std.testing.expect(projections[0].step == .field);
            try std.testing.expect(if (case.indexed) projections[1].step == .index else projections[1].step == .field);
            if (case.indexed) {
                const flow = module.functions[0].effect_flow;
                var index_eval: ?usize = null;
                var take_eval: ?usize = null;
                for (flow, 0..) |event, index| {
                    if (event == .evaluate and event.evaluate == entry.expr.take_index_path_local.index) index_eval = index;
                    if (event == .evaluate and event.evaluate == entry.expr) take_eval = index;
                }
                try std.testing.expect(index_eval.? < take_eval.?);
            }
            entry.metadata.checked_effect = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            entry.metadata.checked_effect = record;
            @constCast(entry.metadata.checked_place_projections.?)[0].result_type_id = @fromBackingInt(@intCast(999));
            try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

test "owned sparse take records its slot and evaluates the key first" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\fn pull(): ?Profile { var slots: [;]Profile = [; 2] [Profile { scores: [7] }]; return take slots[0]; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_sparse_take.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_sparse_take.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .sparse_take) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .take);
        const projections = record.effect.take.source.place.projections orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), projections.len);
        try std.testing.expect(projections[0].step == .index and projections[0].step.index == .fixed);
        try std.testing.expectEqual(@as(i64, 0), projections[0].step.index.fixed);
        const flow = module.functions[0].effect_flow;
        var key_eval: ?usize = null;
        var take_eval: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event == .evaluate and event.evaluate == entry.expr.sparse_take.index) key_eval = index;
            if (event == .evaluate and event.evaluate == entry.expr) take_eval = index;
        }
        try std.testing.expect(key_eval.? < take_eval.?);
        try std.testing.expect(flow[take_eval.? + 1] == .effect and std.meta.eql(flow[take_eval.? + 1].effect, record));
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        entry.metadata.checked_effect = record;
        @constCast(entry.metadata.checked_place_projections.?)[0].step.index.fixed = 1;
        try std.testing.expectError(error.InvalidCheckedPlaceProjection, module.verifyCompilerIdentities());
        return;
    }
    return error.TestUnexpectedResult;
}

test "sparse take retains a checked field prefix and dynamic key" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Profile { scores: [:]i32; }
        \\struct Outer { slots: [;]Profile; }
        \\fn pull(i: i32): ?Profile { var outer = Outer { slots: [; 2] [Profile { scores: [7] }] }; return take outer.slots[i]; }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_sparse_prefix_take.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_sparse_prefix_take.cy", program);
    defer module.deinit(allocator);
    try module.verifyCompilerIdentities();
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .sparse_take) continue;
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        const projections = record.effect.take.source.place.projections orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), projections.len);
        try std.testing.expect(projections[0].step == .field);
        try std.testing.expect(projections[1].step == .index and projections[1].step.index == .dynamic);
        try std.testing.expect(projections[1].step.index.dynamic == entry.expr.sparse_take.index);
        return;
    }
    return error.TestUnexpectedResult;
}

test "dense and sparse storage construction materialize after capacity evaluation" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): i32 {
        \\    const cap = 4;
        \\    var dense = [: cap]i32;
        \\    var sparse = [; cap]i32;
        \\    return dense.len() as i32 + sparse.len() as i32;
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_storage_construct.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_storage_construct.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var saw_dense = false;
    var saw_sparse = false;
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |*entry| {
        const capacity: *const sir.Expr = switch (entry.expr.*) {
            .new_array => |array| blk: {
                saw_dense = true;
                break :blk array.len;
            },
            .new_sparse => |storage| blk: {
                saw_sparse = true;
                break :blk storage.capacity;
            },
            else => continue,
        };
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .materialize);
        const flow = module.functions[0].effect_flow;
        var capacity_index: ?usize = null;
        var construction_index: ?usize = null;
        for (flow, 0..) |event, index| {
            if (event != .evaluate) continue;
            if (event.evaluate == capacity) capacity_index = index;
            if (event.evaluate == entry.expr) construction_index = index;
        }
        try std.testing.expect(capacity_index.? < construction_index.?);
        try std.testing.expect(flow[construction_index.? + 1] == .effect and
            flow[construction_index.? + 1].effect.effect == .materialize);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(saw_dense and saw_sparse);
}

test "sema emits checked call argument transfer to the formal binding" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn take(box: ^Box): i32 { return box.value; }
        \\fn main(): i32 { return take(new Box { value: 7 }); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_call.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_call.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const metadata = @constCast(module.expr_metadata);
    for (metadata) |entry| {
        if (entry.expr.* != .call or !std.mem.eql(u8, entry.expr.call.callee, "take")) continue;
        const call = &@constCast(entry.expr).call;
        try std.testing.expectEqual(@as(usize, 1), call.checked_arguments.len);
        const record = call.checked_arguments[0];
        try std.testing.expect(record.effect == .call_argument);
        try std.testing.expect(record.effect.call_argument.mode == .move);
        try std.testing.expect(record.effect.call_argument.source == .temporary);
        try std.testing.expect(record.effect.call_argument.destination.? == .place);
        const records = @constCast(call.checked_arguments);
        records[0].effect.call_argument.index = 1;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        records[0] = record;
        records[0].effect.call_argument.destination.?.place.root = .{ .binding = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        records[0] = record;
        call.checked_arguments = &.{};
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        call.checked_arguments = records;
        return;
    }
    return error.TestUnexpectedResult;
}

test "nested owned call result is the outer call argument source" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(value: i32): ^Box { return new Box { value: value }; }
        \\fn take(box: ^Box): i32 { return box.value; }
        \\fn main(): i32 { return take(make(7)); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_nested_call.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_nested_call.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .call or !std.mem.eql(u8, entry.expr.call.callee, "take")) continue;
        const call = &@constCast(entry.expr).call;
        const inner = call.args[0].value;
        try std.testing.expect(inner.* == .call);
        const inner_metadata = module.metadataForExpr(inner) orelse return error.TestUnexpectedResult;
        const result_effect = inner.call.checked_result_effect orelse return error.TestUnexpectedResult;
        for (@constCast(module.expr_metadata)) |*metadata_entry| {
            if (metadata_entry.expr != inner) continue;
            try std.testing.expect(metadata_entry.metadata.checked_effect == null);
            metadata_entry.metadata.checked_effect = result_effect;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            metadata_entry.metadata.checked_effect = null;
            break;
        }
        const inner_sites = inner.call.checked_evaluation_sites;
        try std.testing.expectEqual(@as(usize, 2), inner_sites.len);
        try std.testing.expect(inner_sites[0] == .argument_value);
        try std.testing.expect(inner_sites[0].argument_value == inner.call.args[0].value);
        try std.testing.expect(inner_sites[1] == .effect);
        try std.testing.expect(std.meta.eql(result_effect, inner_sites[1].effect));
        try std.testing.expect(result_effect.effect == .move);
        try std.testing.expect(result_effect.effect.move.source == .return_slot);
        try std.testing.expectEqual(inner_metadata.temporary_id.?, result_effect.effect.move.destination.temporary);
        inner.call.checked_result_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        inner.call.checked_result_effect = .{ .effect = .{ .move = .{
            .source = .{ .return_slot = call.decl_id.? },
            .destination = .{ .temporary = inner_metadata.temporary_id.? },
        } } };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        inner.call.checked_result_effect = result_effect;
        const records = @constCast(call.checked_arguments);
        const sites = @constCast(call.checked_evaluation_sites);
        var main_flow: ?[]sir.EffectFlowEvent = null;
        for (module.functions) |function| {
            if (std.mem.eql(u8, function.name, "main")) main_flow = @constCast(function.effect_flow);
        }
        const flow = main_flow orelse return error.TestUnexpectedResult;
        var inner_at: ?usize = null;
        var result_at: ?usize = null;
        var argument_at: ?usize = null;
        var outer_at: ?usize = null;
        for (flow, 0..) |event, index| switch (event) {
            .evaluate => |value| {
                if (value == inner) inner_at = index;
                if (value == entry.expr) outer_at = index;
            },
            .effect => |effect| {
                if (std.meta.eql(effect, result_effect)) result_at = index;
                if (std.meta.eql(effect, records[0])) argument_at = index;
            },
            else => {},
        };
        try std.testing.expect(inner_at.? < result_at.?);
        try std.testing.expect(result_at.? < argument_at.?);
        try std.testing.expect(argument_at.? < outer_at.?);
        std.mem.swap(sir.EffectFlowEvent, &flow[inner_at.?], &flow[result_at.?]);
        try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
        std.mem.swap(sir.EffectFlowEvent, &flow[inner_at.?], &flow[result_at.?]);
        try std.testing.expectEqual(@as(usize, 2), sites.len);
        try std.testing.expect(sites[0] == .argument_value);
        try std.testing.expect(sites[0].argument_value == inner);
        try std.testing.expect(sites[1] == .effect);
        try std.testing.expect(std.meta.eql(records[0], sites[1].effect));
        std.mem.swap(sir.CallEvaluationSite, &sites[0], &sites[1]);
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        std.mem.swap(sir.CallEvaluationSite, &sites[0], &sites[1]);
        call.checked_evaluation_sites = sites[1..];
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        call.checked_evaluation_sites = sites;
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqual(inner_metadata.temporary_id.?, records[0].effect.call_argument.source.temporary);
        const saved = records[0];
        records[0].effect.call_argument.source = .{ .temporary = @fromBackingInt(@intCast(999)) };
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        records[0] = saved;
        return;
    }
    return error.TestUnexpectedResult;
}

test "direct call orders two owned argument results and transfers" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Box { value: i32; }
        \\fn make(value: i32): ^Box { return new Box { value: value }; }
        \\fn pair(a: ^Box, b: ^Box): i32 { return a.value + b.value; }
        \\fn main(): i32 { return pair(make(1), make(2)); }
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "effect_two_call_args.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_two_call_args.cy", program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var main_function: ?*const sir.Function = null;
    for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, "main")) main_function = function;
    }
    const function = main_function orelse return error.TestUnexpectedResult;
    const outer = function.body[0].@"return" orelse return error.TestUnexpectedResult;
    try std.testing.expect(outer.* == .call);
    const call = outer.call;
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqual(@as(usize, 2), call.checked_arguments.len);
    const first = call.args[0].value;
    const second = call.args[1].value;
    try std.testing.expect(first.* == .call and second.* == .call);
    const first_result = first.call.checked_result_effect orelse return error.TestUnexpectedResult;
    const second_result = second.call.checked_result_effect orelse return error.TestUnexpectedResult;
    var positions: [7]?usize = @splat(null);
    for (function.effect_flow, 0..) |event, index| switch (event) {
        .evaluate => |value| {
            if (value == first) positions[0] = index;
            if (value == second) positions[3] = index;
            if (value == outer) positions[6] = index;
        },
        .effect => |effect| {
            if (std.meta.eql(effect, first_result)) positions[1] = index;
            if (std.meta.eql(effect, call.checked_arguments[0])) positions[2] = index;
            if (std.meta.eql(effect, second_result)) positions[4] = index;
            if (std.meta.eql(effect, call.checked_arguments[1])) positions[5] = index;
        },
        else => {},
    };
    for (positions[0 .. positions.len - 1], positions[1..]) |before, after| {
        try std.testing.expect(before.? < after.?);
    }
}

test "hosted thread trampoline uses a checked generated payload source" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\fn worker(value: Arc<i32>): void { const ignored = value; }
        \\fn main(): i32 {
        \\    var value = own.arc(1 as i32);
        \\    const handle = thread.spawn(worker, value) catch (spawn_problem) { const ignored = spawn_problem; return 1; };
        \\    const ignored = handle; return 0;
        \\}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_generated_payload.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    const entries = @constCast(module.expr_metadata);
    for (entries) |*entry| {
        if (entry.expr.* != .call or !std.mem.eql(u8, entry.expr.call.callee, "worker")) continue;
        const call = &@constCast(entry.expr).call;
        try std.testing.expectEqual(@as(usize, 1), call.checked_arguments.len);
        const source_expr = call.args[0].value;
        const source_metadata = @constCast(module.expr_metadata);
        for (source_metadata) |*operand| {
            if (operand.expr != source_expr) continue;
            const binding = operand.metadata.checked_generated_payload_binding orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(binding, call.checked_arguments[0].effect.call_argument.source.generated_payload);
            try std.testing.expect(call.checked_arguments[0].effect.call_argument.mode == .move);
            operand.metadata.checked_generated_payload_binding = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            const saved_records = call.checked_arguments;
            call.checked_arguments = &.{};
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            call.checked_arguments = saved_records;
            operand.metadata.checked_generated_payload_binding = binding;
            const records = @constCast(call.checked_arguments);
            const saved = records[0];
            records[0].effect.call_argument.source.generated_payload = @fromBackingInt(@intCast(999));
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            records[0] = saved;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "TaskGroup trampoline transfers its generated payload into the indirect call" {
    const allocator = std.testing.allocator;
    const source =
        \\import { TaskGroup, TaskStatus, Task } from std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\fn worker(value: Arc<i32>): i32 { const ignored = value; return 1; }
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus {
        \\    return group.spawn(worker, own.arc(1 as i32));
        \\}
        \\fn main(): i32 { return 0; }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_group_payload.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .indirect_call) continue;
        const call = &@constCast(entry.expr).indirect_call;
        const record = call.checked_payload_transfer orelse continue;
        try std.testing.expect(record.effect == .move);
        try std.testing.expect(record.effect.move.source == .generated_payload);
        try std.testing.expect(record.effect.move.destination == .call_slot);
        const sites = call.checked_evaluation_sites[0..call.checked_evaluation_sites_len];
        try std.testing.expectEqual(@as(usize, 3), sites.len);
        try std.testing.expect(sites[0].? == .callee_value);
        try std.testing.expect(sites[0].?.callee_value == call.callee);
        try std.testing.expect(sites[1].? == .argument_value);
        try std.testing.expect(sites[1].?.argument_value == call.args[0].value);
        try std.testing.expect(sites[2].? == .effect);
        try std.testing.expect(std.meta.eql(record, sites[2].?.effect));
        std.mem.swap(?sir.CallEvaluationSite, &sites[1], &sites[2]);
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        std.mem.swap(?sir.CallEvaluationSite, &sites[1], &sites[2]);
        call.checked_evaluation_sites_len = 2;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        call.checked_evaluation_sites_len = 3;
        const source_expr = call.args[call.args.len - 1].value;
        const metadata = @constCast(module.expr_metadata);
        for (metadata) |*operand| {
            if (operand.expr != source_expr) continue;
            const binding = operand.metadata.checked_generated_payload_binding orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(binding, record.effect.move.source.generated_payload);
            call.checked_payload_transfer = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            operand.metadata.checked_generated_payload_binding = null;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            operand.metadata.checked_generated_payload_binding = binding;
            call.checked_payload_transfer = record;
            call.checked_payload_transfer.?.effect.move.destination.call_slot.index = 99;
            try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "TaskGroup context trampoline uses the second indirect argument slot" {
    const allocator = std.testing.allocator;
    const source =
        \\import { TaskGroup, TaskContext, TaskStatus, Task } from std.thread;
        \\import std.own;
        \\import { Arc } from std.own;
        \\fn worker(context: &TaskContext, value: Arc<i32>): i32 {
        \\    const ignored_context = context.is_cancelled();
        \\    const ignored_value = value;
        \\    return 1;
        \\}
        \\fn launch(group: &TaskGroup): Task<i32>!TaskStatus {
        \\    return group.spawn_context(worker, own.arc(1 as i32));
        \\}
        \\fn main(): i32 { return 0; }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = source });
    const root_path = try compat.tmpDirRealpathAlloc(allocator, &tmp, "main.cy");
    defer allocator.free(root_path);
    var loaded = try compiler.loader.loadProgram(allocator, root_path);
    defer loaded.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "effect_group_context_payload.cy", loaded.program);
    defer module.deinit(allocator);
    try module.verifyValueActions();
    try trace.verifyModule(allocator, &module);
    var context_ref_found = false;
    for (@constCast(module.expr_metadata)) |*entry| {
        if (entry.expr.* != .ref_local or !std.mem.eql(u8, entry.expr.ref_local, "__task_context")) continue;
        context_ref_found = true;
        const place = entry.metadata.checkedPlacePath() orelse return error.TestUnexpectedResult;
        try std.testing.expect(place.root == .binding);
        const record = entry.metadata.checked_effect orelse return error.TestUnexpectedResult;
        try std.testing.expect(record.effect == .borrow and record.effect.borrow == .place);
        try std.testing.expect(std.meta.eql(place, record.effect.borrow.place));
        var ordered = false;
        for (module.functions) |function| {
            for (function.effect_flow, 0..) |event, index| {
                if (event != .evaluate or event.evaluate != entry.expr) continue;
                try std.testing.expect(index + 1 < function.effect_flow.len);
                try std.testing.expect(function.effect_flow[index + 1] == .effect and
                    std.meta.eql(function.effect_flow[index + 1].effect, record));
                ordered = true;
            }
        }
        try std.testing.expect(ordered);
        entry.metadata.checked_effect = null;
        try std.testing.expectError(error.InvalidCheckedEffect, module.verifyValueActions());
        entry.metadata.checked_effect = record;
    }
    try std.testing.expect(context_ref_found);
    for (module.expr_metadata) |entry| {
        if (entry.expr.* != .indirect_call) continue;
        const record = entry.expr.indirect_call.checked_payload_transfer orelse continue;
        try std.testing.expectEqual(@as(usize, 2), entry.expr.indirect_call.args.len);
        try std.testing.expectEqual(@as(u32, 1), record.effect.move.destination.call_slot.index);
        const sites = entry.expr.indirect_call.checked_evaluation_sites[0..entry.expr.indirect_call.checked_evaluation_sites_len];
        try std.testing.expectEqual(@as(usize, 4), sites.len);
        try std.testing.expect(sites[2].? == .argument_value);
        try std.testing.expect(sites[2].?.argument_value == entry.expr.indirect_call.args[1].value);
        try std.testing.expect(sites[3].? == .effect);
        return;
    }
    return error.TestUnexpectedResult;
}

test "break effect edge invokes loop defers without invoking outer defers" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main(): void {
        \\    defer assert(true);
        \\    while true { defer assert(true); break; }
        \\}
    ;
    const tokens = try compiler.lexer.lexAll(allocator, source);
    defer allocator.free(tokens);
    const program = try compiler.parser.parse(allocator, "break_effect.cy", source, tokens);
    defer program.deinit(allocator);
    const module = try compiler.sema.buildSir(allocator, "break_effect.cy", program);
    defer module.deinit(allocator);
    try trace.verifyModule(allocator, &module);
    for (module.functions) |function| {
        if (!std.mem.eql(u8, function.name, "main")) continue;
        const inner_defer = &function.body[1].@"while".body[0];
        for (function.effect_flow, 0..) |event, index| {
            if (event != .control or event.control.phase != .break_exit) continue;
            try std.testing.expect(index > 0);
            const invocation = function.effect_flow[index - 1];
            try std.testing.expect(invocation == .control and invocation.control.phase == .defer_invoke and invocation.control.statement == inner_defer);
            const mutable_flow = @constCast(function.effect_flow);
            mutable_flow[index - 1].control.statement = &function.body[0];
            try std.testing.expectError(error.InvalidEffectFlow, trace.verifyModule(allocator, &module));
            mutable_flow[index - 1] = invocation;
            return;
        }
    }
    return error.TestExpectedBreakEdge;
}
