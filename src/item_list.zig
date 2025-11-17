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

    var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), wsr.getInputBuffer());
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    const items = std.json.parseFromTokenSourceLeaky(ItemList, arena.allocator(), &scanner, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |e| {
        wsr.print("{any}", .{diagnostics});
        return e;
    };

    // FIXME: localstorage or URL based state
    //
    //
    // Share URL -> loadouts
    // Usually... use localstorage
    const s = try state.getState(arena.allocator());
    global.state_cache = try StateCache.fromState(s);

    var untracked_writer = std.Io.Writer.Allocating.init(arena.allocator());
    try generateItemList(items, &untracked_writer.writer);
    wsr.setElemProperty("untracked-items", untracked_writer.written(), "innerHTML");
}

fn urlEscape(s: []const u8) []const u8 {
    return s;
}

fn htmlEscape(s: []const u8) []const u8 {
    return s;
}

const ItemType = enum {
    weapon,
    blueprint,
    key,
    @"quest item",
    unknown,

    fn fromString(s: []const u8) ItemType {
        return std.meta.stringToEnum(ItemType, s) orelse ItemType.unknown;
    }
};

fn itemTypeToGunClass(s: []const u8) []const u8 {
    const item_type = std.meta.stringToEnum(ItemType, s) orelse ItemType.unknown;
    return switch (item_type) {
        .weapon => "is-gun",
        else => "",
    };
}

const ItemLevelOverlay = struct {
    level: ?[]const u8,

    pub fn format(self: ItemLevelOverlay, writer: *std.Io.Writer) !void {
        const level = self.level orelse return;

        try writer.print(
            \\<div class="item-level-overlay">{s}</div>
            , .{htmlEscape(level)});
    }
};
const ItemHtmlWidget = struct {
    item: Item,

    pub fn format(self: ItemHtmlWidget, writer: *std.Io.Writer) !void {
        try writer.print(
            \\<div class="item-card">
            \\  <img class="item-img {[gun_class]s}" src="images/{[id]s}.webp" title="{[name]s}"/>
            \\  {[item_level_overlay]f}
            \\  <img class="item-rarity-overlay" src="rarity-overlay-{[rarity]s}.png" title="{[name]s}"/>
            \\</div>
            , .{
                .id = htmlEscape(self.item.id),
                .item_level_overlay = ItemLevelOverlay { .level = self.item.item_level },
                .name = htmlEscape(self.item.name),
                .gun_class = itemTypeToGunClass(self.item.item_type),
                .rarity = htmlEscape(self.item.rarity orelse "uncommon"),
            }
        );
    }

};

fn shouldSkipItem(item: Item) bool {
    const item_type = ItemType.fromString(item.item_type);
    switch (item_type) {
        .weapon, .unknown => return false,
        .@"quest item", .key, .blueprint => return true,
    }
}

fn generateItemList(items: ItemList, untracked_writer: *std.Io.Writer) !void {
    for (items) |item| {

        if (shouldSkipItem(item)) {
            continue;
        }

        const tracked = global.state_cache.?.idTracked(item.id);
        try untracked_writer.print(
            \\<div item-name=\"{[id]s}\">
            \\  <input item-id="{[id]s}" {[checked]s} type="checkbox" wsr-onevent="click" wsr-call="onItemClicked"/>
            \\  {[item_card]f}
            \\</div>
        , .{
            .id = htmlEscape(item.id),
            .checked = htmlChecked(tracked),
            .item_card = ItemHtmlWidget { .item = item },
        },
        );
    }
}

const Item = struct {
    id: []const u8 = &.{},
    item_type: []const u8,
    item_level: ?[]const u8,
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
