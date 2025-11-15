const wsr = @import("wsr");
const std = @import("std");
const state = @import("state.zig");

pub const returnErrorHook = wsr.returnErrorHook;

const ItemList = []const []const u8;

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
    onItemListFailable() catch unreachable;
}

fn onItemListFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    var output_html = std.Io.Writer.Allocating.init(arena.allocator());


    const items = try std.json.parseFromSliceLeaky(ItemList, arena.allocator(), wsr.getInputBuffer(), .{
        .ignore_unknown_fields = true,
    });
    for (items) |item| {
        try output_html.writer.print("<div item-name=\"{s}\", wsr-get=\"arcraiders-data/items/{s}.json\" wsr-call=\"onItemRetrieved\">{s}</div>", .{htmlEscape(item), urlEscape(item), htmlEscape(item)});
    }

    wsr.setSelfProperty(output_html.written(), "innerHTML");
}

const Translation = struct {
    en: []const u8,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Translation {
        if (try source.peekNextTokenType() == .string) {
            return .{
                .en = try std.json.innerParse([]const u8, allocator, source, options),
            };
        } else {
            const Tmp = struct {
                en: []const u8,
            };

            const ret = try std.json.innerParse(Tmp, allocator, source, options);
            return .{
                .en = ret.en,
            };
        }

    }
};

const Item = struct {
    id: []const u8,
    name: Translation,
  imageFilename: ?[]const u8 = null,

  const image_leading_string = "https://cdn.arctracker.io/";
  const image_replace_string = "arcraiders-data/images/";
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

pub export fn onItemRetrieved() void {
    onItemRetrievedFailable() catch |e| {
        wsr.print("Failed {t}\n", .{e});
        wsr.printCapturedBacktrace();
        unreachable;
    };
}

fn htmlChecked(b: bool) []const u8 {
    if (b) return "checked" else return "";
}

fn onItemRetrievedFailable() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    var output_html = std.Io.Writer.Allocating.init(arena.allocator());

    var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), wsr.getInputBuffer());
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    const item = std.json.parseFromTokenSourceLeaky(Item, arena.allocator(), &scanner, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |e| {
        wsr.print("{s}", .{wsr.getInputBuffer()});
        wsr.print("diagnostics {any}", .{diagnostics});
        return e;
    };

    const checked = global.state_cache.?.idTracked(item.id);

    if (std.mem.eql(u8, item.id, "damaged_arc_powercell",)) {
        wsr.print("Setting {s} as {}", .{item.id, checked});
    }
    try output_html.writer.print(
        \\<div>{s}</div>
        \\<input item-id="{s}" {s} type="checkbox" wsr-onevent="click" wsr-call="onItemClicked"/>
        , .{htmlEscape(item.name.en), htmlEscape(item.id), htmlChecked(checked), },
    );
    if (item.imageFilename) |f| {
        // FIXME: What to do when image is not present?
        try output_html.writer.print(
            \\<img src="{s}{s}"/>
        , .{Item.image_replace_string, urlEscape(f[Item.image_leading_string.len..])});
    } else {
    }

    wsr.setSelfProperty(output_html.written(), "innerHTML");
}

// FIXME: Copy pasting URLs with different #states does not trigger a checkmark state update
