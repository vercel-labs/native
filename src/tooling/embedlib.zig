//! Target-keyed staging for the mobile embed static library.
//!
//! The iOS and Android host tiers both drive `zig build lib` and then
//! link the installed archive into a toolkit host. The install
//! destination used to be one shared slot (zig-out/lib/lib<name>.a) for
//! every slice — iOS simulator, iOS device, Android — so whichever
//! target built last owned the bytes, and an interleaved or concurrent
//! session for another target poisoned the next host link. On Android
//! that failure was silent: a `-shared` link tolerates undefined
//! symbols, and a foreign (Mach-O) archive's symbol index never matches
//! ELF references, so ld.lld pulled nothing, emitted only a warning,
//! and produced a host library whose `native_sdk_app_*` references
//! stayed dangling until dlopen failed on the device.
//!
//! Two defenses live here, shared by ios.zig and android.zig:
//!
//! - `prefixAlloc`/`libPathAlloc`: the embed library installs under
//!   `.native/embed/<target-triple>/`, keyed by the exact `-Dtarget`
//!   string the CLI requested — every slice owns a private stage, so
//!   cross-target runs cannot clobber each other. Content freshness
//!   within a stage stays with the compiler's content-addressed build
//!   cache (toolkit or app source changes rebuild the archive; nothing
//!   is keyed on wall-clock time).
//! - `classifyArchive`/`requireArchiveClass`: a content gate the host
//!   compile runs on the staged bytes before linking, so an archive
//!   built for another object format fails loudly with the real cause
//!   instead of surfacing as a device-side link error.

const std = @import("std");

/// Absolute install prefix for `zig build lib --prefix` — the staging
/// directory for one target slice, under the app's own `.native/` (the
/// gitignored, wipe-to-reset toolkit state directory).
pub fn prefixAlloc(allocator: std.mem.Allocator, cwd_path: []const u8, triple: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cwd_path, ".native", "embed", triple });
}

/// The staged archive path relative to the app directory (where the
/// install prefix above puts the `lib` step's artifact).
pub fn libPathAlloc(allocator: std.mem.Allocator, triple: []const u8, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".native/embed/{s}/lib/lib{s}.a", .{ triple, app_name });
}

/// What the first real (non-symbol-table) member of a static archive
/// contains — enough to tell an Android (ELF AArch64) embed library
/// from an Apple (Mach-O) one before a host link consumes it.
pub const ArchiveClass = enum {
    elf_aarch64,
    elf_other,
    macho,
    unknown,

    pub fn describe(self: ArchiveClass) []const u8 {
        return switch (self) {
            .elf_aarch64 => "an ELF AArch64 static library",
            .elf_other => "an ELF static library for another architecture",
            .macho => "a Mach-O (Apple) static library",
            .unknown => "not a recognizable static library",
        };
    }
};

const ar_magic = "!<arch>\n";
const ar_header_len = 60;

/// Classify an archive by its first payload member. Symbol-table and
/// string-table members (GNU `/`, `//`, `/SYM64/`; BSD `__.SYMDEF*`)
/// are skipped — their bytes are index data, not object code. Truncated
/// input classifies as `.unknown` (the caller reads a bounded prefix of
/// the file; real symbol tables are far smaller than the bound).
pub fn classifyArchive(bytes: []const u8) ArchiveClass {
    if (bytes.len < ar_magic.len or !std.mem.eql(u8, bytes[0..ar_magic.len], ar_magic)) return .unknown;
    var offset: usize = ar_magic.len;
    while (offset + ar_header_len <= bytes.len) {
        const header = bytes[offset .. offset + ar_header_len];
        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
        const size = std.fmt.parseUnsigned(usize, std.mem.trim(u8, header[48..58], " "), 10) catch return .unknown;
        var payload_start = offset + ar_header_len;
        var payload_len = size;
        var name = raw_name;
        if (std.mem.startsWith(u8, raw_name, "#1/")) {
            // BSD extended name: the real name is the first N bytes of
            // the member data, and `size` includes it.
            const name_len = std.fmt.parseUnsigned(usize, raw_name["#1/".len..], 10) catch return .unknown;
            if (name_len > payload_len or payload_start + name_len > bytes.len) return .unknown;
            name = std.mem.trimEnd(u8, bytes[payload_start .. payload_start + name_len], "\x00");
            payload_start += name_len;
            payload_len -= name_len;
        }
        const is_index = std.mem.eql(u8, name, "/") or
            std.mem.eql(u8, name, "//") or
            std.mem.eql(u8, name, "/SYM64/") or
            std.mem.startsWith(u8, name, "__.SYMDEF");
        if (!is_index) {
            if (payload_start + 4 > bytes.len) return .unknown;
            const magic = bytes[payload_start .. payload_start + 4];
            if (std.mem.eql(u8, magic, "\x7fELF")) {
                if (payload_start + 20 > bytes.len) return .elf_other;
                const machine = std.mem.readInt(u16, bytes[payload_start + 18 ..][0..2], .little);
                return if (machine == 183) .elf_aarch64 else .elf_other;
            }
            const macho_magics = [_][4]u8{
                .{ 0xcf, 0xfa, 0xed, 0xfe }, // 64-bit, little-endian file
                .{ 0xfe, 0xed, 0xfa, 0xcf },
                .{ 0xce, 0xfa, 0xed, 0xfe }, // 32-bit
                .{ 0xfe, 0xed, 0xfa, 0xce },
                .{ 0xca, 0xfe, 0xba, 0xbe }, // fat
                .{ 0xbe, 0xba, 0xfe, 0xca },
            };
            for (macho_magics) |candidate| {
                if (std.mem.eql(u8, magic, &candidate)) return .macho;
            }
            return .unknown;
        }
        // Skip the index member (2-byte alignment between members).
        offset += ar_header_len + size + (size & 1);
    }
    return .unknown;
}

/// The content gate the host compiles run before linking the staged
/// archive: read a bounded prefix and require the class the target
/// needs. A mismatch names the staged path, what was found, and the
/// rebuild that produces the right bytes — never a silent bad link.
pub fn requireArchiveClass(
    allocator: std.mem.Allocator,
    io: std.Io,
    lib_path: []const u8,
    want: ArchiveClass,
    triple: []const u8,
) !void {
    // A bounded prefix is enough: the classification only walks past
    // the archive's index members (a few KB) to the first object's
    // magic, while the archive itself can be tens of MB.
    const prefix_limit = 1024 * 1024;
    const bytes = try allocator.alloc(u8, prefix_limit);
    defer allocator.free(bytes);
    const prefix_len = readPrefix(io, lib_path, bytes) catch {
        std.debug.print("native: cannot read the embed library at {s}\n", .{lib_path});
        return error.EmbedLibraryMismatch;
    };
    const found = classifyArchive(bytes[0..prefix_len]);
    if (found == want) return;
    std.debug.print(
        \\native: the embed library at {s} is {s}, but this target ({s}) needs {s}.
        \\It was built for another target or is corrupt; rebuild it for this target:
        \\  zig build lib -Dtarget={s}
        \\(the dev and package loops rebuild it automatically on the next run).
        \\
    , .{ lib_path, found.describe(), triple, want.describe(), triple });
    return error.EmbedLibraryMismatch;
}

/// Fill `buffer` with the file's first bytes (short read at EOF),
/// returning the byte count.
fn readPrefix(io: std.Io, path: []const u8, buffer: []u8) !usize {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.readSliceShort(buffer);
}

// ------------------------------------------------------------------- tests

/// A minimal GNU-style archive: symbol table `/`, then one object
/// member whose bytes start with `payload`.
fn gnuArchiveAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, ar_magic);
    try appendMember(&out, allocator, "/", "\x00\x00\x00\x01indexdata");
    try appendMember(&out, allocator, "app.o/", payload);
    return out.toOwnedSlice(allocator);
}

/// A minimal BSD-style archive: `#1/20` extended-name `__.SYMDEF
/// SORTED` index, then one object member with an extended name.
fn bsdArchiveAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, ar_magic);
    const symdef_name = "__.SYMDEF SORTED\x00\x00\x00\x00";
    try appendBsdMember(&out, allocator, symdef_name, "\x10\x00\x00\x00ranlib");
    const object_name = "app.o\x00\x00\x00";
    try appendBsdMember(&out, allocator, object_name, payload);
    return out.toOwnedSlice(allocator);
}

fn appendMember(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    var header: [ar_header_len]u8 = @splat(' ');
    @memcpy(header[0..name.len], name);
    _ = std.fmt.bufPrint(header[48..58], "{d}", .{data.len}) catch unreachable;
    header[58] = '`';
    header[59] = '\n';
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, data);
    if (data.len & 1 == 1) try out.append(allocator, '\n');
}

fn appendBsdMember(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    var header: [ar_header_len]u8 = @splat(' ');
    _ = std.fmt.bufPrint(header[0..16], "#1/{d}", .{name.len}) catch unreachable;
    _ = std.fmt.bufPrint(header[48..58], "{d}", .{name.len + data.len}) catch unreachable;
    header[58] = '`';
    header[59] = '\n';
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, data);
    if ((name.len + data.len) & 1 == 1) try out.append(allocator, '\n');
}

fn elfAarch64Object() [20]u8 {
    var object: [20]u8 = @splat(0);
    @memcpy(object[0..4], "\x7fELF");
    std.mem.writeInt(u16, object[18..20], 183, .little);
    return object;
}

test "the staging path is keyed by the requested target triple" {
    const allocator = std.testing.allocator;
    const android = try libPathAlloc(allocator, "aarch64-linux-android", "demo");
    defer allocator.free(android);
    const ios_sim = try libPathAlloc(allocator, "aarch64-ios-simulator", "demo");
    defer allocator.free(ios_sim);
    const ios_device = try libPathAlloc(allocator, "aarch64-ios", "demo");
    defer allocator.free(ios_device);
    try std.testing.expectEqualStrings(".native/embed/aarch64-linux-android/lib/libdemo.a", android);
    try std.testing.expectEqualStrings(".native/embed/aarch64-ios-simulator/lib/libdemo.a", ios_sim);
    try std.testing.expectEqualStrings(".native/embed/aarch64-ios/lib/libdemo.a", ios_device);
    // Distinct targets never share a stage — the invariant that keeps
    // one slice's build from poisoning another's host link.
    try std.testing.expect(!std.mem.eql(u8, android, ios_sim));
    try std.testing.expect(!std.mem.eql(u8, ios_sim, ios_device));
}

test "archive classification tells ELF AArch64 from Mach-O and junk" {
    const allocator = std.testing.allocator;

    const elf_object = elfAarch64Object();
    const elf_archive = try gnuArchiveAlloc(allocator, &elf_object);
    defer allocator.free(elf_archive);
    try std.testing.expectEqual(ArchiveClass.elf_aarch64, classifyArchive(elf_archive));

    var x86_object = elfAarch64Object();
    std.mem.writeInt(u16, x86_object[18..20], 62, .little);
    const x86_archive = try gnuArchiveAlloc(allocator, &x86_object);
    defer allocator.free(x86_archive);
    try std.testing.expectEqual(ArchiveClass.elf_other, classifyArchive(x86_archive));

    const macho_object = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01 };
    const macho_archive = try bsdArchiveAlloc(allocator, &macho_object);
    defer allocator.free(macho_archive);
    try std.testing.expectEqual(ArchiveClass.macho, classifyArchive(macho_archive));

    try std.testing.expectEqual(ArchiveClass.unknown, classifyArchive("not an archive"));
    try std.testing.expectEqual(ArchiveClass.unknown, classifyArchive(ar_magic));
}

test "the content gate rejects a stage whose bytes were built for another target" {
    // The pin for the observed defect: stage an archive, mutate the
    // staged artifact to another target's format, and assert the stage
    // is refused (forcing a rebuild) instead of silently linked.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = ".zig-cache/test-embedlib-stage";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    const lib_path = dir_path ++ "/libdemo.a";

    const elf_object = elfAarch64Object();
    const elf_archive = try gnuArchiveAlloc(allocator, &elf_object);
    defer allocator.free(elf_archive);
    try cwd.writeFile(io, .{ .sub_path = lib_path, .data = elf_archive });
    try requireArchiveClass(allocator, io, lib_path, .elf_aarch64, "aarch64-linux-android");

    // The keyed input mutates: the same staged path now carries a
    // Mach-O archive (what an interleaved iOS build used to leave in
    // the shared slot). The Android stage must refuse it.
    const macho_object = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01 };
    const macho_archive = try bsdArchiveAlloc(allocator, &macho_object);
    defer allocator.free(macho_archive);
    try cwd.writeFile(io, .{ .sub_path = lib_path, .data = macho_archive });
    try std.testing.expectError(error.EmbedLibraryMismatch, requireArchiveClass(allocator, io, lib_path, .elf_aarch64, "aarch64-linux-android"));
    // And the mirror: an iOS stage accepts the Mach-O bytes it needs
    // and refuses the ELF ones.
    try requireArchiveClass(allocator, io, lib_path, .macho, "aarch64-ios-simulator");
    try cwd.writeFile(io, .{ .sub_path = lib_path, .data = elf_archive });
    try std.testing.expectError(error.EmbedLibraryMismatch, requireArchiveClass(allocator, io, lib_path, .macho, "aarch64-ios-simulator"));
}
