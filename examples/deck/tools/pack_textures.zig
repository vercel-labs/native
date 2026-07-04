//! Texture packer for the deck example: converts raw RGBA dumps into the
//! strict PNG subset the framework decodes everywhere (8-bit RGBA, zlib
//! stream of stored deflate blocks — `canvas.png.writeRgba8`'s exact
//! output), so the committed textures decode both live (CGImageSource)
//! and under the deterministic test decoder.
//!
//! The textures themselves are AI-generated (the prompts live in the
//! example README, "Texture assets") and toned with ImageMagick; this
//! tool only owns the last, framework-specific step. Regeneration:
//!
//!   ai image -m openai/gpt-image-2 --size 1024x1024 -o /tmp/plate-raw.png "<plate prompt>"
//!   magick /tmp/plate-raw.png -resize 256x256 -modulate 100,30,100 -brightness-contrast -8x0 /tmp/plate.png
//!   magick /tmp/plate.png -depth 8 rgba:/tmp/plate.rgba
//!   zig run tools/pack_textures.zig -- /tmp/plate.rgba 256 256 src/textures/plate.png
//!
//! The PNG writer below mirrors `canvas.png.writeRgba8` byte for byte
//! (the same dev-only duplication as soundboard's cover generator); the
//! example's tests decode every committed texture, so drift fails loudly.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) {
        std.debug.print("usage: pack_textures <input.rgba> <width> <height> <output.png>\n", .{});
        return error.BadUsage;
    }
    const width = try std.fmt.parseInt(usize, args[2], 10);
    const height = try std.fmt.parseInt(usize, args[3], 10);

    const pixels = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(width * height * 4 + 1));
    if (pixels.len != width * height * 4) {
        std.debug.print("expected {d} RGBA bytes, read {d}\n", .{ width * height * 4, pixels.len });
        return error.BadInput;
    }

    const out_buffer = try allocator.alloc(u8, encodedRgba8ByteLen(width, height));
    var writer = std.Io.Writer.fixed(out_buffer);
    try writeRgba8(&writer, width, height, pixels);
    const encoded = writer.buffered();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = encoded });
    std.debug.print("wrote {s} ({d} bytes)\n", .{ args[4], encoded.len });
}

// ------------------------------------------------------------- PNG writer
// A byte-exact mirror of `canvas.png.writeRgba8` (see the module comment).

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
const max_stored_block_bytes: usize = 65535;
const chunk_overhead: usize = 12; // length + type + crc

fn rowByteLen(width: usize) usize {
    return 1 + width * 4; // filter byte + pixels
}

fn rawStreamLen(width: usize, height: usize) usize {
    return height * rowByteLen(width);
}

fn storedBlockCount(raw_len: usize) usize {
    return (raw_len + max_stored_block_bytes - 1) / max_stored_block_bytes;
}

fn encodedRgba8ByteLen(width: usize, height: usize) usize {
    const raw_len = rawStreamLen(width, height);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    return signature.len + (chunk_overhead + 13) + (chunk_overhead + idat_data_len) + chunk_overhead;
}

fn writeRgba8(writer: *std.Io.Writer, width: usize, height: usize, rgba8: []const u8) anyerror!void {
    try writer.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor with alpha
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(writer, "IHDR", &ihdr);

    const raw_len = rawStreamLen(width, height);
    const row_bytes = rowByteLen(width);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(idat_data_len), .big);
    try writer.writeAll(&length_bytes);
    var crc = std.hash.Crc32.init();
    crc.update("IDAT");
    try writer.writeAll("IDAT");

    const zlib_header = [_]u8{ 0x78, 0x01 };
    crc.update(&zlib_header);
    try writer.writeAll(&zlib_header);

    var adler: std.hash.Adler32 = .{};
    const filter_byte = [_]u8{0};
    var block_start: usize = 0;
    while (block_start < raw_len) {
        const block_len = @min(raw_len - block_start, max_stored_block_bytes);
        const block_end = block_start + block_len;
        const is_final = block_end == raw_len;
        var block_header: [5]u8 = undefined;
        block_header[0] = if (is_final) 1 else 0; // BFINAL, BTYPE=00 (stored)
        std.mem.writeInt(u16, block_header[1..3], @intCast(block_len), .little);
        std.mem.writeInt(u16, block_header[3..5], @intCast(block_len ^ 0xFFFF), .little);
        crc.update(&block_header);
        try writer.writeAll(&block_header);

        var position = block_start;
        while (position < block_end) {
            const row = position / row_bytes;
            const column = position % row_bytes;
            if (column == 0) {
                crc.update(&filter_byte);
                adler.update(&filter_byte);
                try writer.writeAll(&filter_byte);
                position += 1;
                continue;
            }
            const pixel_start = row * width * 4 + (column - 1);
            const available = @min(row_bytes - column, block_end - position);
            const slice = rgba8[pixel_start .. pixel_start + available];
            crc.update(slice);
            adler.update(slice);
            try writer.writeAll(slice);
            position += available;
        }
        block_start = block_end;
    }

    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler.adler, .big);
    crc.update(&adler_bytes);
    try writer.writeAll(&adler_bytes);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);

    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) anyerror!void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(data.len), .big);
    try writer.writeAll(&length_bytes);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);
}
