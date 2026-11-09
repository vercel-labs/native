// Frozen portable command rules from the native runtime before ownership moved.
const std = @import("std");
const native_sdk = @import("native_sdk");
const platform = native_sdk.platform;
const policy = native_sdk.runtime.testing.command_policy;

pub fn dispatch(name: []const u8) policy.Dispatch {
    if (name.len == 0 or name.len > 128) return .invalid;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return .invalid;
    for (name) |ch| if (ch == 0 or ch == '/' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') return .invalid;
    return if (std.mem.eql(u8, name, platform.update_check_command)) .updater else .app;
}
pub fn bridgeLabel(label: []const u8) []const u8 {
    return if (std.mem.eql(u8, label, "main")) "" else label;
}
fn findView(views: anytype, window: platform.WindowId, label: []const u8) ?usize {
    for (views, 0..) |*view, i| if (view.open and view.window_id == window and std.mem.eql(u8, view.label, label)) return i;
    return null;
}
pub fn toolbar(views: anytype, window: platform.WindowId, label: []const u8) bool {
    const index = findView(views, window, label) orelse return false;
    var view = &views[index];
    var depth: usize = 0;
    while (depth < platform.max_views) : (depth += 1) {
        if (view.kind == .toolbar) return true;
        const parent_label = view.parent orelse return false;
        const parent_index = findView(views, window, parent_label) orelse return false;
        view = &views[parent_index];
    }
    return false;
}
pub fn menu(items: []const platform.TrayMenuItem, id: platform.TrayItemId) policy.Menu {
    var result = policy.Menu{ .exists = false, .actionable = false, .row = null, .option = null };
    exists: for (items) |item| {
        if (item.id == id) {
            result.exists = true;
            break;
        }
        if (item.segmented) |segment| for (segment.options) |option| if (option.id == id) {
            result.exists = true;
            break :exists;
        };
    }
    action: for (items) |item| {
        if (item.id == id) {
            result.actionable = !item.separator and item.enabled and (item.role == .command or item.role == .agent);
            break;
        }
        if (item.segmented) |segment| for (segment.options) |option| if (option.id == id) {
            result.actionable = option.enabled;
            break :action;
        };
    }
    command: for (items, 0..) |item, row| {
        if (item.id == id and item.command.len > 0) {
            result.row = row;
            break;
        }
        if (item.segmented) |segment| for (segment.options, 0..) |option, i| if (option.id == id) {
            result.row = row;
            result.option = i;
            break :command;
        };
    }
    return result;
}
pub fn slot(slots: anytype, id: platform.StatusItemId, admit: bool, count: usize) policy.Slot {
    for (slots, 0..) |*entry, i| if (entry.active and entry.id == id) return .{ .kind = .retained, .index = i };
    if (!admit) return .{ .kind = .absent, .index = null };
    if (count >= slots.len) return .{ .kind = .full, .index = null };
    for (slots, 0..) |*entry, i| if (!entry.active) return .{ .kind = .available, .index = i };
    return .{ .kind = .full, .index = null };
}
