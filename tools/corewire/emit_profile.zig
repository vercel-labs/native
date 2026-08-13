//! core_profile.json emission: the compiler profile that configures a
//! library-mode build of the generated facade. One sidecar, three
//! projections — the host imports core_shim.zig, a compiler consumes
//! core_facade.ts, and this profile tells that compiler's library mode
//! what to build: the entry module, the C symbol family (the ABI's
//! mode-provided symbols plus the export map binding every facade
//! export the sidecar attests to its marshalled signature), the
//! contract-sidecar emission the same invocation must produce, and the
//! SDK's determinism policy (fences, teachings, remediations).
//!
//! The emission is deterministic: a pure function of the contract facts
//! and the entry-module name, fixed key order, no timestamps or
//! environment — re-running the identical invocation reproduces a
//! byte-identical file, the same doctrine the sidecar emitter follows.
//!
//! Marshalled signatures use the v1 classes only (params f64/bool/
//! string/bytes/u8/u32/i32; returns those minus the integer plumbing
//! classes, plus void). The wire-shaped channel entries are expressible
//! in exactly these classes — bytes ride buffer parameters, the
//! modifier booleans u8, the pinch phase u32 — which is the point of
//! the wire shape: a union-typed parameter has no marshalling class and
//! never becomes one.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");

const Sidecar = sidecar_mod.Sidecar;

pub const Error = error{ Refused, OutOfMemory };

/// The entry-module spelling the profile declares when the caller
/// names none: the facade projection's conventional file name, beside
/// the profile.
pub const default_entry = "core_facade.ts";

/// One export-map row: the marshalled signature of a facade export, by
/// ABI suffix. The export name is the generated facade's own exported
/// function (the plain suffix; the conditional channel entries take the
/// facade's `abi_` spelling); the symbol takes the contract's prefix.
const ExportSignature = struct {
    suffix: []const u8,
    /// The facade's exported function name when it differs from the
    /// suffix (the subscription and channel ABI entries).
    export_name: ?[]const u8 = null,
    params: []const []const u8,
    returns: []const u8,
};

/// The marshalled signatures of every profile-mapped ABI entry, keyed
/// by export suffix. The four mode-provided symbols (init, the sink
/// registration, the result-arena reset, collect) ride the profile's
/// abi block instead, and the two identity getters are synthesized
/// from the profile's sidecar section — neither family appears here.
const export_signatures = [_]ExportSignature{
    .{ .suffix = "boot_cmd", .params = &.{}, .returns = "bytes" },
    .{ .suffix = "dispatch_void", .params = &.{"u8"}, .returns = "bytes" },
    .{ .suffix = "dispatch_bytes", .params = &.{ "u8", "bytes" }, .returns = "bytes" },
    .{ .suffix = "dispatch_number", .params = &.{ "u8", "f64" }, .returns = "bytes" },
    .{ .suffix = "dispatch_number_bytes", .params = &.{ "u8", "f64", "bytes" }, .returns = "bytes" },
    .{ .suffix = "dispatch_bool", .params = &.{ "u8", "u8" }, .returns = "bytes" },
    .{ .suffix = "dispatch_enum", .params = &.{ "u8", "u32" }, .returns = "bytes" },
    .{ .suffix = "dispatch_record", .params = &.{ "u8", "bytes" }, .returns = "bytes" },
    .{ .suffix = "dispatch_text_input", .params = &.{ "u8", "bytes" }, .returns = "bytes" },
    // The two-axis scroll record crosses as direct scalars: one
    // offset/velocity/viewport/content quartet per axis.
    .{ .suffix = "dispatch_scroll_state", .params = &.{ "u8", "f64", "f64", "f64", "f64", "f64", "f64", "f64", "f64" }, .returns = "bytes" },
    .{ .suffix = "subscriptions", .export_name = "abi_subscriptions", .params = &.{}, .returns = "bytes" },
    .{ .suffix = "model_snapshot", .params = &.{}, .returns = "bytes" },
    .{ .suffix = "persist_snapshot", .params = &.{}, .returns = "bytes" },
    .{ .suffix = "restore_model", .params = &.{"bytes"}, .returns = "bytes" },
    .{ .suffix = "migrate_model", .params = &.{ "bytes", "f64" }, .returns = "bytes" },
    .{ .suffix = "helper_call", .params = &.{ "u32", "bytes" }, .returns = "bytes" },
    // The wire-shaped conditional channel entries (present exactly when
    // the sidecar wires the channel): host-event params in, the channel
    // bytes envelope out.
    .{ .suffix = "command_msg", .export_name = "abi_command_msg", .params = &.{"bytes"}, .returns = "bytes" },
    .{ .suffix = "frame_msg", .export_name = "abi_frame_msg", .params = &.{ "f64", "f64", "f64", "f64" }, .returns = "bytes" },
    .{ .suffix = "key_msg", .export_name = "abi_key_msg", .params = &.{ "bytes", "u8", "u8", "u8", "u8" }, .returns = "bytes" },
    .{ .suffix = "pinch_msg", .export_name = "abi_pinch_msg", .params = &.{ "f64", "bytes", "u32", "f64", "f64", "f64" }, .returns = "bytes" },
    .{ .suffix = "drop_msg", .export_name = "abi_drop_msg", .params = &.{"bytes"}, .returns = "bytes" },
};

/// Suffixes that never enter the export map: the mode-provided symbols
/// the abi block names, and the identity getters the sidecar section
/// synthesizes from profile constants.
const unmapped_suffixes = [_][]const u8{
    "abi_version", "build_id", "set_panic_sink", "init", "collect", "frame_reset",
};

/// One determinism fence: a surface denied at compile time when the
/// compiled module graph reaches it, with the SDK's teaching naming the
/// sanctioned effect route.
const Fence = struct {
    /// Exactly one of `id` (one surface-manifest entry) or `prefix`
    /// (every entry it prefixes) is set.
    id: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    teaching: []const u8,
};

const randomness_teaching = "randomness is an effect: the core requests it through a command and the value arrives as a Msg, so a recorded session replays it exactly.";
const network_teaching = "network is an effect: declare requests as commands (Cmd.fetch, Cmd.request) and responses arrive as Msgs.";

const clock_teaching = "the wall clock is an effect: read it through the host's journaled clock — Cmd.now, Cmd.delay, and Sub.timer deliver fire times as Msgs, so a recorded session replays them exactly.";

/// The SDK determinism fences, keyed by the pinned compiler release's
/// surface-manifest ids. RELEASE-PINNED DATA: a fence id or prefix must
/// resolve against the pinned release's surface manifest, covering at
/// least one runtime-deniable entry — an unknown or unpoliceable
/// selector refuses the whole profile at load rather than riding
/// inert — so this table lists exactly what the pinned release can
/// fence, and it is the one place to grow when a release lands new
/// ids. Not fenceable at the pinned release, verified against its
/// loader: http/https/dgram/dns (module-level entries only, no
/// per-call trace to deny) and worker_threads/cluster (their members
/// fold to compile-time constants). Member prefixes carry the folded-
/// constant exemption, so a folded read (os.EOL) stays compilable
/// under its family's fence.
const determinism_fences = [_]Fence{
    .{ .id = "stdlib.math.random", .teaching = randomness_teaching },
    .{ .id = "node-builtin.crypto.randomBytes", .teaching = randomness_teaching },
    .{ .id = "node-builtin.crypto.randomUUID", .teaching = randomness_teaching },
    .{ .prefix = "stdlib.date.", .teaching = clock_teaching },
    .{ .prefix = "node-builtin.perf_hooks.", .teaching = clock_teaching },
    .{ .prefix = "node-builtin.fs.", .teaching = "files are effects: declare reads and writes as commands (Cmd.readFile, Cmd.writeFile) and results arrive as Msgs." },
    .{ .prefix = "node-builtin.net.", .teaching = network_teaching },
    .{ .prefix = "node-builtin.http2.", .teaching = network_teaching },
    .{ .prefix = "node-builtin.tls.", .teaching = network_teaching },
    .{ .prefix = "node-builtin.child_process.", .teaching = "processes are effects: run them through Cmd.spawn and their output arrives as Msgs." },
    .{ .prefix = "node-builtin.timers.", .teaching = "timers are effects: schedule Cmd.delay or Sub.timer and fire times arrive as Msgs through the host's journaled clock." },
    .{ .prefix = "node-builtin.os.", .teaching = "machine and session facts are host inputs: they reach a core as journaled Msgs, never as ambient reads." },
    .{ .prefix = "node-builtin.process.", .teaching = "process and environment facts are host inputs: environment values arrive as journaled Msgs through the env channel, and every other session fact reaches a core only as a host-delivered Msg." },
};

/// One rider entry for the teachings/remediations maps.
const Rider = struct {
    code: []const u8,
    text: []const u8,
};

/// Profile teachings on non-fence refusals. "async" is the shared key
/// both async-surface refusal codes read.
const determinism_teachings = [_]Rider{
    .{ .code = "async", .text = "async, promises, and timer callbacks are unavailable in an app core: the host executes effects — declare a command (Cmd.fetch, Cmd.delay) or a subscription (Sub.timer) and results arrive as Msgs." },
};

/// Remediations threaded into the structured trap encoding, one per
/// trap code where the SDK has a sanctioned recovery to name. A trapped
/// core is poisoned by contract, so every recovery goes through the
/// process, never through the wounded core.
const determinism_remediations = [_]Rider{
    .{ .code = "SC4013", .text = "rebuild the app: an exception escaping a core entry is contract skew between the compiled core and its host bindings, and one build regenerates both from one contract." },
    .{ .code = "SC4017", .text = "restart the app process: a trapped core is poisoned and never resumes in place, and the recorded session replays deterministically." },
};

pub fn emitProfile(arena: std.mem.Allocator, sidecar: Sidecar, entry: []const u8, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    // The profile is ENFORCEMENT data: a compile that succeeds under its
    // determinism fences attests deterministic, and the compilation mode
    // is structurally async-free — so a contract attesting false for
    // either cannot round-trip through this profile. Emitting one would
    // move the contradiction downstream (the core refuses at compile, or
    // its co-emitted contract silently flips the attestation); refuse
    // here instead, where the teaching can name the attestation.
    if (!sidecar.deterministic) {
        diags.flag("deterministic", "the contract attests deterministic: false, but this profile enforces the determinism fences and a core that compiles under them attests true by construction — build the core under this profile and regenerate from the contract it co-emits", .{});
    }
    if (!sidecar.async_free) {
        diags.flag("async_free", "the contract attests async_free: false, but this profile's compilation mode is structurally async-free — a core reaching async surface refuses under it, so this contract cannot have come from the profile it asks for; remove the async surface and regenerate the contract", .{});
    }
    if (diags.hasErrors()) return error.Refused;
    var emitter = ProfileEmitter{ .arena = arena, .sidecar = sidecar, .out = .empty };
    try emitter.run(entry);
    return emitter.out.items;
}

const ProfileEmitter = struct {
    arena: std.mem.Allocator,
    sidecar: Sidecar,
    out: std.ArrayListUnmanaged(u8),

    fn print(self: *ProfileEmitter, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.out.appendSlice(self.arena, text);
    }

    fn raw(self: *ProfileEmitter, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn run(self: *ProfileEmitter, entry: []const u8) Error!void {
        const prefix = self.sidecar.abi.prefix;
        try self.print(
            \\{{
            \\  "profile_format": 1,
            \\  "name": "native-sdk-core",
            \\  "entry": {s},
            \\  "emission": "llvm",
            \\  "abi": {{
            \\    "prefix": {s},
            \\    "init_symbol": {s},
            \\    "sink_register_symbol": {s},
            \\    "collect_symbol": {s},
            \\    "result_reset_symbol": {s}
            \\  }},
            \\  "exports": [
            \\
        , .{
            try self.jsonString(entry),
            try self.jsonString(prefix),
            try self.symbol(prefix, "init"),
            try self.symbol(prefix, "set_panic_sink"),
            try self.symbol(prefix, "collect"),
            try self.symbol(prefix, "frame_reset"),
        });

        // The export map, in the sidecar's attested (canonical) order:
        // every suffix the object exports that is neither mode-provided
        // nor identity-synthesized. The export name is the generated
        // facade's own exported function; the symbol carries the
        // contract's prefix.
        var first = true;
        for (self.sidecar.abi.exports) |suffix| {
            if (nameListed(&unmapped_suffixes, suffix)) continue;
            const signature = signatureFor(suffix) orelse continue;
            if (!first) try self.raw(",\n");
            first = false;
            try self.print("    {{ \"export\": {s}, \"symbol\": {s}, \"params\": [", .{ try self.jsonString(signature.export_name orelse suffix), try self.symbol(prefix, suffix) });
            for (signature.params, 0..) |class, index| {
                try self.print("{s}\"{s}\"", .{ if (index == 0) "" else ", ", class });
            }
            try self.print("], \"returns\": \"{s}\" }}", .{signature.returns});
        }
        try self.raw("\n  ],\n");

        // The contract-sidecar section: the same invocation that builds
        // the archive emits the sidecar at the declared path and
        // synthesizes the two identity getters from these constants.
        // The designations name the generated facade's own exported
        // declarations: the contract's root type spellings (the facade
        // re-exports the author's declarations verbatim) and the
        // wrapper entries whose return shapes restate the contract's
        // shape flags. A subscribing contract designates its
        // subscriptions wrapper; a non-subscribing one names none (the
        // compiler refuses dangling designations).
        try self.print(
            \\  "sidecar": {{
            \\    "path": "core.contract.json",
            \\    "wire_version": {d},
            \\    "abi_version": {d},
            \\    "snapshot_format": {d},
            \\    "build_id_symbol": {s},
            \\    "abi_version_symbol": {s},
            \\    "model": {s},
            \\    "msg": {s},
            \\    "init_export": "init",
            \\    "update_export": "coreUpdate",
            \\
        , .{
            self.sidecar.wire_version,
            self.sidecar.abi_version,
            self.sidecar.abi.snapshot_format,
            try self.symbol(prefix, "build_id"),
            try self.symbol(prefix, "abi_version"),
            try self.jsonString(self.sidecar.model),
            try self.jsonString(self.sidecar.msg.name),
        });
        if (self.sidecar.has_subscriptions) {
            try self.raw("    \"subscriptions_export\": \"coreSubscriptions\",\n");
        }
        // The integer-slot declarations carry through from the contract:
        // the compiler proves every declared slot whole at construction
        // (the generated facade and the author's own update logic carry
        // the inline proofs), and the co-emitted contract attests the
        // same classes the reference lane derived.
        if (self.sidecar.integer_slots.len == 0) {
            try self.raw("    \"integer_slots\": []\n  },\n");
        } else {
            try self.raw("    \"integer_slots\": [\n");
            for (self.sidecar.integer_slots, 0..) |slot, index| {
                try self.print("      {{ \"slot\": {s}, \"class\": \"{t}\" }}{s}\n", .{ try self.jsonString(slot.slot), slot.class, if (index + 1 == self.sidecar.integer_slots.len) "" else "," });
            }
            try self.raw("    ]\n  },\n");
        }

        // The determinism policy: deny-fences over the ambient surfaces
        // with the SDK's teachings, the shared async teaching, and the
        // trap remediations.
        try self.raw("  \"determinism\": {\n    \"teachings\": {\n");
        for (determinism_teachings, 0..) |rider, index| {
            try self.print("      {s}: {s}{s}\n", .{ try self.jsonString(rider.code), try self.jsonString(rider.text), if (index + 1 == determinism_teachings.len) "" else "," });
        }
        try self.raw("    },\n    \"remediations\": {\n");
        for (determinism_remediations, 0..) |rider, index| {
            try self.print("      {s}: {s}{s}\n", .{ try self.jsonString(rider.code), try self.jsonString(rider.text), if (index + 1 == determinism_remediations.len) "" else "," });
        }
        try self.raw("    },\n    \"fences\": [\n");
        for (determinism_fences, 0..) |fence, index| {
            if (fence.id) |id| {
                try self.print("      {{ \"id\": {s}, \"teaching\": {s} }}{s}\n", .{ try self.jsonString(id), try self.jsonString(fence.teaching), if (index + 1 == determinism_fences.len) "" else "," });
            } else {
                try self.print("      {{ \"prefix\": {s}, \"teaching\": {s} }}{s}\n", .{ try self.jsonString(fence.prefix.?), try self.jsonString(fence.teaching), if (index + 1 == determinism_fences.len) "" else "," });
            }
        }
        try self.raw("    ]\n  }\n}\n");
    }

    /// A prefixed symbol spelling as a JSON string literal.
    fn symbol(self: *ProfileEmitter, prefix: []const u8, suffix: []const u8) Error![]const u8 {
        return self.jsonString(try std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, suffix }));
    }

    /// A JSON double-quoted string literal: quotes and backslashes
    /// escape, control bytes take \u escapes, everything else rides as
    /// UTF-8 — which the input must therefore be (JSON has no other
    /// text). The CLI validates its one caller-supplied string (the
    /// entry spelling) with a teaching before emission ever starts;
    /// this check is the emitter's own backstop.
    fn jsonString(self: *ProfileEmitter, text: []const u8) Error![]const u8 {
        if (!std.unicode.utf8ValidateSlice(text)) return error.Refused;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.append(self.arena, '"');
        for (text) |char| {
            switch (char) {
                '"' => try out.appendSlice(self.arena, "\\\""),
                '\\' => try out.appendSlice(self.arena, "\\\\"),
                '\n' => try out.appendSlice(self.arena, "\\n"),
                '\r' => try out.appendSlice(self.arena, "\\r"),
                '\t' => try out.appendSlice(self.arena, "\\t"),
                else => {
                    if (char < 0x20) {
                        try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "\\u{x:0>4}", .{char}));
                    } else {
                        try out.append(self.arena, char);
                    }
                },
            }
        }
        try out.append(self.arena, '"');
        return out.items;
    }
};

fn signatureFor(suffix: []const u8) ?*const ExportSignature {
    for (&export_signatures) |*signature| {
        if (std.mem.eql(u8, signature.suffix, suffix)) return signature;
    }
    return null;
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn profileFromJson(arena: std.mem.Allocator, json: []const u8, entry: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, json, &diags);
    return emitProfile(arena, parsed, entry, &diags);
}

test "profile emission is deterministic and carries the library-mode surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try profileFromJson(arena, sidecar_mod.minimal_valid_json, default_entry);
    const second = try profileFromJson(arena, sidecar_mod.minimal_valid_json, default_entry);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "\"profile_format\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"entry\": \"core_facade.ts\"") != null);
    // Mode symbols ride the abi block under the contract's prefix.
    try testing.expect(std.mem.indexOf(u8, first, "\"init_symbol\": \"nsc_core_init\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"sink_register_symbol\": \"nsc_core_set_panic_sink\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"collect_symbol\": \"nsc_core_collect\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"result_reset_symbol\": \"nsc_core_frame_reset\"") != null);
    // The export map binds the facade's exported function name to the
    // prefixed symbol with the marshalled signature; mode symbols and
    // identity getters stay out of it.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"export\": \"dispatch_number\", \"symbol\": \"nsc_core_dispatch_number\", \"params\": [\"u8\", \"f64\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"init\"") == null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"build_id\"") == null);
    // The fixed ABI entry must not take the author-facing
    // `subscriptions` spelling: the sidecar emitter treats an export under
    // that name as a real subscription declaration even when the profile
    // deliberately carries no subscriptions_export designation.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"export\": \"abi_subscriptions\", \"symbol\": \"nsc_core_subscriptions\", \"params\": [], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"export\": \"subscriptions\"") == null);
    // The sidecar section echoes the contract's generations and
    // declares the SDK's emission path, identity-getter symbols, the
    // facade's designated entries, and the integer-slot declarations.
    try testing.expect(std.mem.indexOf(u8, first, "\"path\": \"core.contract.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"wire_version\": 6") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"build_id_symbol\": \"nsc_core_build_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"abi_version_symbol\": \"nsc_core_abi_version\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"init_export\": \"init\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"update_export\": \"coreUpdate\"") != null);
    // minimal_valid_json has no subscriptions: the designation must not
    // dangle (the compiler refuses a name that resolves to nothing).
    try testing.expect(std.mem.indexOf(u8, first, "subscriptions_export") == null);
    // The integer-slot declarations carry through from the contract.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"slot\": \"Model.count\", \"class\": \"i64\" }") != null);
    // No provenance stub rides the profile (the compiler computes its
    // own source hash over the module graph).
    try testing.expect(std.mem.indexOf(u8, first, "source_hash") == null);
    // The determinism policy rides whole: fences with SDK teachings,
    // the shared async teaching, the trap remediations.
    try testing.expect(std.mem.indexOf(u8, first, "{ \"id\": \"stdlib.math.random\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "{ \"prefix\": \"node-builtin.fs.\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"async\":") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"SC4013\":") != null);
}

test "wired channels join the export map with their wire shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"pinch_msg\": false", "\"pinch_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"drop_msg\": false", "\"drop_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\", \"pinch_msg\", \"drop_msg\"]");
    const generated = try profileFromJson(arena, source, default_entry);
    // The wire-shaped signatures: bytes as buffers, u8 modifier
    // booleans, the pinch phase a u32 member index. The export names
    // take the facade's abi_ spellings; the symbols the contract's
    // prefix.
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_key_msg\", \"symbol\": \"nsc_core_key_msg\", \"params\": [\"bytes\", \"u8\", \"u8\", \"u8\", \"u8\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_pinch_msg\", \"symbol\": \"nsc_core_pinch_msg\", \"params\": [\"f64\", \"bytes\", \"u32\", \"f64\", \"f64\", \"f64\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"abi_drop_msg\", \"symbol\": \"nsc_core_drop_msg\", \"params\": [\"bytes\"], \"returns\": \"bytes\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_command_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_frame_msg") == null);
}

test "the profile tracks the contract's prefix and generations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"prefix\": \"nsc_core_\"", "\"prefix\": \"app2_\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"wire_version\": 6", "\"wire_version\": 6");
    const generated = try profileFromJson(arena, source, "my_facade.ts");
    try testing.expect(std.mem.indexOf(u8, generated, "\"entry\": \"my_facade.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"prefix\": \"app2_\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"init_symbol\": \"app2_init\"") != null);
    // Export names keep the facade's own function spellings; only the
    // symbols take the contract's prefix.
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"model_snapshot\", \"symbol\": \"app2_model_snapshot\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ \"export\": \"persist_snapshot\", \"symbol\": \"app2_persist_snapshot\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"export\": \"app2_") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"build_id_symbol\": \"app2_build_id\"") != null);
}

test "a non-UTF-8 entry spelling refuses instead of corrupting the JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, sidecar_mod.minimal_valid_json, &diags);
    try testing.expectError(error.Refused, emitProfile(arena, parsed, "core_\xfffacade.ts", &diags));
}

test "a contract attesting false for an enforced posture refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { needle: []const u8, replacement: []const u8, fragment: []const u8 }{
        .{ .needle = "\"deterministic\": true", .replacement = "\"deterministic\": false", .fragment = "attests deterministic: false" },
        .{ .needle = "\"async_free\": true", .replacement = "\"async_free\": false", .fragment = "attests async_free: false" },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, case.needle, case.replacement);
        var diags = sidecar_mod.Diagnostics{ .arena = arena };
        const parsed = try sidecar_mod.read(arena, source, &diags);
        try testing.expectError(error.Refused, emitProfile(arena, parsed, default_entry, &diags));
        var found = false;
        for (diags.list.items) |item| {
            if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, case.fragment) != null) found = true;
        }
        try testing.expect(found);
    }
}

test "the emitted profile parses as JSON with the expected top-level keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try profileFromJson(arena, sidecar_mod.minimal_valid_json, default_entry);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, generated, .{});
    const top = parsed.object;
    for ([_][]const u8{ "profile_format", "name", "entry", "emission", "abi", "exports", "sidecar", "determinism" }) |key| {
        try testing.expect(top.contains(key));
    }
    const determinism = top.get("determinism").?.object;
    try testing.expect(determinism.get("fences").?.array.items.len == determinism_fences.len);
    // Teachings and remediations stay within the profile loader's
    // string constraints: no control bytes below 0x20 except newline,
    // 512 bytes at most.
    for (determinism_fences) |fence| {
        try testing.expect(fence.teaching.len <= 512);
        for (fence.teaching) |char| try testing.expect(char >= 0x20 or char == '\n');
    }
    for (determinism_teachings ++ determinism_remediations) |rider| {
        try testing.expect(rider.text.len <= 512);
        for (rider.text) |char| try testing.expect(char >= 0x20 or char == '\n');
    }
}
