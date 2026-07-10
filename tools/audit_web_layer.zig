//! Web-layer PE audit: assert whether a built Windows executable carries
//! the embedded WebView layer. The host loads WebView2Loader.dll through
//! LoadLibraryW, so the loader never appears in the import table — the
//! honest evidence is the string literal itself, stored as UTF-16 in the
//! web build and compiled out entirely (with the whole layer) in a
//! native-only build. The audit verifies the PE header first so a wrong
//! path can never "pass" by scanning the wrong kind of file.
//!
//! usage: audit_web_layer <exe> present|absent

const std = @import("std");

const needle_ascii = "WebView2Loader.dll";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: audit_web_layer <exe> present|absent\n", .{});
        std.process.exit(2);
    }
    const path = args[1];
    const expect_present = if (std.mem.eql(u8, args[2], "present"))
        true
    else if (std.mem.eql(u8, args[2], "absent"))
        false
    else {
        std.debug.print("usage: audit_web_layer <exe> present|absent\n", .{});
        std.process.exit(2);
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
        std.debug.print("failed to read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    if (!isPeExecutable(bytes)) {
        std.debug.print("{s} is not a PE executable - the audit refuses to scan it\n", .{path});
        std.process.exit(1);
    }

    // The literal lives as a wide string (L"WebView2Loader.dll"), so the
    // authoritative probe is UTF-16LE; ASCII is scanned too in case a
    // future host stores it narrow.
    var needle_wide: [needle_ascii.len * 2]u8 = undefined;
    for (needle_ascii, 0..) |ch, index| {
        needle_wide[index * 2] = ch;
        needle_wide[index * 2 + 1] = 0;
    }
    const found = std.mem.indexOf(u8, bytes, &needle_wide) != null or
        std.mem.indexOf(u8, bytes, needle_ascii) != null;

    if (found == expect_present) {
        std.debug.print("web-layer audit ok: {s} {s} {s}\n", .{ path, if (found) "references" else "does not reference", needle_ascii });
        return;
    }
    if (expect_present) {
        std.debug.print("web-layer audit FAILED: {s} does not reference {s} but this app declares web use - the embedded WebView layer was compiled out of a web build\n", .{ path, needle_ascii });
    } else {
        std.debug.print("web-layer audit FAILED: {s} references {s} but nothing in its app.zon declares web use - the native-only inference did not strip the web layer\n", .{ path, needle_ascii });
    }
    std.process.exit(1);
}

/// The same PE-header sniff packaging uses to pick the loader
/// architecture (package.zig peExecutableIsArm64): MZ magic, then the
/// PE\0\0 signature at the offset the DOS header names.
fn isPeExecutable(bytes: []const u8) bool {
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return false;
    const pe_offset: usize = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (pe_offset + 4 > bytes.len) return false;
    return std.mem.eql(u8, bytes[pe_offset..][0..4], "PE\x00\x00");
}
