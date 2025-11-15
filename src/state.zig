const std = @import("std");
const wsr = @import("wsr");

pub const State = []const []const u8;

pub fn setState(alloc: std.mem.Allocator, state: State) !void {
    const serialized = try std.json.Stringify.valueAlloc(alloc, state, .{});
    var serialized_writer = std.Io.Writer.Allocating.init(alloc);
    try serialized_writer.writer.writeByte('#');
    try std.base64.url_safe.Encoder.encodeWriter(&serialized_writer.writer, serialized);
    wsr.setWindowProperty(serialized_writer.written(), "location");
}

pub fn getState(alloc: std.mem.Allocator) !State {
    wsr.getWindowProperty("location");

    const loc = wsr.getInputBuffer();
    const state_key = "#";
    const state_start = (std.mem.indexOf(u8, loc, state_key) orelse return &.{}) + state_key.len;
    const state = loc[state_start..];

    if (state.len == 0) return &.{};

    const serialized = try alloc.alloc(u8, try std.base64.url_safe.Decoder.calcSizeForSlice(state));
    try std.base64.url_safe.Decoder.decode(serialized, state);

    return try std.json.parseFromSliceLeaky(State, alloc, serialized, .{
        .allocate = .alloc_always,
    });
}

