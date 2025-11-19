const std = @import("std");
const wsr = @import("wsr");

pub const ItemQuantity = struct {
    id: []const u8,
    quantity: u32,
};

pub const State = struct {
    tracked_items: []const []const u8 = &.{},
    stash_quantities: []ItemQuantity = &.{},
};

const imported = struct {
    extern fn getState() void;
    extern fn setState(state_ptr: [*]const u8, state_len: usize) void;
};

pub fn setState(alloc: std.mem.Allocator, state: State) !void {
    const serialized = try std.json.Stringify.valueAlloc(alloc, state, .{});
    imported.setState(serialized.ptr, serialized.len);
}

pub fn getState(alloc: std.mem.Allocator) !State {
    imported.getState();
    const state_str = wsr.getInputBuffer();
    if (state_str.len == 0) {
        return .{};
    }

    return std.json.parseFromSliceLeaky(State, alloc, state_str, .{
        .allocate = .alloc_always,
    }) catch {
        wsr.print("Invalid state, resetting", .{});
        return .{};
    };
}

