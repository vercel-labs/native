//! Generated-runner stub for apps without src/services/.
pub const enabled = false;
pub const protocol_version: u8 = 3;
pub const compiler_version = "";
pub const inproc_symbol_prefix = "nsc_svc_";
pub const contract_fingerprint = [_]u8{0} ** 32;
pub const Operation = struct { name: []const u8, index: u16, deadline_ms: ?u32, cancellable: bool, streaming: bool, in_flight: u8 };
pub const operations = [_]Operation{};
pub fn indexOf(name: []const u8) ?u16 {
    _ = name;
    return null;
}
pub fn operationAt(index: u16) ?Operation {
    _ = index;
    return null;
}
pub fn isStreaming(index: u16) bool {
    _ = index;
    return false;
}
