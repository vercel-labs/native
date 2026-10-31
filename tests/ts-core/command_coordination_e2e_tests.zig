const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const platform = native_sdk.platform;
const policy = native_sdk.runtime.testing.command_policy;
const services = native_sdk.runtime.testing.command_services;
const reference = @import("command_reference.zig");
const complete = @import("surface_layout_e2e_tests.zig").expectComplete;

fn catalogEqual(commands: []const native_sdk.Command) !void {
    const expected: ?anyerror = if (native_sdk.app_manifest.validateCommands(commands)) |_| null else |err| err;
    const actual: ?anyerror = if (policy.catalog(core.nativeWindowPolicy, commands)) |_| null else |err| err;
    try std.testing.expectEqual(expected, actual);
    core.rt.frameReset();
}

test "compiled command catalogs preserve all raw field bounds and native error distinctions" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [129]u8 = undefined;
    for (0..256) |raw| {
        @memset(&bytes, @intCast(raw));
        for ([_]usize{ 0, 1, 2, 127, 128, 129 }) |length| {
            try catalogEqual(&.{.{ .id = bytes[0..length], .title = "" }});
            try catalogEqual(&.{.{ .id = "app.sync", .title = bytes[0..length], .enabled = false, .checked = true }});
        }
    }
    for ([_][]const u8{ ".", "..", "a..b", "a\n/b", "a\t\x00", "a\n\\b", "a\rb", "\xff", " " }) |id| try catalogEqual(&.{.{ .id = id }});
}

test "compiled command catalogs retain maximum transport duplicate ordering and borrowed descriptors" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var ids: [256][128]u8 = @splat(@splat('x'));
    const title: [129]u8 = @splat('T');
    var rows: [257]native_sdk.Command = undefined;
    for (rows[0..256], &ids, 0..) |*row, *id, slot| {
        _ = try std.fmt.bufPrint(id, "cmd.{x:0>4}", .{slot});
        row.* = .{ .id = id, .title = title[0..128], .enabled = slot % 2 == 0, .checked = slot % 3 == 0 };
    }
    try catalogEqual(rows[0..256]);
    for (rows[0..256], &ids) |row, *id| {
        try std.testing.expectEqual(@intFromPtr(id), @intFromPtr(row.id.ptr));
        try std.testing.expectEqual(@intFromPtr(&title), @intFromPtr(row.title.ptr));
        try std.testing.expectEqualSlices(u8, id, row.id);
    }
    rows[256] = .{ .id = "", .title = &title };
    try catalogEqual(&rows); // Excess count precedes every row field.
    rows[255].id = rows[0].id;
    try catalogEqual(rows[0..256]);
    rows[255].title = &title; // Invalid title precedes this duplicate.
    try catalogEqual(rows[0..256]);
    rows[0].title = "\x00";
    rows[255].id = ""; // Earlier row failure precedes later invalid ID.
    try catalogEqual(rows[0..256]);
    try catalogEqual(&.{ .{ .id = "\xff" }, .{ .id = "\xff" } });
}

test "compiled command startup admits declarations before OS configuration and app callbacks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Probe = struct {
        var calls: usize = 0;
        fn configure(_: ?*anyopaque, _: native_sdk.security.Policy) !void {
            calls += 1;
            return error.ReachedOsConfiguration;
        }
    };
    const rows = [_]native_sdk.Command{ .{ .id = "app.sync", .title = "Sync" }, .{ .id = "app.sync", .title = "Duplicate" } };
    for ([_]bool{ false, true }) |compiled| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        Probe.calls = 0;
        harness.runtime.options.platform.services.configure_security_policy_fn = Probe.configure;
        harness.runtime.options.commands = &rows;
        var probe = RuntimeProbe{ .compiled = compiled };
        try std.testing.expectError(error.DuplicateCommand, harness.runtime.run(probe.app()));
        try std.testing.expectEqual(@as(usize, 0), Probe.calls);
        try std.testing.expectEqual(@as(usize, 0), probe.count);
        harness.runtime.options.commands = rows[0..1];
        try std.testing.expectError(error.ReachedOsConfiguration, harness.runtime.run(probe.app()));
        try std.testing.expectEqual(@as(usize, 1), Probe.calls);
        try std.testing.expectEqual(@as(usize, 0), probe.count);
        // run() must select the app callback even before app_start installs it.
        try std.testing.expect(harness.runtime.command_policy == null);
    }
}

test "compiled command registry initialization preserves untouched bulk storage" {
    const runtime = try std.testing.allocator.create(native_sdk.Runtime);
    defer std.testing.allocator.destroy(runtime);
    @memset(std.mem.asBytes(&runtime.status_items), 0xa5);
    var host = platform.NullPlatform.init(.{});
    defer host.deinit();
    native_sdk.Runtime.initAt(runtime, .{ .platform = host.platform(), .allocator = std.testing.allocator });
    defer runtime.deinit();
    for (&runtime.status_items) |*item| {
        try std.testing.expect(!item.active);
        try std.testing.expect(item.visible);
        try std.testing.expectEqual(@as(platform.StatusItemId, 0), item.id);
        try std.testing.expectEqual(@as(usize, 0), item.title.len);
        try std.testing.expectEqual(@as(usize, 0), item.item_count);
        for (std.mem.asBytes(&item.items)) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
}

test "compiled command dispatch preserves raw bytes reserved names and borrowed bridge labels" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [129]u8 = undefined;
    for (0..256) |raw| for ([_]usize{ 0, 1, 2, 127, 128, 129 }) |length| {
        @memset(&bytes, @intCast(raw));
        try complete(reference.dispatch(bytes[0..length]), policy.dispatch(core.nativeWindowPolicy, bytes[0..length]));
        core.rt.frameReset();
    };
    for ([_][]const u8{ ".", "..", "a..b", "app.check-for-updates", "app.check-for-updates ", "\xff\x00", "main", "main\x00", "Main", "", "aux\xff" }) |name| {
        try complete(reference.dispatch(name), policy.dispatch(core.nativeWindowPolicy, name));
        const label = policy.bridgeLabel(core.nativeWindowPolicy, name);
        try complete(reference.bridgeLabel(name), label);
        if (label.len > 0) try std.testing.expectEqual(name.ptr, label.ptr);
        core.rt.frameReset();
    }
    @memset(&bytes, 'x');
    for (0..128) |at| for ([_]u8{ 0, '\t', '\n', '\r', '/', '\\', 0xff }) |byte| {
        bytes[at] = byte;
        try complete(reference.dispatch(bytes[0..128]), policy.dispatch(core.nativeWindowPolicy, bytes[0..128]));
        bytes[at] = 'x';
        core.rt.frameReset();
    };
}

test "compiled command toolbar ancestry preserves exact identity first match closure and cycles" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const View = struct { open: bool = true, window_id: platform.WindowId = 9007199254740993, kind: platform.ViewKind = .button, label: []const u8, parent: ?[]const u8 = null };
    var labels: [32][1]u8 = undefined;
    var views: [32]View = undefined;
    for (&views, &labels, 0..) |*view, *label, i| {
        label[0] = @intCast(i + 128);
        view.* = .{ .label = label, .parent = if (i > 0) &labels[i - 1] else null };
    }
    for (0..32) |toolbar| {
        views[toolbar].kind = .toolbar;
        for (0..32) |start| {
            try complete(reference.toolbar(&views, 9007199254740993, &labels[start]), policy.nativeViewSource(core.nativeWindowPolicy, &views, 9007199254740993, &labels[start]));
            try complete(reference.toolbar(&views, 9007199254740992, &labels[start]), policy.nativeViewSource(core.nativeWindowPolicy, &views, 9007199254740992, &labels[start]));
            core.rt.frameReset();
        }
        views[toolbar].kind = .button;
    }
    views[0].parent = &labels[31];
    for ([_]platform.WindowId{ 0, 9007199254740993, std.math.maxInt(u64) }) |window| for (0..32) |start| {
        try complete(reference.toolbar(&views, window, &labels[start]), policy.nativeViewSource(core.nativeWindowPolicy, &views, window, &labels[start]));
        core.rt.frameReset();
    };
    views[0].open = false;
    views[1].label = views[0].label;
    views[1].kind = .toolbar;
    try complete(reference.toolbar(&views, 9007199254740993, &labels[0]), policy.nativeViewSource(core.nativeWindowPolicy, &views, 9007199254740993, &labels[0]));
    views[0].open = true;
    try complete(reference.toolbar(&views, 9007199254740993, &labels[0]), policy.nativeViewSource(core.nativeWindowPolicy, &views, 9007199254740993, &labels[0]));
}

test "compiled command menu selection preserves independent duplicate and segmented rules" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const options = [_]platform.TraySegmentOption{ .{ .id = 7, .label = "first", .command = "", .enabled = false }, .{ .id = std.math.maxInt(u32), .label = "second", .command = "segment\xff", .enabled = true } };
    var items = [_]platform.TrayMenuItem{ .{ .id = 7, .label = "row\x00", .command = "", .segmented = .{ .options = &options } }, .{ .id = 7, .label = "duplicate", .command = "later" } };
    inline for (@typeInfo(platform.TrayItemRole).@"enum".fields) |role| for ([_]bool{ false, true }) |separator| for ([_]bool{ false, true }) |enabled| for ([_][]const u8{ "", "row\xff" }) |command| {
        items[0].role = @enumFromInt(role.value);
        items[0].separator = separator;
        items[0].enabled = enabled;
        items[0].command = command;
        for ([_]platform.TrayItemId{ 0, 7, 8, std.math.maxInt(u32) }) |id| {
            try complete(reference.menu(&items, id), policy.menu(core.nativeWindowPolicy, &items, id));
            core.rt.frameReset();
        }
    };
    var full: [32]platform.TrayMenuItem = undefined;
    for (&full, 0..) |*row, i| row.* = .{ .id = @intCast(i), .label = "", .command = if (i % 2 == 0) "even" else "", .segmented = .{ .options = &options } };
    for (0..34) |id| {
        try complete(reference.menu(&full, @intCast(id)), policy.menu(core.nativeWindowPolicy, &full, @intCast(id)));
        core.rt.frameReset();
    }
}

test "compiled command status admission preserves every occupancy mask and retained duplicate" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Entry = struct { active: bool, id: platform.StatusItemId };
    var slots: [8]Entry = undefined;
    for (0..256) |mask| for ([_]usize{ 0, 7, 8 }) |count| for ([_]bool{ false, true }) |admit| {
        for (&slots, 0..) |*entry, i| entry.* = .{ .active = mask & (@as(usize, 1) << @intCast(i)) != 0, .id = if (i == 0) 0 else if (i == 7) std.math.maxInt(u32) else @intCast(i) };
        for ([_]platform.StatusItemId{ 0, 1, 6, 8, std.math.maxInt(u32) }) |id| {
            try complete(reference.slot(&slots, id, admit, count), policy.slot(core.nativeWindowPolicy, &slots, id, admit, count));
            core.rt.frameReset();
        }
    };
    for (&slots) |*entry| entry.* = .{ .active = true, .id = 7 };
    try complete(reference.slot(&slots, 7, true, 8), policy.slot(core.nativeWindowPolicy, &slots, 7, true, 8));
}

const RuntimeProbe = struct {
    const Record = struct { name: [128]u8 = @splat(0), name_len: usize = 0, source: native_sdk.CommandSource = .runtime, window: platform.WindowId = 0, label: [64]u8 = @splat(0), label_len: usize = 0, status: platform.StatusItemId = 0, item: platform.TrayItemId = 0 };
    records: [32]Record = @splat(.{}),
    count: usize = 0,
    shortcuts: usize = 0,
    compiled: bool,
    fn app(self: *@This()) native_sdk.App {
        return .{ .context = self, .name = "command-parity", .source = platform.WebViewSource.html("<p>Commands</p>"), .event_fn = event, .command_policy = if (self.compiled) core.nativeWindowPolicy else null };
    }
    fn event(context: *anyopaque, _: *native_sdk.Runtime, value: native_sdk.Event) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (value) {
            .command => |command| {
                const record = &self.records[self.count];
                self.count += 1;
                @memcpy(record.name[0..command.name.len], command.name);
                record.name_len = command.name.len;
                @memcpy(record.label[0..command.view_label.len], command.view_label);
                record.label_len = command.view_label.len;
                record.source = command.source;
                record.window = command.window_id;
                record.status = command.status_item_id;
                record.item = command.tray_item_id;
            },
            .shortcut => self.shortcuts += 1,
            else => {},
        }
    }
};
fn runtimeEqual(left: anytype, right: @TypeOf(left), probes: *[2]RuntimeProbe) !void {
    try complete(probes[0].records, probes[1].records);
    try complete(probes[0].count, probes[1].count);
    try complete(probes[0].shortcuts, probes[1].shortcuts);
    try complete(left.runtime.automationSnapshot("command-parity"), right.runtime.automationSnapshot("command-parity"));
    try complete(left.runtime.status_item_count, right.runtime.status_item_count);
    for (&left.runtime.status_items, &right.runtime.status_items) |*a, *b| {
        try complete(a.active, b.active);
        try complete(a.id, b.id);
        try complete(a.visible, b.visible);
        try complete(a.title, b.title);
        try complete(a.items[0..a.item_count], b.items[0..b.item_count]);
        inline for (.{ a, b }) |item| {
            if (item.title.len > 0) try std.testing.expectEqual(@intFromPtr(item.title_storage[0..].ptr), @intFromPtr(item.title.ptr));
            for (item.items[0..item.item_count]) |*row| {
                inline for (.{ "command", "label", "detail", "key" }) |field| {
                    const bytes = @field(row, field);
                    if (bytes.len > 0) try std.testing.expectEqual(@intFromPtr(@field(row, field ++ "_storage")[0..].ptr), @intFromPtr(bytes.ptr));
                }
                if (row.segmented) |segment| {
                    try std.testing.expectEqual(@intFromPtr(row.segment_options[0..].ptr), @intFromPtr(segment.options.ptr));
                    for (segment.options, 0..) |option, index| {
                        if (option.label.len > 0) try std.testing.expectEqual(@intFromPtr(row.segment_option_label_storage[index][0..].ptr), @intFromPtr(option.label.ptr));
                        if (option.command.len > 0) try std.testing.expectEqual(@intFromPtr(row.segment_option_command_storage[index][0..].ptr), @intFromPtr(option.command.ptr));
                    }
                }
            }
        }
    }
    try complete(left.null_platform.lastBridgeResponse(), right.null_platform.lastBridgeResponse());
    try complete(left.null_platform.lastBridgeResponseWindowId(), right.null_platform.lastBridgeResponseWindowId());
    try complete(left.null_platform.lastBridgeResponseWebViewLabel(), right.null_platform.lastBridgeResponseWebViewLabel());
    core.rt.frameReset();
}
test "compiled command runtime preserves full source records snapshots registry ownership and failures" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const left = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer left.destroy(std.testing.allocator);
    const right = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer right.destroy(std.testing.allocator);
    const harnesses = .{ left, right };
    var probes = [_]RuntimeProbe{ .{ .compiled = false }, .{ .compiled = true } };
    const policies = [_]native_sdk.BridgeCommandPolicy{ .{ .name = "native-sdk.command.invoke", .origins = &.{"zero://inline"} }, .{ .name = "native-sdk.command.list", .origins = &.{"zero://inline"} } };
    const catalog = [_]native_sdk.Command{ .{ .id = "app.sync", .title = "Sync" }, .{ .id = "app.other", .title = "Other", .enabled = false, .checked = true } };
    const segments = [_]platform.TraySegmentOption{ .{ .id = 11, .label = "On", .command = "app.on" }, .{ .id = 12, .label = "Off", .command = "app.off", .enabled = false } };
    var command = "app.sync".*;
    const items = [_]platform.TrayMenuItem{ .{ .id = 7, .label = "Sync", .command = &command }, .{ .id = 8, .label = "Disabled", .enabled = false }, .{ .role = .segmented, .segmented = .{ .options = &segments } } };
    inline for (harnesses, 0..) |harness, lane| {
        // Disable wall-clock uptime in this deterministic headless fixture.
        // Complete snapshots still compare every diagnostic field unchanged.
        harness.runtime.started_timestamp_ns = 0;
        // Unused native payload buffers deliberately have no runtime defaults.
        // Seed fixture bytes so complete retained-row comparisons also cover
        // unused backing capacity without traversing undefined slice headers.
        for (&harness.runtime.status_items) |*item| {
            @memset(&item.title_storage, 0);
            @memset(std.mem.asBytes(&item.items), 0);
        }
        harness.runtime.options.builtin_bridge = .{ .enabled = true, .commands = &policies };
        harness.runtime.options.commands = &catalog;
        harness.runtime.options.security.navigation.allowed_origins = &.{"zero://inline"};
        // Observe command/registry state before requesting presentation.
        try harness.runtime.dispatchPlatformEvent(probes[lane].app(), .app_start);
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "toolbar", .kind = .toolbar, .frame = .init(0, 0, 200, 40) });
        _ = try harness.runtime.createView(.{ .window_id = 1, .label = "button", .parent = "toolbar", .kind = .button, .frame = .init(5, 5, 90, 25) });
        try harness.runtime.createStatusItem(std.math.maxInt(u32), .{ .title = "Commands", .items = &items });
    }
    @memset(&command, 'x'); // retained command storage must be independent
    try runtimeEqual(left, right, &probes);
    const events = [_]platform.Event{
        .{ .native_command = .{ .name = "app.sync", .window_id = 1, .view_label = "button" } },
        .{ .native_command = .{ .name = "app.sync", .window_id = std.math.maxInt(u64), .view_label = "button" } },
        .{ .menu_command = .{ .name = "app.sync", .window_id = 1 } },
        .{ .tray_action = .{ .status_item_id = std.math.maxInt(u32), .item_id = 7 } },
        .{ .tray_action = .{ .status_item_id = std.math.maxInt(u32), .item_id = 11 } },
        .{ .tray_command = .{ .name = "app.direct", .status_item_id = std.math.maxInt(u32), .window_id = 1 } },
        .{ .notification_command = .{ .name = "app.notice", .window_id = 1 } },
        .{ .shortcut = .{ .id = "app.sync", .key = "s", .window_id = 1, .modifiers = .{ .primary = true } } },
        .{ .bridge_message = .{ .bytes = "{\"id\":\"invoke\",\"command\":\"native-sdk.command.invoke\",\"payload\":{\"name\":\"app.sync\",\"id\":\"ignored\"}}", .origin = "zero://inline", .window_id = 1, .webview_label = "main" } },
        .{ .bridge_message = .{ .bytes = "{\"id\":\"list\",\"command\":\"native-sdk.command.list\",\"payload\":{}}", .origin = "zero://inline", .window_id = 1, .webview_label = "main" } },
        .{ .bridge_message = .{ .bytes = "{\"id\":\"invalid\",\"command\":\"native-sdk.command.invoke\",\"payload\":{\"name\":\"a/b\"}}", .origin = "zero://inline", .window_id = 1, .webview_label = "main" } },
    };
    for (events) |event| {
        inline for (harnesses, 0..) |harness, lane| try harness.runtime.dispatchPlatformEvent(probes[lane].app(), event);
        try runtimeEqual(left, right, &probes);
    }
    try std.testing.expectEqual(native_sdk.CommandSource.toolbar, probes[1].records[0].source);
    try std.testing.expectEqualStrings("app.sync", probes[1].records[3].name[0..probes[1].records[3].name_len]);
    inline for (harnesses, 0..) |harness, lane| {
        try std.testing.expectError(error.InvalidCommand, harness.runtime.dispatchCommand(probes[lane].app(), .{ .name = ".." }));
        try harness.runtime.dispatchCommand(probes[lane].app(), .{ .name = platform.update_check_command });
    }
    try runtimeEqual(left, right, &probes);
    const UpdateService = struct {
        var fail: bool = false;
        var calls: usize = 0;
        fn check(_: ?*anyopaque, user_initiated: bool) !void {
            try std.testing.expect(user_initiated);
            calls += 1;
            if (fail) return error.UpdaterFailed;
        }
    };
    UpdateService.calls = 0;
    const before = probes[0].count;
    for ([_]bool{ false, true }) |fail| {
        UpdateService.fail = fail;
        inline for (harnesses, 0..) |harness, lane| {
            harness.runtime.options.platform.services.check_for_updates_fn = UpdateService.check;
            if (fail) try std.testing.expectError(error.UpdaterFailed, harness.runtime.dispatchCommand(probes[lane].app(), .{ .name = platform.update_check_command })) else try harness.runtime.dispatchCommand(probes[lane].app(), .{ .name = platform.update_check_command });
        }
        try runtimeEqual(left, right, &probes);
    }
    try std.testing.expectEqual(@as(usize, 4), UpdateService.calls);
    try std.testing.expectEqual(before, probes[0].count);
    for ([_]platform.TrayItemId{ 0, 7, 8, 11, 12, 99 }) |id| {
        try complete(services.statusItemMenuItemExists(&left.runtime, std.math.maxInt(u32), id), services.statusItemMenuItemExists(&right.runtime, std.math.maxInt(u32), id));
        try complete(services.statusItemMenuItemActionable(&left.runtime, std.math.maxInt(u32), id), services.statusItemMenuItemActionable(&right.runtime, std.math.maxInt(u32), id));
        try complete(services.statusItemCommandNameForItem(&left.runtime, std.math.maxInt(u32), id), services.statusItemCommandNameForItem(&right.runtime, std.math.maxInt(u32), id));
        core.rt.frameReset();
    }
    inline for (harnesses) |harness| try harness.runtime.updateStatusItemMenu(std.math.maxInt(u32), &.{.{ .id = 9, .label = "New", .command = "app.new" }});
    try runtimeEqual(left, right, &probes);
    inline for (harnesses) |harness| try harness.runtime.updateStatusItemTitle(std.math.maxInt(u32), "Changed");
    try runtimeEqual(left, right, &probes);
    // Rejected declarations never mutate retained registry storage. Validation
    // precedes lookup, occupancy and platform execution on every patch seam.
    const oversized_title: [65]u8 = @splat('A');
    inline for (harnesses) |harness| {
        try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.createStatusItem(0, .{ .title = &oversized_title }));
        try std.testing.expectError(error.TrayFieldTooLarge, harness.runtime.createStatusItem(std.math.maxInt(u32), .{ .title = &oversized_title }));
        try std.testing.expectError(error.InvalidCommand, harness.runtime.updateStatusItemShell(std.math.maxInt(u32), .{ .activation_command = "a/b" }));
        try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateStatusItemMenu(std.math.maxInt(u32), &.{.{ .role = .segmented, .segmented = .{} }}));
        try std.testing.expectError(error.TrayFieldTooLarge, harness.runtime.updateStatusItemTitle(99, &oversized_title));
        try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.updateStatusItemPresentation(99, .{ .width = std.math.nan(f32) }));
        try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.removeStatusItem(0));
    }
    try runtimeEqual(left, right, &probes);
    for (0..2) |_| {
        inline for (harnesses) |harness| try harness.runtime.removeStatusItem(std.math.maxInt(u32));
        try runtimeEqual(left, right, &probes);
    }
    for (1..9) |id| {
        inline for (harnesses) |harness| try harness.runtime.createStatusItem(@intCast(id), .{ .title = "Full" });
        try runtimeEqual(left, right, &probes);
    }
    inline for (harnesses) |harness| {
        try std.testing.expectError(error.InvalidTrayOptions, harness.runtime.createStatusItem(9, .{ .title = "Overflow" }));
        try harness.runtime.createStatusItem(3, .{ .title = "Retained" });
    }
    try runtimeEqual(left, right, &probes);
    inline for (harnesses) |harness| try harness.runtime.removeStatusItem(2);
    try runtimeEqual(left, right, &probes);
    inline for (harnesses) |harness| try harness.runtime.createStatusItem(9, .{ .title = "Reused" });
    try runtimeEqual(left, right, &probes);
    try std.testing.expectEqual(@as(platform.StatusItemId, 9), right.runtime.status_items[1].id);
}
