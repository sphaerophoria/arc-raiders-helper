const wsr = @import("wsr");
const std = @import("std");
const state = @import("state.zig");

pub const returnErrorHook = wsr.returnErrorHook;

const ItemList = []const Item;

const imported = struct {
    pub extern fn toggleTargetClass(class_ptr: [*]const u8, class_len: usize) void;
};

const StateCache = struct {
    alloc: std.mem.Allocator,
    items: std.StringHashMapUnmanaged(void),
    stash_quantities: std.StringHashMapUnmanaged(u32),

    fn idTracked(self: StateCache, id: []const u8) bool {
        return self.items.contains(id);
    }

    fn removeItem(self: *StateCache, s: []const u8) void {
        const kv = self.items.fetchRemove(s) orelse return;
        self.alloc.free(kv.key);
    }

    fn addItem(self: *StateCache, s: []const u8) !void {
        const cloned = try self.alloc.dupe(u8, s);
        try self.items.put(self.alloc, cloned, {});
    }

    fn updateStashQuantity(self: *StateCache, s: []const u8, val: u32) !void {
        if (val == 0) {
            const kv = self.stash_quantities.fetchRemove(s) orelse return;
            self.alloc.free(kv.key);
            return;
        }

        const gop = try self.stash_quantities.getOrPut(self.alloc, s);

        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, s);
        }
        gop.value_ptr.* = val;
    }

    fn toggleTracked(self: *StateCache, s: []const u8) !bool {
        if (self.idTracked(s)) {
            self.removeItem(s);
            return false;
        } else {
            try self.addItem(s);
            return true;
        }
    }

    fn fromState(s: state.State) !StateCache {
        const alloc = std.heap.wasm_allocator;
        var ret = StateCache{
            .alloc = alloc,
            .items = std.StringHashMapUnmanaged(void){},
            .stash_quantities = std.StringHashMapUnmanaged(u32){},
        };

        for (s.tracked_items) |item| {
            try ret.addItem(item);
        }

        for (s.stash_quantities) |item| {
            try ret.updateStashQuantity(item.id, item.quantity);
        }

        return ret;
    }

    fn toState(self: StateCache, alloc: std.mem.Allocator) !state.State {
        var tracked_items = std.ArrayList([]const u8).initBuffer(try alloc.alloc([]const u8, self.items.count()));
        {
            var it = self.items.iterator();
            while (it.next()) |entry| {
                tracked_items.appendBounded(entry.key_ptr.*) catch unreachable;
            }
        }

        var stash_quantities = std.ArrayList(state.ItemQuantity).initBuffer(try alloc.alloc(state.ItemQuantity, self.stash_quantities.count()));
        {
            var it = self.stash_quantities.iterator();
            while (it.next()) |entry| {
                stash_quantities.appendBounded(.{
                    .id = entry.key_ptr.*,
                    .quantity = entry.value_ptr.*
                }) catch unreachable;
            }
        }

        return .{
            .tracked_items = tracked_items.items,
            .stash_quantities = stash_quantities.items,
        };
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

    const items = std.json.parseFromTokenSourceLeaky([]Item, arena.allocator(), &scanner, .{
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

    std.mem.sort(Item, items, {}, struct {

        fn f(_: void, a: Item , b: Item) bool {
            const a_category = ItemType.fromString(a.item_type);
            const b_category = ItemType.fromString(b.item_type);

            if (ItemType.lt(a_category, b_category)) |val|{
                return val;
            }

            const a_rarity = Rarity.fromString(a.rarity);
            const b_rarity = Rarity.fromString(b.rarity);
            if (a_rarity != b_rarity) {
                return enumLt(a_rarity, b_rarity);
            }

            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.f);

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
    augment,
    shield,
    weapon,
    ammunition,
    @"quick use",
    recyclable,
    @"refined material",
    material,
    @"basic material",
    trinket,
    blueprint,
    key,
    @"quest item",
    unknown,

    fn lt(a: ItemType, b: ItemType) ?bool {
        const a_modified = switch (a) {
            .recyclable, .@"refined material", .material => ItemType.recyclable,
            else => a,
        };
        const b_modified = switch (b) {
            .recyclable, .@"refined material", .material => ItemType.recyclable,
            else => b,
        };
        if (a_modified == b_modified) return null;
        return enumLt(a_modified, b_modified);
    }

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

const RuntimeFormatter = struct {
    const FormatFn =* const fn (ctx: ?*const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void;
    const empty = RuntimeFormatter{
        .ctx = null,
        .f = null,
    };

    ctx: ?*const anyopaque,
    f: ?FormatFn,

    pub fn format(self: RuntimeFormatter, writer: *std.Io.Writer) !void {
        const f = self.f orelse return;
        return f(self.ctx, writer);
    }
};

fn runtimeFormatFnWrapper(comptime T: type)  RuntimeFormatter.FormatFn {
    return struct {
        fn f(ctx: ?*const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const concrete: *const T = @ptrCast(@alignCast(ctx));
            try concrete.format(writer);
        }
    }.f;
}

fn makeRuntimeFormatter(ctx: anytype) RuntimeFormatter {
    return .{
        .ctx = ctx,
        .f = runtimeFormatFnWrapper(@TypeOf(ctx.*)),
    };
}

const ItemHtmlWidget = struct {
    item: Item,
    extra_data: RuntimeFormatter = .empty,

    pub fn format(self: ItemHtmlWidget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\<div class="item-card">
            \\  <div class="item-img-stack">
            \\    <img class="item-img {[gun_class]s}" src="images/{[id]s}.webp" title="{[name]s}"/>
            \\    {[item_level_overlay]f}
            \\    <img class="item-rarity-overlay" src="rarity-overlay-{[rarity]s}.png" title="{[name]s}"/>
            \\  </div>
            \\  <div class="item-extradata">
            \\    {[extra_data]f}
            \\  </div>
            \\</div>
            , .{
                .id = htmlEscape(self.item.id),
                .item_level_overlay = ItemLevelOverlay { .level = self.item.item_level },
                .name = htmlEscape(self.item.name),
                .gun_class = itemTypeToGunClass(self.item.item_type),
                .rarity = htmlEscape(self.item.rarity orelse "uncommon"),
                .extra_data = self.extra_data,
            }
        );
    }
};

const DragIntHtmlWidgetInner = struct {
    val: u32,

    pub fn format(self: DragIntHtmlWidgetInner, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\<div>{[val]d}</div>
            \\<div>
            \\  <div class="drag-int-up"></div>
            \\  <div class="drag-int-down"></div>
            \\</div>
            , self);
    }
};
const DragIntHtmlWidget = struct {
    val: u32,
    on_drag: []const u8,
    extra_attrs: RuntimeFormatter,

    pub fn format(self: DragIntHtmlWidget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const inner = DragIntHtmlWidgetInner {
            .val = self.val,
        };
        try writer.print(
            \\<div class="drag-int" {[extra_attrs]f} onmousedown="startDrag(event, &quot;{[on_drag]s}&quot;)">
            \\  {[inner]f}
            \\</div>
            , .{
                .on_drag = self.on_drag,
                .extra_attrs = self.extra_attrs,
                .inner =makeRuntimeFormatter(&inner),
            });

    }
};

fn shouldSkipItem(item: Item) bool {
    const item_type = ItemType.fromString(item.item_type);
    switch (item_type) {
        .@"basic material", .recyclable, .augment, .shield, .ammunition, .@"quick use", .weapon, .@"refined material", .material, .trinket, .unknown => return false,
        .@"quest item", .key, .blueprint => return true,
    }
}

fn makeTrackedItem(item: Item, writer: *std.Io.Writer) !void {
    try writer.print(
        \\<div id="{[id]s}-tracked" item-id="{[id]s}" wsr-onevent="click" wsr-call="onTrackedItemClicked" >
        \\  {[item_card]f}
        \\</div>
    , .{
            .id = htmlEscape(item.id),
            .item_card = ItemHtmlWidget { .item = item },
        },
    );
}

fn generateItemList(items: ItemList, untracked_writer: *std.Io.Writer, tracked_writer: *std.Io.Writer) !void {
    for (items) |item| {
        if (shouldSkipItem(item)) {
            continue;
        }

        const tracked = global.state_cache.?.idTracked(item.id);

        const hidden_style = if (tracked) "display: none" else "";

        try untracked_writer.print(
            \\<div id="{[id]s}-untracked" style="{[hidden_style]s}" item-id="{[id]s}" wsr-onevent="click" wsr-call="onUntrackedItemClicked" >
            \\  {[item_card]f}
            \\</div>
        , .{
                .id = htmlEscape(item.id),
                .item_card = ItemHtmlWidget { .item = item },
                .hidden_style = hidden_style,
            },
        );

        if (tracked) {
            try makeTrackedItem(item, tracked_writer);
        }
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

pub export fn onTrackedItemClicked() void {
    onTrackedItemClickedFailable() catch |e| {
        wsr.print("{t}\n", .{e});
        if (@errorReturnTrace()) |t| {
            wsr.print("trace: {any}", .{t});
        }
        unreachable;
    };
}

fn onTrackedItemClickedFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    wsr.getTargetAttribute("item-id");
    global.state_cache.?.removeItem(wsr.getInputBuffer());

    wsr.setTargetProperty("", "outerHTML");

    const untracked_dom_id = try std.fmt.allocPrint(arena.allocator(), "{s}-untracked", .{wsr.getInputBuffer()});
    wsr.setElemAttribute(untracked_dom_id, "", "style");

    try regenerateComponents();
    try state.setState(arena.allocator(), try global.state_cache.?.toState(arena.allocator()));
}

pub export fn onUntrackedItemClicked() void {
    onUntrackedItemClickedFailable() catch |e| {
        wsr.print("{t}\n", .{e});
        if (@errorReturnTrace()) |t| {
            wsr.print("trace: {any}", .{t});
        }
        unreachable;
    };
}

fn onUntrackedItemClickedFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    wsr.getTargetAttribute("item-id");
    try global.state_cache.?.addItem(wsr.getInputBuffer());

    var writer = std.Io.Writer.Allocating.init(arena.allocator());

    const item = global.item_map.get(wsr.getInputBuffer()) orelse return error.InvalidItem;
    try makeTrackedItem(item, &writer.writer);
    wsr.appendToElem("tracked-items", writer.written());

    wsr.setTargetAttribute("display: none;", "style");

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
            try self.addComponent(component.id, component.quantity, quantity * multiplier);
        }
    }
};

const ComponentConfigurationWidget = struct {
    item_id: []const u8,
    desired_quantity: u32,
    stash_size: u32,

    pub fn format(self: ComponentConfigurationWidget, writer: *std.Io.Writer) !void {
        const DragAttrs = struct {
            item_id: []const u8,

            pub fn format(ctx: @This(), w: *std.Io.Writer) !void {
                try w.print(
                    \\item-id="{[item_id]s}" id="{[item_id]s}-stash-amount"
                , ctx);
            }
        };

        const drag_attrs = DragAttrs{
            .item_id = self.item_id,
        };

        // FIXME: Inline styling here is stupid
        try writer.print(
            \\<div>
            \\  <div style="display:flex; align-items: center">
            \\    <div style="flex-grow: 1;">Stash: </div>
            \\    {[drag]f}
            \\  </div>
            \\  <div style="display:flex; align-items: center">
            \\    <div style="flex-grow: 1;">Need: </div>
            \\    <div>{[desired_quantity]d}</div>
            \\  </div>
            \\</div>
            , .{
                .desired_quantity = self.desired_quantity,
                .drag = DragIntHtmlWidget {
                    .val = self.stash_size,
                    .on_drag = "onStashSizeDrag",
                    .extra_attrs = makeRuntimeFormatter(&drag_attrs),
                },
            });
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

        const stash_quantity = global.state_cache.?.stash_quantities.get(kv.key_ptr.*) orelse 0;

        const extra_data = ComponentConfigurationWidget{
            .item_id = item.id,
            .stash_size = stash_quantity,
            .desired_quantity = kv.value_ptr.*,
        };

        try component_writer.writer.print(
            \\<div class="component-item">
            \\  {[image_widget]f}
            \\</div>
            , .{
                .image_widget = ItemHtmlWidget { .item = item, .extra_data = makeRuntimeFormatter(&extra_data) },
        });
    }

    wsr.setElemProperty("item-components", component_writer.written(), "innerHTML");
}

pub export fn updateStashAmount() void {
    updateStashAmountFailable() catch |e| {
        wsr.print("{t}", .{e});
        wsr.printCapturedBacktrace();
        unreachable;
    };
}

fn sliderValToQuantity(input_val: f32) u32 {
    // Wolframalpha looking at exp(x) graphs in ranges till the shape looks reasonable
    const max_exp = std.math.exp(100.0 / 20.0) - 1;
    const max_val = 1000.0;
    var val = std.math.exp(input_val / 20.0) - 1;
    val *= max_val / max_exp;

    // quantity = (exp(slider_val / 20) - 1) * max_val / max_exp
    // ln(max_exp * quantity / max_val + 1) * 20
    return @intFromFloat(val);
}

fn quantityToSliderVal(quantity: f32) f32 {
    // FIXME: Duped with above
    const max_exp = std.math.exp(100.0 / 20.0) - 1;
    const max_val = 1000.0;

    return std.math.log(f32, std.math.e, max_exp * quantity / max_val + 1) * 20.0;
}

pub fn updateStashAmountFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    wsr.getTargetProperty("value");

    wsr.print("{s}", .{wsr.getInputBuffer()});
    // [0, 100]
    const input_val: f32 = try std.fmt.parseFloat(f32, wsr.getInputBuffer());

    // Wolframalpha looking at exp(x) graphs in ranges till the shape looks reasonable
    const max_exp = std.math.exp(100.0 / 20.0) - 1;
    const max_val = 1000.0;
    var val = std.math.exp(input_val / 20.0) - 1;
    val *= max_val / max_exp;

    const val_i: u32 = @intFromFloat(val);

    var new_html = std.Io.Writer.Allocating.init(arena.allocator());
    try new_html.writer.print("{d}", .{val_i});

    wsr.getTargetAttribute("to-update");
    wsr.setElemProperty(wsr.getInputBuffer(), new_html.written(), "innerHTML");

    wsr.getTargetAttribute("item-id");
    try global.state_cache.?.updateStashQuantity(wsr.getInputBuffer(), val_i);
    try state.setState(arena.allocator(), try global.state_cache.?.toState(arena.allocator()));
}

fn htmlChecked(b: bool) []const u8 {
    if (b) return "checked" else return "";
}

const Rarity = enum {
    epic,
    legendary,
    rare,
    uncommon,
    common,
    unknown,

    fn fromString(s: ?[]const u8) Rarity {
        if (s == null) return .unknown;
        return std.meta.stringToEnum(Rarity, s.?) orelse return .unknown;
    }
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

export fn onStashSizeDrag() void {
    onStashSizeDragFailable() catch |e| {
        wsr.print("{t}", .{e});
        wsr.printCapturedBacktrace();
        unreachable;
    };
}

fn onStashSizeDragFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    wsr.getEventProperty("initialVal");
    const initial_val = try std.fmt.parseFloat(f32, wsr.getInputBuffer());

    wsr.getEventProperty("dragStart");
    const start_mouse_y = try std.fmt.parseFloat(f32, wsr.getInputBuffer());

    wsr.getEventProperty("clientY");
    const mouse_y = try std.fmt.parseFloat(f32, wsr.getInputBuffer());

    wsr.getEventProperty("movementY");
    const mouse_movement = mouse_y - start_mouse_y;

    var size_buf: [150]u8 = undefined;
    var writer = std.Io.Writer.fixed(&size_buf);

    const val: u32 = @intFromFloat(@max(0, initial_val - mouse_movement));
    try writer.print("{f}", .{DragIntHtmlWidgetInner{
        .val = val,
    }});

    wsr.setTargetProperty(writer.buffered(), "innerHTML");

    wsr.getTargetAttribute("item-id");
    try global.state_cache.?.updateStashQuantity(wsr.getInputBuffer(), val);
    try state.setState(arena.allocator(), try global.state_cache.?.toState(arena.allocator()));
}

// FIXME: Copy pasting URLs with different #states does not trigger a checkmark state update

fn enumLt(a: anytype, b: @TypeOf(a)) bool {
    // FIXME: Deduce backing type of enum
    return @as(u32, @intFromEnum(a)) < @as(u32, @intFromEnum(b));

}
