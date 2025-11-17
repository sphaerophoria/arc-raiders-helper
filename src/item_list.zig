const wsr = @import("wsr");
const std = @import("std");
const state = @import("state.zig");

pub const returnErrorHook = wsr.returnErrorHook;

const ItemList = []const Item;

const StateCache = struct {
    alloc: std.mem.Allocator,
    items: std.StringHashMapUnmanaged(void),


    fn idTracked(self: StateCache, id: []const u8) bool {
        return self.items.contains(id);
    }

    fn remove(self: *StateCache, s: []const u8) void {
        const kv = self.items.fetchRemove(s) orelse return;
        self.alloc.free(kv.key);
    }

    fn add(self: *StateCache, s: []const u8) !void {
        const cloned = try self.alloc.dupe(u8, s);
        try self.items.put(self.alloc, cloned, {});
    }

    fn fromState(s: state.State) !StateCache {
        const alloc = std.heap.wasm_allocator;
        var ret = StateCache{
            .alloc = alloc,
            .items = std.StringHashMapUnmanaged(void){},
        };

        for (s) |item| {
            try ret.add(item);
        }

        return ret;
    }

    fn toState(self: StateCache, alloc: std.mem.Allocator) !state.State {
        var it = self.items.iterator();
        var ret = std.ArrayList([]const u8).initBuffer(try alloc.alloc([]const u8, self.items.count()));
        while (it.next()) |entry| {
            ret.appendBounded(entry.key_ptr.*) catch unreachable;
        }

        return ret.items;
    }
};

var global = struct {
    state_cache: ?StateCache = null,
}{};

pub export fn initPage() void {
    initPageFailable() catch {
        wsr.printCapturedBacktrace();
        unreachable;
    };
}

pub fn initPageFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    const s = try state.getState(arena.allocator());
    global.state_cache = try StateCache.fromState(s);

    for (s) |item| {
        wsr.print("Checked: {s}\n", .{item});
    }
}

fn urlEscape(s: []const u8) []const u8 {
    return s;
}

fn htmlEscape(s: []const u8) []const u8 {
    return s;
}

pub export fn onItemList() void {
    onItemListFailable() catch |e| {
        wsr.print("{t}", .{e});
        wsr.printCapturedBacktrace();
        unreachable;
    };
}

fn onItemListFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    var output_html = std.Io.Writer.Allocating.init(arena.allocator());


    wsr.print("{s}", .{wsr.getInputBuffer()});
    const items = try std.json.parseFromSliceLeaky(ItemList, arena.allocator(), wsr.getInputBuffer(), .{
        .ignore_unknown_fields = true,
    });

    for (items) |item| {
        //const checked = global.state_cache.?.idTracked(item.id);
            try output_html.writer.print(
                \\<div item-name=\"{s}\">
                \\  <input item-id="{s}" {s} type="checkbox" wsr-onevent="click" wsr-call="onItemClicked"/>
                \\  <div class="item-card">
                \\    <img class="item-img" src="images/{s}.webp" />
                \\    <img src="rarity-overlay-{s}.png" title="{s}"/>
                \\  </div>
                \\</div>
            , .{
                htmlEscape(item.id),
                htmlEscape(item.id),
                htmlChecked(false),
                htmlEscape(item.id),
                htmlEscape(item.rarity orelse "uncommon"),
                htmlEscape(item.name),
            },
        );
    }

    wsr.setSelfProperty(output_html.written(), "innerHTML");
}

const Item = struct {
    id: []const u8 = &.{},
    name: []const u8 = &.{},
    rarity: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};


fn stringToBool(s: []const u8) !bool {
    const StringBool = enum {
        true,
        false,
    };

    const b = std.meta.stringToEnum(StringBool, s) orelse return error.Invalid;
    return b == .true;
}

pub export fn onItemClicked() void {
    onItemClickedFailable() catch |e| {
        wsr.print("{t}\n", .{e});
        if (@errorReturnTrace()) |t| {
            wsr.print("trace: {any}", .{t});
        }
        unreachable;
    };
}

fn onItemClickedFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    wsr.getSelfProperty("checked");
    const is_checked = try stringToBool(wsr.getInputBuffer());

    wsr.getSelfAttribute("item-id");
    if (is_checked) {
        try global.state_cache.?.add(wsr.getInputBuffer());
    } else {
        global.state_cache.?.remove(wsr.getInputBuffer());
    }

    try state.setState(arena.allocator(), try global.state_cache.?.toState(arena.allocator()));
}

fn htmlChecked(b: bool) []const u8 {
    if (b) return "checked" else return "";
}

const Rarity = enum {
    Epic,
    Legendary,
    Rare,
    Uncommon,
    Common,
};
fn rarityMap(rarity_s: []const u8) []const u8 {
    const rarity = std.meta.stringToEnum(Rarity, rarity_s) orelse return "common";
    return switch (rarity) {
        .Epic => "epic",
        .Legendary => "legendary",
        .Uncommon => "uncommon",
        .Rare => "rare",
        .Common => "common",
    };
}

// FIXME: Copy pasting URLs with different #states does not trigger a checkmark state update
