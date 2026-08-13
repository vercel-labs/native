const std = @import("std");
const native_sdk = @import("native_sdk");

const Msg = union(enum) { file: native_sdk.EffectFileResult };
const Fx = native_sdk.Effects(Msg);

fn waitResult(fx: *Fx, io: std.Io) !native_sdk.EffectFileResult {
    while (true) {
        if (fx.takeMsg()) |msg| return msg.file;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const destination = args[1];
    const ready = args[2];
    var fx = Fx.init(init.gpa);
    // Deliberately no deinit: the parent kills this process to model a hard
    // crash after the temporary contains bytes but before atomic replace.
    fx.writeFileStream(.{ .key = 1, .path = destination, .on_result = Fx.fileMsg(.file) });
    if ((try waitResult(&fx, init.io)).outcome != .ok) return error.OpenFailed;
    fx.writeFileChunk(.{ .key = 1, .bytes = "partial replacement that must never become visible", .on_result = Fx.fileMsg(.file) });
    if ((try waitResult(&fx, init.io)).outcome != .ok) return error.ChunkFailed;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready, .data = "ready" });
    while (true) try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(60), .awake);
}
