//! Compile-cost guard: a deliberately huge Model — ovation-shaped,
//! ~240 public decls plus dozens of distinct slice item types — must build
//! through BOTH markup engines without the test (or any app) raising
//! `@setEvalBranchQuota`. Before the fix, `collectItemTypes`'s comptime
//! walk blew the default 1000-backwards-branch quota the moment `UiApp`'s
//! default features compiled `MarkupView(Model)`, even for apps that never
//! use markup. The engines now derive their quotas from the scanned type
//! (`typeScanQuota`); this fixture is the regression tripwire — if a new
//! Model-scaled comptime walk lands without a derived quota, this file
//! fails to compile.

const std = @import("std");
const canvas = @import("root.zig");
const markup_view = @import("ui_markup_view.zig");
const compiled_view = @import("ui_markup_compiled.zig");


const Item0 = struct {
    name: []const u8 = "item0",
    count: u32 = 0,
};

const Item1 = struct {
    name: []const u8 = "item1",
    count: u32 = 1,
};

const Item2 = struct {
    name: []const u8 = "item2",
    count: u32 = 2,
};

const Item3 = struct {
    name: []const u8 = "item3",
    count: u32 = 3,
};

const Item4 = struct {
    name: []const u8 = "item4",
    count: u32 = 4,
};

const Item5 = struct {
    name: []const u8 = "item5",
    count: u32 = 5,
};

const Item6 = struct {
    name: []const u8 = "item6",
    count: u32 = 6,
};

const Item7 = struct {
    name: []const u8 = "item7",
    count: u32 = 7,
};

const Item8 = struct {
    name: []const u8 = "item8",
    count: u32 = 8,
};

const Item9 = struct {
    name: []const u8 = "item9",
    count: u32 = 9,
};

const Item10 = struct {
    name: []const u8 = "item10",
    count: u32 = 10,
};

const Item11 = struct {
    name: []const u8 = "item11",
    count: u32 = 11,
};

const Item12 = struct {
    name: []const u8 = "item12",
    count: u32 = 12,
};

const Item13 = struct {
    name: []const u8 = "item13",
    count: u32 = 13,
};

const Item14 = struct {
    name: []const u8 = "item14",
    count: u32 = 14,
};

const Item15 = struct {
    name: []const u8 = "item15",
    count: u32 = 15,
};

const Item16 = struct {
    name: []const u8 = "item16",
    count: u32 = 16,
};

const Item17 = struct {
    name: []const u8 = "item17",
    count: u32 = 17,
};

const Item18 = struct {
    name: []const u8 = "item18",
    count: u32 = 18,
};

const Item19 = struct {
    name: []const u8 = "item19",
    count: u32 = 19,
};

const Item20 = struct {
    name: []const u8 = "item20",
    count: u32 = 20,
};

const Item21 = struct {
    name: []const u8 = "item21",
    count: u32 = 21,
};

const Item22 = struct {
    name: []const u8 = "item22",
    count: u32 = 22,
};

const Item23 = struct {
    name: []const u8 = "item23",
    count: u32 = 23,
};

pub const HugeModel = struct {
    items0: []const Item0 = &.{},
    items1: []const Item1 = &.{},
    items2: []const Item2 = &.{},
    items3: []const Item3 = &.{},
    items4: []const Item4 = &.{},
    items5: []const Item5 = &.{},
    items6: []const Item6 = &.{},
    items7: []const Item7 = &.{},
    items8: []const Item8 = &.{},
    items9: []const Item9 = &.{},
    items10: []const Item10 = &.{},
    items11: []const Item11 = &.{},
    items12: []const Item12 = &.{},
    items13: []const Item13 = &.{},
    items14: []const Item14 = &.{},
    items15: []const Item15 = &.{},
    items16: []const Item16 = &.{},
    items17: []const Item17 = &.{},
    items18: []const Item18 = &.{},
    items19: []const Item19 = &.{},
    items20: []const Item20 = &.{},
    items21: []const Item21 = &.{},
    items22: []const Item22 = &.{},
    items23: []const Item23 = &.{},
    tasks: []const Item0 = &.{},
    title: []const u8 = "huge",
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
    pub fn slice0(self: *const HugeModel) []const Item0 { return self.items0; }
    pub fn slice1(self: *const HugeModel) []const Item1 { return self.items1; }
    pub fn slice2(self: *const HugeModel) []const Item2 { return self.items2; }
    pub fn slice3(self: *const HugeModel) []const Item3 { return self.items3; }
    pub fn slice4(self: *const HugeModel) []const Item4 { return self.items4; }
    pub fn slice5(self: *const HugeModel) []const Item5 { return self.items5; }
    pub fn slice6(self: *const HugeModel) []const Item6 { return self.items6; }
    pub fn slice7(self: *const HugeModel) []const Item7 { return self.items7; }
    pub fn slice8(self: *const HugeModel) []const Item8 { return self.items8; }
    pub fn slice9(self: *const HugeModel) []const Item9 { return self.items9; }
    pub fn slice10(self: *const HugeModel) []const Item10 { return self.items10; }
    pub fn slice11(self: *const HugeModel) []const Item11 { return self.items11; }
    pub fn slice12(self: *const HugeModel) []const Item12 { return self.items12; }
    pub fn slice13(self: *const HugeModel) []const Item13 { return self.items13; }
    pub fn slice14(self: *const HugeModel) []const Item14 { return self.items14; }
    pub fn slice15(self: *const HugeModel) []const Item15 { return self.items15; }
    pub fn slice16(self: *const HugeModel) []const Item16 { return self.items16; }
    pub fn slice17(self: *const HugeModel) []const Item17 { return self.items17; }
    pub fn slice18(self: *const HugeModel) []const Item18 { return self.items18; }
    pub fn slice19(self: *const HugeModel) []const Item19 { return self.items19; }
    pub const constant0: u32 = 0;
    pub const constant1: u32 = 1;
    pub const constant2: u32 = 2;
    pub const constant3: u32 = 3;
    pub const constant4: u32 = 4;
    pub const constant5: u32 = 5;
    pub const constant6: u32 = 6;
    pub const constant7: u32 = 7;
    pub const constant8: u32 = 8;
    pub const constant9: u32 = 9;
    pub const constant10: u32 = 10;
    pub const constant11: u32 = 11;
    pub const constant12: u32 = 12;
    pub const constant13: u32 = 13;
    pub const constant14: u32 = 14;
    pub const constant15: u32 = 15;
    pub const constant16: u32 = 16;
    pub const constant17: u32 = 17;
    pub const constant18: u32 = 18;
    pub const constant19: u32 = 19;
};

pub const HugeMsg = union(enum) {
    variant0,
    variant1,
    variant2,
    variant3,
    variant4,
    variant5,
    variant6,
    variant7,
    variant8,
    variant9,
    variant10,
    variant11,
    variant12,
    variant13,
    variant14,
    variant15,
    variant16,
    variant17,
    variant18,
    variant19,
    variant20,
    variant21,
    variant22,
    variant23,
    variant24,
    variant25,
    variant26,
    variant27,
    variant28,
    variant29,
    variant30,
    variant31,
    variant32,
    variant33,
    variant34,
    variant35,
    variant36,
    variant37,
    variant38,
    variant39,
    variant40,
    variant41,
    variant42,
    variant43,
    variant44,
    variant45,
    variant46,
    variant47,
    variant48,
    variant49,
    variant50,
    variant51,
    variant52,
    variant53,
    variant54,
    variant55,
    variant56,
    variant57,
    variant58,
    variant59,
    variant60,
    variant61,
    variant62,
    variant63,
    press_item: u32,
};


const huge_source =
    \\<column gap="8">
    \\  <text>{title}</text>
    \\  <text>{label0}</text>
    \\  <for each="tasks" as="task">
    \\    <button on-press="variant0">{task.name}</button>
    \\  </for>
    \\  <if test="{count}">
    \\    <text>nonzero</text>
    \\  </if>
    \\</column>
;

test "huge Model builds through the interpreter without raising the eval-branch quota" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var view = try markup_view.MarkupView(HugeModel, HugeMsg).init(arena, huge_source);
    var ui = canvas.Ui(HugeMsg).init(arena);
    const model: HugeModel = .{ .tasks = &.{ .{ .name = "a" }, .{ .name = "b" } } };
    const node = try view.build(&ui, &model);
    try std.testing.expect(node.nodes.len >= 3);
}

test "huge Model builds through the compiled engine without raising the eval-branch quota" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ui = canvas.Ui(HugeMsg).init(arena);
    const model: HugeModel = .{ .tasks = &.{.{ .name = "a" }} };
    const node = compiled_view.CompiledMarkupView(HugeModel, HugeMsg, huge_source).build(&ui, &model);
    try std.testing.expect(node.nodes.len >= 3);
}
