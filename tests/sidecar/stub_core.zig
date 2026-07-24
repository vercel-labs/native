//! A link-time stand-in for a compiled core: exports every symbol of
//! core ABI version 1 under the canonical prefix so the conformance
//! suite can force FULL semantic analysis and codegen of the generated
//! shims (dispatch stubs, snapshot decoder, channel forwarders, helper
//! methods) and still link.
//!
//! No compiled core exists in this repo, so the dispatch paths that
//! would need one are compile- and link-checked here, never executed:
//! every such entry traps. The identity getters, the empty-buffer
//! entries, and the channel entries behave — a channel's whole result
//! is one bytes envelope, so this stub can hand back real envelopes
//! (nothing-produced by default, test-settable otherwise) and the
//! generated shims' unpack paths execute for real.

const std = @import("std");

/// The build_id the identity getter reports; a test may set it to a
/// shim's expected value to walk the boot fence.
pub var stub_build_id: u64 = 0;

export fn nsc_core_abi_version() u32 {
    return 1;
}

export fn nsc_core_build_id() u64 {
    return stub_build_id;
}

const PanicSinkFn = *const fn (ctx: ?*anyopaque, msg: [*]const u8, msg_len: usize, address: u64) callconv(.c) void;

export fn nsc_core_set_panic_sink(sink: PanicSinkFn, ctx: ?*anyopaque) void {
    _ = sink;
    _ = ctx;
}

export fn nsc_core_init() void {}

export fn nsc_core_boot_cmd(cmd: *[*]const u8, cmd_len: *usize) void {
    cmd.* = &empty;
    cmd_len.* = 0;
}

var empty: [1]u8 = .{0};

fn noCore() noreturn {
    @panic("the stub core has no update function — dispatch paths are compile-checked only until a compiled core exists");
}

export fn nsc_core_dispatch_void(tag: u8, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_bytes(tag: u8, ptr: [*]const u8, len: usize, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = ptr;
    _ = len;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_number(tag: u8, value: f64, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = value;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_number_bytes(tag: u8, number: f64, ptr: [*]const u8, len: usize, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = number;
    _ = ptr;
    _ = len;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_bool(tag: u8, value: u8, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = value;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_enum(tag: u8, member: u32, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = member;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_record(tag: u8, fields: [*]const u8, fields_len: usize, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = fields;
    _ = fields_len;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_text_input(tag: u8, event: [*]const u8, event_len: usize, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = event;
    _ = event_len;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_dispatch_scroll_state(tag: u8, offset_x: f64, offset_y: f64, velocity_x: f64, velocity_y: f64, viewport_extent_x: f64, viewport_extent_y: f64, content_extent_x: f64, content_extent_y: f64, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = offset_x;
    _ = offset_y;
    _ = velocity_x;
    _ = velocity_y;
    _ = viewport_extent_x;
    _ = viewport_extent_y;
    _ = content_extent_x;
    _ = content_extent_y;
    _ = cmd;
    _ = cmd_len;
    noCore();
}

export fn nsc_core_subscriptions(subs: *[*]const u8, subs_len: *usize) void {
    subs.* = &empty;
    subs_len.* = 0;
}

export fn nsc_core_frame_reset() void {}

export fn nsc_core_model_snapshot(snap: *[*]const u8, snap_len: *usize) void {
    snap.* = &empty;
    snap_len.* = 0;
    noCore();
}

export fn nsc_core_helper_call(helper: u32, args: [*]const u8, args_len: usize, out: *[*]const u8, out_len: *usize) void {
    _ = helper;
    _ = args;
    _ = args_len;
    _ = out;
    _ = out_len;
    noCore();
}

export fn nsc_core_collect() void {}

// Channel entries return the bytes envelope ([produced u8][tag u8]
// [payload…]) on the ordinary out-pointer pair. Unlike the dispatch
// entries these are EXECUTABLE without a core: the empty envelope is a
// complete, honest "nothing produced", so the generated shims' unpack
// paths run for real against this stub.

/// The two-byte nothing-produced envelope.
const no_msg_envelope = [2]u8{ 0, 0 };

/// The envelope every channel entry hands back. A test may point it at
/// a produced envelope (or a malformed one) to drive the generated
/// shim's unpack path without a compiled core.
pub var stub_channel_envelope: []const u8 = &no_msg_envelope;

fn channelEnvelopeOut(out: *[*]const u8, out_len: *usize) void {
    out.* = stub_channel_envelope.ptr;
    out_len.* = stub_channel_envelope.len;
}

export fn nsc_core_command_msg(name: [*]const u8, name_len: usize, out: *[*]const u8, out_len: *usize) void {
    _ = name;
    _ = name_len;
    channelEnvelopeOut(out, out_len);
}

export fn nsc_core_frame_msg(width: f64, height: f64, timestamp_ms: f64, interval_ms: f64, out: *[*]const u8, out_len: *usize) void {
    _ = width;
    _ = height;
    _ = timestamp_ms;
    _ = interval_ms;
    channelEnvelopeOut(out, out_len);
}

export fn nsc_core_key_msg(key: [*]const u8, key_len: usize, shift: u8, control: u8, alt: u8, super_mod: u8, out: *[*]const u8, out_len: *usize) void {
    _ = key;
    _ = key_len;
    _ = shift;
    _ = control;
    _ = alt;
    _ = super_mod;
    channelEnvelopeOut(out, out_len);
}

export fn nsc_core_pinch_msg(window_id: f64, label: [*]const u8, label_len: usize, phase: u32, scale: f64, x: f64, y: f64, out: *[*]const u8, out_len: *usize) void {
    _ = window_id;
    _ = label;
    _ = label_len;
    _ = phase;
    _ = scale;
    _ = x;
    _ = y;
    channelEnvelopeOut(out, out_len);
}
