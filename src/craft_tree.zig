const wsr = @import("wsr");

pub export fn hello() void {
    wsr.print("hello", .{});
}
