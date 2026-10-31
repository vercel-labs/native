//! Web-layer audit: assert whether a built executable carries the
//! embedded web layer, on the evidence each format actually leaves.
//!
//! PE (Windows): the host loads WebView2Loader.dll through LoadLibraryW,
//! so the loader never appears in the import table — the honest evidence
//! is the string literal itself, stored as UTF-16 in the web build and
//! compiled out entirely (with the whole layer) in a native-only build.
//!
//! ELF (Linux): the host links webkitgtk-6.0 directly, so the honest
//! evidence is structural — a libwebkitgtk/libjavascriptcoregtk
//! DT_NEEDED entry and webkit_*/jsc_* undefined dynamic symbols, all of
//! which the WebKitGTK compile seam (NATIVE_SDK_ALLOW_WEBKITGTK_STUB)
//! removes from a native-only build. Both tables are parsed by hand from
//! the section headers (the same dependency-free spirit as the PE sniff;
//! package.zig `elfReferencesWebKitGtk` is the package-time twin).
//!
//! The audit verifies the container format first so a wrong path can
//! never "pass" by scanning the wrong kind of file.
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

    if (isPeExecutable(bytes)) {
        auditPe(path, bytes, expect_present);
        return;
    }
    if (isElfExecutable(bytes)) {
        auditElf(path, bytes, expect_present);
        return;
    }
    std.debug.print("{s} is not a PE or ELF executable - the audit refuses to scan it\n", .{path});
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// PE: the WebView2Loader.dll string probe.
// ---------------------------------------------------------------------------

fn auditPe(path: []const u8, bytes: []const u8, expect_present: bool) void {
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

// ---------------------------------------------------------------------------
// ELF: DT_NEEDED entries plus dynamic symbol names.
// ---------------------------------------------------------------------------

fn auditElf(path: []const u8, bytes: []const u8, expect_present: bool) void {
    const reference = scanElfWebKitReference(bytes) catch |err| {
        std.debug.print("{s} could not be scanned as ELF ({s}) - the audit refuses to guess\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    if ((reference != null) == expect_present) {
        if (reference) |found| {
            std.debug.print("web-layer audit ok: {s} references WebKitGTK ({s})\n", .{ path, found });
        } else {
            std.debug.print("web-layer audit ok: {s} references no WebKitGTK library or symbol\n", .{path});
        }
        return;
    }
    if (expect_present) {
        std.debug.print("web-layer audit FAILED: {s} carries no WebKitGTK reference but this app declares web use - the embedded web layer was compiled out of a web build\n", .{path});
    } else {
        std.debug.print("web-layer audit FAILED: {s} references WebKitGTK ({s}) but nothing in its app.zon declares web use - the native-only inference did not strip the web layer\n", .{ path, reference.? });
    }
    std.process.exit(1);
}

const ElfError = error{
    NotElf64LittleEndian,
    NoSectionHeaders,
    TruncatedSectionHeaders,
    TruncatedSection,
};

fn isElfExecutable(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

const sht_dynamic: u32 = 6;
const sht_dynsym: u32 = 11;
const dt_needed: i64 = 1;

const ElfSection = struct {
    sh_type: u32,
    link: u32,
    offset: u64,
    size: u64,
    entsize: u64,
};

/// The first WebKitGTK reference in an ELF executable, or null: a
/// DT_NEEDED entry naming libwebkitgtk/libjavascriptcoregtk, or a
/// dynamic-symbol name in webkit_*/jsc_* (the WebKitGTK and JSC C
/// namespaces the GTK host calls into). Returns the matched name so a
/// failed audit teaches what leaked. Parsing walks the section headers
/// (zig-built executables always carry them); a stripped section table
/// proves nothing about the layer, so it is refused rather than passed.
fn scanElfWebKitReference(bytes: []const u8) ElfError!?[]const u8 {
    if (!isElfExecutable(bytes) or bytes.len < 0x40) return error.NotElf64LittleEndian;
    // EI_CLASS 2 = 64-bit, EI_DATA 1 = little endian: every Linux target
    // this toolkit builds. Anything else is refused, never guessed at.
    if (bytes[4] != 2 or bytes[5] != 1) return error.NotElf64LittleEndian;

    const sh_offset: u64 = std.mem.readInt(u64, bytes[0x28..0x30], .little);
    const sh_entsize: u16 = std.mem.readInt(u16, bytes[0x3a..0x3c], .little);
    const sh_count: u16 = std.mem.readInt(u16, bytes[0x3c..0x3e], .little);
    if (sh_offset == 0 or sh_count == 0) return error.NoSectionHeaders;
    if (sh_entsize < 0x40) return error.TruncatedSectionHeaders;

    var index: u16 = 0;
    while (index < sh_count) : (index += 1) {
        const header = try elfSlice(bytes, sh_offset + @as(u64, index) * sh_entsize, 0x40);
        const section = ElfSection{
            .sh_type = std.mem.readInt(u32, header[0x04..0x08], .little),
            .link = std.mem.readInt(u32, header[0x28..0x2c], .little),
            .offset = std.mem.readInt(u64, header[0x18..0x20], .little),
            .size = std.mem.readInt(u64, header[0x20..0x28], .little),
            .entsize = std.mem.readInt(u64, header[0x38..0x40], .little),
        };
        switch (section.sh_type) {
            sht_dynamic => {
                if (try scanDynamicNeeded(bytes, section, sh_offset, sh_entsize, sh_count)) |name| return name;
            },
            sht_dynsym => {
                if (try scanDynamicSymbols(bytes, section, sh_offset, sh_entsize, sh_count)) |name| return name;
            },
            else => {},
        }
    }
    return null;
}

/// DT_NEEDED entries of a .dynamic section, matched against the WebKit
/// library names.
fn scanDynamicNeeded(bytes: []const u8, section: ElfSection, sh_offset: u64, sh_entsize: u16, sh_count: u16) ElfError!?[]const u8 {
    const strtab = try elfLinkedStringTable(bytes, section.link, sh_offset, sh_entsize, sh_count);
    const entries = try elfSlice(bytes, section.offset, section.size);
    var cursor: usize = 0;
    while (cursor + 16 <= entries.len) : (cursor += 16) {
        const tag: i64 = @bitCast(std.mem.readInt(u64, entries[cursor..][0..8], .little));
        if (tag != dt_needed) continue;
        const name_offset: u64 = std.mem.readInt(u64, entries[cursor + 8 ..][0..8], .little);
        const name = elfString(strtab, name_offset) orelse continue;
        if (nameIsWebKitLibrary(name)) return name;
    }
    return null;
}

/// Dynamic-symbol names of a .dynsym section, matched against the
/// WebKitGTK C namespaces.
fn scanDynamicSymbols(bytes: []const u8, section: ElfSection, sh_offset: u64, sh_entsize: u16, sh_count: u16) ElfError!?[]const u8 {
    const strtab = try elfLinkedStringTable(bytes, section.link, sh_offset, sh_entsize, sh_count);
    const entsize: usize = if (section.entsize >= 24) @intCast(section.entsize) else 24;
    const symbols = try elfSlice(bytes, section.offset, section.size);
    var cursor: usize = 0;
    while (cursor + 24 <= symbols.len) : (cursor += entsize) {
        const name_offset: u32 = std.mem.readInt(u32, symbols[cursor..][0..4], .little);
        if (name_offset == 0) continue;
        const name = elfString(strtab, name_offset) orelse continue;
        if (nameIsWebKitSymbol(name)) return name;
    }
    return null;
}

fn nameIsWebKitLibrary(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "webkitgtk") != null or
        std.mem.indexOf(u8, name, "javascriptcoregtk") != null;
}

fn nameIsWebKitSymbol(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "webkit_") or
        std.mem.startsWith(u8, name, "jsc_");
}

/// The string table a section's sh_link points at.
fn elfLinkedStringTable(bytes: []const u8, link: u32, sh_offset: u64, sh_entsize: u16, sh_count: u16) ElfError![]const u8 {
    if (link >= sh_count) return error.TruncatedSectionHeaders;
    const header = try elfSlice(bytes, sh_offset + @as(u64, link) * sh_entsize, 0x40);
    const offset = std.mem.readInt(u64, header[0x18..0x20], .little);
    const size = std.mem.readInt(u64, header[0x20..0x28], .little);
    return elfSlice(bytes, offset, size);
}

fn elfString(strtab: []const u8, offset: u64) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(u8, strtab, start, 0) orelse return null;
    return strtab[start..end];
}

fn elfSlice(bytes: []const u8, offset: u64, size: u64) ElfError![]const u8 {
    if (offset > bytes.len) return error.TruncatedSection;
    const start: usize = @intCast(offset);
    if (size > bytes.len - start) return error.TruncatedSection;
    return bytes[start .. start + @as(usize, @intCast(size))];
}
