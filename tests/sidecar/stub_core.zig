//! A link-time stand-in for a compiled core: exports every symbol of
//! core ABI version 1 under the canonical prefix so the conformance
//! suite can force FULL semantic analysis and codegen of the generated
//! shims (dispatch stubs, snapshot decoder, channel forwarders, helper
//! methods) and still link.
//!
//! No compiled core exists yet — the ABI is a draft pending
//! ratification — so the runtime dispatch paths are compile- and
//! link-checked here, never executed: every entry that would need a
//! real core traps. The identity getters and the empty-buffer entries
//! behave, so the boot fence and lifecycle ordering stay testable.

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

export fn nsc_core_dispatch_scroll_state(tag: u8, offset: f64, velocity: f64, viewport_extent: f64, content_extent: f64, cmd: *[*]const u8, cmd_len: *usize) void {
    _ = tag;
    _ = offset;
    _ = velocity;
    _ = viewport_extent;
    _ = content_extent;
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

const CoreMsg = extern struct {
    tag: u8,
    payload: [*]const u8,
    payload_len: usize,
};

export fn nsc_core_command_msg(name: [*]const u8, name_len: usize, out: *CoreMsg) u8 {
    _ = name;
    _ = name_len;
    _ = out;
    return 0;
}

export fn nsc_core_frame_msg(width: f64, height: f64, timestamp_ms: f64, interval_ms: f64, out: *CoreMsg) u8 {
    _ = width;
    _ = height;
    _ = timestamp_ms;
    _ = interval_ms;
    _ = out;
    return 0;
}

export fn nsc_core_key_msg(key: [*]const u8, key_len: usize, shift: u8, control: u8, alt: u8, super_mod: u8, out: *CoreMsg) u8 {
    _ = key;
    _ = key_len;
    _ = shift;
    _ = control;
    _ = alt;
    _ = super_mod;
    _ = out;
    return 0;
}

export fn nsc_core_pinch_msg(window_id: f64, label: [*]const u8, label_len: usize, phase: u32, scale: f64, x: f64, y: f64, out: *CoreMsg) u8 {
    _ = window_id;
    _ = label;
    _ = label_len;
    _ = phase;
    _ = scale;
    _ = x;
    _ = y;
    _ = out;
    return 0;
}
