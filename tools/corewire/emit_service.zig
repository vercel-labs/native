//! Fourth corewire projection: the service entries and the Zig name/index
//! registry consumed by the runner transports. Two entry projections share
//! one contract: the plain-scriptc child-process host main (framed stdio)
//! and the in-process library facade (a library-mode archive linked into
//! the app binary, one instance per pool thread).

const std = @import("std");
const service = @import("service_contract.zig");

/// The in-process service archive's C symbol family. Distinct from the
/// compiled core's prefix (the frontend's abi.prefix, canonically
/// "nsc_core_") so both archives link into one binary; fixed because one
/// app binary carries at most one service archive.
pub const inproc_symbol_prefix = "nsc_svc_";

const fingerprint_len = std.crypto.hash.sha2.Sha256.digest_length;

fn fingerprintField(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, @intCast(bytes.len), .little);
    hasher.update(&len);
    hasher.update(bytes);
}

fn fingerprintType(hasher: *std.crypto.hash.sha2.Sha256, ref: service.TypeRef) void {
    hasher.update(&.{@intFromEnum(ref.kind)});
    if (ref.inner) |inner| fingerprintType(hasher, inner.*);
    if (ref.elem) |elem| fingerprintType(hasher, elem.*);
    if (ref.name) |name| fingerprintField(hasher, name);
}

/// Identity of every fact that can change generated dispatch semantics. The
/// same digest is embedded in the service executable and the Zig registry so
/// a stale or hand-supplied sibling is refused before numeric indices are used.
fn contractFingerprint(contract: service.Contract) [fingerprint_len]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("native-sdk.services.contract.v3\x00");
    var scalar: [8]u8 = undefined;
    std.mem.writeInt(i64, &scalar, contract.format, .little);
    hasher.update(&scalar);
    std.mem.writeInt(i64, &scalar, contract.protocol_version, .little);
    hasher.update(&scalar);
    hasher.update(&.{@intFromBool(contract.deterministic)});
    fingerprintField(&hasher, contract.compiler_version);
    std.mem.writeInt(u64, &scalar, @intCast(contract.packages.len), .little);
    hasher.update(&scalar);
    for (contract.packages) |package_entry| {
        fingerprintField(&hasher, package_entry.name);
        fingerprintField(&hasher, package_entry.version);
        fingerprintField(&hasher, package_entry.content_hash);
    }
    for (contract.types.records) |record| {
        fingerprintField(&hasher, record.name);
        fingerprintField(&hasher, record.origin);
        for (record.fields) |field| {
            fingerprintField(&hasher, field.name);
            fingerprintType(&hasher, field.type);
        }
    }
    for (contract.types.enums) |enum_type| {
        fingerprintField(&hasher, enum_type.name);
        fingerprintField(&hasher, enum_type.origin);
        for (enum_type.members) |member| fingerprintField(&hasher, member);
    }
    for (contract.types.unions) |union_type| {
        fingerprintField(&hasher, union_type.name);
        fingerprintField(&hasher, union_type.origin);
        for (union_type.arms) |arm| {
            fingerprintField(&hasher, arm.name);
            for (arm.fields) |field| {
                fingerprintField(&hasher, field.name);
                fingerprintType(&hasher, field.type);
            }
        }
    }
    std.mem.writeInt(u64, &scalar, @intCast(contract.operations.len), .little);
    hasher.update(&scalar);
    for (contract.operations) |op| {
        fingerprintField(&hasher, op.name);
        fingerprintField(&hasher, op.client);
        fingerprintField(&hasher, op.module);
        fingerprintField(&hasher, op.@"export");
        fingerprintType(&hasher, op.request);
        fingerprintType(&hasher, op.result);
        std.mem.writeInt(i64, &scalar, op.deadline_ms orelse 0, .little);
        hasher.update(&scalar);
        hasher.update(&.{@intFromBool(op.cancellable)});
        if (op.stream) |stream| {
            hasher.update(&.{1});
            fingerprintType(&hasher, stream.chunk);
            std.mem.writeInt(i64, &scalar, stream.in_flight, .little);
            hasher.update(&scalar);
        } else hasher.update(&.{0});
        fingerprintField(&hasher, op.source_hash);
    }
    return hasher.finalResult();
}

fn jsString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (byte < 0x20)
            try w.print("\\u00{x:0>2}", .{byte})
        else
            try w.writeByte(byte),
    };
    try w.writeByte('"');
}

fn emitDecodeExpr(w: *std.Io.Writer, ref: service.TypeRef, reader: []const u8) !void {
    switch (ref.kind) {
        .none => try w.writeAll("undefined"),
        .bool => try w.print("{s}.bool()", .{reader}),
        .f64 => try w.print("{s}.f64()", .{reader}),
        .i64 => try w.print("{s}.i64()", .{reader}),
        .bytes => try w.print("{s}.bytesValue()", .{reader}),
        .optional => {
            try w.print("readOptional({s}, (nested) => ", .{reader});
            try emitDecodeExpr(w, ref.inner.?.*, "nested");
            try w.writeByte(')');
        },
        .slice => {
            try w.print("readSlice({s}, (nested) => ", .{reader});
            try emitDecodeExpr(w, ref.elem.?.*, "nested");
            try w.writeByte(')');
        },
        .record, .@"enum", .@"union" => try w.print("__nativeSdkDecode{s}({s})", .{ ref.name.?, reader }),
    }
}

fn emitEncodeExpr(w: *std.Io.Writer, ref: service.TypeRef, value: []const u8) !void {
    switch (ref.kind) {
        .none => try w.writeAll("new Uint8Array(0)"),
        .bool => try w.print("writeBool({s})", .{value}),
        .f64 => try w.print("writeF64({s})", .{value}),
        .i64 => try w.print("writeI64({s})", .{value}),
        .bytes => try w.print("writeBytes({s})", .{value}),
        .optional => {
            try w.print("{s} === null ? writeOptional(null) : writeOptional(", .{value});
            try emitEncodeExpr(w, ref.inner.?.*, value);
            try w.writeByte(')');
        },
        .slice => {
            try w.print("writeSlice({s}.map((item) => ", .{value});
            try emitEncodeExpr(w, ref.elem.?.*, "item");
            try w.writeAll("))");
        },
        .record, .@"enum", .@"union" => try w.print("__nativeSdkEncode{s}({s})", .{ ref.name.?, value }),
    }
}

fn emitHostCodecs(w: *std.Io.Writer, contract: service.Contract) !void {
    try w.writeAll(
        \\class __NativeSdkReader {
        \\  readonly bytes: Uint8Array;
        \\  at: number;
        \\  constructor(bytes: Uint8Array) { this.bytes = bytes; this.at = 0; }
        \\  take(length: number): Uint8Array {
        \\    if (length < 0 || this.at + length > this.bytes.length) throw new Error("truncated service value");
        \\    const out = this.bytes.subarray(this.at, this.at + length);
        \\    this.at += length;
        \\    return out;
        \\  }
        \\  u8(): number { return this.take(1)[0]; }
        \\  u32(): number {
        \\    const b = this.take(4);
        \\    return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0;
        \\  }
        \\  bool(): boolean {
        \\    const value = this.u8();
        \\    if (value > 1) throw new Error("invalid service boolean");
        \\    return value === 1;
        \\  }
        \\  f64(): number {
        \\    const b = this.take(8);
        \\    return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true);
        \\  }
        \\  i64(): number {
        \\    const b = this.take(8);
        \\    const view = new DataView(b.buffer, b.byteOffset, 8);
        \\    return view.getUint32(0, true) + view.getInt32(4, true) * 4294967296;
        \\  }
        \\  bytesValue(): Uint8Array { return this.take(this.u32()); }
        \\  finish(): void {
        \\    if (this.at !== this.bytes.length) throw new Error("trailing service value bytes");
        \\  }
        \\}
        \\function readOptional<T>(reader: __NativeSdkReader, decode: (reader: __NativeSdkReader) => T): T | null {
        \\  const present = reader.u8();
        \\  if (present === 0) return null;
        \\  if (present !== 1) throw new Error("invalid service optional");
        \\  return decode(reader);
        \\}
        \\function readSlice<T>(reader: __NativeSdkReader, decode: (reader: __NativeSdkReader) => T): T[] {
        \\  const count = reader.u32();
        \\  const out: T[] = [];
        \\  for (let i = 0; i < count; i++) out.push(decode(reader));
        \\  return out;
        \\}
        \\function writeU32(value: number): Uint8Array {
        \\  const out = new Uint8Array(4);
        \\  new DataView(out.buffer).setUint32(0, value, true);
        \\  return out;
        \\}
        \\function concat(parts: readonly Uint8Array[]): Uint8Array {
        \\  let length = 0;
        \\  for (const part of parts) length += part.length;
        \\  const out = new Uint8Array(length);
        \\  let at = 0;
        \\  for (const part of parts) { out.set(part, at); at += part.length; }
        \\  return out;
        \\}
        \\function writeBool(value: boolean): Uint8Array { return new Uint8Array([value ? 1 : 0]); }
        \\function writeF64(value: number): Uint8Array {
        \\  const out = new Uint8Array(8);
        \\  new DataView(out.buffer).setFloat64(0, Number.isNaN(value) ? Number.NaN : value, true);
        \\  return out;
        \\}
        \\function writeI64(value: number): Uint8Array {
        \\  const out = new Uint8Array(8);
        \\  const view = new DataView(out.buffer);
        \\  const base = 4294967296;
        \\  let low = value % base;
        \\  if (low < 0) low += base;
        \\  view.setUint32(0, low, true);
        \\  view.setInt32(4, Math.floor(value / base), true);
        \\  return out;
        \\}
        \\function writeBytes(value: Uint8Array): Uint8Array { return concat([writeU32(value.length), value]); }
        \\function writeOptional(value: Uint8Array | null): Uint8Array {
        \\  return value === null ? new Uint8Array([0]) : concat([new Uint8Array([1]), value]);
        \\}
        \\function writeSlice(values: readonly Uint8Array[]): Uint8Array {
        \\  return concat([writeU32(values.length), ...values]);
        \\}
        \\
    );
    for (contract.types.records) |record| {
        try w.print("function __nativeSdkDecode{s}(reader: __NativeSdkReader): {s} {{ return {{ ", .{ record.name, record.name });
        for (record.fields, 0..) |field, index| {
            if (index > 0) try w.writeAll(", ");
            try w.print("{s}: ", .{field.name});
            try emitDecodeExpr(w, field.type, "reader");
        }
        try w.writeAll(" }; }\n");
        try w.print("function __nativeSdkEncode{s}(value: {s}): Uint8Array {{ return concat([", .{ record.name, record.name });
        for (record.fields, 0..) |field, index| {
            if (index > 0) try w.writeAll(", ");
            const field_value = try std.fmt.allocPrint(std.heap.page_allocator, "value.{s}", .{field.name});
            defer std.heap.page_allocator.free(field_value);
            try emitEncodeExpr(w, field.type, field_value);
        }
        try w.writeAll("]); }\n");
    }
    for (contract.types.enums) |enum_type| {
        try w.print("function __nativeSdkDecode{s}(reader: __NativeSdkReader): {s} {{ switch (reader.u32()) {{\n", .{ enum_type.name, enum_type.name });
        for (enum_type.members, 0..) |member, index| {
            try w.print("  case {d}: return ", .{index});
            try jsString(w, member);
            try w.writeAll(";\n");
        }
        try w.writeAll("  default: throw new Error(\"invalid service enum\");\n} }\n");
        try w.print("function __nativeSdkEncode{s}(value: {s}): Uint8Array {{ return writeU32(", .{ enum_type.name, enum_type.name });
        for (enum_type.members, 0..) |member, index| {
            try w.writeAll("value === ");
            try jsString(w, member);
            try w.print(" ? {d} : (", .{index});
        }
        try w.writeAll("0");
        for (enum_type.members) |_| try w.writeByte(')');
        try w.writeAll("); }\n");
    }
    for (contract.types.unions) |union_type| {
        try w.print("function __nativeSdkDecode{s}(reader: __NativeSdkReader): {s} {{ switch (reader.u8()) {{\n", .{ union_type.name, union_type.name });
        for (union_type.arms, 0..) |arm, index| {
            try w.print("  case {d}: return {{ kind: ", .{index});
            try jsString(w, arm.name);
            for (arm.fields) |field| {
                try w.print(", {s}: ", .{field.name});
                try emitDecodeExpr(w, field.type, "reader");
            }
            try w.writeAll(" };\n");
        }
        try w.writeAll("  default: throw new Error(\"invalid service union\");\n} }\n");
        try w.print("function __nativeSdkEncode{s}(value: {s}): Uint8Array {{ switch (value.kind) {{\n", .{ union_type.name, union_type.name });
        for (union_type.arms, 0..) |arm, index| {
            try w.writeAll("  case ");
            try jsString(w, arm.name);
            try w.print(": return concat([new Uint8Array([{d}])", .{index});
            for (arm.fields) |field| {
                try w.writeAll(", ");
                const field_value = try std.fmt.allocPrint(std.heap.page_allocator, "value.{s}", .{field.name});
                defer std.heap.page_allocator.free(field_value);
                try emitEncodeExpr(w, field.type, field_value);
            }
            try w.writeAll("]);\n");
        }
        try w.writeAll("} }\n");
    }
}

pub fn emitHost(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\// Generated by corewire from services.contract.json. Do not edit.
        \\import * as fs from "node:fs";
        \\
    );
    for (contract.operations, 0..) |op, index| {
        const staged_module = op.module["src/".len..];
        try w.print("import {{ {s} as serviceOp{d} }} from \"./{s}\";\n", .{ op.@"export", index, staged_module });
    }
    for (contract.types.records) |record| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ record.name, record.origin });
    for (contract.types.enums) |enum_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ enum_type.name, enum_type.origin });
    for (contract.types.unions) |union_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ union_type.name, union_type.origin });
    const fingerprint = contractFingerprint(contract);
    try w.print("\nconst PROTOCOL_VERSION = {d};\nconst CONTRACT_FINGERPRINT = new Uint8Array([", .{contract.protocol_version});
    for (fingerprint, 0..) |byte, index| {
        if (index > 0) try w.writeAll(", ");
        try w.print("{d}", .{byte});
    }
    try w.writeAll("]);\n");
    try w.writeAll(
        \\const MAX_FRAME_BYTES = 16 * 1024 * 1024;
        \\function readExact(length: number, eofAllowed: boolean): Uint8Array | null {
        \\  const bytes = new Uint8Array(length);
        \\  let offset = 0;
        \\  while (offset < length) {
        \\    const read = fs.readSync(0, bytes, offset, length - offset);
        \\    if (read === 0) {
        \\      if (offset === 0 && eofAllowed) return null;
        \\      throw { kind: "service_protocol", message: "truncated frame" };
        \\    }
        \\    offset += read;
        \\  }
        \\  return bytes;
        \\}
        \\
        \\function u16(bytes: Uint8Array, at: number): number {
        \\  return bytes[at] | (bytes[at + 1] << 8);
        \\}
        \\function u32(bytes: Uint8Array, at: number): number {
        \\  return (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
        \\}
        \\function putU32(bytes: Uint8Array, at: number, value: number): void {
        \\  bytes[at] = value & 255;
        \\  bytes[at + 1] = (value >>> 8) & 255;
        \\  bytes[at + 2] = (value >>> 16) & 255;
        \\  bytes[at + 3] = (value >>> 24) & 255;
        \\}
        \\function writeHello(): void {
        \\  const frame = new Uint8Array(5 + CONTRACT_FINGERPRINT.length);
        \\  putU32(frame, 0, 1 + CONTRACT_FINGERPRINT.length);
        \\  frame[4] = PROTOCOL_VERSION;
        \\  frame.set(CONTRACT_FINGERPRINT, 5);
        \\  process.stdout.write(frame);
        \\}
        \\function writeResult(requestId: number, status: number, payload: Uint8Array): void {
        \\  const frame = new Uint8Array(9 + payload.length);
        \\  putU32(frame, 0, 5 + payload.length);
        \\  putU32(frame, 4, requestId);
        \\  frame[8] = status;
        \\  frame.set(payload, 9);
        \\  process.stdout.write(frame);
        \\}
        \\class __NativeSdkCancelled extends Error {
        \\  constructor() { super("service operation was cancelled"); this.name = "cancelled"; }
        \\}
        \\function cancellation(path: string) {
        \\  const cancelled = (): boolean => path.length > 0 && fs.existsSync(path);
        \\  return {
        \\    cancelled,
        \\    throwIfCancelled: (): void => { if (cancelled()) throw new __NativeSdkCancelled(); },
        \\  };
        \\}
        \\
    );
    try emitHostCodecs(w, contract);
    for (contract.operations, 0..) |op, index| if (op.stream) |stream| {
        try w.print("\nfunction __nativeSdkEmit{d}(requestId: number, chunk: ", .{index});
        try emitTsType(w, stream.chunk);
        try w.writeAll("): void { writeResult(requestId, 2, ");
        if (stream.chunk.kind == .bytes) try w.writeAll("chunk") else try emitEncodeExpr(w, stream.chunk, "chunk");
        try w.writeAll("); }\n");
    };
    try w.writeAll(
        \\function dispatch(index: number, payload: Uint8Array, requestId: number, cancelPath: string): Uint8Array {
        \\  switch (index) {
        \\
    );
    try emitDispatchCases(w, arena, contract, .child_process);
    try w.writeAll(
        \\    default: throw new Error("service operation index is not in the contract");
        \\  }
        \\}
        \\
        \\writeHello();
        \\while (true) {
        \\  const header = readExact(4, true);
        \\  if (header === null) break;
        \\  const length = u32(header, 0);
        \\  if (length < 8 || length > MAX_FRAME_BYTES) throw { kind: "service_protocol", message: "invalid request frame length" };
        \\  const body = readExact(length, false) as Uint8Array;
        \\  const requestId = u32(body, 0);
        \\  const operation = u16(body, 4);
        \\  const cancelPathLength = u16(body, 6);
        \\  if (8 + cancelPathLength > body.length) throw { kind: "service_protocol", message: "truncated cancellation path" };
        \\  const cancelPath = new TextDecoder().decode(body.subarray(8, 8 + cancelPathLength));
        \\  const payload = body.subarray(8 + cancelPathLength);
        \\  try {
        \\    const result = dispatch(operation, payload, requestId, cancelPath);
        \\    cancellation(cancelPath).throwIfCancelled();
        \\    writeResult(requestId, 0, result);
        \\  } catch (error) {
        \\    if (error instanceof Error) {
        \\      writeResult(requestId, 1, new TextEncoder().encode(JSON.stringify({ kind: error.name, message: error.message })));
        \\    } else {
        \\      writeResult(requestId, 1, new TextEncoder().encode(JSON.stringify({ kind: "service_error", message: "service operation threw" })));
        \\    }
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice();
}

/// The dispatch switch shared by both entry projections. The child host
/// main's streaming emits carry the frame's request id; the in-process
/// facade's emits write to the request's chunk-relay file instead, so its
/// emit helpers take the chunk alone.
const DispatchLane = enum { child_process, in_process };

fn emitDispatchCases(w: *std.Io.Writer, arena: std.mem.Allocator, contract: service.Contract, lane: DispatchLane) !void {
    for (contract.operations, 0..) |op, index| {
        try w.print("    case {d}: {{\n", .{index});
        const emit_callback = switch (lane) {
            .child_process => try std.fmt.allocPrint(arena, "(chunk) => __nativeSdkEmit{d}(requestId, chunk)", .{index}),
            .in_process => try std.fmt.allocPrint(arena, "(chunk) => __nativeSdkEmit{d}(chunk)", .{index}),
        };
        defer arena.free(emit_callback);
        if (op.request.kind == .none) {
            try w.writeAll("      if (payload.length !== 0) throw new Error(\"unexpected service request payload\");\n");
            try w.print("      return ", .{});
            const call = if (op.stream != null and op.cancellable)
                try std.fmt.allocPrint(arena, "serviceOp{d}({s}, cancellation(cancelPath))", .{ index, emit_callback })
            else if (op.stream != null)
                try std.fmt.allocPrint(arena, "serviceOp{d}({s})", .{ index, emit_callback })
            else if (op.cancellable)
                try std.fmt.allocPrint(arena, "serviceOp{d}(cancellation(cancelPath))", .{index})
            else
                try std.fmt.allocPrint(arena, "serviceOp{d}()", .{index});
            defer arena.free(call);
            if (op.result.kind == .bytes) try w.writeAll(call) else try emitEncodeExpr(w, op.result, call);
            try w.writeAll(";\n");
        } else {
            if (op.request.kind == .bytes) {
                try w.writeAll("      const request = payload;\n      return ");
            } else {
                try w.writeAll("      const reader = new __NativeSdkReader(payload);\n      const request = ");
                try emitDecodeExpr(w, op.request, "reader");
                try w.writeAll(";\n      reader.finish();\n      return ");
            }
            const call = if (op.stream != null and op.cancellable)
                try std.fmt.allocPrint(arena, "serviceOp{d}(request, {s}, cancellation(cancelPath))", .{ index, emit_callback })
            else if (op.stream != null)
                try std.fmt.allocPrint(arena, "serviceOp{d}(request, {s})", .{ index, emit_callback })
            else if (op.cancellable)
                try std.fmt.allocPrint(arena, "serviceOp{d}(request, cancellation(cancelPath))", .{index})
            else
                try std.fmt.allocPrint(arena, "serviceOp{d}(request)", .{index});
            defer arena.free(call);
            if (op.result.kind == .bytes) try w.writeAll(call) else try emitEncodeExpr(w, op.result, call);
            try w.writeAll(";\n");
        }
        try w.writeAll("    }\n");
    }
}

/// The in-process facade: the library-mode entry the service archive
/// compiles from. One exported dispatch covers every operation — the pool
/// passes the contract's operation index, the encoded request, the
/// cooperative-cancellation marker path, and (streaming operations only)
/// the chunk-relay file path. The return is a status byte (0 ok, 1 err)
/// followed by the encoded result or the error JSON. Interim stream
/// chunks ride the relay file as [len u32 LE][bytes] frames while the
/// operation runs — the same liveness the child's stdout frames give.
pub fn emitInprocMain(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\// Generated by corewire from services.contract.json. Do not edit.
        \\import * as fs from "node:fs";
        \\
    );
    for (contract.operations, 0..) |op, index| {
        const staged_module = op.module["src/".len..];
        try w.print("import {{ {s} as serviceOp{d} }} from \"./{s}\";\n", .{ op.@"export", index, staged_module });
    }
    for (contract.types.records) |record| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ record.name, record.origin });
    for (contract.types.enums) |enum_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ enum_type.name, enum_type.origin });
    for (contract.types.unions) |union_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ union_type.name, union_type.origin });
    const fingerprint = contractFingerprint(contract);
    try w.writeAll("\nconst CONTRACT_FINGERPRINT = new Uint8Array([");
    for (fingerprint, 0..) |byte, index| {
        if (index > 0) try w.writeAll(", ");
        try w.print("{d}", .{byte});
    }
    try w.writeAll("]);\n");
    try w.writeAll(
        \\export function contractFingerprint(): Uint8Array {
        \\  return CONTRACT_FINGERPRINT;
        \\}
        \\class __NativeSdkCancelled extends Error {
        \\  constructor() { super("service operation was cancelled"); this.name = "cancelled"; }
        \\}
        \\function cancellation(path: string) {
        \\  const cancelled = (): boolean => path.length > 0 && fs.existsSync(path);
        \\  return {
        \\    cancelled,
        \\    throwIfCancelled: (): void => { if (cancelled()) throw new __NativeSdkCancelled(); },
        \\  };
        \\}
        \\let __nativeSdkStreamFd = -1;
        \\function __nativeSdkEmitFrame(bytes: Uint8Array): void {
        \\  if (__nativeSdkStreamFd < 0) return;
        \\  const frame = new Uint8Array(4 + bytes.length);
        \\  frame[0] = bytes.length & 255;
        \\  frame[1] = (bytes.length >>> 8) & 255;
        \\  frame[2] = (bytes.length >>> 16) & 255;
        \\  frame[3] = (bytes.length >>> 24) & 255;
        \\  frame.set(bytes, 4);
        \\  fs.writeSync(__nativeSdkStreamFd, frame, 0, frame.length);
        \\}
        \\
    );
    try emitHostCodecs(w, contract);
    for (contract.operations, 0..) |op, index| if (op.stream) |stream| {
        try w.print("\nfunction __nativeSdkEmit{d}(chunk: ", .{index});
        try emitTsType(w, stream.chunk);
        try w.writeAll("): void { __nativeSdkEmitFrame(");
        if (stream.chunk.kind == .bytes) try w.writeAll("chunk") else try emitEncodeExpr(w, stream.chunk, "chunk");
        try w.writeAll("); }\n");
    };
    try w.writeAll(
        \\function dispatchOperation(index: number, payload: Uint8Array, cancelPath: string): Uint8Array {
        \\  switch (index) {
        \\
    );
    try emitDispatchCases(w, arena, contract, .in_process);
    try w.writeAll(
        \\    default: throw new Error("service operation index is not in the contract");
        \\  }
        \\}
        \\
        \\export function dispatch(operation: number, payload: Uint8Array, cancelPathBytes: Uint8Array, streamPathBytes: Uint8Array): Uint8Array {
        \\  const cancelPath = new TextDecoder().decode(cancelPathBytes);
        \\  const streamPath = new TextDecoder().decode(streamPathBytes);
        \\  __nativeSdkStreamFd = streamPath.length > 0 ? fs.openSync(streamPath, "a") : -1;
        \\  try {
        \\    const result = dispatchOperation(operation, payload, cancelPath);
        \\    cancellation(cancelPath).throwIfCancelled();
        \\    const out = new Uint8Array(1 + result.length);
        \\    out[0] = 0;
        \\    out.set(result, 1);
        \\    return out;
        \\  } catch (error) {
        \\    let kind = "service_error";
        \\    let message = "service operation threw";
        \\    if (error instanceof Error) {
        \\      kind = error.name;
        \\      message = error.message;
        \\    }
        \\    const body = new TextEncoder().encode(JSON.stringify({ kind, message }));
        \\    const out = new Uint8Array(1 + body.length);
        \\    out[0] = 1;
        \\    out.set(body, 1);
        \\    return out;
        \\  } finally {
        \\    if (__nativeSdkStreamFd >= 0) {
        \\      fs.closeSync(__nativeSdkStreamFd);
        \\      __nativeSdkStreamFd = -1;
        \\    }
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice();
}

/// The library-mode compiler profile for the in-process service archive.
/// Contract-independent by design: one fixed entry, the fixed service
/// symbol family, runtime localization (so the archive links beside the
/// compiled core's archive), and thread-instanced state (one independent
/// instance per pool thread). No sidecar section — the archive is built
/// and linked by one build graph, and the facade's fingerprint export is
/// the pairing check. No determinism fences — services run with ambient
/// authority by contract.
pub fn emitInprocProfile(arena: std.mem.Allocator) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.print(
        \\{{
        \\  "profile_format": 1,
        \\  "name": "native-sdk-services",
        \\  "entry": "service_inproc_main.ts",
        \\  "emission": "llvm",
        \\  "abi": {{
        \\    "prefix": "{s}",
        \\    "init_symbol": "{s}init",
        \\    "sink_register_symbol": "{s}set_panic_sink",
        \\    "collect_symbol": "{s}collect",
        \\    "result_reset_symbol": null,
        \\    "localize_runtime": true,
        \\    "instance_per_thread": true
        \\  }},
        \\  "exports": [
        \\    {{ "export": "dispatch", "symbol": "{s}dispatch", "params": ["u32", "bytes", "bytes", "bytes"], "returns": "bytes" }},
        \\    {{ "export": "contractFingerprint", "symbol": "{s}contract_fingerprint", "params": [], "returns": "bytes" }}
        \\  ]
        \\}}
        \\
    , .{ inproc_symbol_prefix, inproc_symbol_prefix, inproc_symbol_prefix, inproc_symbol_prefix, inproc_symbol_prefix, inproc_symbol_prefix });
    return out.toOwnedSlice();
}

pub fn emitRegistry(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    const fingerprint = contractFingerprint(contract);
    try w.print(
        \\//! Generated by corewire from services.contract.json. Do not edit.
        \\pub const enabled = true;
        \\pub const protocol_version: u8 = {d};
        \\pub const compiler_version = "{s}";
        \\pub const inproc_symbol_prefix = "{s}";
        \\
    , .{ contract.protocol_version, contract.compiler_version, inproc_symbol_prefix });
    try w.writeAll("pub const contract_fingerprint = [_]u8{");
    for (fingerprint, 0..) |byte, index| {
        if (index > 0) try w.writeAll(", ");
        try w.print("{d}", .{byte});
    }
    try w.writeAll(
        \\};
        \\pub const Operation = struct { name: []const u8, index: u16, deadline_ms: ?u32, cancellable: bool, streaming: bool, in_flight: u8 };
        \\pub const operations = [_]Operation{
        \\
    );
    for (contract.operations, 0..) |op, index| {
        const streaming = op.stream != null;
        const in_flight: i64 = if (op.stream) |stream| stream.in_flight else 0;
        if (op.deadline_ms) |deadline| {
            try w.print("    .{{ .name = \"{s}\", .index = {d}, .deadline_ms = {d}, .cancellable = {}, .streaming = {}, .in_flight = {d} }},\n", .{ op.name, index, deadline, op.cancellable, streaming, in_flight });
        } else {
            try w.print("    .{{ .name = \"{s}\", .index = {d}, .deadline_ms = null, .cancellable = {}, .streaming = {}, .in_flight = {d} }},\n", .{ op.name, index, op.cancellable, streaming, in_flight });
        }
    }
    try w.writeAll(
        \\};
        \\pub fn indexOf(name: []const u8) ?u16 {
        \\    for (operations) |op| if (@import("std").mem.eql(u8, op.name, name)) return op.index;
        \\    return null;
        \\}
        \\pub fn operationAt(index: u16) ?Operation {
        \\    for (operations) |op| if (op.index == index) return op;
        \\    return null;
        \\}
        \\pub fn isStreaming(index: u16) bool {
        \\    return if (operationAt(index)) |op| op.streaming else false;
        \\}
    );
    try w.writeAll("pub fn resultIsBytes(index: u16) bool {\n    return switch (index) {\n");
    for (contract.operations, 0..) |op, index| if (op.result.kind == .bytes) {
        try w.print("        {d} => true,\n", .{index});
    };
    try w.writeAll("        else => false,\n    };\n}\n");
    try w.writeAll(
        \\pub fn resultDecoder(comptime core: type) *const fn (operation: u16, tag: u8, bytes: []const u8) core.Msg {
        \\    return struct {
        \\        fn decode(operation: u16, tag: u8, bytes: []const u8) core.Msg {
        \\            if (operationAt(operation) == null) @panic("typed service result names an operation outside services.contract.json");
        \\            inline for (@typeInfo(core.Msg).@"union".fields, 0..) |arm, index| {
        \\                if (tag == index) {
        \\                    if (comptime arm.type == void) @panic("typed service result targets a void Msg arm");
        \\                    if (resultIsBytes(operation)) {
        \\                        if (comptime arm.type == []const u8) return @unionInit(core.Msg, arm.name, core.rt.copyServiceBytes(bytes));
        \\                        @panic("typed byte service result targets a non-bytes Msg arm");
        \\                    }
        \\                    return @unionInit(core.Msg, arm.name, core.rt.decodeExact(arm.type, bytes));
        \\                }
        \\            }
        \\            @panic("typed service result names a Msg tag outside the core contract");
        \\        }
        \\    }.decode;
        \\}
        \\
    );
    return out.toOwnedSlice();
}

fn emitTsType(w: *std.Io.Writer, ref: service.TypeRef) !void {
    switch (ref.kind) {
        .none => try w.writeAll("void"),
        .bool => try w.writeAll("boolean"),
        .f64, .i64 => try w.writeAll("number"),
        .bytes => try w.writeAll("Uint8Array"),
        .optional => {
            try emitTsType(w, ref.inner.?.*);
            try w.writeAll(" | null");
        },
        .slice => {
            try w.writeAll("readonly ");
            const parenthesize = ref.elem.?.kind == .optional or ref.elem.?.kind == .slice;
            if (parenthesize) try w.writeByte('(');
            try emitTsType(w, ref.elem.?.*);
            if (parenthesize) try w.writeByte(')');
            try w.writeAll("[]");
        },
        .record, .@"enum", .@"union" => try w.writeAll(ref.name.?),
    }
}

pub fn emitClient(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\// Generated by corewire from services.contract.json. Do not edit.
        \\import {
        \\  Cmd,
        \\  serviceBoolBytes as writeBool,
        \\  serviceBytes as writeBytes,
        \\  serviceConcat as concat,
        \\  serviceEnumBytes as writeEnum,
        \\  serviceF64Bytes as writeF64,
        \\  serviceI64Bytes as writeI64,
        \\  serviceOptionalBytes as writeOptional,
        \\  serviceSliceBytes as writeSlice,
        \\  serviceUnionBytes as writeUnion,
        \\  type ServiceRoute,
        \\  type ServiceStreamRoute,
        \\} from "@native-sdk/core";
        \\import type { Msg } from "./core.ts";
        \\
    );
    for (contract.types.records) |record| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ record.name, record.origin });
    for (contract.types.enums) |enum_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ enum_type.name, enum_type.origin });
    for (contract.types.unions) |union_type| try w.print("import type {{ {s} }} from \"./{s}\";\n", .{ union_type.name, union_type.origin });

    for (contract.types.records) |record| {
        try w.print("\nfunction __nativeSdkEncode{s}(value: {s}): Uint8Array {{ return concat([", .{ record.name, record.name });
        for (record.fields, 0..) |field, index| {
            if (index > 0) try w.writeAll(", ");
            const field_value = try std.fmt.allocPrint(arena, "value.{s}", .{field.name});
            try emitEncodeExpr(w, field.type, field_value);
        }
        try w.writeAll("]); }\n");
    }
    for (contract.types.enums) |enum_type| {
        try w.print("\nfunction __nativeSdkEncode{s}(value: {s}): Uint8Array {{ return writeEnum(", .{ enum_type.name, enum_type.name });
        for (enum_type.members, 0..) |member, index| {
            try w.writeAll("value === ");
            try jsString(w, member);
            try w.print(" ? {d} : (", .{index});
        }
        try w.writeAll("0");
        for (enum_type.members) |_| try w.writeByte(')');
        try w.writeAll("); }\n");
    }
    for (contract.types.unions) |union_type| {
        try w.print("\nfunction __nativeSdkEncode{s}(value: {s}): Uint8Array {{ switch (value.kind) {{\n", .{ union_type.name, union_type.name });
        for (union_type.arms, 0..) |arm, index| {
            try w.writeAll("  case ");
            try jsString(w, arm.name);
            try w.print(": return concat([writeUnion({d})", .{index});
            for (arm.fields) |field| {
                try w.writeAll(", ");
                const field_value = try std.fmt.allocPrint(arena, "value.{s}", .{field.name});
                try emitEncodeExpr(w, field.type, field_value);
            }
            try w.writeAll("]);\n");
        }
        try w.writeAll("} }\n");
    }
    for (contract.operations) |op| {
        try w.print("\nexport function {s}(", .{op.client});
        if (op.request.kind != .none) {
            try w.writeAll("request: ");
            try emitTsType(w, op.request);
            try w.writeAll(", ");
        }
        try w.writeAll(if (op.stream == null) "route: ServiceRoute<Msg, " else "route: ServiceStreamRoute<Msg, ");
        try emitTsType(w, op.result);
        try w.writeAll(">): Cmd<Msg> {\n  return Cmd.");
        try w.writeAll(if (op.stream == null) "serviceRequest(" else "serviceStreamRequest(");
        try jsString(w, op.name);
        if (op.stream != null) try w.writeAll(", route.channelKey");
        try w.writeAll(", ");
        if (op.request.kind == .none) {
            try w.writeAll("new Uint8Array(0)");
        } else if (op.request.kind == .bytes) {
            try w.writeAll("request");
        } else {
            try emitEncodeExpr(w, op.request, "request");
        }
        try w.writeAll(", route");
        if (op.stream) |stream| try w.print(", {d}", .{stream.in_flight});
        try w.writeAll(");\n}\n");
    }
    return out.toOwnedSlice();
}

test "service projection derives host dispatch and registry from one contract" {
    const bytes_type: service.TypeRef = .{ .kind = .bytes };
    const optional_bytes: service.TypeRef = .{ .kind = .optional, .inner = &bytes_type };
    const slice_optional_bytes: service.TypeRef = .{ .kind = .slice, .elem = &optional_bytes };
    const operations = [_]service.Operation{
        .{
            .name = "feeds.parse",
            .client = "feedsParse",
            .module = "src/services/feeds.ts",
            .@"export" = "parse",
            .request = .{ .kind = .bytes },
            .result = .{ .kind = .bytes },
            .deadline_ms = null,
            .cancellable = false,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .{
            .name = "feeds.$refresh",
            .client = "feeds$refresh",
            .module = "src/services/feeds.ts",
            .@"export" = "$refresh",
            .request = .{ .kind = .none },
            .result = .{ .kind = .bytes },
            .deadline_ms = null,
            .cancellable = true,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .{
            .name = "feeds.nested",
            .client = "feedsNested",
            .module = "src/services/feeds.ts",
            .@"export" = "nested",
            .request = slice_optional_bytes,
            .result = slice_optional_bytes,
            .deadline_ms = null,
            .cancellable = false,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    };
    const contract: service.Contract = .{
        .format = 3,
        .protocol_version = 3,
        .compiler_version = "1.2.3",
        .deterministic = false,
        .packages = &.{},
        .types = .{ .records = &.{}, .enums = &.{}, .unions = &.{} },
        .operations = &operations,
    };

    const host = try emitHost(std.testing.allocator, contract);
    defer std.testing.allocator.free(host);
    try std.testing.expect(std.mem.indexOf(u8, host, "const request = payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "serviceOp0(request)") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "serviceOp1(cancellation(cancelPath))") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "import { $refresh as serviceOp1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "PROTOCOL_VERSION = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "CONTRACT_FINGERPRINT = new Uint8Array([") != null);

    const inproc = try emitInprocMain(std.testing.allocator, contract);
    defer std.testing.allocator.free(inproc);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "export function dispatch(operation: number, payload: Uint8Array, cancelPathBytes: Uint8Array, streamPathBytes: Uint8Array): Uint8Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "export function contractFingerprint(): Uint8Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "serviceOp0(request)") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "serviceOp1(cancellation(cancelPath))") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "import { $refresh as serviceOp1 }") != null);
    // The facade returns its status byte in-band; no stdio protocol rides it.
    try std.testing.expect(std.mem.indexOf(u8, inproc, "writeHello") == null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "requestId") == null);

    const profile = try emitInprocProfile(std.testing.allocator);
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"prefix\": \"nsc_svc_\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"localize_runtime\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"instance_per_thread\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"entry\": \"service_inproc_main.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"symbol\": \"nsc_svc_dispatch\"") != null);

    const registry = try emitRegistry(std.testing.allocator, contract);
    defer std.testing.allocator.free(registry);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const inproc_symbol_prefix = \"nsc_svc_\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, ".name = \"feeds.parse\", .index = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "0 => true") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "copyServiceBytes(bytes)") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const compiler_version = \"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const contract_fingerprint = [_]u8{") != null);

    const client = try emitClient(std.testing.allocator, contract);
    defer std.testing.allocator.free(client);
    try std.testing.expect(std.mem.indexOf(u8, client, "request: readonly (Uint8Array | null)[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, client, "ServiceRoute<Msg, readonly (Uint8Array | null)[]>") != null);

    const original_fingerprint = contractFingerprint(contract);
    const reordered_operations = [_]service.Operation{ operations[1], operations[0] };
    const reordered_fingerprint = contractFingerprint(.{
        .format = contract.format,
        .protocol_version = contract.protocol_version,
        .compiler_version = contract.compiler_version,
        .deterministic = contract.deterministic,
        .packages = contract.packages,
        .types = contract.types,
        .operations = &reordered_operations,
    });
    try std.testing.expect(!std.mem.eql(u8, &original_fingerprint, &reordered_fingerprint));
}
