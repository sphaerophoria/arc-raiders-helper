const std = @import("std");
const wsr = @import("wsr");

pub const ItemQuantity = struct {
    id: []const u8,
    quantity: u32,
};

pub const State = struct {
    tracked_items: []ItemQuantity = &.{},
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

    const ret =  std.json.parseFromSliceLeaky(State, alloc, state_str, .{
        .allocate = .alloc_always,
    }) catch {
        wsr.print("Invalid state, resetting", .{});
        return .{};
    };

    for (ret.tracked_items) |item| {
        if (std.mem.eql(u8, item.id, "null")) {
            wsr.print("Invalid state, resetting", .{});
            return .{};
        }
    }

    return ret;
}

