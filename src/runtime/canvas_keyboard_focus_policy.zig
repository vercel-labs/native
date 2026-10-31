//! Portable keyboard focus decisions. The reference is retained for Zig-core
//! apps; compiled views supply the same copied-byte policy via the existing
//! surface callback. Native keeps identities, retained geometry and effects.
const std = @import("std");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");

pub const Policy = ?*const fn ([]const u8, []u8) usize;
pub const Stage = enum(u8) { intent, lifetime, group, edge, spatial, coordinate, commit, visibility, caret, moved };
pub const Intent = enum(u8) { none, tab, back_tab, home, end, left, right, up, down };
pub const Action = enum(u8) { stop, tab_target, tab_commit, tab_visible, tab_visible_commit, tab_fallback, tab_fallback_commit, tab_finish, menu, tree_edge, group_edge, tree, group, spatial, commit, radio_commit, radio_next, moved, capture_tab };
pub const Facts = struct {
    pub const present: u16 = 1;
    pub const moved: u16 = 2;
    pub const different: u16 = 4;
    pub const same: u16 = 8;
    pub const initial: u16 = 16;
    pub const radio_scope: u16 = 32;
    pub const focused: u16 = 64;
    pub const quiet: u16 = 128;
    pub const owner: u16 = 512;
    pub const nonzero: u16 = 1024;
    pub const budget: u16 = 2048;
    pub const allowed: u16 = 4096;
};
pub const Request = struct {
    stage: Stage,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    kind: ?canvas.WidgetKind = null,
    parent: ?canvas.WidgetKind = null,
    target: ?canvas.WidgetKind = null,
    facts: u16 = 0,
};

pub fn decide(policy: Policy, request: Request) u8 {
    if (policy) |callback| {
        var bytes = [10]u8{ 34, @intFromEnum(request.stage), request.a, request.b, request.c, code(request.kind), code(request.parent), code(request.target), 0, 0 };
        std.mem.writeInt(u16, bytes[8..10], request.facts, .little);
        var result: [1]u8 = undefined;
        const max: u8 = switch (request.stage) {
            .intent => 8,
            .lifetime, .group => 2,
            .coordinate => 18,
            .commit => 7,
            else => 1,
        };
        if (callback(&bytes, &result) != 1 or result[0] > max or (request.stage == .commit and result[0] != 0 and result[0] != 1 and result[0] != 7)) @panic("invalid compiled keyboard focus result");
        return result[0];
    }
    return reference(request);
}
fn code(kind: ?canvas.WidgetKind) u8 {
    return if (kind) |value| @intCast(canvas.widgetKindCode(value)) else 63;
}
pub fn phase(input: platform.GpuSurfaceInputEvent) u8 {
    return switch (input.kind) {
        .key_down => 0,
        .key_up => 1,
        else => 2,
    };
}
pub fn key(value: []const u8) u8 {
    const names = [_][]const u8{ "tab", "home", "end", "arrowleft", "arrowright", "arrowup", "arrowdown" };
    for (names, 1..) |name, index| if (std.ascii.eqlIgnoreCase(value, name)) return @intCast(index);
    return 0;
}
pub fn modifiers(input: platform.GpuSurfaceInputEvent) u8 {
    const m = input.modifiers;
    return @as(u8, if (m.shift) 1 else 0) | @as(u8, if (m.control) 2 else 0) | @as(u8, if (m.option) 4 else 0) | @as(u8, if (m.command) 8 else 0) | @as(u8, if (m.primary) 16 else 0);
}
pub fn directionCode(value: canvas.WidgetFocusDirection) u8 {
    return switch (value) {
        .forward => 0,
        .backward => 1,
        .left => 2,
        .right => 3,
        .up => 4,
        .down => 5,
    };
}
pub fn direction(intent: Intent) canvas.WidgetFocusDirection {
    return switch (intent) {
        .back_tab => .backward,
        .left, .end => .left,
        .right, .home => .right,
        .up => .up,
        .down => .down,
        else => .forward,
    };
}

pub fn reference(r: Request) u8 {
    const horizontal = r.a == 2 or r.a == 3;
    const vertical = r.a == 4 or r.a == 5;
    const button_parent = r.parent == .button_group or r.parent == .pagination or r.parent == .breadcrumb;
    const toggle_parent = r.parent == .button_group or r.parent == .toggle_group;
    switch (r.stage) {
        .intent => {
            if (r.a != 0) return 0;
            if (r.b == 1) {
                if (r.facts & 1 != 0 or (r.facts & 2 != 0 and r.c == 0)) return 0;
                return if (r.c & 1 != 0) 2 else 1;
            }
            if (r.c & 30 != 0) return 0;
            if (r.b == 2 and r.c == 0) return 3;
            if (r.b == 3 and r.c == 0) return 4;
            return if (r.b >= 4 and r.b <= 7) r.b + 1 else 0;
        },
        .lifetime => return if (r.a < 2 and r.b == 1 and r.facts & 1 != 0) (if (r.a == 1) 2 else 1) else 0,
        .group => {
            const horizontal_group = (button_parent and (r.kind == .button or r.kind == .icon_button)) or (r.parent == .toggle_group and r.kind == .toggle_button) or (r.parent == .tabs and r.kind == .segmented_control);
            const vertical_group = (r.parent == .list and r.kind == .list_item) or ((r.parent == .menu_surface or r.parent == .dropdown_menu) and r.kind == .menu_item);
            if ((horizontal_group and horizontal) or (vertical_group and vertical)) return if (r.a == 2 or r.a == 4) 1 else 2;
            return 0;
        },
        .edge => return @intFromBool(r.kind == .list_item or r.kind == .menu_item or r.kind == .data_cell or r.kind == .segmented_control or r.kind == .radio or ((r.kind == .button or r.kind == .icon_button) and button_parent) or (r.kind == .toggle_button and toggle_parent)),
        .spatial => {
            if (r.kind != r.target) return 0;
            if (r.kind == .data_cell) return 1;
            if (r.kind == .radio) return if (r.facts & 6 != 0) @intFromBool(r.facts & 10 == 10) else @intCast(r.facts & 1);
            return @intFromBool(r.facts & 1 != 0 and (((r.kind == .list_item or r.kind == .menu_item) and vertical) or (r.kind == .segmented_control and horizontal) or ((r.kind == .button or r.kind == .icon_button) and button_parent and horizontal) or (r.kind == .toggle_button and toggle_parent and horizontal)));
        },
        .coordinate => {
            const present = r.facts & Facts.present != 0;
            const moved = r.facts & Facts.moved != 0;
            const different = r.facts & Facts.different != 0;
            const action: Action = @enumFromInt(r.b);
            return @intFromEnum(switch (action) {
                .stop => if (r.a == 1 or r.a == 2) Action.tab_target else if (r.a != 0 and r.facts & 192 == 64) (if (r.a == 3 or r.a == 4) Action.tree_edge else if ((r.a == 7 or r.a == 8) and (r.kind == .button or r.kind == .icon_button or r.kind == .select or r.kind == .combobox)) Action.menu else Action.tree) else Action.stop,
                .tab_target => if (present) Action.tab_commit else Action.stop,
                .tab_commit => if (moved) Action.tab_finish else if (different) Action.tab_visible else Action.tab_finish,
                .tab_visible => if (present and r.facts & Facts.same == 0) Action.tab_visible_commit else Action.tab_fallback,
                .tab_visible_commit => if (moved) Action.tab_finish else Action.tab_fallback,
                .tab_fallback => if (present and r.facts & Facts.same == 0) Action.tab_fallback_commit else Action.stop,
                .tab_fallback_commit => Action.tab_finish,
                .tab_finish => if (moved) (if (r.facts & Facts.owner != 0) Action.capture_tab else Action.moved) else Action.stop,
                .menu => if (present) Action.commit else Action.tree,
                .tree_edge => if (present) Action.commit else Action.group_edge,
                .group_edge, .group => if (present) (if (r.kind == .radio and r.facts & Facts.radio_scope != 0) (if (r.facts & 3076 == 3076) Action.radio_commit else Action.stop) else Action.commit) else (if (action == .group) Action.spatial else Action.stop),
                .tree => if (present) Action.commit else Action.group,
                .spatial => if (present and r.facts & Facts.allowed != 0) Action.commit else Action.stop,
                .commit => if (moved) Action.moved else Action.stop,
                .radio_commit => if (moved) Action.moved else Action.radio_next,
                .radio_next => if (present and r.facts & 24 == 0 and r.facts & 3076 == 3076) Action.radio_commit else Action.stop,
                .moved, .capture_tab => Action.stop,
            });
        },
        .commit => return if (r.facts & 3 == 3) 0 else 1 | @as(u8, if (r.a == 1 and r.facts & 4 != 0) 6 else 0),
        .visibility => return @intFromBool(r.a == 1 or r.a == 2 or r.facts != 0),
        .caret, .moved => return @intFromBool(r.facts == 7),
    }
}
