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

    fn toggleTracked(self: *StateCache, s: []const u8) !bool {
        if (self.idTracked(s)) {
            self.remove(s);
            return false;
        } else {
            try self.add(s);
            return true;
        }
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

const ItemMap = std.StringHashMapUnmanaged(Item);

var global = struct {
    state_cache: ?StateCache = null,
    item_map: ItemMap = .{},
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

    for (items) |item| {
        // A little inefficient, but we parse the json into our temp allocator
        // because it will allocate more than we technically want to store. We
        // then copy into the real global alloc for the stuff we want to keep.
        // In reality it might be better to just over-allocate directly onto
        // the global alloc
        const duped = try item.dupe(std.heap.wasm_allocator);
        try global.item_map.put(
            std.heap.wasm_allocator,
            duped.id,
            duped,
        );
    }

    // FIXME: localstorage or URL based state
    //
    //
    // Share URL -> loadouts
    // Usually... use localstorage
    const s = try state.getState(arena.allocator());
    global.state_cache = try StateCache.fromState(s);

    var untracked_writer = std.Io.Writer.Allocating.init(arena.allocator());
    var tracked_writer = std.Io.Writer.Allocating.init(arena.allocator());
    try generateItemList(items, &untracked_writer.writer, &tracked_writer.writer);

    wsr.setElemProperty("untracked-items", untracked_writer.written(), "innerHTML");
    wsr.setElemProperty("tracked-items", tracked_writer.written(), "innerHTML");

    try regenerateComponents();
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

fn generateItemList(items: ItemList, untracked_writer: *std.Io.Writer, tracked_writer: *std.Io.Writer) !void {
    for (items) |item| {
        if (shouldSkipItem(item)) {
            continue;
        }

        const tracked = global.state_cache.?.idTracked(item.id);
        const writer = if (tracked) tracked_writer else untracked_writer;
        try writer.print(
            \\<div item-id="{[id]s}" wsr-onevent="click" wsr-call="onItemClicked" >
            \\  {[item_card]f}
            \\</div>
        , .{
                .id = htmlEscape(item.id),
                .item_card = ItemHtmlWidget { .item = item },
            },
        );
    }
}

const Component = struct {
    id: []const u8,
    quantity: u16,

    fn dupe(self: Component, alloc: std.mem.Allocator) !Component {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .quantity = self.quantity,
        };
    }
};

// FIXME: JSON repr != internal repr
//
// Convert rarity to enum
const Item = struct {
    id: []const u8 = &.{},
    item_type: []const u8,
    item_level: ?[]const u8,
    name: []const u8 = &.{},
    rarity: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    components: []Component,

    fn dupe(self: Item, alloc: std.mem.Allocator) !Item {
        const new_components = try alloc.alloc(Component, self.components.len);
        for (self.components, new_components) |old, *new| {
            new.* = try old.dupe(alloc);
        }

        return .{
            .id = try alloc.dupe(u8, self.id),
            .item_type = try alloc.dupe(u8, self.item_type),
            .item_level = if (self.item_level) |l| try alloc.dupe(u8, l) else null,
            .name = try alloc.dupe(u8, self.name),
            .rarity = if (self.rarity) |r| try alloc.dupe(u8, r) else null,
            .icon = if (self.icon) |i| try alloc.dupe(u8, i) else null,
            .components = new_components,
        };
    }
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

    wsr.getTargetAttribute("item-id");
    wsr.print("{s}", .{wsr.getInputBuffer()});

    const tracked = try global.state_cache.?.toggleTracked(wsr.getInputBuffer());

    const to_append_id = if (tracked) "tracked-items" else "untracked-items";

    // FIXME: Hide from untracked instead of remove to preserve sort order
    wsr.getTargetProperty("outerHTML");
    wsr.appendToElem(to_append_id, wsr.getInputBuffer());
    wsr.setTargetProperty("", "outerHTML");

    try regenerateComponents();

    try state.setState(arena.allocator(), try global.state_cache.?.toState(arena.allocator()));
}

const ComponentListBuilder = struct {
    quantities: std.StringHashMap(u32),

    fn addComponent(self: *ComponentListBuilder, item_id: []const u8, quantity: u32, multiplier: u32) !void {
        const gop = try self.quantities.getOrPut(item_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }

        gop.value_ptr.* += quantity * multiplier;

        const item = global.item_map.get(item_id).?;
        for (item.components) |component| {
            try self.addComponent(component.id, component.quantity, quantity);
        }
    }
};

fn regenerateComponents() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    var builder = ComponentListBuilder {
        .quantities = .init(arena.allocator()),
    };

    var tracked_item_it = global.state_cache.?.items.keyIterator();
    while (tracked_item_it.next()) |tracked_item_id| {
        const item = global.item_map.get(tracked_item_id.*).?;
        for (item.components) |component| {
            try builder.addComponent(component.id, component.quantity, 1);
        }
    }

    var component_writer = std.Io.Writer.Allocating.init(arena.allocator());

    var component_it = builder.quantities.iterator();
    while (component_it.next()) |kv| {
        const item = global.item_map.get(kv.key_ptr.*).?;
        if (shouldSkipItem(item)) continue;
        try component_writer.writer.print(
            \\<div class="component-item">
            \\<div class="item-quantity-overlay">{d}</div>
            \\{f}
            \\</div>
            , .{
            kv.value_ptr.*,
            ItemHtmlWidget { .item = item },
        });
        wsr.print("{s}: {d}", .{kv.key_ptr.*, kv.value_ptr.*});
    }

    wsr.setElemProperty("item-components", component_writer.written(), "innerHTML");
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
