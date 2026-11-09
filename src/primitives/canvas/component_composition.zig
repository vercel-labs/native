//! Typed assembly for compiled composition recipes. The native reference
//! remains in Ui for explicit native extensions without a compiled owner.
const policy = @import("component_composition_policy.zig");
const drawing = @import("drawing.zig");

pub fn Composer(comptime Ui: type) type {
    return struct {
        pub fn inputGroup(self: *Ui, options: Ui.InputGroupOptions, entry: Ui.Node, actions: ?Ui.Node) Ui.Node {
            const p = policy.plan(self.composition_policy.?, .input_group, @intFromBool(actions != null), options.semantics.role, 0, 0, 0, 0, 0);
            var semantics = options.semantics;
            semantics.role = p.role();
            var entry_node = entry;
            const flags: u8 = @as(u8, @intFromBool(entry.widget.style.background == null and entry.style_tokens.background == null)) |
                (@as(u8, @intFromBool(entry.widget.style.border == null and entry.style_tokens.border_color == null)) << 1) |
                (@as(u8, @intFromBool(entry.widget.style.focus_ring == null and entry.style_tokens.focus_ring == null)) << 2) |
                (@as(u8, @intFromBool(entry.widget.layout.grow == 0)) << 3);
            const chrome = policy.plan(self.composition_policy.?, .input_entry, flags, .none, 0, 0, 0, entry.widget.layout.grow, 0);
            const transparent = drawing.Color.rgba8(0, 0, 0, 0);
            if (chrome.flag(1)) entry_node.widget.style.background = transparent;
            if (chrome.flag(2)) entry_node.widget.style.border = transparent;
            if (chrome.flag(4)) entry_node.widget.style.focus_ring = transparent;
            entry_node.widget.layout.grow = chrome.float(6);
            if (p.bytes[3] != @as(u8, if (actions != null) 2 else 1) or p.flag(1) != (actions != null)) @panic("invalid compiled input group capacity");
            const nodes = self.arena.alloc(Ui.Node, p.bytes[3]) catch {
                self.failed = true;
                return self.el(.input_group, .{ .semantics = semantics }, .{});
            };
            nodes[0] = entry_node;
            if (p.flag(1)) nodes[1] = actions.?;
            return self.el(.input_group, .{ .key = options.key, .global_key = options.global_key, .width = options.width, .height = options.height, .min_width = options.min_width, .grow = options.grow, .semantics = semantics }, .{nodes});
        }

        pub fn inputActions(self: *Ui, options: Ui.InputGroupActionsOptions, children: anytype) Ui.Node {
            const p = policy.plan(self.composition_policy.?, .input_actions, 0, .none, 0, 0, 0, 0, options.gap);
            var node = self.el(.row, .{ .key = options.key, .global_key = options.global_key, .gap = p.float(0), .cross = .center }, children);
            node.widget.layout.padding = .{ .top = p.float(2), .right = p.float(3), .bottom = p.float(4), .left = p.float(5) };
            return node;
        }

        pub fn stepper(self: *Ui, options: Ui.StepperOptions, steps: []const Ui.StepperStep) Ui.Node {
            const p = policy.plan(self.composition_policy.?, .stepper, 0, options.semantics.role, options.active, 0, steps.len, 0, 0);
            var semantics = options.semantics;
            semantics.role = p.role();
            if (p.count() != (if (steps.len == 0) @as(usize, 0) else steps.len * 2 - 1)) @panic("invalid compiled stepper capacity");
            const nodes = self.arena.alloc(Ui.Node, p.count()) catch {
                self.failed = true;
                return self.el(.row, .{ .semantics = semantics }, .{});
            };
            for (steps, 0..) |step, index| {
                nodes[index * 2] = stepNode(self, options.active, index, steps.len, step);
                if (index * 2 + 1 < nodes.len) nodes[index * 2 + 1] = self.el(.separator, .{ .grow = 1 }, .{});
            }
            return self.el(.row, .{ .key = options.key, .global_key = options.global_key, .gap = p.float(0), .cross = .center, .grow = options.grow, .semantics = semantics }, .{nodes});
        }

        fn stepNode(self: *Ui, active: usize, index: usize, count: usize, step: Ui.StepperStep) Ui.Node {
            const p = policy.plan(self.composition_policy.?, .step, 0, .none, active, index, count, 0, 0);
            const indicator = self.el(.badge, .{ .variant = @enumFromInt(p.bytes[4]), .icon = if (p.flag(1)) "check" else "", .text = if (p.flag(1)) "" else self.fmt("{d}", .{index + 1}) }, .{});
            const label = if (p.flag(2)) self.paragraph(.{}, &.{.{ .text = step.label, .weight = .bold }}) else self.text(.{ .style_tokens = .{ .foreground = if (p.flag(4)) .text_muted else null } }, step.label);
            return self.el(.row, .{ .key = .{ .int = @intCast(index) }, .gap = p.float(0), .cross = .center, .selected = p.flag(2), .semantics = .{ .role = .listitem, .label = self.fmt("{s} ({s})", .{ step.label, p.stateName() }), .list_item_index = @intCast(index), .list_item_count = @intCast(count) } }, .{ indicator, label });
        }

        pub fn timelineItem(self: *Ui, options: Ui.TimelineItemOptions) Ui.Node {
            const flags: u8 = @as(u8, @intFromBool(options.connector)) |
                (@as(u8, @intFromBool(options.description.len > 0)) << 1) |
                (@as(u8, @intFromBool(options.meta.len > 0)) << 2) |
                (@as(u8, @intFromBool(options.on_press != null)) << 3) |
                (@as(u8, @intFromBool(options.indicator.len == 0 and options.icon.len == 0)) << 4);
            const p = policy.plan(self.composition_policy.?, .timeline_item, flags, .none, 0, 0, 0, 0, 0);
            const indicator = self.el(.badge, .{ .variant = options.variant, .text = options.indicator, .icon = options.icon, .width = p.float(7), .height = p.float(8) }, .{});
            const lead = if (p.flag(1)) self.el(.column, .{ .cross = .center, .gap = p.float(9) }, .{
                indicator, self.el(.separator, .{ .grow = p.float(10), .width = p.float(11) }, .{}),
            }) else self.el(.column, .{ .cross = .center, .gap = p.float(9) }, .{indicator});
            // Native capacities and allocation-failure order match the reference.
            const content_nodes = self.arena.alloc(Ui.Node, 3) catch {
                self.failed = true;
                return self.el(.stack, .{}, .{});
            };
            content_nodes[0] = self.paragraph(.{}, &.{.{ .text = options.title, .weight = .bold }});
            var content_len: usize = 1;
            if (p.flag(2)) {
                content_nodes[content_len] = self.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, options.description);
                content_len += 1;
            }
            if (p.flag(4)) {
                content_nodes[content_len] = self.paragraph(.{}, &.{.{ .text = options.meta, .color = .text_muted, .scale = p.float(16) }});
                content_len += 1;
            }
            if (content_len != p.bytes[3]) @panic("invalid compiled timeline content count");
            const content = self.el(.column, .{ .grow = p.float(12), .gap = p.float(13) }, .{content_nodes[0..content_len]});
            const row_children = self.arena.alloc(Ui.Node, 3) catch {
                self.failed = true;
                return self.el(.stack, .{}, .{});
            };
            row_children[0] = lead;
            row_children[1] = content;
            var row_len: usize = 2;
            if (p.flag(8)) {
                row_children[row_len] = self.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "›");
                row_len += 1;
            }
            const row = self.el(.row, .{ .gap = p.float(14), .padding = p.float(15) }, .{row_children[0..row_len]});
            return self.el(.stack, .{ .key = options.key, .global_key = options.global_key, .selected = options.selected, .on_press = options.on_press, .semantics = .{ .role = p.role(), .label = options.title, .focusable = p.flag(8) } }, .{row});
        }

        pub fn nav(self: *Ui, options: Ui.NavOptions, pages: []const Ui.Node) Ui.Node {
            const p = policy.plan(self.composition_policy.?, .nav, @intFromBool(options.retain), options.semantics.role, options.active, 0, pages.len, 0, 0);
            var semantics = options.semantics;
            semantics.role = p.role();
            if (p.count() == 0) return self.el(.stack, .{ .key = options.key, .global_key = options.global_key, .grow = options.grow, .min_width = options.min_width, .semantics = semantics }, .{});
            if (p.count() > pages.len or p.active() >= pages.len) @panic("invalid compiled navigation capacity");
            const mounted = self.arena.alloc(Ui.Node, p.count()) catch {
                self.failed = true;
                return self.el(.stack, .{ .semantics = semantics }, .{});
            };
            for (mounted, 0..) |*slot, offset| {
                const index = if (p.flag(1)) offset else p.active();
                slot.* = pages[index];
                if (slot.key == null) slot.key = .{ .int = @intCast(index) };
                if (index != p.active()) slot.widget.semantics.hidden = true;
            }
            return self.el(.stack, .{ .key = options.key, .global_key = options.global_key, .grow = options.grow, .min_width = options.min_width, .semantics = semantics }, .{mounted});
        }
    };
}
