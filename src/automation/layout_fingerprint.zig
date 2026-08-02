//! Comptime layout fingerprints: build identity for wire formats that
//! never migrate.
//!
//! The session journal and the automation dropbox protocol refuse ANY
//! skew — both sides always rebuild from one checkout, no old shape is
//! ever read — so an ordered version integer carried no information
//! ("same or different" is the entire question) while costing two
//! recurring failures: parallel branches contending for the next
//! integer, and forgettable bumps. A fingerprint has neither: it is a
//! Wyhash over a canonical comptime-built DESCRIPTION of the layout
//! (the ui_schema registry's fingerprint idiom), and because the
//! description reflects over the actual declared types, a layout change
//! moves the identity with no manual step.
//!
//! `describe` renders a type structurally and deterministically:
//! integers/floats/bools by name, enums with every field name AND value
//! (journaled enums ride their declaration-order integers, so a reorder
//! must move the fingerprint), structs and unions with field names and
//! recursively-described types in declaration order (a tagged union's
//! tag enum included, names and values — discriminants are layout when
//! the tag rides the wire), optionals, arrays with lengths, slices, and
//! pointers. What reflection cannot see —
//! hand-written byte layouts inside codecs (bit assignments, chosen
//! integer widths, framing) — the caller states as deliberate constants
//! in its description string, with the coupling commented at the codec.
//!
//! Fingerprints are combined with a small manual `semantic_epoch` at
//! each call site: the escape hatch for a change in MEANING that leaves
//! the bytes identical, which no layout description can see.

const std = @import("std");

/// Wyhash over a canonical layout description. Stated once so every
/// fingerprint (and every test perturbing one) agrees on what a
/// fingerprint is.
pub fn hash(description: []const u8) u64 {
    return std.hash.Wyhash.hash(0, description);
}

/// A canonical, structural, comptime description of `T`. Two types
/// describe equal exactly when their declared layouts match — field
/// names, field order, field types (recursively), enum values, array
/// lengths. Type NAMES are deliberately not included (a rename that
/// keeps the shape is not a layout change); field names are (decoders
/// key meaning off them).
pub fn describe(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        switch (@typeInfo(T)) {
            .int, .float => return @typeName(T),
            .bool => return "bool",
            .void => return "void",
            .@"enum" => |info| {
                var out: []const u8 = "enum(" ++ @typeName(info.tag_type) ++ "){";
                for (info.fields) |field| {
                    out = out ++ field.name ++ "=" ++ std.fmt.comptimePrint("{d}", .{field.value}) ++ ",";
                }
                return out ++ "}";
            },
            .@"struct" => |info| {
                var out: []const u8 = "struct{";
                for (info.fields) |field| {
                    out = out ++ field.name ++ ":" ++ describe(field.type) ++ ",";
                }
                return out ++ "}";
            },
            .@"union" => |info| {
                // A tagged union's discriminant VALUES are layout when
                // the tag rides the wire, so the tag enum (names and
                // values) is part of the description — two unions with
                // identical fields but swapped tag values must never
                // fingerprint equal.
                var out: []const u8 = if (info.tag_type) |tag|
                    "union(" ++ describe(tag) ++ "){"
                else
                    "union{";
                for (info.fields) |field| {
                    out = out ++ field.name ++ ":" ++ describe(field.type) ++ ",";
                }
                return out ++ "}";
            },
            .optional => |info| return "?" ++ describe(info.child),
            .array => |info| return "[" ++ std.fmt.comptimePrint("{d}", .{info.len}) ++ "]" ++ describe(info.child),
            .pointer => |info| switch (info.size) {
                .slice => return "[]" ++ describe(info.child),
                else => return "*" ++ if (info.child == anyopaque) "anyopaque" else describe(info.child),
            },
            .@"opaque" => return @typeName(T),
            else => @compileError("layout fingerprint cannot describe " ++ @typeName(T)),
        }
    }
}

// -------------------------------------------------------------- tests

const testing = std.testing;

test "describe renders shape, not names" {
    const A = struct { count: u32, label: []const u8 };
    const B = struct { count: u32, label: []const u8 };
    // Same shape, different type name: identical description.
    try testing.expectEqualStrings(comptime describe(A), comptime describe(B));
    try testing.expectEqualStrings("struct{count:u32,label:[]u8,}", comptime describe(A));
}

test "an added field moves the fingerprint with no manual step" {
    // The forgettable-bump killer, pinned: a deliberately-different
    // layout (one extra field) through the same description builder
    // yields a different fingerprint.
    const Base = struct { kind: u8, key: u64, payload: []const u8 };
    const Extended = struct { kind: u8, key: u64, payload: []const u8, dropped: u32 };
    try testing.expect(hash(comptime describe(Base)) != hash(comptime describe(Extended)));
}

test "field renames, reorders, and type changes all move the fingerprint" {
    const Base = struct { width: u32, height: u32 };
    const Renamed = struct { w: u32, height: u32 };
    const Reordered = struct { height: u32, width: u32 };
    const Widened = struct { width: u64, height: u32 };
    const base = hash(comptime describe(Base));
    try testing.expect(base != hash(comptime describe(Renamed)));
    try testing.expect(base != hash(comptime describe(Reordered)));
    try testing.expect(base != hash(comptime describe(Widened)));
}

test "enum reorders move the fingerprint (declaration values ride the wire)" {
    const Forward = enum(u8) { header = 1, event = 2 };
    const Swapped = enum(u8) { header = 2, event = 1 };
    try testing.expect(hash(comptime describe(Forward)) != hash(comptime describe(Swapped)));
}

test "union tag discriminants move the fingerprint" {
    // Identical field names and payload types, swapped tag VALUES: a
    // serialized tag byte would decode as the wrong variant, so the
    // descriptions must differ.
    const TagForward = enum(u8) { data = 1, closed = 2 };
    const TagSwapped = enum(u8) { data = 2, closed = 1 };
    const Forward = union(TagForward) { data: u32, closed: void };
    const Swapped = union(TagSwapped) { data: u32, closed: void };
    try testing.expect(hash(comptime describe(Forward)) != hash(comptime describe(Swapped)));
    try testing.expectEqualStrings(
        "union(enum(u8){data=1,closed=2,}){data:u32,closed:void,}",
        comptime describe(Forward),
    );
}

test "describe reaches through optionals, arrays, slices, and nesting" {
    const Inner = enum(u8) { light, dark };
    const Outer = struct {
        scheme: Inner,
        point: ?struct { x: f32, y: f32 },
        bands: [4]u8,
        paths: []const []const u8,
        handle: ?*anyopaque,
    };
    try testing.expectEqualStrings(
        "struct{scheme:enum(u8){light=0,dark=1,},point:?struct{x:f32,y:f32,},bands:[4]u8,paths:[][]u8,handle:?*anyopaque,}",
        comptime describe(Outer),
    );
}
