//! Minimal dependency-free PNG writer (plus a strict parser for tests and
//! verification). The encoder emits 8-bit RGBA PNGs whose zlib stream uses
//! stored (uncompressed) deflate blocks only: the output is fully
//! deterministic — the same pixels always produce the same bytes — which is
//! what the automation screenshot artifacts rely on. The parser accepts only
//! the subset the writer emits.

const std = @import("std");

pub const Error = error{
    InvalidPngDimensions,
    PngPixelBufferTooSmall,
    InvalidPng,
    UnsupportedPng,
};

pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// PNG dimensions are u32; keep a conservative bound well past the canvas
/// surface limit (16384 px) while rejecting nonsense sizes.
pub const max_dimension: usize = 1 << 20;

const max_stored_block_bytes: usize = 65535;
const chunk_overhead: usize = 12; // length + type + crc

fn rowByteLen(width: usize) usize {
    // One filter byte followed by 4 bytes per pixel.
    return 1 + width * 4;
}

fn rawStreamLen(width: usize, height: usize) usize {
    return height * rowByteLen(width);
}

fn storedBlockCount(raw_len: usize) usize {
    return (raw_len + max_stored_block_bytes - 1) / max_stored_block_bytes;
}

fn validateDimensions(width: usize, height: usize) Error!void {
    if (width == 0 or height == 0) return error.InvalidPngDimensions;
    if (width > max_dimension or height > max_dimension) return error.InvalidPngDimensions;
}

pub fn pixelByteLen(width: usize, height: usize) Error!usize {
    try validateDimensions(width, height);
    return width * height * 4;
}

/// Exact number of bytes `writeRgba8` produces for a surface of this size.
pub fn encodedRgba8ByteLen(width: usize, height: usize) Error!usize {
    try validateDimensions(width, height);
    const raw_len = rawStreamLen(width, height);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    return signature.len +
        (chunk_overhead + 13) + // IHDR
        (chunk_overhead + idat_data_len) + // IDAT
        chunk_overhead; // IEND
}

/// Write `rgba8` (tightly packed, row-major, 4 bytes per pixel) as a PNG.
/// The output is byte-for-byte deterministic for identical input.
pub fn writeRgba8(writer: *std.Io.Writer, width: usize, height: usize, rgba8: []const u8) anyerror!void {
    try validateDimensions(width, height);
    if (rgba8.len < width * height * 4) return error.PngPixelBufferTooSmall;

    try writer.writeAll(&signature);

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor with alpha
    ihdr[10] = 0; // compression method
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace method
    try writeChunk(writer, "IHDR", &ihdr);

    // IDAT: zlib header + stored deflate blocks + adler32 of the raw stream.
    const raw_len = rawStreamLen(width, height);
    const row_bytes = rowByteLen(width);
    const idat_data_len = 2 + storedBlockCount(raw_len) * 5 + raw_len + 4;
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(idat_data_len), .big);
    try writer.writeAll(&length_bytes);
    var crc = std.hash.Crc32.init();
    crc.update("IDAT");
    try writer.writeAll("IDAT");

    // zlib header: deflate, 32 KiB window, no preset dictionary, fastest.
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

        // The raw stream is `height` rows of: filter byte 0 + pixel bytes.
        // Emit the slice of it covered by this stored block.
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
            const pixel_offset = row * width * 4 + (column - 1);
            const run = @min(row_bytes - column, block_end - position);
            const slice = rgba8[pixel_offset .. pixel_offset + run];
            crc.update(slice);
            adler.update(slice);
            try writer.writeAll(slice);
            position += run;
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

    // IEND
    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: []const u8, data: []const u8) anyerror!void {
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

pub const Decoded = struct {
    width: usize,
    height: usize,
    rgba8: []const u8,
};

/// Strict parser for the subset `writeRgba8` emits: 8-bit RGBA, no
/// interlace, filter 0 rows, stored deflate blocks in a single IDAT.
/// `output` must hold the raw stream (`height * (1 + width * 4)` bytes); the
/// returned `rgba8` slice aliases its prefix.
pub fn decodeRgba8(bytes: []const u8, output: []u8) Error!Decoded {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.InvalidPng;

    var offset: usize = signature.len;
    var header: ?struct { width: usize, height: usize } = null;
    var raw_len: usize = 0;
    var raw_written: usize = 0;
    var saw_idat = false;
    var saw_iend = false;
    var expected_adler: u32 = 0;

    while (offset < bytes.len) {
        if (bytes.len - offset < chunk_overhead) return error.InvalidPng;
        const data_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const chunk_type = bytes[offset + 4 .. offset + 8];
        if (bytes.len - offset < chunk_overhead + data_len) return error.InvalidPng;
        const data = bytes[offset + 8 .. offset + 8 + data_len];
        const stored_crc = std.mem.readInt(u32, bytes[offset + 8 + data_len ..][0..4], .big);
        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(data);
        if (crc.final() != stored_crc) return error.InvalidPng;
        offset += chunk_overhead + data_len;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (header != null or data.len != 13) return error.InvalidPng;
            const width: usize = std.mem.readInt(u32, data[0..4], .big);
            const height: usize = std.mem.readInt(u32, data[4..8], .big);
            validateDimensions(width, height) catch return error.InvalidPng;
            if (data[8] != 8 or data[9] != 6) return error.UnsupportedPng;
            if (data[10] != 0 or data[11] != 0 or data[12] != 0) return error.UnsupportedPng;
            header = .{ .width = width, .height = height };
            raw_len = rawStreamLen(width, height);
            if (output.len < raw_len) return error.PngPixelBufferTooSmall;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (header == null or saw_idat) return error.UnsupportedPng;
            saw_idat = true;
            if (data.len < 2 + 4) return error.InvalidPng;
            if (data[0] != 0x78) return error.UnsupportedPng;
            expected_adler = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .big);
            var stream = data[2 .. data.len - 4];
            var final_block = false;
            while (!final_block) {
                if (stream.len < 5) return error.InvalidPng;
                const block_header = stream[0];
                if (block_header & 0xFE != 0) return error.UnsupportedPng; // stored blocks only
                final_block = block_header & 1 == 1;
                const block_len: usize = std.mem.readInt(u16, stream[1..3], .little);
                const block_nlen: usize = std.mem.readInt(u16, stream[3..5], .little);
                if (block_len ^ 0xFFFF != block_nlen) return error.InvalidPng;
                if (stream.len < 5 + block_len) return error.InvalidPng;
                if (raw_written + block_len > raw_len) return error.InvalidPng;
                @memcpy(output[raw_written .. raw_written + block_len], stream[5 .. 5 + block_len]);
                raw_written += block_len;
                stream = stream[5 + block_len ..];
            }
            if (stream.len != 0) return error.InvalidPng;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (data.len != 0) return error.InvalidPng;
            saw_iend = true;
            break;
        } else {
            return error.UnsupportedPng;
        }
    }

    const parsed_header = header orelse return error.InvalidPng;
    if (!saw_idat or !saw_iend) return error.InvalidPng;
    if (raw_written != raw_len) return error.InvalidPng;
    if (std.hash.Adler32.hash(output[0..raw_len]) != expected_adler) return error.InvalidPng;

    // Strip the per-row filter bytes in place (destination stays behind the
    // source, so a forward copy is safe).
    const width = parsed_header.width;
    const height = parsed_header.height;
    const row_pixel_bytes = width * 4;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const source = row * (row_pixel_bytes + 1);
        if (output[source] != 0) return error.UnsupportedPng; // filter 0 only
        std.mem.copyForwards(u8, output[row * row_pixel_bytes .. (row + 1) * row_pixel_bytes], output[source + 1 .. source + 1 + row_pixel_bytes]);
    }

    return .{ .width = width, .height = height, .rgba8 = output[0 .. width * height * 4] };
}

/// Decode the strict writer subset while fitting its RGBA8 pixels inside a
/// pixel-count budget. Stored-deflate bytes are addressed directly from the
/// encoded stream, so an oversized source is never materialized at native
/// size. Downscaling uses deterministic integer box averages in sRGB space;
/// the test/null codec values bounded repeatability over color-management
/// fidelity (real hosts use their platform codecs' native thumbnail paths).
pub fn decodeRgba8Fitted(bytes: []const u8, output: []u8, max_pixels: usize) Error!Decoded {
    if (max_pixels == 0) return error.PngPixelBufferTooSmall;
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.InvalidPng;

    var offset: usize = signature.len;
    var width: usize = 0;
    var height: usize = 0;
    var idat: ?[]const u8 = null;
    var saw_iend = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < chunk_overhead) return error.InvalidPng;
        const data_len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const chunk_type = bytes[offset + 4 .. offset + 8];
        if (bytes.len - offset < chunk_overhead + data_len) return error.InvalidPng;
        const data = bytes[offset + 8 .. offset + 8 + data_len];
        const stored_crc = std.mem.readInt(u32, bytes[offset + 8 + data_len ..][0..4], .big);
        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(data);
        if (crc.final() != stored_crc) return error.InvalidPng;
        offset += chunk_overhead + data_len;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (width != 0 or data.len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            try validateDimensions(width, height);
            if (data[8] != 8 or data[9] != 6 or data[10] != 0 or data[11] != 0 or data[12] != 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (width == 0 or idat != null) return error.UnsupportedPng;
            idat = data;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (data.len != 0) return error.InvalidPng;
            saw_iend = true;
            break;
        } else {
            return error.UnsupportedPng;
        }
    }
    if (!saw_iend) return error.InvalidPng;
    const stream_data = idat orelse return error.InvalidPng;
    if (stream_data.len < 6 or stream_data[0] != 0x78) return error.UnsupportedPng;
    const expected_adler = std.mem.readInt(u32, stream_data[stream_data.len - 4 ..][0..4], .big);
    const deflate = stream_data[2 .. stream_data.len - 4];
    const raw_len = rawStreamLen(width, height);

    // The strict writer emits canonical full-sized stored blocks. Validate
    // that shape and the zlib checksum once, then rawByteAt below can map a
    // raw offset to its encoded byte in O(1) without an allocation.
    var compressed_offset: usize = 0;
    var raw_offset: usize = 0;
    var adler: std.hash.Adler32 = .{};
    while (raw_offset < raw_len) {
        if (deflate.len - compressed_offset < 5) return error.InvalidPng;
        const header = deflate[compressed_offset];
        if (header & 0xFE != 0) return error.UnsupportedPng;
        const block_len: usize = std.mem.readInt(u16, deflate[compressed_offset + 1 ..][0..2], .little);
        const block_nlen: usize = std.mem.readInt(u16, deflate[compressed_offset + 3 ..][0..2], .little);
        const expected_len = @min(raw_len - raw_offset, max_stored_block_bytes);
        if (block_len != expected_len or block_len ^ 0xFFFF != block_nlen) return error.UnsupportedPng;
        if (deflate.len - compressed_offset < 5 + block_len) return error.InvalidPng;
        const block = deflate[compressed_offset + 5 .. compressed_offset + 5 + block_len];
        adler.update(block);
        raw_offset += block_len;
        compressed_offset += 5 + block_len;
        const should_be_final = raw_offset == raw_len;
        if ((header & 1 == 1) != should_be_final) return error.InvalidPng;
    }
    if (compressed_offset != deflate.len or adler.adler != expected_adler) return error.InvalidPng;

    const source_pixels = std.math.mul(usize, width, height) catch return error.InvalidPngDimensions;
    var fitted_width = width;
    var fitted_height = height;
    if (source_pixels > max_pixels) {
        const scale = @sqrt(@as(f64, @floatFromInt(max_pixels)) / @as(f64, @floatFromInt(source_pixels)));
        fitted_width = @max(1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(width)) * scale))));
        fitted_height = @max(1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(height)) * scale))));
        while (fitted_width * fitted_height > max_pixels) {
            if (fitted_width > 1 and (fitted_height == 1 or fitted_width > fitted_height)) fitted_width -= 1 else fitted_height -= 1;
        }
    }
    const fitted_byte_len = fitted_width * fitted_height * 4;
    if (output.len < fitted_byte_len) return error.PngPixelBufferTooSmall;

    const Reader = struct {
        fn byteAt(data: []const u8, index: usize) u8 {
            const block_index = index / max_stored_block_bytes;
            const in_block = index % max_stored_block_bytes;
            return data[block_index * (5 + max_stored_block_bytes) + 5 + in_block];
        }
    };
    const source_row_len = rowByteLen(width);
    var oy: usize = 0;
    while (oy < fitted_height) : (oy += 1) {
        const top: u64 = @as(u64, oy) * height;
        const bottom: u64 = @as(u64, oy + 1) * height;
        const sy0: usize = @intCast(top / fitted_height);
        const sy1: usize = @intCast((bottom + fitted_height - 1) / fitted_height);
        var ox: usize = 0;
        while (ox < fitted_width) : (ox += 1) {
            const left: u64 = @as(u64, ox) * width;
            const right: u64 = @as(u64, ox + 1) * width;
            const sx0: usize = @intCast(left / fitted_width);
            const sx1: usize = @intCast((right + fitted_width - 1) / fitted_width);
            var sums = [4]u64{ 0, 0, 0, 0 };
            var weight_total: u64 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                if (Reader.byteAt(deflate, sy * source_row_len) != 0) return error.UnsupportedPng;
                const source_top: u64 = @as(u64, sy) * fitted_height;
                const source_bottom: u64 = @as(u64, sy + 1) * fitted_height;
                const weight_y = @min(bottom, source_bottom) - @max(top, source_top);
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const source_left: u64 = @as(u64, sx) * fitted_width;
                    const source_right: u64 = @as(u64, sx + 1) * fitted_width;
                    const weight_x = @min(right, source_right) - @max(left, source_left);
                    const weight = weight_x * weight_y;
                    const source = sy * source_row_len + 1 + sx * 4;
                    inline for (0..4) |channel| sums[channel] += @as(u64, Reader.byteAt(deflate, source + channel)) * weight;
                    weight_total += weight;
                }
            }
            const destination = (oy * fitted_width + ox) * 4;
            inline for (0..4) |channel| output[destination + channel] = @intCast((sums[channel] + weight_total / 2) / weight_total);
        }
    }
    return .{ .width = fitted_width, .height = fitted_height, .rgba8 = output[0..fitted_byte_len] };
}

test "png writer emits signature and IHDR fields" {
    const width: usize = 3;
    const height: usize = 2;
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index * 7);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeRgba8(&writer, width, height, &pixels);
    const encoded = writer.buffered();

    try std.testing.expectEqual(try encodedRgba8ByteLen(width, height), encoded.len);
    try std.testing.expectEqualSlices(u8, &signature, encoded[0..8]);
    // IHDR: 13-byte payload, big-endian dimensions, 8-bit RGBA, no interlace.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 13 }, encoded[8..12]);
    try std.testing.expectEqualSlices(u8, "IHDR", encoded[12..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0 }, encoded[16..29]);
    // IHDR CRC matches a recomputation over type + payload.
    var crc = std.hash.Crc32.init();
    crc.update(encoded[12..29]);
    try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, encoded[29..33], .big));
    // IDAT chunk follows, and the stream ends with IEND.
    try std.testing.expectEqualSlices(u8, "IDAT", encoded[37..41]);
    try std.testing.expectEqualSlices(u8, "IEND", encoded[encoded.len - 8 .. encoded.len - 4]);
}

test "png round-trips rgba pixels through the strict parser" {
    const width: usize = 5;
    const height: usize = 4;
    var pixels: [width * height * 4]u8 = undefined;
    var seed: u8 = 11;
    for (&pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 31 +% 7;
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeRgba8(&writer, width, height, &pixels);
    const encoded = writer.buffered();

    var raw: [height * (1 + width * 4)]u8 = undefined;
    const decoded = try decodeRgba8(encoded, &raw);
    try std.testing.expectEqual(width, decoded.width);
    try std.testing.expectEqual(height, decoded.height);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.rgba8);
}

test "png encoding is deterministic" {
    const width: usize = 4;
    const height: usize = 3;
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index * 13 + 5);

    var first_buffer: [512]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_buffer);
    try writeRgba8(&first_writer, width, height, &pixels);
    var second_buffer: [512]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_buffer);
    try writeRgba8(&second_writer, width, height, &pixels);
    try std.testing.expectEqualSlices(u8, first_writer.buffered(), second_writer.buffered());
}

test "png writer splits raw streams larger than one stored block" {
    // 200x90 RGBA = 72,090 raw bytes: forces at least two stored blocks.
    const width: usize = 200;
    const height: usize = 90;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(pixels);
    var seed: u8 = 3;
    for (pixels) |*byte| {
        byte.* = seed;
        seed = seed *% 17 +% 29;
    }

    const encoded_len = try encodedRgba8ByteLen(width, height);
    const encoded_buffer = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded_buffer);
    var writer = std.Io.Writer.fixed(encoded_buffer);
    try writeRgba8(&writer, width, height, pixels);
    try std.testing.expectEqual(encoded_len, writer.buffered().len);

    const raw = try allocator.alloc(u8, rawStreamLen(width, height));
    defer allocator.free(raw);
    const decoded = try decodeRgba8(writer.buffered(), raw);
    try std.testing.expectEqualSlices(u8, pixels, decoded.rgba8);
}

test "png writer validates dimensions and buffers" {
    var pixels: [16]u8 = undefined;
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidPngDimensions, writeRgba8(&writer, 0, 1, &pixels));
    try std.testing.expectError(error.InvalidPngDimensions, writeRgba8(&writer, 1, 0, &pixels));
    try std.testing.expectError(error.PngPixelBufferTooSmall, writeRgba8(&writer, 4, 4, &pixels));
    try std.testing.expectError(error.InvalidPngDimensions, encodedRgba8ByteLen(max_dimension + 1, 1));

    var raw: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidPng, decodeRgba8("not a png", &raw));
}
