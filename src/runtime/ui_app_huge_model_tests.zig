//! Stack-safety guard: a Model bigger than the 8 MiB test-thread
//! stack must construct, install, and dispatch without EVER riding the
//! stack. `UiApp.init` takes the Model by value — at ovation's 5.9 MB
//! Model one test's 2 MB scratch beside it overflowed the stack and
//! segfaulted inside init (the third sighting of the multi-MB-by-value
//! stack-overflow trap). The
//! `create`/`initInPlace` seam heap-allocates the app and constructs
//! every field, the Model included, in place; with a 12 MiB Model any
//! regression back to a stack temporary crashes this test outright.
//!
//! The Model also carries a realistic pile of public decls so the
//! default-features `UiApp` (which compiles `MarkupView(Model)`) guards
//! the comptime-quota cliff at the UiApp level too: the markup engines'
//! comptime scans must budget for real Model sizes on their own.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");

const canvas_label = "huge-canvas";

const HugeItem = struct {
    name: []const u8 = "item",
    count: u32 = 0,
};


pub const HugeModel = struct {
    /// Larger than the default 8 MiB stack: any path that puts the
    /// Model (or the app struct) on the stack crashes immediately.
    payload: [12 * 1024 * 1024]u8 = @splat(0),
    items: []const HugeItem = &.{},
    count: u32 = 0,

    pub fn accessor0(self: *const HugeModel) u32 { return self.count +% 0; }
    pub fn accessor1(self: *const HugeModel) u32 { return self.count +% 1; }
    pub fn accessor2(self: *const HugeModel) u32 { return self.count +% 2; }
    pub fn accessor3(self: *const HugeModel) u32 { return self.count +% 3; }
    pub fn accessor4(self: *const HugeModel) u32 { return self.count +% 4; }
    pub fn accessor5(self: *const HugeModel) u32 { return self.count +% 5; }
    pub fn accessor6(self: *const HugeModel) u32 { return self.count +% 6; }
    pub fn accessor7(self: *const HugeModel) u32 { return self.count +% 7; }
    pub fn accessor8(self: *const HugeModel) u32 { return self.count +% 8; }
    pub fn accessor9(self: *const HugeModel) u32 { return self.count +% 9; }
    pub fn accessor10(self: *const HugeModel) u32 { return self.count +% 10; }
    pub fn accessor11(self: *const HugeModel) u32 { return self.count +% 11; }
    pub fn accessor12(self: *const HugeModel) u32 { return self.count +% 12; }
    pub fn accessor13(self: *const HugeModel) u32 { return self.count +% 13; }
    pub fn accessor14(self: *const HugeModel) u32 { return self.count +% 14; }
    pub fn accessor15(self: *const HugeModel) u32 { return self.count +% 15; }
    pub fn accessor16(self: *const HugeModel) u32 { return self.count +% 16; }
    pub fn accessor17(self: *const HugeModel) u32 { return self.count +% 17; }
    pub fn accessor18(self: *const HugeModel) u32 { return self.count +% 18; }
    pub fn accessor19(self: *const HugeModel) u32 { return self.count +% 19; }
    pub fn accessor20(self: *const HugeModel) u32 { return self.count +% 20; }
    pub fn accessor21(self: *const HugeModel) u32 { return self.count +% 21; }
    pub fn accessor22(self: *const HugeModel) u32 { return self.count +% 22; }
    pub fn accessor23(self: *const HugeModel) u32 { return self.count +% 23; }
    pub fn accessor24(self: *const HugeModel) u32 { return self.count +% 24; }
    pub fn accessor25(self: *const HugeModel) u32 { return self.count +% 25; }
    pub fn accessor26(self: *const HugeModel) u32 { return self.count +% 26; }
    pub fn accessor27(self: *const HugeModel) u32 { return self.count +% 27; }
    pub fn accessor28(self: *const HugeModel) u32 { return self.count +% 28; }
    pub fn accessor29(self: *const HugeModel) u32 { return self.count +% 29; }
    pub fn accessor30(self: *const HugeModel) u32 { return self.count +% 30; }
    pub fn accessor31(self: *const HugeModel) u32 { return self.count +% 31; }
    pub fn accessor32(self: *const HugeModel) u32 { return self.count +% 32; }
    pub fn accessor33(self: *const HugeModel) u32 { return self.count +% 33; }
    pub fn accessor34(self: *const HugeModel) u32 { return self.count +% 34; }
    pub fn accessor35(self: *const HugeModel) u32 { return self.count +% 35; }
    pub fn accessor36(self: *const HugeModel) u32 { return self.count +% 36; }
    pub fn accessor37(self: *const HugeModel) u32 { return self.count +% 37; }
    pub fn accessor38(self: *const HugeModel) u32 { return self.count +% 38; }
    pub fn accessor39(self: *const HugeModel) u32 { return self.count +% 39; }
    pub fn accessor40(self: *const HugeModel) u32 { return self.count +% 40; }
    pub fn accessor41(self: *const HugeModel) u32 { return self.count +% 41; }
    pub fn accessor42(self: *const HugeModel) u32 { return self.count +% 42; }
    pub fn accessor43(self: *const HugeModel) u32 { return self.count +% 43; }
    pub fn accessor44(self: *const HugeModel) u32 { return self.count +% 44; }
    pub fn accessor45(self: *const HugeModel) u32 { return self.count +% 45; }
    pub fn accessor46(self: *const HugeModel) u32 { return self.count +% 46; }
    pub fn accessor47(self: *const HugeModel) u32 { return self.count +% 47; }
    pub fn accessor48(self: *const HugeModel) u32 { return self.count +% 48; }
    pub fn accessor49(self: *const HugeModel) u32 { return self.count +% 49; }
    pub fn accessor50(self: *const HugeModel) u32 { return self.count +% 50; }
    pub fn accessor51(self: *const HugeModel) u32 { return self.count +% 51; }
    pub fn accessor52(self: *const HugeModel) u32 { return self.count +% 52; }
    pub fn accessor53(self: *const HugeModel) u32 { return self.count +% 53; }
    pub fn accessor54(self: *const HugeModel) u32 { return self.count +% 54; }
    pub fn accessor55(self: *const HugeModel) u32 { return self.count +% 55; }
    pub fn accessor56(self: *const HugeModel) u32 { return self.count +% 56; }
    pub fn accessor57(self: *const HugeModel) u32 { return self.count +% 57; }
    pub fn accessor58(self: *const HugeModel) u32 { return self.count +% 58; }
    pub fn accessor59(self: *const HugeModel) u32 { return self.count +% 59; }
    pub fn accessor60(self: *const HugeModel) u32 { return self.count +% 60; }
    pub fn accessor61(self: *const HugeModel) u32 { return self.count +% 61; }
    pub fn accessor62(self: *const HugeModel) u32 { return self.count +% 62; }
    pub fn accessor63(self: *const HugeModel) u32 { return self.count +% 63; }
    pub fn accessor64(self: *const HugeModel) u32 { return self.count +% 64; }
    pub fn accessor65(self: *const HugeModel) u32 { return self.count +% 65; }
    pub fn accessor66(self: *const HugeModel) u32 { return self.count +% 66; }
    pub fn accessor67(self: *const HugeModel) u32 { return self.count +% 67; }
    pub fn accessor68(self: *const HugeModel) u32 { return self.count +% 68; }
    pub fn accessor69(self: *const HugeModel) u32 { return self.count +% 69; }
    pub fn accessor70(self: *const HugeModel) u32 { return self.count +% 70; }
    pub fn accessor71(self: *const HugeModel) u32 { return self.count +% 71; }
    pub fn accessor72(self: *const HugeModel) u32 { return self.count +% 72; }
    pub fn accessor73(self: *const HugeModel) u32 { return self.count +% 73; }
    pub fn accessor74(self: *const HugeModel) u32 { return self.count +% 74; }
    pub fn accessor75(self: *const HugeModel) u32 { return self.count +% 75; }
    pub fn accessor76(self: *const HugeModel) u32 { return self.count +% 76; }
    pub fn accessor77(self: *const HugeModel) u32 { return self.count +% 77; }
    pub fn accessor78(self: *const HugeModel) u32 { return self.count +% 78; }
    pub fn accessor79(self: *const HugeModel) u32 { return self.count +% 79; }
    pub fn accessor80(self: *const HugeModel) u32 { return self.count +% 80; }
    pub fn accessor81(self: *const HugeModel) u32 { return self.count +% 81; }
    pub fn accessor82(self: *const HugeModel) u32 { return self.count +% 82; }
    pub fn accessor83(self: *const HugeModel) u32 { return self.count +% 83; }
    pub fn accessor84(self: *const HugeModel) u32 { return self.count +% 84; }
    pub fn accessor85(self: *const HugeModel) u32 { return self.count +% 85; }
    pub fn accessor86(self: *const HugeModel) u32 { return self.count +% 86; }
    pub fn accessor87(self: *const HugeModel) u32 { return self.count +% 87; }
    pub fn accessor88(self: *const HugeModel) u32 { return self.count +% 88; }
    pub fn accessor89(self: *const HugeModel) u32 { return self.count +% 89; }
    pub fn accessor90(self: *const HugeModel) u32 { return self.count +% 90; }
    pub fn accessor91(self: *const HugeModel) u32 { return self.count +% 91; }
    pub fn accessor92(self: *const HugeModel) u32 { return self.count +% 92; }
    pub fn accessor93(self: *const HugeModel) u32 { return self.count +% 93; }
    pub fn accessor94(self: *const HugeModel) u32 { return self.count +% 94; }
    pub fn accessor95(self: *const HugeModel) u32 { return self.count +% 95; }
    pub fn accessor96(self: *const HugeModel) u32 { return self.count +% 96; }
    pub fn accessor97(self: *const HugeModel) u32 { return self.count +% 97; }
    pub fn accessor98(self: *const HugeModel) u32 { return self.count +% 98; }
    pub fn accessor99(self: *const HugeModel) u32 { return self.count +% 99; }
    pub fn accessor100(self: *const HugeModel) u32 { return self.count +% 100; }
    pub fn accessor101(self: *const HugeModel) u32 { return self.count +% 101; }
    pub fn accessor102(self: *const HugeModel) u32 { return self.count +% 102; }
    pub fn accessor103(self: *const HugeModel) u32 { return self.count +% 103; }
    pub fn accessor104(self: *const HugeModel) u32 { return self.count +% 104; }
    pub fn accessor105(self: *const HugeModel) u32 { return self.count +% 105; }
    pub fn accessor106(self: *const HugeModel) u32 { return self.count +% 106; }
    pub fn accessor107(self: *const HugeModel) u32 { return self.count +% 107; }
    pub fn accessor108(self: *const HugeModel) u32 { return self.count +% 108; }
    pub fn accessor109(self: *const HugeModel) u32 { return self.count +% 109; }
    pub fn accessor110(self: *const HugeModel) u32 { return self.count +% 110; }
    pub fn accessor111(self: *const HugeModel) u32 { return self.count +% 111; }
    pub fn accessor112(self: *const HugeModel) u32 { return self.count +% 112; }
    pub fn accessor113(self: *const HugeModel) u32 { return self.count +% 113; }
    pub fn accessor114(self: *const HugeModel) u32 { return self.count +% 114; }
    pub fn accessor115(self: *const HugeModel) u32 { return self.count +% 115; }
    pub fn accessor116(self: *const HugeModel) u32 { return self.count +% 116; }
    pub fn accessor117(self: *const HugeModel) u32 { return self.count +% 117; }
    pub fn accessor118(self: *const HugeModel) u32 { return self.count +% 118; }
    pub fn accessor119(self: *const HugeModel) u32 { return self.count +% 119; }
    pub fn accessor120(self: *const HugeModel) u32 { return self.count +% 120; }
    pub fn accessor121(self: *const HugeModel) u32 { return self.count +% 121; }
    pub fn accessor122(self: *const HugeModel) u32 { return self.count +% 122; }
    pub fn accessor123(self: *const HugeModel) u32 { return self.count +% 123; }
    pub fn accessor124(self: *const HugeModel) u32 { return self.count +% 124; }
    pub fn accessor125(self: *const HugeModel) u32 { return self.count +% 125; }
    pub fn accessor126(self: *const HugeModel) u32 { return self.count +% 126; }
    pub fn accessor127(self: *const HugeModel) u32 { return self.count +% 127; }
    pub fn accessor128(self: *const HugeModel) u32 { return self.count +% 128; }
    pub fn accessor129(self: *const HugeModel) u32 { return self.count +% 129; }
    pub fn accessor130(self: *const HugeModel) u32 { return self.count +% 130; }
    pub fn accessor131(self: *const HugeModel) u32 { return self.count +% 131; }
    pub fn accessor132(self: *const HugeModel) u32 { return self.count +% 132; }
    pub fn accessor133(self: *const HugeModel) u32 { return self.count +% 133; }
    pub fn accessor134(self: *const HugeModel) u32 { return self.count +% 134; }
    pub fn accessor135(self: *const HugeModel) u32 { return self.count +% 135; }
    pub fn accessor136(self: *const HugeModel) u32 { return self.count +% 136; }
    pub fn accessor137(self: *const HugeModel) u32 { return self.count +% 137; }
    pub fn accessor138(self: *const HugeModel) u32 { return self.count +% 138; }
    pub fn accessor139(self: *const HugeModel) u32 { return self.count +% 139; }
    pub fn accessor140(self: *const HugeModel) u32 { return self.count +% 140; }
    pub fn accessor141(self: *const HugeModel) u32 { return self.count +% 141; }
    pub fn accessor142(self: *const HugeModel) u32 { return self.count +% 142; }
    pub fn accessor143(self: *const HugeModel) u32 { return self.count +% 143; }
    pub fn accessor144(self: *const HugeModel) u32 { return self.count +% 144; }
    pub fn accessor145(self: *const HugeModel) u32 { return self.count +% 145; }
    pub fn accessor146(self: *const HugeModel) u32 { return self.count +% 146; }
    pub fn accessor147(self: *const HugeModel) u32 { return self.count +% 147; }
    pub fn accessor148(self: *const HugeModel) u32 { return self.count +% 148; }
    pub fn accessor149(self: *const HugeModel) u32 { return self.count +% 149; }
    pub fn label0(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label0 {d}", .{self.count}) catch "label0"; }
    pub fn label1(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label1 {d}", .{self.count}) catch "label1"; }
    pub fn label2(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label2 {d}", .{self.count}) catch "label2"; }
    pub fn label3(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label3 {d}", .{self.count}) catch "label3"; }
    pub fn label4(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label4 {d}", .{self.count}) catch "label4"; }
    pub fn label5(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label5 {d}", .{self.count}) catch "label5"; }
    pub fn label6(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label6 {d}", .{self.count}) catch "label6"; }
    pub fn label7(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label7 {d}", .{self.count}) catch "label7"; }
    pub fn label8(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label8 {d}", .{self.count}) catch "label8"; }
    pub fn label9(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label9 {d}", .{self.count}) catch "label9"; }
    pub fn label10(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label10 {d}", .{self.count}) catch "label10"; }
    pub fn label11(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label11 {d}", .{self.count}) catch "label11"; }
    pub fn label12(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label12 {d}", .{self.count}) catch "label12"; }
    pub fn label13(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label13 {d}", .{self.count}) catch "label13"; }
    pub fn label14(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label14 {d}", .{self.count}) catch "label14"; }
    pub fn label15(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label15 {d}", .{self.count}) catch "label15"; }
    pub fn label16(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label16 {d}", .{self.count}) catch "label16"; }
    pub fn label17(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label17 {d}", .{self.count}) catch "label17"; }
    pub fn label18(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label18 {d}", .{self.count}) catch "label18"; }
    pub fn label19(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label19 {d}", .{self.count}) catch "label19"; }
    pub fn label20(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label20 {d}", .{self.count}) catch "label20"; }
    pub fn label21(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label21 {d}", .{self.count}) catch "label21"; }
    pub fn label22(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label22 {d}", .{self.count}) catch "label22"; }
    pub fn label23(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label23 {d}", .{self.count}) catch "label23"; }
    pub fn label24(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label24 {d}", .{self.count}) catch "label24"; }
    pub fn label25(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label25 {d}", .{self.count}) catch "label25"; }
    pub fn label26(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label26 {d}", .{self.count}) catch "label26"; }
    pub fn label27(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label27 {d}", .{self.count}) catch "label27"; }
    pub fn label28(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label28 {d}", .{self.count}) catch "label28"; }
    pub fn label29(self: *const HugeModel, arena: std.mem.Allocator) []const u8 { return std.fmt.allocPrint(arena, "label29 {d}", .{self.count}) catch "label29"; }
    pub fn slice0(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice1(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice2(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice3(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice4(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice5(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice6(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice7(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice8(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice9(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice10(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice11(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice12(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice13(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice14(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice15(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice16(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice17(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice18(self: *const HugeModel) []const HugeItem { return self.items; }
    pub fn slice19(self: *const HugeModel) []const HugeItem { return self.items; }
};

const HugeMsg = union(enum) {
    increment,
    reset,
};

/// Default features on purpose: this instantiates `MarkupView(HugeModel)`
/// exactly the way a real ~200-decl app Model failed before the quota
/// derivation.
const HugeApp = ui_app_model.UiApp(HugeModel, HugeMsg);

fn hugeUpdate(model: *HugeModel, msg: HugeMsg) void {
    switch (msg) {
        .increment => model.count += 1,
        .reset => model.count = 0,
    }
}

fn hugeView(ui: *HugeApp.Ui, model: *const HugeModel) HugeApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, ui.fmt("Count {d}", .{model.count})),
        ui.button(.{ .variant = .primary, .on_press = .increment }, "Increment"),
    });
}

const huge_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const huge_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Huge",
    .width = 400,
    .height = 300,
    .views = &huge_views,
}};
const huge_scene: app_manifest.ShellConfig = .{ .windows = &huge_windows };

fn hugeOptions() HugeApp.Options {
    return .{
        .name = "ui-app-huge",
        .scene = huge_scene,
        .canvas_label = canvas_label,
        .update = hugeUpdate,
        .view = hugeView,
    };
}

fn findButtonId(tree: HugeApp.Ui.Tree) ?canvas.ObjectId {
    return findIn(tree.root);
}

fn findIn(widget: canvas.Widget) ?canvas.ObjectId {
    if (widget.kind == .button) return widget.id;
    for (widget.children) |child| {
        if (findIn(child)) |id| return id;
    }
    return null;
}

test "a Model larger than the stack constructs, installs, and dispatches through create" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // The old shape — `app.* = HugeApp.init(alloc, .{}, options)` — put a
    // 12 MiB Model temporary on this frame and segfaulted before the
    // assertion machinery even ran.
    // The old shape — `app.* = HugeApp.init(alloc, initialHugeModel(),
    // options)` — materialized the runtime-built 12 MiB Model as a
    // caller-stack temporary and segfaulted (verified while landing
    // this fix; comptime-known `.{}` arguments happen to dodge it via
    // rodata, which is why only REAL apps with runtime-initialized
    // models crashed).
    const app_state = try HugeApp.create(std.heap.page_allocator, hugeOptions());
    defer app_state.destroy();

    // Follow-up model mutation through the pointer, the create contract.
    app_state.model.count = 41;

    // Follow-up model mutation through the pointer, the create contract.

    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // Update dispatch and view rebuild run against the heap model.
    const increment_id = findButtonId(app_state.tree.?).?;
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, increment_id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqual(@as(u32, 42), app_state.model.count);
}

test "initInPlace leaves the model to the caller and the app still runs" {
    const app_state = try std.heap.page_allocator.create(HugeApp);
    defer std.heap.page_allocator.destroy(app_state);
    HugeApp.initInPlace(app_state, std.heap.page_allocator, hugeOptions());
    // Result-location semantics write the literal straight into the heap
    // struct; a 12 MiB Model makes any regression here a crash.
    app_state.model = .{ .count = 7 };
    defer app_state.deinit();

    try std.testing.expectEqual(@as(u32, 7), app_state.model.count);
    try std.testing.expectEqual(@as(u32, 8), HugeModel.accessor1(&app_state.model));
}
