//! The extern-binding layer for a compiled core: every C-ABI symbol the
//! generated shim (core_shim.zig) may reference, in one module.
//!
//! ISOLATION IS THE POINT OF THIS FILE. The core ABI is a draft pending
//! cross-repo ratification; the shim generator emits no extern
//! declarations of its own, so a post-ratification symbol or signature
//! change is an edit HERE and a regeneration — never a generator-logic
//! change. The build stages this file (and shim_rt.zig) beside the
//! generated shim, exactly as the transpiler lane stages rt.zig beside
//! its emitted core.
//!
//! Contract summary (the header is the specification; this file only
//! binds it):
//! - Symbols are `prefix + suffix`, ccc calling convention, prefix
//!   declared by the sidecar's abi section (canonical default
//!   "nsc_core_").
//! - The identity getters are pure, callable before init, and MUST NOT
//!   trap: they are the boot-time staleness fence.
//! - One dispatch entry per payload-descriptor class; `tag` is the
//!   arm's declaration-order index in the sidecar's msg section (the
//!   sidecar is the tag authority). Each entry runs one update+commit
//!   and returns the cycle's command bytes.
//! - Inbound pointers are borrowed for the call; the core copies what
//!   it keeps. Outbound buffers are core-owned: cmd/subs bytes live
//!   until frame_reset, the snapshot until the next dispatch entry,
//!   init, or collect. No alignment guarantee on any encoded buffer.
//! - Encoded buffers use the canonical value encoding (shim_rt.zig):
//!   little-endian, headerless, schema-driven, record fields in sidecar
//!   declaration order.
//! - Narrow integers in these signatures (u8 tags, u32 member/helper
//!   indices, the sink's u64 address) are C-SIGNATURE PLUMBING for
//!   host-produced values, never value-payload crossings: payload
//!   numbers ride the two-class number model (f64/i64) exclusively.
//! - Four entries are runtime-owned mode symbols rather than ordinary
//!   compiled-core exports: set_panic_sink, init, frame_reset, and
//!   collect (which folds the transient-arena reset). The rest project
//!   the core module's own surface.

const std = @import("std");

/// The C-ABI generation these bindings implement. The generator refuses
/// a sidecar declaring any other value; the generated shim re-checks the
/// object's own getter at boot (the out-of-graph pairing backstop).
pub const abi_version: u32 = 1;

/// The snapshot-encoding generation the shim's decoder implements.
pub const snapshot_format: u32 = 1;

/// The host-supplied trap sink. `msg` is a UTF-8 teaching message valid
/// only for the duration of the call; `address` is the faulting return
/// address (0 when unknown); `ctx` echoes the registered context
/// pointer. The sink must not return and must not call back into any
/// core entry point.
///
/// The sink covers DETECTED traps only: contract violations the core's
/// own checks catch throw with their teaching text, and an exception
/// that escapes the core reaches the sink with an "Uncaught " prefix on
/// its message. Hardware faults (SIGSEGV/SIGBUS) belong to the host's
/// process-wide handler — the core installs no signal handlers.
pub const PanicSinkFn = *const fn (
    ctx: ?*anyopaque,
    msg: [*]const u8,
    msg_len: usize,
    address: u64,
) callconv(.c) void;

// A conditional channel entry hands its whole result back as ONE bytes
// buffer on the ordinary out-pointer slot — the channel bytes envelope:
//
//   [produced u8][tag u8][payload…]
//
// Byte 0 is 0 (nothing produced; the envelope is exactly two bytes) or
// 1. Byte 1 is the produced arm's declaration-order wire tag in the
// sidecar's msg section (meaningless when nothing was produced; the
// producer emits 0). The remainder is the arm's payload in the
// canonical value encoding of its mirror payload type (shim_rt.zig; an
// i64 arm rides as 8-byte two's-complement LE) — so the envelope's tail
// is byte-identical to the canonical union encoding of the produced
// message. Envelope bytes are valid until the next core entry call of
// any kind. One bytes return keeps the one-return-slot rule intact: the
// multi-value result needs no marshalling shape of its own.

/// The full symbol set of ABI version 1, bound under `prefix`. The
/// conditional channel entries are declared unconditionally here —
/// `@extern` binds lazily, so a symbol is required at link time only
/// when the generated shim actually references it, which it does
/// exactly when the sidecar's abi.exports lists it.
pub fn Bindings(comptime prefix: []const u8) type {
    return struct {
        fn Symbol(comptime T: type, comptime suffix: []const u8) *const T {
            return @extern(*const T, .{ .name = prefix ++ suffix });
        }

        // ---------------------------------------------------- identity
        pub const abi_version_fn = Symbol(fn () callconv(.c) u32, "abi_version");
        pub const build_id = Symbol(fn () callconv(.c) u64, "build_id");

        // -------------------------------------------------- panic sink
        pub const set_panic_sink = Symbol(fn (sink: PanicSinkFn, ctx: ?*anyopaque) callconv(.c) void, "set_panic_sink");

        // --------------------------------------------------- lifecycle
        /// Deterministic (re)initialization: resets all runtime state,
        /// evaluates the core's init, commits the boot model. Callable
        /// repeatedly (the session-replay re-init seam); invalidates
        /// every previously returned pointer.
        pub const init = Symbol(fn () callconv(.c) void, "init");
        /// The boot command bytes produced by init (empty when the
        /// core's init returns a bare model). Arena truth governs the
        /// lifetime: valid until the next frame_reset, dispatch entry,
        /// or init.
        pub const boot_cmd = Symbol(fn (cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "boot_cmd");

        // ---------------------------------------------------- dispatch
        pub const dispatch_void = Symbol(fn (tag: u8, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_void");
        pub const dispatch_bytes = Symbol(fn (tag: u8, ptr: [*]const u8, len: usize, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_bytes");
        /// The value crosses as f64; an i64-classed arm narrows
        /// core-side by truncation toward zero (producers guarantee
        /// integer-classed values are exact below 2^53).
        pub const dispatch_number = Symbol(fn (tag: u8, value: f64, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_number");
        pub const dispatch_number_bytes = Symbol(fn (tag: u8, number: f64, ptr: [*]const u8, len: usize, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_number_bytes");
        pub const dispatch_bool = Symbol(fn (tag: u8, value: u8, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_bool");
        /// `member` is the declaration-order member index from the
        /// sidecar's type table (= the wire value).
        pub const dispatch_enum = Symbol(fn (tag: u8, member: u32, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_enum");
        /// A record OR non-text-input union payload in the canonical
        /// value encoding (a union rides as its u8 declaration-order arm
        /// index followed by that arm's payload — the same encoding the
        /// snapshot uses, so one decoder serves both directions).
        pub const dispatch_record = Symbol(fn (tag: u8, fields: [*]const u8, fields_len: usize, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_record");
        /// The declared text-input mirror union: [arm u8] + arm payload
        /// in the canonical value encoding.
        pub const dispatch_text_input = Symbol(fn (tag: u8, event: [*]const u8, event_len: usize, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_text_input");
        /// The declared scroll-state mirror record as direct scalars
        /// (the hottest markup dispatch: per-frame during scrolls) —
        /// the TWO-AXIS record's eight fields in declaration order.
        pub const dispatch_scroll_state = Symbol(fn (tag: u8, offset_x: f64, offset_y: f64, velocity_x: f64, velocity_y: f64, viewport_extent_x: f64, viewport_extent_y: f64, content_extent_x: f64, content_extent_y: f64, cmd: *[*]const u8, cmd_len: *usize) callconv(.c) void, "dispatch_scroll_state");

        // -------------------------------------------------- post-cycle
        pub const subscriptions = Symbol(fn (subs: *[*]const u8, subs_len: *usize) callconv(.c) void, "subscriptions");
        pub const frame_reset = Symbol(fn () callconv(.c) void, "frame_reset");
        /// The committed model in the canonical value encoding of the
        /// sidecar's model type (root record, declaration-order fields),
        /// encoded on demand from the committed heap into a transient
        /// buffer: valid until the next dispatch entry, frame_reset,
        /// init, or collect (arena truth — the buffer does NOT survive a
        /// frame reset; re-read after resetting).
        pub const model_snapshot = Symbol(fn (snap: *[*]const u8, snap_len: *usize) callconv(.c) void, "model_snapshot");
        /// Call the exported helper at `helper` (index into the
        /// sidecar's model_helpers). An unknown index is a generator/
        /// sidecar skew and TRAPS through the panic sink — it is never a
        /// status the host is asked to check.
        pub const helper_call = Symbol(fn (helper: u32, args: [*]const u8, args_len: usize, out: *[*]const u8, out_len: *usize) callconv(.c) void, "helper_call");
        /// Reference-cycle collection over the model heap, with the
        /// transient-arena reset folded in (a runtime-owned mode
        /// symbol): observable model state unchanged, every previously
        /// returned snapshot, helper, cmd, and subscription pointer
        /// invalidated.
        pub const collect = Symbol(fn () callconv(.c) void, "collect");

        // -------------------------- conditional channel entries
        //
        // Each returns the channel bytes envelope (see the module doc
        // above) through the ordinary out-pointer pair.
        pub const command_msg = Symbol(fn (name: [*]const u8, name_len: usize, out: *[*]const u8, out_len: *usize) callconv(.c) void, "command_msg");
        pub const frame_msg = Symbol(fn (width: f64, height: f64, timestamp_ms: f64, interval_ms: f64, out: *[*]const u8, out_len: *usize) callconv(.c) void, "frame_msg");
        pub const key_msg = Symbol(fn (key: [*]const u8, key_len: usize, shift: u8, control: u8, alt: u8, super_mod: u8, out: *[*]const u8, out_len: *usize) callconv(.c) void, "key_msg");
        pub const pinch_msg = Symbol(fn (window_id: f64, label: [*]const u8, label_len: usize, phase: u32, scale: f64, x: f64, y: f64, out: *[*]const u8, out_len: *usize) callconv(.c) void, "pinch_msg");
    };
}
