//! Native scroll driver tests: the runtime publishes per-region
//! drivers to the platform, follows driver-reported offsets (including
//! rubber-band overscroll), pushes runtime-side offset changes back, and
//! keeps the rebuild reconciliation invariant. The null platform records
//! the pushed driver sets behind the opt-in
//! `gpu_surface_scroll_drivers` flag.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;
const testCanvasWidgetPartId = support.testCanvasWidgetPartId;

const PassiveApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "scroll-drivers", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
    }
};

fn scrollFixtureLayout(nodes: []canvas.WidgetLayoutNode, offset: f32) !canvas.WidgetLayoutTree {
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = offset,
        .children = &children,
    };
    return canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), nodes);
}

test "layout install publishes native scroll drivers and suppresses engine scrollbars" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 24);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // The install pushed one driver: region frame, rebased content extent
    // (viewport 72, content 120 -> max offset 48 -> content height 120),
    // the source offset, and the set-offset flags (a fresh driver
    // adopts both axes).
    try std.testing.expect(harness.null_platform.scroll_driver_set_count >= 1);
    try std.testing.expectEqualStrings("canvas", harness.null_platform.scrollDriverLabel());
    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 1), drivers.len);
    try std.testing.expectEqual(@as(u64, 1), drivers[0].id);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 180, 72), drivers[0].frame);
    try std.testing.expectEqual(@as(f32, 180), drivers[0].content_size.width);
    try std.testing.expectEqual(@as(f32, 120), drivers[0].content_size.height);
    try std.testing.expectEqual(@as(f32, 24), drivers[0].offset_y);
    try std.testing.expect(drivers[0].set_offset_y);
    // Edge behavior defaults off: the native scroller pins at the
    // content edges unless the region (or the scroll-physics token)
    // opts into rubber-band.
    try std.testing.expect(!drivers[0].rubber_band);

    // The retained scroll node is marked natively driven and the engine
    // scrollbar (widget part slots 2 and 3) is not emitted.
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[0].widget.native_scroll);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                try std.testing.expect(fill.id != testCanvasWidgetPartId(1, 2));
                try std.testing.expect(fill.id != testCanvasWidgetPartId(1, 3));
            },
            else => {},
        }
    }

    // Automation snapshots still expose the reconciled offset.
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    try std.testing.expect(snapshot.widgets[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 24.0), snapshot.widgets[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 120.0), snapshot.widgets[0].scroll.content_extent);
}

test "a region's rubber-band opt-in reaches its driver spec" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // The same scroll fixture with the per-region opt-in stamped: the
    // driver spec asks the OS scroller for elastic edges.
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 88, 0, 32), .text = "Three" },
    };
    const scroll = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .overscroll = .rubber_band,
        .children = &children,
    };
    const layout = try canvas.layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 1), drivers.len);
    try std.testing.expect(drivers[0].rubber_band);
}

test "driver offsets scroll retained scroll views and pass through overscroll" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_000_000_000,
    } });

    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 32), retained.nodes[1].frame);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len >= 1);
    // The driver owns physics: no engine velocity was introduced.
    try std.testing.expectEqual(@as(f32, 0), harness.runtime.views[0].widget_scroll_states[0].velocity_y);

    // Rubber-band overscroll passes through so the bounce is visible;
    // the engine performs no kinetic recovery of its own.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = -10,
        .timestamp_ns = 1_016_000_000,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, -10), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 10, 180, 32), retained.nodes[1].frame);
    try std.testing.expect(!harness.runtime.views[0].canvasWidgetKineticScrollActive());

    // The OS scroller settles the bounce and reports the rested offset.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 0,
        .timestamp_ns = 1_032_000_000,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 0), retained.nodes[0].widget.value);
}

test "driver offsets deliver canvas_widget_scroll observation events" {
    const ObservingApp = struct {
        scroll_event_count: u32 = 0,
        last_id: canvas.ObjectId = 0,
        last_scroll: canvas.ScrollState = .{},

        fn app(self: *@This()) App {
            return .{ .context = self, .name = "scroll-driver-events", .source = platform.WebViewSource.html("<h1>Hello</h1>"), .event_fn = event };
        }

        fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
            _ = runtime;
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event_value) {
                .canvas_widget_scroll => |scroll_event| {
                    self.scroll_event_count += 1;
                    self.last_id = scroll_event.id;
                    self.last_scroll = scroll_event.scroll;
                },
                else => {},
            }
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: ObservingApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // A driver-reported offset is a user-driven scroll: the app observes
    // one canvas_widget_scroll event carrying the applied state, same as
    // an engine wheel gesture would deliver.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_000_000_000,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.scroll_event_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 1), app_state.last_id);
    try std.testing.expectEqual(@as(f32, 24), app_state.last_scroll.offset_y);
    try std.testing.expectEqual(@as(f32, 72), app_state.last_scroll.viewport_extent_y);
    try std.testing.expectEqual(@as(f32, 120), app_state.last_scroll.content_extent_y);

    // An echo of the applied offset changes nothing and observes nothing.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_016_000_000,
    } });
    try std.testing.expectEqual(@as(u32, 1), app_state.scroll_event_count);
}

test "runtime-side offset changes push set_offset while driver echoes do not" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const frame_event: platform.Event = .{ .gpu_surface_frame = .{
        .label = "canvas",
        .size = geometry.SizeF.init(180, 72),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_016_000_000,
        .frame_interval_ns = 16_000_000,
        .nonblank = true,
    } };

    // Frame sync after a driver echo: tracked == runtime offset, no push.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_000_000_000,
    } });
    const pushes_before = harness.null_platform.scroll_driver_set_offset_count;
    try harness.runtime.dispatchPlatformEvent(app, frame_event);
    try std.testing.expectEqual(pushes_before, harness.null_platform.scroll_driver_set_offset_count);
    try std.testing.expectEqual(@as(f32, 24), harness.null_platform.scrollDrivers()[0].offset_y);

    // An engine-side wheel (the automation widget-wheel path) moves the
    // offset without the driver knowing: the next sync forces it across.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .timestamp_ns = 1_032_000_000,
        .kind = .scroll,
        .x = 20,
        .y = 20,
        .delta_y = 24,
    } });
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 48), retained.nodes[0].widget.value);
    try harness.runtime.dispatchPlatformEvent(app, frame_event);
    try std.testing.expect(harness.null_platform.scroll_driver_set_offset_count > pushes_before);
    try std.testing.expectEqual(@as(f32, 48), harness.null_platform.scrollDrivers()[0].offset_y);
}

test "driver-scrolled offsets survive rebuilds until the source offset changes" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_000_000_000,
    } });

    // Rebuild with the same source offset: the driver-scrolled offset
    // survives and no forced offset push is needed.
    var rebuild_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const rebuild = try scrollFixtureLayout(&rebuild_nodes, 0);
    const pushes_before = harness.null_platform.scroll_driver_set_offset_count;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild);
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqual(pushes_before, harness.null_platform.scroll_driver_set_offset_count);

    // A source-side change wins and is pushed into the native scroller.
    var programmatic_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const programmatic = try scrollFixtureLayout(&programmatic_nodes, 40);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", programmatic);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), retained.nodes[0].widget.value);
    try std.testing.expect(harness.null_platform.scroll_driver_set_offset_count > pushes_before);
    try std.testing.expectEqual(@as(f32, 40), harness.null_platform.scrollDrivers()[0].offset_y);
    try std.testing.expect(harness.null_platform.scrollDrivers()[0].set_offset_y);
}

test "scroll drivers stay unpublished without platform support" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: PassiveApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 24);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.scroll_driver_set_count);
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.nodes[0].widget.native_scroll);

    // Engine scrollbar still draws for engine-owned scrolling.
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    const display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_scrollbar_thumb = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| {
                if (fill.id == testCanvasWidgetPartId(1, 3)) saw_scrollbar_thumb = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_scrollbar_thumb);
}

fn windowedVirtualListLayout(nodes: []canvas.WidgetLayoutNode, offset: f32, declared_count: usize) !canvas.WidgetLayoutTree {
    const window = [_]canvas.Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 0" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 1" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 2" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 3" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 4" },
    };
    const list = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = offset,
        .layout = .{
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
            .virtual_item_count = declared_count,
            .virtual_first_index = 0,
        },
        .children = &window,
    };
    return canvas.layoutWidgetTree(list, geometry.RectF.init(0, 0, 180, 72), nodes);
}

test "windowed virtual lists ride the native scroll driver with the full virtual extent" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // A 10k-item windowed virtual list mounting a five-row window: the
    // driver's content size is the VIRTUAL extent (10_000 x 20 = 200_000
    // rebased onto the region frame), so the OS scrollbar spans the whole
    // list while five rows exist.
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try windowedVirtualListLayout(&nodes, 0, 10_000);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try std.testing.expect(harness.null_platform.scroll_driver_set_count >= 1);
    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 1), drivers.len);
    try std.testing.expectEqual(@as(u64, 1), drivers[0].id);
    try std.testing.expectEqual(@as(f32, 200_000), drivers[0].content_size.height);

    // The retained region is natively driven: engine scrollbar and
    // engine physics stand down.
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[0].widget.native_scroll);

    // A driver-reported offset scrolls the window (the optimistic echo
    // translates the built rows; the app's rebuild re-windows).
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 30,
        .timestamp_ns = 1_000_000_000,
    } });
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 30), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -30, 180, 20), retained.nodes[1].frame);

    // A LEGACY virtualized container (no declared count: children are
    // the full item set, model-driven offset) stays unpublished.
    var legacy_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const legacy_layout = try windowedVirtualListLayout(&legacy_nodes, 0, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", legacy_layout);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.scrollDrivers().len);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!retained.nodes[0].widget.native_scroll);
}

test "a rebuild mid-overscroll keeps the driver's offset and pushes nothing" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // The OS scroller is mid-rubber-band above the top: overscroll
    // passes through so the bounce is visible.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = -10,
        .timestamp_ns = 1_000_000_000,
    } });

    // An elm rebuild lands mid-bounce (a stream tick, a timer) with the
    // source offset unchanged: the engine must NOT clamp the overscrolled
    // offset (the OS scroller owns clamping for natively driven regions)
    // and must NOT force-push the clamp back into the live bounce.
    var rebuild_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const rebuild = try scrollFixtureLayout(&rebuild_nodes, 0);
    const pushes_before = harness.null_platform.scroll_driver_set_offset_count;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, -10), retained.nodes[0].widget.value);
    // The restored offset arrives WITH its translation: the first child
    // (laid out at y=0 for the source offset 0) sits 10 below the top.
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 10, 180, 32), retained.findById(2).?.frame);
    try std.testing.expectEqual(pushes_before, harness.null_platform.scroll_driver_set_offset_count);
}

test "a rebuild restores the retained scroll offset with translated descendants" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try scrollFixtureLayout(&nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_y = 24,
        .timestamp_ns = 1_000_000_000,
    } });

    // An UNBOUND scroll region (source stays 0) rebuilt while scrolled:
    // the retained offset survives AND the children land translated —
    // value-only restore would paint this whole rebuild at the top while
    // the scrollbar stayed at 24 (the bug that forced apps to echo every
    // offset through `value` just to keep rebuilds honest).
    var rebuild_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const rebuild = try scrollFixtureLayout(&rebuild_nodes, 0);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuild);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 24), retained.nodes[0].widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, -24, 180, 32), retained.findById(2).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 20, 180, 32), retained.findById(3).?.frame);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 64, 180, 32), retained.findById(4).?.frame);
}

test "a two-axis region's driver carries both content dimensions and follows offset_x reports" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // A BOTH-axes region: content reaches x = 460 and y = 120 inside a
    // 180 x 72 viewport, so the driver's content size must exceed the
    // frame on both dimensions.
    const tiles = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 140, 120) },
        .{ .id = 3, .kind = .panel, .frame = geometry.RectF.init(320, 0, 140, 60) },
    };
    const region = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .scroll_axes = .both,
        .value = 12,
        .value_x = 24,
        .children = &tiles,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(region, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 1), drivers.len);
    // Rebased: frame + (content - viewport) on each axis.
    try std.testing.expectEqual(@as(f32, 460), drivers[0].content_size.width);
    try std.testing.expectEqual(@as(f32, 120), drivers[0].content_size.height);
    try std.testing.expectEqual(@as(f32, 24), drivers[0].offset_x);
    try std.testing.expectEqual(@as(f32, 12), drivers[0].offset_y);
    try std.testing.expect(drivers[0].set_offset_x);
    try std.testing.expect(drivers[0].set_offset_y);
    try std.testing.expect(drivers[0].scrolls_x);
    try std.testing.expect(drivers[0].scrolls_y);

    // A driver report with both offsets lands on both axes: the widget
    // adopts the offsets and the descendants translate to match.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_x = 60,
        .offset_y = 30,
        .timestamp_ns = 1_000_000_000,
    } });
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 60), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 30), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(-60, -30, 140, 120), retained.findById(2).?.frame);
}

test "a horizontal-only region's driver pins its vertical range" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // Content is both WIDE and TALL, but the region grants only the
    // horizontal axis: the driver's content height pins to the frame so
    // the OS scroller can never travel vertically, and a stray vertical
    // report must not displace content.
    const tiles = [_]canvas.Widget{
        .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 140, 200) },
        .{ .id = 3, .kind = .panel, .frame = geometry.RectF.init(320, 0, 140, 60) },
    };
    const shelf = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .scroll_axes = .horizontal,
        .children = &tiles,
    };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(shelf, geometry.RectF.init(0, 0, 180, 72), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 1), drivers.len);
    try std.testing.expectEqual(@as(f32, 460), drivers[0].content_size.width);
    try std.testing.expectEqual(@as(f32, 72), drivers[0].content_size.height);
    try std.testing.expect(drivers[0].scrolls_x);
    try std.testing.expect(!drivers[0].scrolls_y);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{
        .window_id = 1,
        .label = "canvas",
        .driver_id = 1,
        .offset_x = 40,
        .offset_y = 50,
        .timestamp_ns = 1_000_000_000,
    } });
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(f32, 40), retained.findById(1).?.widget.value_x);
    try std.testing.expectEqual(@as(f32, 0), retained.findById(1).?.widget.value);
    try std.testing.expectEqualDeep(geometry.RectF.init(-40, 0, 140, 200), retained.findById(2).?.frame);
}

test "floating surfaces push occluders that block underlying drivers but not their own" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    var app_state: PassiveApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(10, 20, 180, 72),
    });

    // A horizontal shelf (id 1) with an ANCHORED popover above part of
    // it (id 4); the popover holds its own scroll region (id 5). The
    // popover occludes the shelf where they overlap, but never its own
    // scroll region.
    const nodes = [_]canvas.WidgetLayoutNode{
        .{ .widget = .{ .id = 1, .kind = .scroll_view, .scroll_axes = .horizontal, .frame = geometry.RectF.init(0, 0, 180, 72) }, .frame = geometry.RectF.init(0, 0, 180, 72), .depth = 0 },
        .{ .widget = .{ .id = 2, .kind = .panel, .frame = geometry.RectF.init(0, 0, 400, 60) }, .frame = geometry.RectF.init(0, 0, 400, 60), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 4, .kind = .popover, .frame = geometry.RectF.init(40, 10, 100, 50), .layout = .{ .anchor = .{ .placement = .below } } }, .frame = geometry.RectF.init(40, 10, 100, 50), .depth = 1, .parent_index = 0 },
        .{ .widget = .{ .id = 5, .kind = .scroll_view, .frame = geometry.RectF.init(44, 14, 92, 42) }, .frame = geometry.RectF.init(44, 14, 92, 42), .depth = 2, .parent_index = 2 },
        .{ .widget = .{ .id = 6, .kind = .panel, .frame = geometry.RectF.init(44, 14, 92, 200) }, .frame = geometry.RectF.init(44, 14, 92, 200), .depth = 3, .parent_index = 3 },
    };
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", .{ .nodes = &nodes });

    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.scroll_occluder_count);
    try std.testing.expectEqualDeep(geometry.RectF.init(40, 10, 100, 50), harness.null_platform.scroll_occluders[0].frame);

    const drivers = harness.null_platform.scrollDrivers();
    try std.testing.expectEqual(@as(usize, 2), drivers.len);
    // The shelf is blocked by the popover (bit 0)...
    try std.testing.expectEqual(@as(u64, 1), drivers[0].id);
    try std.testing.expectEqual(@as(u32, 1), drivers[0].occluder_mask);
    // ...while the popover's own scroll region is exempt.
    try std.testing.expectEqual(@as(u64, 5), drivers[1].id);
    try std.testing.expectEqual(@as(u32, 0), drivers[1].occluder_mask);
    // And the nested chain rides the parent ids.
    try std.testing.expectEqual(@as(u64, 0), drivers[0].parent_id);
    try std.testing.expectEqual(@as(u64, 1), drivers[1].parent_id);
}
