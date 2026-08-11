//! Generated-runner stub for apps without src/services/.
pub const enabled = false;
pub const protocol_version: u8 = 1;
pub const compiler_version = "";
pub const contract_fingerprint = [_]u8{0} ** 32;
pub const Operation = struct { name: []const u8, index: u16 };
pub const operations = [_]Operation{};
pub fn indexOf(name: []const u8) ?u16 {
    _ = name;
    return null;
}
