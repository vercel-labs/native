//! Harness binding over the emitted core's C-ABI shim (static lib).

extern fn inbox_reset() callconv(.c) void;
extern fn inbox_push_text(byte: f64) callconv(.c) void;
extern fn inbox_dispatch(tag: f64, a: f64, b: f64, c: f64, f0: f64, f1: f64) callconv(.c) f64;
extern fn inbox_snapshot() callconv(.c) f64;
extern fn inbox_snapshot_byte(i: f64) callconv(.c) f64;
extern fn inbox_effect_len() callconv(.c) f64;
extern fn inbox_effect_byte(i: f64) callconv(.c) f64;

pub const name = "zig";

pub fn init() void {
    inbox_reset();
}

pub fn reset() void {
    inbox_reset();
}

pub fn pushText(byte: f64) void {
    inbox_push_text(byte);
}

pub fn dispatch(tag: f64, a: f64, b: f64, c: f64, f0: f64, f1: f64) f64 {
    return inbox_dispatch(tag, a, b, c, f0, f1);
}

pub fn snapshot() f64 {
    return inbox_snapshot();
}

pub fn snapshotByte(i: f64) f64 {
    return inbox_snapshot_byte(i);
}

pub fn effectLen() f64 {
    return inbox_effect_len();
}

pub fn effectByte(i: f64) f64 {
    return inbox_effect_byte(i);
}
