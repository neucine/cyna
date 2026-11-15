const std = @import("std");
const obligations = @import("cyna").compiler.resource_obligations;
const Model = obligations.Model;
const State = obligations.State;

test "a stored obligation prevents closing its aggregate" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const window = try model.newOwner(0, null);
    const jobs = try model.newOwner(0, window);
    const obligation = try model.admit(jobs, "window.jobs");
    try std.testing.expectError(error.Unsettled, model.closeOwner(window));
    try model.settle(obligation);
    try model.closeOwner(window);
    try model.leaveScope(0);
}

test "transfer keeps the obligation with the longer lived owner" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const callback_scope = try model.newScope(0);
    const application = try model.newOwner(0, null);
    const local = try model.newOwner(callback_scope, null);
    const obligation = try model.admit(local, "jobs");
    try model.reparent(local, application);
    try model.leaveScope(callback_scope);
    try std.testing.expectError(error.Unsettled, model.closeOwner(application));
    try model.settle(obligation);
    try model.closeOwner(application);
}

test "joining settled and unsettled branches still requires settlement" {
    var left = try Model.init(std.testing.allocator);
    defer left.deinit();
    const owner = try left.newOwner(0, null);
    const obligation = try left.admit(owner, "jobs");
    var right = try left.clone();
    defer right.deinit();
    try right.settle(obligation);
    var joined = try Model.merge(&left, &right);
    defer joined.deinit();
    try std.testing.expectEqual(State.maybe_live, joined.obligations.items[obligation].state);
    try std.testing.expectError(error.Unsettled, joined.leaveScope(0));
    try std.testing.expectError(error.AlreadySettled, joined.settle(obligation));
}

test "early scope exit requires settlement even after a failed second admission" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const scope = try model.newScope(0);
    const jobs = try model.newOwner(scope, null);
    const first = try model.admit(jobs, "first task group");
    try std.testing.expectError(error.Unsettled, model.leaveScope(scope));
    try model.settle(first);
    try model.leaveScope(scope);
}

test "a direct move into a returned owner does not discharge settlement" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const function_scope = try model.newScope(0);
    const local = try model.newOwner(function_scope, null);
    const returned = try model.newOwner(0, null);
    const obligation = try model.admit(local, "jobs");
    try model.move(obligation, returned);
    try model.leaveScope(function_scope);
    try std.testing.expectError(error.Unsettled, model.closeOwner(returned));
}

test "moving a nested aggregate retains all field obligations" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const callback_scope = try model.newScope(0);
    const local_window = try model.newOwner(callback_scope, null);
    const jobs = try model.newOwner(callback_scope, local_window);
    const second_service = try model.newOwner(callback_scope, local_window);
    const first = try model.admit(jobs, "window.jobs");
    const second = try model.admit(second_service, "window.service");
    const application = try model.newOwner(0, null);
    try model.reparent(local_window, application);
    try model.leaveScope(callback_scope);
    try model.settle(first);
    try std.testing.expectError(error.Unsettled, model.closeOwner(application));
    try model.settle(second);
    try model.closeOwner(application);
}

test "branch merge rejects owners that diverge" {
    var left = try Model.init(std.testing.allocator);
    defer left.deinit();
    const original = try left.newOwner(0, null);
    const destination = try left.newOwner(0, null);
    const obligation = try left.admit(original, "jobs");
    var right = try left.clone();
    defer right.deinit();
    try right.move(obligation, destination);
    try std.testing.expectError(error.AmbiguousOwner, Model.merge(&left, &right));
}

test "settlement cannot happen twice" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const owner = try model.newOwner(0, null);
    const obligation = try model.admit(owner, "jobs");
    try model.settle(obligation);
    try std.testing.expectError(error.AlreadySettled, model.settle(obligation));
}

test "moving a group does not release a service its tasks still need" {
    var model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const callback_scope = try model.newScope(0);
    const application = try model.newOwner(0, null);
    const jobs = try model.newOwner(callback_scope, null);
    const services = try model.newOwner(callback_scope, null);
    const obligation = try model.admit(jobs, "guest tasks");
    try model.requireBacking(obligation, services);
    try model.reparent(jobs, application);
    try std.testing.expectEqual(obligation, (try model.outstandingForOwner(services)).?);
    try std.testing.expectEqualStrings("guest tasks", model.obligations.items[(try model.outstandingForScope(callback_scope)).?].label);
    try std.testing.expectError(error.Unsettled, model.closeOwner(services));
    try std.testing.expectError(error.Unsettled, model.leaveScope(callback_scope));
    try model.reparent(services, application);
    try model.leaveScope(callback_scope);
    try model.settle(obligation);
    try model.closeOwner(application);
}
