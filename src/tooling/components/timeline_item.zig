//! Your app's timeline item.
//! Ejected from the Native SDK component library.
//!
//! This file now belongs to your app: edit it freely, and SDK updates
//! never touch it. It builds the same widget tree `ui.timelineItem`
//! produced at the moment it was ejected, so migrating a call site is a
//! rename (the type takes your app's message union once, because a
//! pressable item carries a typed `on_press`):
//!
//!     const timeline_item = @import("components/timeline_item.zig");
//!     const TimelineItem = timeline_item.TimelineItem(Msg);
//!
//!     // before: ui.timelineItem(.{ .title = run.title, .on_press = .{ .open = run.id } })
//!     // after:  TimelineItem.build(&ui, .{ .title = run.title, .on_press = .{ .open = run.id } })
//!
//! The library form stays available — call sites you have not migrated
//! keep rendering the stock item, and deleting this file costs nothing
//! (`native eject component timeline-item` writes it again).

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub fn TimelineItem(comptime Msg: type) type {
    return struct {
        const Ui = canvas.Ui(Msg);

        pub const Options = struct {
            key: ?canvas.UiKey = null,
            global_key: ?canvas.UiKey = null,
            indicator: []const u8 = "",
            icon: []const u8 = "",
            variant: canvas.WidgetVariant = .outline,
            title: []const u8,
            description: []const u8 = "",
            meta: []const u8 = "",
            connector: bool = true,
            on_press: ?Msg = null,
            selected: bool = false,
        };

        pub fn build(ui: *Ui, options: Options) Ui.Node {
            const dot = options.indicator.len == 0 and options.icon.len == 0;
            const indicator = ui.el(.badge, .{
                .variant = options.variant,
                .text = options.indicator,
                .icon = options.icon,
                .width = if (dot) 10 else 0,
                .height = if (dot) 10 else 0,
            }, .{});
            const lead = if (options.connector)
                ui.el(.column, .{ .cross = .center, .gap = 4 }, .{
                    indicator,
                    ui.el(.separator, .{ .grow = 1, .width = 1 }, .{}),
                })
            else
                ui.el(.column, .{ .cross = .center }, .{indicator});

            const content_nodes = ui.arena.alloc(Ui.Node, 3) catch {
                ui.failed = true;
                return ui.el(.stack, .{}, .{});
            };
            content_nodes[0] = ui.paragraph(.{}, &.{.{ .text = options.title, .weight = .bold }});
            var content_len: usize = 1;
            if (options.description.len > 0) {
                content_nodes[content_len] = ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, options.description);
                content_len += 1;
            }
            if (options.meta.len > 0) {
                content_nodes[content_len] = ui.paragraph(.{}, &.{.{ .text = options.meta, .color = .text_muted, .scale = 0.9 }});
                content_len += 1;
            }
            const content = ui.el(.column, .{ .grow = 1, .gap = 2 }, .{content_nodes[0..content_len]});
            const item_semantics = canvas.WidgetSemantics{
                .role = .listitem,
                .label = options.title,
                .focusable = options.on_press != null,
            };
            const row_children = ui.arena.alloc(Ui.Node, 3) catch {
                ui.failed = true;
                return ui.el(.stack, .{}, .{});
            };
            row_children[0] = lead;
            row_children[1] = content;
            var row_len: usize = 2;
            if (options.on_press != null) {
                row_children[row_len] = ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "›");
                row_len += 1;
            }
            const row_node = ui.el(.row, .{ .gap = 10, .padding = 8 }, .{row_children[0..row_len]});
            return ui.el(.stack, .{
                .key = options.key,
                .global_key = options.global_key,
                .selected = options.selected,
                .semantics = item_semantics,
                .on_press = options.on_press,
            }, .{row_node});
        }
    };
}
