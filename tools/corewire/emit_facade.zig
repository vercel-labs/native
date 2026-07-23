//! core_facade.ts emission: the TypeScript projection of the same
//! contract the Zig mirror carries. One sidecar, two projections — the
//! host imports core_shim.zig, a compiler consumes this module — so the
//! two sides can never skew: types, declaration orders, number classes,
//! wire tags, and the canonical value encoding all derive from one
//! artifact.
//!
//! The emitted module is subset TypeScript the shipped checker accepts,
//! and it is deliberately SELF-CONTAINED: it declares the contract's
//! mirror types itself instead of importing the author's module,
//! because today's subset rules pin the behavioral entry points to the
//! compile entry (a core exporting update from an imported module is
//! refused, and command values may not leave update's return path).
//! The behavioral surface — dispatch entries that run the author's
//! update, command-byte encoding, helper forwarders — therefore stays
//! with the compile mode that owns those dispensations; what THIS
//! module carries is everything the byte contract needs stated in
//! TypeScript:
//!
//! - the mirror types (interfaces, literal-union enums, kind-tagged
//!   message union) with the sidecar's names, field orders, and — for
//!   single-payload arms, whose authored member names the emitted
//!   contract erases — a fixed `value` member that erases identically;
//! - the declaration-order wire-tag table and one typed constructor per
//!   message arm (`nsc_core_msg_<arm>`), throwing a kind-tagged
//!   teaching value on contract violations;
//! - the canonical value encoding, including the arithmetic f64 bit
//!   extractor (exact for every finite double, the infinities, and the
//!   canonical quiet NaN), exported as `nsc_core_model_snapshot` plus
//!   the two scalar probes the parity suite drives;
//! - the identity constants, the sidecar's unbound-list declarations
//!   (authors declare nothing; the generator carries them), and
//!   deterministic zero/sample model builders so a compiled facade can
//!   prove its encodings against the host's canonical encoder.
//!
//! Input model: the generator consumes CONTRACT FACTS — the author
//! module's own declarations (types, arms, unbound markings) plus the
//! profile's constants. In production those facts precede compilation
//! (the facade is the compile's entry, so no compiler-emitted artifact
//! can feed it); the conformance harness drives this emitter from
//! corpus sidecars as its adapter, which is sound because a sidecar
//! encodes exactly those facts. Deterministic: a pure function of the
//! fact value, pinned by a test. FACADE-GAPS in SCHEMA-GAPS.md records
//! each inexpressible surface with the subset rule that pins it.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const emit_mod = @import("emit.zig");

const Sidecar = sidecar_mod.Sidecar;
const TypeRef = sidecar_mod.TypeRef;

pub const Error = error{ Refused, OutOfMemory };

pub fn emitFacade(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    var emitter = FacadeEmitter{
        .arena = arena,
        .sidecar = sidecar,
        .diags = diags,
        .out = .empty,
    };
    try emitter.run();
    if (diags.hasErrors()) return error.Refused;
    return emitter.out.items;
}

/// TypeScript reserved words a declaration may not take (no quoting
/// escape exists on that side, unlike Zig's @"..." names).
const ts_reserved_words = [_][]const u8{
    "break",     "case",     "catch",     "class",   "const",     "continue",   "debugger",  "default",
    "delete",    "do",       "else",      "enum",    "export",    "extends",    "false",     "finally",
    "for",       "function", "if",        "import",  "in",        "instanceof", "new",       "null",
    "return",    "super",    "switch",    "this",    "throw",     "true",       "try",       "typeof",
    "var",       "void",     "while",     "with",    "let",       "static",     "yield",     "await",
    "interface", "type",     "number",    "boolean", "string",    "object",     "undefined",
    // Strict-mode reservations (modules are always strict).
    "implements",
    "package",   "private",  "protected", "public",  "arguments", "eval",
};

const FacadeEmitter = struct {
    arena: std.mem.Allocator,
    sidecar: Sidecar,
    diags: *sidecar_mod.Diagnostics,
    out: std.ArrayListUnmanaged(u8),
    inlined: []const []const u8 = &.{},
    sample_ordinal: usize = 0,

    /// The projection's spelling for a table name: the compile profile
    /// designates the root exports `Model` and `Msg` by exact name (the
    /// root's commit machinery and dispatch wiring key on them), so the
    /// facade DECLARES its roots under those spellings whatever the
    /// contract calls them, and aliases the contract names for
    /// reference fidelity. TypeScript type names never reach the host's
    /// reflection surface, so this renames nothing observable.
    fn spellName(self: *FacadeEmitter, name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, self.sidecar.model)) return "Model";
        if (std.mem.eql(u8, name, self.sidecar.msg.name)) return "Msg";
        return name;
    }

    fn print(self: *FacadeEmitter, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.out.appendSlice(self.arena, text);
    }

    fn raw(self: *FacadeEmitter, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn run(self: *FacadeEmitter) Error!void {
        try self.validateNames();
        self.validateOptionalDepth();
        if (self.diags.hasErrors()) return;
        self.inlined = try emit_mod.inlinedTableNames(self.arena, self.sidecar);
        try self.header();
        try self.typeMirrors();
        try self.unboundDecl();
        try self.entryPoints();
        try self.constants();
        try self.msgConstructors();
        try self.sampleBuilders();
        try self.encoders();
    }

    // ------------------------------------------------------- fencing

    fn validateNames(self: *FacadeEmitter) Error!void {
        // Declaration names (type-table entries and the message union)
        // must be plain TypeScript identifiers: TypeScript has no
        // quoted-declaration escape. Field, member, and arm names are
        // free — properties may quote, and arm names ride string
        // literals plus identifier FRAGMENTS (constructor suffixes), so
        // they only need fragment-safe characters.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.enums) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.unions) |entry| try names.append(self.arena, entry.name);
        try names.append(self.arena, self.sidecar.msg.name);

        for (names.items) |name| {
            if (!isTsIdentifier(name)) {
                self.diags.flag("types", "\"{s}\" is not a declarable TypeScript identifier, and TypeScript has no quoted-declaration escape — rename it in the core source", .{name});
            }
            // Ambient globals the generated module leans on: a local
            // declaration would shadow them out from under the encoders.
            if (std.mem.eql(u8, name, "Uint8Array")) {
                self.diags.flag("types", "\"Uint8Array\" shadows the ambient byte type every encoder in the generated facade uses; rename the type in the core source", .{});
            }
        }
        for (self.sidecar.msg.arms) |arm| {
            if (!isIdentifierFragment(arm.name)) {
                self.diags.flag("msg.arms", "arm \"{s}\" cannot join the facade's constructor names (nsc_core_msg_<arm>); use identifier characters in the core source", .{arm.name});
            }
        }
        const facade_decls = [_][]const u8{ "initialModel", "update", "viewUnbound", "asciiBytes", "NscfContractError", "NSCF_POW" };
        // Field names join the fence only for the reserved nsc name
        // space (they may otherwise be anything, quoted if exotic):
        // constructor parameter fallbacks and the runtime prelude own
        // those spellings.
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                if (std.mem.startsWith(u8, field.name, "nsc_core_") or std.mem.startsWith(u8, field.name, "nscf")) {
                    self.diags.flag("types", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field.name});
                }
            }
        }
        // number_bytes descriptor fields never enter the type table but
        // become constructor parameters and record members all the same.
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    for ([_][]const u8{ desc.number_field, desc.bytes_field }) |field_name| {
                        if (std.mem.startsWith(u8, field_name, "nsc_core_") or std.mem.startsWith(u8, field_name, "nscf")) {
                            self.diags.flag("msg.arms", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field_name});
                        }
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.structs) |entry| try self.fenceDecl(entry.name, &facade_decls);
        for (self.sidecar.types.enums) |entry| try self.fenceDecl(entry.name, &facade_decls);
        for (self.sidecar.types.unions) |entry| try self.fenceDecl(entry.name, &facade_decls);
        try self.fenceDecl(self.sidecar.msg.name, &facade_decls);
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) try self.fenceDecl("", &.{}); // placeholder keeps shape symmetric
    }

    fn fenceDecl(self: *FacadeEmitter, name: []const u8, facade_decls: []const []const u8) Error!void {
        if (name.len == 0) return;
        if (std.mem.startsWith(u8, name, "nsc_core_") or std.mem.startsWith(u8, name, "nscf")) {
            self.diags.flag("types", "\"{s}\" collides with the facade's reserved nsc name space; rename it in the core source", .{name});
            return;
        }
        for (facade_decls) |decl| {
            if (std.mem.eql(u8, name, decl)) {
                self.diags.flag("types", "\"{s}\" collides with a declaration the generated facade itself must make; rename it in the core source", .{name});
            }
        }
        // The facade aliases the entry vocabulary's fixed spellings when
        // the sidecar's own names differ (mirroring the Zig side).
        if (!std.mem.eql(u8, self.sidecar.model, name) and std.mem.eql(u8, name, "Model") and !std.mem.eql(u8, self.sidecar.model, "Model")) {
            self.diags.flag("types", "\"Model\" collides with the facade's entry alias for the model root; rename it in the core source", .{});
        }
        if (!std.mem.eql(u8, self.sidecar.msg.name, name) and std.mem.eql(u8, name, "Msg") and !std.mem.eql(u8, self.sidecar.msg.name, "Msg")) {
            self.diags.flag("types", "\"Msg\" collides with the facade's entry alias for the message union; rename it in the core source", .{});
        }
    }

    /// TypeScript's null carries exactly one absence level, so a nested
    /// optional has no faithful projection (its own source language
    /// cannot author one either: `T | null | null` collapses).
    fn validateOptionalDepth(self: *FacadeEmitter) void {
        for (self.sidecar.types.structs, 0..) |entry, index| {
            for (entry.fields, 0..) |field, field_index| {
                self.flagNestedOptional(field.type, false, pathText(self.arena, "types.structs[{d}].fields[{d}].type", .{ index, field_index }));
            }
        }
        for (self.sidecar.types.unions, 0..) |entry, index| {
            for (entry.arms, 0..) |arm, arm_index| {
                self.flagNestedOptional(arm.payload, false, pathText(self.arena, "types.unions[{d}].arms[{d}].payload", .{ index, arm_index }));
            }
        }
        for (self.sidecar.model_helpers, 0..) |helper, index| {
            self.flagNestedOptional(helper.returns, false, pathText(self.arena, "model_helpers[{d}].returns", .{index}));
            for (helper.params, 0..) |param, param_index| {
                self.flagNestedOptional(param, false, pathText(self.arena, "model_helpers[{d}].params[{d}]", .{ index, param_index }));
            }
        }
        for (self.sidecar.msg.arms, 0..) |arm, index| {
            switch (arm.payload) {
                .scalar => |ref| self.flagNestedOptional(ref, false, pathText(self.arena, "msg.arms[{d}].payload.type", .{index})),
                else => {},
            }
        }
    }

    fn flagNestedOptional(self: *FacadeEmitter, ref: TypeRef, inside_optional: bool, at: []const u8) void {
        switch (ref) {
            .optional => |inner| {
                if (inside_optional) {
                    self.diags.flag(at, "a nested optional has no TypeScript projection — one null carries one absence level, and the source language cannot author a second; flatten the state in the core source", .{});
                    return;
                }
                self.flagNestedOptional(inner.*, true, at);
            },
            .slice => |elem| self.flagNestedOptional(elem.*, false, at),
            else => {},
        }
    }

    // ------------------------------------------------------- sections

    fn header(self: *FacadeEmitter) Error!void {
        try self.print(
            \\// Generated by corewire from this app's core.contract.json — the
            \\// TypeScript projection of the compiled core's contract. The same
            \\// sidecar generates the host's Zig mirror (core_shim.zig), so the
            \\// two sides carry one set of types, wire tags, field orders, and
            \\// byte encodings by construction. Do not edit; regenerate from the
            \\// sidecar.
            \\//
            \\// Contract identity: entry {s}, compiler {s}, build_id
            \\// {x:0>16}.
            \\
            \\import {{ asciiBytes }} from "@native-sdk/core";
            \\
        , .{ commentText(self.arena, self.sidecar.entry), commentText(self.arena, self.sidecar.compiler_version), self.sidecar.build_id });
    }

    fn typeMirrors(self: *FacadeEmitter) Error!void {
        for (self.sidecar.types.enums) |entry| {
            try self.print("\nexport type {s} =", .{entry.name});
            for (entry.members, 0..) |member, index| {
                try self.print("{s} \"{s}\"", .{ if (index == 0) "" else " |", tsString(self.arena, member) });
            }
            try self.raw(";\n");
        }
        // Every table entry gets a NAMED declaration: the subset has no
        // inline object types, and TypeScript names never reach the
        // host's reflection surface, so the Zig lane's inline-anonymous
        // fidelity concern does not exist here.
        for (self.sidecar.types.structs) |*entry| {
            if (std.mem.eql(u8, entry.name, self.sidecar.model)) continue;
            try self.structInterface(entry);
        }
        for (self.sidecar.types.unions) |entry| {
            try self.print("\nexport type {s} =", .{entry.name});
            for (entry.arms) |arm| {
                try self.print("\n  | {s}", .{try self.armTypeLiteral(entry.name, arm.name, armPayloadRef(arm))});
            }
            try self.raw(";\n");
        }
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        try self.structInterface(model);
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) {
            try self.print("\n/// The contract's own spelling for the root state type (the\n/// declaration takes the profile's designated export name).\nexport type {s} = Model;\n", .{self.sidecar.model});
        }

        try self.raw("\nexport type Msg =");
        for (self.sidecar.msg.arms) |arm| {
            try self.print("\n  | {s}", .{try self.msgArmTypeLiteral(arm)});
        }
        try self.raw(";\n");
        if (!std.mem.eql(u8, self.sidecar.msg.name, "Msg")) {
            try self.print("\n/// The contract's own spelling for the message union (the\n/// declaration takes the profile's designated export name).\nexport type {s} = Msg;\n", .{self.sidecar.msg.name});
        }
    }

    fn structInterface(self: *FacadeEmitter, entry: *const sidecar_mod.Struct) Error!void {
        try self.print("\nexport interface {s} {{", .{self.spellName(entry.name)});
        for (entry.fields) |field| {
            try self.print("\n  readonly {s}: {s};", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, entry.name, field.name) });
        }
        try self.raw("\n}\n");
    }

    /// One arm of a kind-tagged union type: bare, single `value`
    /// member, or (for a synthesized inline record) the record's own
    /// fields flattened beside `kind`. Single-payload member names are
    /// the facade's choice — the emitted contract erases them, so any
    /// spelling projects to the same compiled layout.
    fn armTypeLiteral(self: *FacadeEmitter, union_name: []const u8, arm_name: []const u8, payload: ?TypeRef) Error![]const u8 {
        const escaped = tsString(self.arena, arm_name);
        const ref = payload orelse
            return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\" }}", .{escaped});
        // A synthesized inline record flattens beside `kind`, exactly
        // as its authoring produced it; everything else is a single
        // payload whose authored member name the contract erased.
        if (self.synthesizedRecordOf(ref, union_name, arm_name)) |record| {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"", .{escaped}));
            for (record.fields) |field| {
                try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "; readonly {s}: {s}", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, record.name, field.name) }));
            }
            try text.appendSlice(self.arena, " }");
            return text.items;
        }
        return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, try self.spellRef(ref, union_name, arm_name) });
    }

    /// The struct behind a synthesized, inlined record reference at
    /// this site — the shape that flattens beside `kind`.
    fn synthesizedRecordOf(self: *FacadeEmitter, ref: TypeRef, container: []const u8, member: []const u8) ?*const sidecar_mod.Struct {
        const name = switch (ref) {
            .node, .value => |n| n,
            else => return null,
        };
        if (!emit_mod.isSynthesizedRef(container, member, name) or !nameListed(self.inlined, name)) return null;
        return sidecar_mod.findStruct(self.sidecar.types, name);
    }

    fn msgArmTypeLiteral(self: *FacadeEmitter, arm: sidecar_mod.MsgArm) Error![]const u8 {
        const escaped = tsString(self.arena, arm.name);
        switch (arm.payload) {
            .void => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\" }}", .{escaped}),
            .bytes => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: Uint8Array }}", .{escaped}),
            .number => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: number }}", .{escaped}),
            .number_bytes => |desc| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly {s}: number; readonly {s}: Uint8Array }}", .{ escaped, try tsProp(self.arena, desc.number_field), try tsProp(self.arena, desc.bytes_field) }),
            .record => |name| {
                if (nameListed(self.inlined, name) and emit_mod.isSynthesizedRef(self.sidecar.msg.name, arm.name, name)) {
                    // The transpiled contract flattened these fields
                    // beside `kind`, preserving their names — restate
                    // them the same way.
                    const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                    var text: std.ArrayListUnmanaged(u8) = .empty;
                    try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"", .{escaped}));
                    for (record.fields) |field| {
                        try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "; readonly {s}: {s}", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, name, field.name) }));
                    }
                    try text.appendSlice(self.arena, " }");
                    return text.items;
                }
                return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, name });
            },
            .union_ref, .enum_ref => |name| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, name }),
            .scalar => |ref| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, try self.spellRef(ref, "", "") }),
        }
    }

    /// The one TypeRef-to-TypeScript-spelling authority (the facade twin
    /// of the Zig mirror's spellRef).
    fn spellRef(self: *FacadeEmitter, ref: TypeRef, container: []const u8, member: []const u8) Error![]const u8 {
        return switch (ref) {
            .bool => "boolean",
            .f64, .i64 => "number",
            .bytes => "Uint8Array",
            .void => "void",
            .optional => |inner| try std.fmt.allocPrint(self.arena, "{s} | null", .{try self.spellRef(inner.*, container, member)}),
            .slice => |elem| blk: {
                // Composite element spellings parenthesize: `number |
                // null[]` would type the null as the array.
                const spelled = try self.spellRef(elem.*, container, member);
                if (std.mem.indexOfAny(u8, spelled, " |") != null) {
                    break :blk try std.fmt.allocPrint(self.arena, "readonly ({s})[]", .{spelled});
                }
                break :blk try std.fmt.allocPrint(self.arena, "readonly {s}[]", .{spelled});
            },
            // Reference storage is a layout fact of the host mirror;
            // TypeScript sees the record value either way.
            .node, .value => |name| self.arena.dupe(u8, self.spellName(name)),
            .enum_ref, .union_ref => |name| self.arena.dupe(u8, self.spellName(name)),
        };
    }

    fn unboundDecl(self: *FacadeEmitter) Error!void {
        // Only names this module DECLARES may ride the list: message
        // arms and model fields. An unbound HELPER stays in the sidecar
        // fact (helpers are mode-forwarded and the facade declares
        // none), so listing it here would name nothing the checker can
        // resolve.
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        var field_unbound: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.model_unbound) |name| {
            for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    try field_unbound.append(self.arena, name);
                    break;
                }
            }
        }
        // The authoring surface is ONE list resolved by name, so a name
        // that is both a model field and a message arm cannot be marked
        // on one side only — the sidecar's split lists carry more than
        // the projection can say. Refuse the divergent case instead of
        // silently marking the wrong declaration.
        for (self.sidecar.msg.unbound) |name| {
            const also_field = for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break true;
            } else false;
            if (also_field and !nameListed(self.sidecar.model_unbound, name)) {
                self.diags.flag("msg.unbound", "\"{s}\" is an unbound message arm AND a bound model field — the projection's single unbound list resolves by name and would mark both; rename one side in the core source", .{name});
            }
        }
        for (field_unbound.items) |name| {
            const also_arm = sidecar_mod.findArm(self.sidecar.msg, name) != null;
            if (also_arm and !nameListed(self.sidecar.msg.unbound, name)) {
                self.diags.flag("model_unbound", "\"{s}\" is an unbound model field AND a bound message arm — the projection's single unbound list resolves by name and would mark both; rename one side in the core source", .{name});
            }
        }
        if (self.diags.hasErrors()) return;
        if (field_unbound.items.len == 0 and self.sidecar.msg.unbound.len == 0) return;
        try self.raw(
            \\
            \\// The unbound-list declaration, carried by the generator from the
            \\// author's own markings in the core module: message arms only the
            \\// host fires and model fields only update logic reads. (This
            \\// convention's exact wording is provisional pending the authoring
            \\// spec; the mechanics — one list, generator-carried — are settled.)
            \\export const viewUnbound = [
            \\
        );
        for (self.sidecar.msg.unbound) |name| {
            try self.print("  \"{s}\",\n", .{tsString(self.arena, name)});
        }
        for (field_unbound.items) |name| {
            // A name unbound on both sides rides once.
            if (nameListed(self.sidecar.msg.unbound, name)) continue;
            try self.print("  \"{s}\",\n", .{tsString(self.arena, name)});
        }
        try self.raw("] as const;\n");
    }

    fn entryPoints(self: *FacadeEmitter) Error!void {
        // The zero model: the deterministic value every entry-shape
        // consumer can boot against. The compiled core's real init and
        // update stay with the author's module; the compile mode wires
        // them in (FACADE-GAPS records the subset rules that keep the
        // forwarders out of this module today).
        var zero = std.ArrayListUnmanaged(u8).empty;
        try self.zeroValue(&zero, .{ .value = self.sidecar.model }, 1);
        try self.print(
            \\
            \\export function initialModel(): Model {{
            \\  return {s};
            \\}}
            \\
            \\export function update(model: Model, msg: Msg): Model {{
            \\  return model;
            \\}}
            \\
        , .{zero.items});
    }

    fn constants(self: *FacadeEmitter) Error!void {
        try self.print(
            \\
            \\export const nsc_core_abi_version = {d};
            \\export const nsc_core_snapshot_format = {d};
            \\// 64-bit identities ride as 16-hex-digit strings: a number carries
            \\// at most 2^53 exactly.
            \\export const nsc_core_build_id = "{x:0>16}";
            \\
            \\// Declaration-order wire tags, one constant per arm (the subset
            \\// folds numeric constants; a generic string table is not model
            \\// vocabulary).
            \\
        , .{ self.sidecar.abi_version, self.sidecar.abi.snapshot_format, self.sidecar.build_id });
        for (self.sidecar.msg.arms, 0..) |arm, tag| {
            try self.print("export const nsc_core_tag_{s} = {d};\n", .{ arm.name, tag });
        }
    }

    fn msgConstructors(self: *FacadeEmitter) Error!void {
        const msg = "Msg";
        try self.raw("\n// One typed constructor per message arm (the dispatch-table\n// projection): the host names arms by wire tag, this side by name.\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .void => try self.print("\nexport function nsc_core_msg_{s}(): {s} {{\n  return {{ kind: \"{s}\" }};\n}}\n", .{ arm.name, msg, tsString(self.arena, arm.name) }),
                .bytes => try self.print("\nexport function nsc_core_msg_{s}(value: Uint8Array): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, msg, tsString(self.arena, arm.name) }),
                .number => try self.print("\nexport function nsc_core_msg_{s}(value: number): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, msg, tsString(self.arena, arm.name) }),
                .number_bytes => |desc| {
                    const number_param = try tsParam(self.arena, desc.number_field, 0);
                    const bytes_param = try tsParam(self.arena, desc.bytes_field, 1);
                    try self.print("\nexport function nsc_core_msg_{s}({s}: number, {s}: Uint8Array): {s} {{\n  return {{ kind: \"{s}\", {s}: {s}, {s}: {s} }};\n}}\n", .{ arm.name, number_param, bytes_param, msg, tsString(self.arena, arm.name), try tsProp(self.arena, desc.number_field), number_param, try tsProp(self.arena, desc.bytes_field), bytes_param });
                },
                .record => |name| {
                    // Synthesized names pattern on the CONTRACT's message
                    // name; the facade's fixed `Msg` spelling is only the
                    // declared type.
                    if (nameListed(self.inlined, name) and emit_mod.isSynthesizedRef(self.sidecar.msg.name, arm.name, name)) {
                        const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                        var params: std.ArrayListUnmanaged(u8) = .empty;
                        var fields: std.ArrayListUnmanaged(u8) = .empty;
                        for (record.fields, 0..) |field, index| {
                            const param = try tsParam(self.arena, field.name, index);
                            if (index > 0) try params.appendSlice(self.arena, ", ");
                            try params.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ param, try self.spellRef(field.type, name, field.name) }));
                            try fields.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", {s}: {s}", .{ try tsProp(self.arena, field.name), param }));
                        }
                        try self.print("\nexport function nsc_core_msg_{s}({s}): {s} {{\n  return {{ kind: \"{s}\"{s} }};\n}}\n", .{ arm.name, params.items, msg, tsString(self.arena, arm.name), fields.items });
                    } else {
                        try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, name, msg, tsString(self.arena, arm.name) });
                    }
                },
                .union_ref, .enum_ref => |name| try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, name, msg, tsString(self.arena, arm.name) }),
                .scalar => |ref| try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, try self.spellRef(ref, "", ""), msg, tsString(self.arena, arm.name) }),
            }
        }
    }

    // ------------------------------------------------ value builders

    fn sampleBuilders(self: *FacadeEmitter) Error!void {
        var sample = std.ArrayListUnmanaged(u8).empty;
        self.sample_ordinal = 0;
        try self.sampleValue(&sample, .{ .value = self.sidecar.model }, 1);
        try self.print(
            \\
            \\/// A deterministic, non-trivial model value (every field populated,
            \\/// varied numbers, present optionals, two-element sequences) for
            \\/// proving the snapshot encoding against the host's canonical
            \\/// encoder.
            \\export function nsc_core_sample_model(): Model {{
            \\  return {s};
            \\}}
            \\
        , .{sample.items});
    }

    fn indentText(self: *FacadeEmitter, depth: usize) Error![]const u8 {
        const text = try self.arena.alloc(u8, depth * 2);
        @memset(text, ' ');
        return text;
    }

    fn zeroValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize) Error!void {
        switch (ref) {
            .bool => try out.appendSlice(self.arena, "false"),
            .f64, .i64 => try out.appendSlice(self.arena, "0"),
            .bytes => try out.appendSlice(self.arena, "new Uint8Array(0)"),
            .void => try out.appendSlice(self.arena, "undefined"),
            .optional => try out.appendSlice(self.arena, "null"),
            .slice => try out.appendSlice(self.arena, "[]"),
            .node, .value => |name| {
                const entry = sidecar_mod.findStruct(self.sidecar.types, name).?;
                try self.recordValue(out, entry, depth, zeroField);
            },
            .enum_ref => |name| {
                const entry = sidecar_mod.findEnum(self.sidecar.types, name).?;
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "\"{s}\"", .{tsString(self.arena, entry.members[0])}));
            },
            .union_ref => |name| {
                const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
                try self.unionValue(out, entry, 0, depth, zeroField);
            },
        }
    }

    const FieldValueFn = *const fn (self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize) Error!void;

    fn zeroField(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize) Error!void {
        try self.zeroValue(out, ref, depth);
    }

    fn sampleField(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize) Error!void {
        try self.sampleValue(out, ref, depth);
    }

    fn recordValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), entry: *const sidecar_mod.Struct, depth: usize, field_value: FieldValueFn) Error!void {
        try out.appendSlice(self.arena, "{\n");
        for (entry.fields) |field| {
            try out.appendSlice(self.arena, try self.indentText(depth + 1));
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s}: ", .{try tsProp(self.arena, field.name)}));
            try field_value(self, out, field.type, depth + 1);
            try out.appendSlice(self.arena, ",\n");
        }
        try out.appendSlice(self.arena, try self.indentText(depth));
        try out.appendSlice(self.arena, "}");
    }

    fn unionValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), entry: *const sidecar_mod.Union, arm_index: usize, depth: usize, field_value: FieldValueFn) Error!void {
        const arm = entry.arms[arm_index];
        if (arm.payload == .void) {
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\" }}", .{tsString(self.arena, arm.name)}));
            return;
        }
        if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\"", .{tsString(self.arena, arm.name)}));
            for (record.fields) |field| {
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", {s}: ", .{try tsProp(self.arena, field.name)}));
                try field_value(self, out, field.type, depth);
            }
            try out.appendSlice(self.arena, " }");
            return;
        }
        try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", value: ", .{tsString(self.arena, arm.name)}));
        try field_value(self, out, arm.payload, depth);
        try out.appendSlice(self.arena, " }");
    }

    fn sampleValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize) Error!void {
        self.sample_ordinal += 1;
        const n: i64 = @intCast(self.sample_ordinal);
        switch (ref) {
            .bool => try out.appendSlice(self.arena, if (@rem(n, 2) == 0) "true" else "false"),
            .i64 => try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{n * 7 - 12})),
            .f64 => {
                // Varied signs and fractions (quarters stay exact in
                // binary, so both encoders see identical values).
                const quarters = n * 13 - 22;
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}.{s}", .{ @divFloor(quarters, 4), fractionText(@mod(quarters, 4)) }));
            },
            .bytes => try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "asciiBytes(\"sample-{d}\")", .{n})),
            .void => try out.appendSlice(self.arena, "undefined"),
            .optional => |inner| try self.sampleValue(out, inner.*, depth),
            .slice => |elem| {
                try out.appendSlice(self.arena, "[\n");
                for (0..2) |_| {
                    try out.appendSlice(self.arena, try self.indentText(depth + 1));
                    try self.sampleValue(out, elem.*, depth + 1);
                    try out.appendSlice(self.arena, ",\n");
                }
                try out.appendSlice(self.arena, try self.indentText(depth));
                try out.appendSlice(self.arena, "]");
            },
            .node, .value => |name| {
                const entry = sidecar_mod.findStruct(self.sidecar.types, name).?;
                try self.recordValue(out, entry, depth, sampleField);
            },
            .enum_ref => |name| {
                const entry = sidecar_mod.findEnum(self.sidecar.types, name).?;
                const member = entry.members[@intCast(@mod(n, @as(i64, @intCast(entry.members.len))))];
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "\"{s}\"", .{tsString(self.arena, member)}));
            },
            .union_ref => |name| {
                const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
                const arm_index: usize = @intCast(@mod(n, @as(i64, @intCast(entry.arms.len))));
                try self.unionValue(out, entry, arm_index, depth, sampleField);
            },
        }
    }

    // ---------------------------------------------------- encoders

    fn encoders(self: *FacadeEmitter) Error!void {
        try self.raw(
            \\
            \\// ----------------------------------------------------------------
            \\// The canonical value encoding (the host decodes with the same
            \\// rules): little-endian, headerless, record fields in declaration
            \\// order; numbers 8 bytes (i64 two's complement / f64 bit pattern),
            \\// bool one byte, bytes and sequences u32-length-prefixed, enums a
            \\// u32 declaration-order member index, options one presence byte,
            \\// union values a one-byte arm index before the payload.
            \\
            \\// Detected contract violations throw this kind-tagged teaching
            \\// value; an exception that escapes the compiled core reaches the
            \\// host's panic sink with an "Uncaught " prefix on its message.
            \\export interface NscfContractError {
            \\  readonly kind: "nscf_contract";
            \\  readonly teaching: Uint8Array;
            \\}
            \\
            \\// Every encoder returns an OWNED byte buffer and byte values are
            \\// integer-derived end to end (literals, lengths, byte reads, and
            \\// integer arithmetic over them): the number model gives each
            \\// number slot one machine class, and byte stores require the
            \\// integer one. Runs concatenate by copy (nscfCat); fractional
            \\// arithmetic (the f64 bit extraction) only ever feeds comparisons.
            \\
            \\function nscfNoParts(): Uint8Array[] {
            \\  return [];
            \\}
            \\
            \\function nscfCat(parts: readonly Uint8Array[]): Uint8Array {
            \\  let total = 0;
            \\  for (let i = 0; i < parts.length; i++) {
            \\    total = total + parts[i].length;
            \\  }
            \\  const out = new Uint8Array(total);
            \\  let at = 0;
            \\  for (let i = 0; i < parts.length; i++) {
            \\    out.set(parts[i], at);
            \\    at = at + parts[i].length;
            \\  }
            \\  return out;
            \\}
            \\
            \\function nscfByte(value: number): Uint8Array {
            \\  const out = new Uint8Array(1);
            \\  out[0] = value;
            \\  return out;
            \\}
            \\
            \\// The most-significant-first bits of a whole value below 2^width,
            \\// as bytes (byte reads are integer-valued, so bits re-enter integer
            \\// arithmetic when the bytes assemble). The scan carries two locals —
            \\// the remaining value and a halving power — and dividing a power of
            \\// two by two is exact all the way down to one. nscfI64 repeats this
            \\// scan privately instead of calling here: its input slots are host
            \\// boundary values, and keeping boundary and non-boundary callers
            \\// out of one function keeps the number-model resolution linear.
            \\function nscfBitsBelow(value: number, width: number): Uint8Array {
            \\  let p = 1;
            \\  for (let i = 1; i < width; i++) {
            \\    p = p * 2;
            \\  }
            \\  let rest = value;
            \\  // The emitted `new Uint8Array(n)` is a fresh arena allocation that
            \\  // only counts as initialized where written; sparse bit writers
            \\  // start from explicit zeros.
            \\  const bits = new Uint8Array(width);
            \\  for (let i = 0; i < width; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  for (let i = 0; i < width; i++) {
            \\    if (rest >= p) {
            \\      bits[i] = 1;
            \\      rest = rest - p;
            \\    }
            \\    p = p / 2;
            \\  }
            \\  return bits;
            \\}
            \\
            \\// Little-endian bytes from most-significant-first bits (byteCount
            \\// times eight bits).
            \\function nscfBitsToBytes(bits: Uint8Array, byteCount: number): Uint8Array {
            \\  const out = new Uint8Array(byteCount);
            \\  let start = bits.length - 8;
            \\  let at = 0;
            \\  while (start >= 0) {
            \\    let v = 0;
            \\    for (let bit = 0; bit < 8; bit++) {
            \\      v = v * 2 + bits[start + bit];
            \\    }
            \\    out[at] = v;
            \\    at = at + 1;
            \\    start = start - 8;
            \\  }
            \\  return out;
            \\}
            \\
            \\// i64, two's complement LE. Values are whole and within +-(2^53 - 1)
            \\// by the number model; negatives ride the identity
            \\// bits(v) = ~bits(-1 - v). The sign paths stay separate statements
            \\// end to end.
            \\function nscfI64(value: number): Uint8Array {
            \\  const bits = new Uint8Array(64);
            \\  for (let i = 0; i < 64; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  if (value < 0) {
            \\    let rest = -1 - value;
            \\    let p = 4503599627370496;
            \\    for (let i = 0; i < 53; i++) {
            \\      if (rest >= p) {
            \\        rest = rest - p;
            \\      } else {
            \\        bits[11 + i] = 1;
            \\      }
            \\      p = p / 2;
            \\    }
            \\    for (let i = 0; i < 11; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  let rest = value;
            \\  let p = 4503599627370496;
            \\  for (let i = 0; i < 53; i++) {
            \\    if (rest >= p) {
            \\      bits[11 + i] = 1;
            \\      rest = rest - p;
            \\    }
            \\    p = p / 2;
            \\  }
            \\  return nscfBitsToBytes(bits, 8);
            \\}
            \\
            \\function nscfU32(value: number): Uint8Array {
            \\  return nscfBitsToBytes(nscfBitsBelow(value, 32), 4);
            \\}
            \\
            \\// The f64 bit pattern by exact arithmetic (multiplying and dividing
            \\// by two is exact for every finite double): sign, biased exponent,
            \\// then 52 fraction bits extracted most significant first. NaN
            \\// canonicalizes to the quiet pattern; fractional arithmetic feeds
            \\// comparisons only, never a byte slot.
            \\function nscfF64(value: number): Uint8Array {
            \\  const bits = new Uint8Array(64);
            \\  for (let i = 0; i < 64; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  if (value !== value) {
            \\    for (let i = 1; i < 13; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  const negative = value < 0 || (value === 0 && 1 / value < 0);
            \\  if (negative) {
            \\    bits[0] = 1;
            \\  }
            \\  const magnitude = value < 0 ? -value : value;
            \\  if (magnitude - magnitude !== 0) {
            \\    for (let i = 1; i < 12; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  if (magnitude === 0) {
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  let exponent = 0;
            \\  let mantissa = magnitude;
            \\  while (mantissa >= 2) {
            \\    mantissa = mantissa / 2;
            \\    exponent = exponent + 1;
            \\  }
            \\  while (mantissa < 1 && exponent > -1022) {
            \\    mantissa = mantissa * 2;
            \\    exponent = exponent - 1;
            \\  }
            \\  let biased = 0;
            \\  let fraction = mantissa;
            \\  if (mantissa >= 1) {
            \\    biased = exponent + 1023;
            \\    fraction = mantissa - 1;
            \\  }
            \\  const expBits = nscfBitsBelow(biased, 11);
            \\  for (let i = 0; i < 11; i++) {
            \\    const expBit = expBits[i];
            \\    bits[1 + i] = expBit;
            \\  }
            \\  for (let i = 0; i < 52; i++) {
            \\    fraction = fraction * 2;
            \\    if (fraction >= 1) {
            \\      bits[12 + i] = 1;
            \\      fraction = fraction - 1;
            \\    }
            \\  }
            \\  return nscfBitsToBytes(bits, 8);
            \\}
            \\
            \\function nscfBytes(value: Uint8Array): Uint8Array {
            \\  return nscfCat([nscfU32(value.length), value]);
            \\}
            \\
            \\export function nsc_core_probe_i64(value: number): Uint8Array {
            \\  return nscfI64(value);
            \\}
            \\
            \\export function nsc_core_probe_f64(value: number): Uint8Array {
            \\  return nscfF64(value);
            \\}
            \\
        );

        for (self.sidecar.types.enums) |entry| {
            try self.print("\nfunction nscfIndex{s}(value: {s}): number {{\n", .{ entry.name, entry.name });
            for (entry.members, 0..) |member, index| {
                if (index + 1 == entry.members.len) {
                    try self.print("  return {d};\n}}\n", .{index});
                } else {
                    try self.print("  if (value === \"{s}\") {{\n    return {d};\n  }}\n", .{ tsString(self.arena, member), index });
                }
            }
        }

        for (self.sidecar.types.structs) |*entry| {
            try self.structEncoder(entry);
        }
        for (self.sidecar.types.unions) |*entry| {
            try self.unionEncoder(entry);
        }

        try self.print(
            \\
            \\/// The committed model in the canonical value encoding — the exact
            \\/// bytes the host's snapshot decoder expects. The caller states the
            \\/// snapshot generation it wants (a mismatch is a refusal, never a
            \\/// silently different encoding), and the committed value arrives as
            \\/// a parameter: module state lives in the model, and a snapshot
            \\/// entry is not a view helper, so it must not join the model's
            \\/// binding surface.
            \\export function nsc_core_model_snapshot(snapshotFormat: number, model: Model): Uint8Array {{
            \\  if (snapshotFormat !== nsc_core_snapshot_format) {{
            \\    throw {{ kind: "nscf_contract", teaching: asciiBytes("this facade encodes snapshot format {d}; re-generate the caller or the facade so both speak one generation") }} as NscfContractError;
            \\  }}
            \\  return nscfEncode{s}(model);
            \\}}
            \\
        , .{ self.sidecar.abi.snapshot_format, self.sidecar.model });
    }

    fn encoderNameFor(self: *FacadeEmitter, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "nscfEncode{s}", .{name});
    }

    fn structEncoder(self: *FacadeEmitter, entry: *const sidecar_mod.Struct) Error!void {
        try self.print("\nfunction {s}(value: {s}): Uint8Array {{\n  const parts: Uint8Array[] = [...nscfNoParts()];\n", .{ try self.encoderNameFor(entry.name), self.spellName(entry.name) });
        for (entry.fields, 0..) |field, index| {
            // Temp names seed per field: every statement shares one
            // function scope, and optional/slice nesting takes the +1
            // steps within the field's own range.
            try self.fieldEncodeStatements(field.type, try tsAccess(self.arena, "value", field.name), 1, index * 8);
        }
        try self.raw("  return nscfCat(parts);\n}\n");
    }

    fn unionEncoder(self: *FacadeEmitter, entry: *const sidecar_mod.Union) Error!void {
        try self.print("\nfunction {s}(value: {s}): Uint8Array {{\n", .{ try self.encoderNameFor(entry.name), self.spellName(entry.name) });
        for (entry.arms, 0..) |arm, index| {
            try self.print("  if (value.kind === \"{s}\") {{\n    const parts: Uint8Array[] = [nscfByte({d})];\n", .{ tsString(self.arena, arm.name), index });
            if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                // Flattened beside `kind`: encode the record's fields
                // off the narrowed arm in declaration order.
                for (record.fields, 0..) |field, field_index| {
                    try self.fieldEncodeStatements(field.type, try tsAccess(self.arena, "value", field.name), 2, field_index * 8);
                }
            } else if (arm.payload != .void) {
                try self.fieldEncodeStatements(arm.payload, "value.value", 2, 0);
            }
            try self.raw("    return nscfCat(parts);\n  }\n");
        }
        try self.print("  throw {{ kind: \"nscf_contract\", teaching: asciiBytes(\"{s} carries an arm outside its declared union — the value and the contract disagree\") }} as NscfContractError;\n}}\n", .{tsString(self.arena, entry.name)});
    }

    /// Statements appending `expr`'s canonical encoding to `parts`.
    fn fieldEncodeStatements(self: *FacadeEmitter, ref: TypeRef, expr: []const u8, depth: usize, temp_seed: usize) Error!void {
        const pad = try self.indentText(depth);
        switch (ref) {
            .bool => try self.print("{s}parts[parts.length] = nscfByte({s} ? 1 : 0);\n", .{ pad, expr }),
            .i64 => try self.print("{s}parts[parts.length] = nscfI64({s});\n", .{ pad, expr }),
            .f64 => try self.print("{s}parts[parts.length] = nscfF64({s});\n", .{ pad, expr }),
            .bytes => try self.print("{s}parts[parts.length] = nscfBytes({s});\n", .{ pad, expr }),
            .void => {},
            .optional => |inner| {
                const temp = try std.fmt.allocPrint(self.arena, "nscfOpt{d}", .{temp_seed});
                try self.print("{s}const {s} = {s};\n{s}if ({s} === null) {{\n{s}  parts[parts.length] = nscfByte(0);\n{s}}} else {{\n{s}  parts[parts.length] = nscfByte(1);\n", .{ pad, temp, expr, pad, temp, pad, pad, pad });
                try self.fieldEncodeStatements(inner.*, temp, depth + 1, temp_seed + 1);
                try self.print("{s}}}\n", .{pad});
            },
            .slice => |elem| {
                const index = try std.fmt.allocPrint(self.arena, "nscfIdx{d}", .{temp_seed});
                try self.print("{s}parts[parts.length] = nscfU32({s}.length);\n{s}for (let {s} = 0; {s} < {s}.length; {s}++) {{\n", .{ pad, expr, pad, index, index, expr, index });
                try self.fieldEncodeStatements(elem.*, try std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ expr, index }), depth + 1, temp_seed + 1);
                try self.print("{s}}}\n", .{pad});
            },
            .node, .value => |name| try self.print("{s}parts[parts.length] = {s}({s});\n", .{ pad, try self.encoderNameFor(name), expr }),
            .enum_ref => |name| try self.print("{s}parts[parts.length] = nscfU32(nscfIndex{s}({s}));\n", .{ pad, name, expr }),
            .union_ref => |name| try self.print("{s}parts[parts.length] = {s}({s});\n", .{ pad, try self.encoderNameFor(name), expr }),
        }
    }
};

fn pathText(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "";
}

fn armPayloadRef(arm: sidecar_mod.UnionArm) ?TypeRef {
    return if (arm.payload == .void) null else arm.payload;
}

fn fractionText(quarters: i64) []const u8 {
    return switch (quarters) {
        0 => "0",
        1 => "25",
        2 => "5",
        else => "75",
    };
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn commentText(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const out = arena.dupe(u8, text) catch return "";
    for (out) |*char| {
        if (char.* < 0x20 or char.* == 0x7f) char.* = ' ';
    }
    // U+2028/U+2029 are line terminators to a TypeScript scanner: blank
    // their UTF-8 bytes so provenance text cannot end the comment early.
    var index: usize = 0;
    while (index + 2 < out.len) : (index += 1) {
        if (out[index] == 0xe2 and out[index + 1] == 0x80 and (out[index + 2] == 0xa8 or out[index + 2] == 0xa9)) {
            out[index] = ' ';
            out[index + 1] = ' ';
            out[index + 2] = ' ';
        }
    }
    return out;
}

/// Escape a name into a TS double-quoted string literal (arm names ride
/// string literals in the kind-tagged union).
fn tsString(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |char| {
        switch (char) {
            '"' => out.appendSlice(arena, "\\\"") catch return text,
            '\\' => out.appendSlice(arena, "\\\\") catch return text,
            '\n' => out.appendSlice(arena, "\\n") catch return text,
            '\r' => out.appendSlice(arena, "\\r") catch return text,
            '\t' => out.appendSlice(arena, "\\t") catch return text,
            else => out.append(arena, char) catch return text,
        }
    }
    return out.items;
}

/// A property spelling: plain identifiers stay bare (reserved words
/// are legal property names); anything else quotes.
fn tsProp(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return name;
    }
    return std.fmt.allocPrint(arena, "\"{s}\"", .{tsString(arena, name)});
}

/// A property ACCESS: dot for plain spellings, brackets otherwise.
fn tsAccess(arena: std.mem.Allocator, base: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ base, name });
    }
    return std.fmt.allocPrint(arena, "{s}[\"{s}\"]", .{ base, tsString(arena, name) });
}

/// A parameter name derived from an authored field name: reserved words
/// and exotic spellings fall back to a positional name (parameters,
/// unlike properties, must be plain identifiers).
fn tsParam(arena: std.mem.Allocator, name: []const u8, index: usize) error{OutOfMemory}![]const u8 {
    if (isTsIdentifier(name)) return name;
    // The fallback lives in the fenced nsc name space, so it can never
    // collide with an authored sibling field's spelling.
    return std.fmt.allocPrint(arena, "nscf_arg{d}", .{index});
}

fn isIdentifierFragment(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    return true;
}

fn isTsIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    for (ts_reserved_words) |word| {
        if (std.mem.eql(u8, name, word)) return false;
    }
    return true;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn facadeFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, json, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
    return emitFacade(arena, parsed, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
}

test "facade emission is deterministic and carries the projection surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "export interface Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "readonly count: number;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export type Msg =") != null);
    try testing.expect(std.mem.indexOf(u8, first, "| { readonly kind: \"label_set\"; readonly value: Uint8Array }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export const nsc_core_build_id = \"00000000b01dface\";") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function nsc_core_msg_bump(): Msg {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function nsc_core_model_snapshot(snapshotFormat: number, model: Model): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "function nscfF64(value: number): Uint8Array {") != null);
    // The unbound list rides the facade (the author declares nothing).
    try testing.expect(std.mem.indexOf(u8, first, "export const viewUnbound = [\n  \"label_set\",\n] as const;") != null);
}

test "composite slice elements parenthesize in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "readonly label: readonly (number | null)[];") != null);
}

test "renamed roots declare under the profile's designated spellings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"State\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"slot\": \"Model.count\"", "\"slot\": \"State.count\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    const generated = try facadeFromJson(arena, source);
    // The root commit machinery and dispatch wiring key on the exact
    // exports; the contract's own names ride as aliases.
    try testing.expect(std.mem.indexOf(u8, generated, "export interface Model {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type State = Model;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type Msg =") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type Event = Msg;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function initialModel(): Model {") != null);
}

test "unbound helper names stay out of the facade's viewUnbound list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"summary\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_unbound\": []", "\"model_unbound\": [\"summary\", \"count\"]");
    const generated = try facadeFromJson(arena, source);
    // The facade declares no helpers, so the checker could resolve
    // "summary" to nothing; the field entry rides, the helper's stays a
    // sidecar fact.
    try testing.expect(std.mem.indexOf(u8, generated, "\"count\",") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"summary\",") == null);
}

test "synthesized records inside tabled unions flatten beside kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The set_composition shape: an authored multi-field arm whose
    // record was tabled under the synthesized pattern.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Edit_set_composition\", \"fields\": [{\"name\": \"text\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"cursor\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Edit\", \"arms\": [{\"name\": \"clear\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"set_composition\", \"payload\": {\"kind\": \"value\", \"name\": \"Edit_set_composition\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "| { readonly kind: \"set_composition\"; readonly text: Uint8Array; readonly cursor: number | null }") != null);
    // The union encoder reads the flattened fields off the narrowed arm.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"set_composition\")") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfOpt8 = value.cursor;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "value.value") == null);
}

test "renamed message roots still flatten their synthesized payload records" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A single-use Event_loaded record on a union named Event: the arm
    // type flattens it, so the constructor must build the flattened
    // shape, not a `value` member.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Event_loaded\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Event_loaded\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "| { readonly kind: \"loaded\"; readonly status: number; readonly ok: boolean }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_msg_loaded(status: number, ok: boolean): Msg {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "return { kind: \"loaded\", status: status, ok: ok };") != null);
}

test "an unbound name split across homonymous field and arm refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Msg arm "count" is unbound; Model field "count" is bound: one
    // name-resolved list cannot say that.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"count\"]");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "single unbound list resolves by name") != null) found = true;
    }
    try testing.expect(found);
}

test "nested optionals refuse in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "one absence level") != null) found = true;
    }
    try testing.expect(found);
}

test "strict-mode reserved words cannot declare" {
    try testing.expect(!isTsIdentifier("implements"));
    try testing.expect(!isTsIdentifier("private"));
    try testing.expect(!isTsIdentifier("arguments"));
    try testing.expect(isTsIdentifier("implementation"));
}

test "number_bytes fields in the reserved nsc space refuse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An authored "nscf_arg1" beside an exotic sibling would collide
    // with the sibling's positional parameter fallback.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"nscf_arg1\", \"number_class\": \"f64\", \"bytes_field\": \"body-data\"}}",
    );
    _ = &source;
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "reserved nsc name space") != null) found = true;
    }
    try testing.expect(found);
}

test "a type taking a generated facade declaration's name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"NscfContractError\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"NscfContractError\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}

test "facade names that TypeScript cannot declare refuse with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"class\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "not a declarable TypeScript identifier") != null) found = true;
    }
    try testing.expect(found);
}

test "a type in the facade's reserved nsc name space refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"nscfHelper\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"nscfHelper\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}
