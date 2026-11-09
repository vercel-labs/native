const registry = @import("ts_services_registry");

// Fault injection stays at the native ABI boundary. Out-of-range typed-array
// reads are ordinary JavaScript `undefined`, so they cannot stand in for a
// detected runtime trap. Forward every normal call to the real service archive;
// only the designated operation receives a length beyond JavaScript's exact
// integer range. The compiler rejects it before allocating or reading memory
// and delivers the detected ABI violation through its registered panic sink.
pub const inproc_symbol_prefix = "nsc_test_trap_";
pub const contract_fingerprint = registry.contract_fingerprint;
pub const indexOf = registry.indexOf;
pub const operationAt = registry.operationAt;
const ServiceAbi = struct {
    const prefix = registry.inproc_symbol_prefix;
    const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
    const init = @extern(*const fn () callconv(.c) void, .{ .name = prefix ++ "init" });
    const set_panic_sink = @extern(*const fn (PanicSink, ?*anyopaque) callconv(.c) void, .{ .name = prefix ++ "set_panic_sink" });
    const collect = @extern(*const fn () callconv(.c) void, .{ .name = prefix ++ "collect" });
    const fingerprint = @extern(*const fn (*[*]const u8, *usize) callconv(.c) void, .{ .name = prefix ++ "contract_fingerprint" });
    const dispatch = @extern(*const fn (u32, [*]const u8, usize, [*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) callconv(.c) void, .{ .name = prefix ++ "dispatch" });
};
export fn nsc_test_trap_init() callconv(.c) void {
    ServiceAbi.init();
}
export fn nsc_test_trap_set_panic_sink(sink: ServiceAbi.PanicSink, context: ?*anyopaque) callconv(.c) void {
    ServiceAbi.set_panic_sink(sink, context);
}
export fn nsc_test_trap_collect() callconv(.c) void {
    ServiceAbi.collect();
}
export fn nsc_test_trap_contract_fingerprint(pointer: *[*]const u8, length: *usize) callconv(.c) void {
    ServiceAbi.fingerprint(pointer, length);
}
export fn nsc_test_trap_dispatch(operation: u32, payload: [*]const u8, payload_len: usize, cancel: [*]const u8, cancel_len: usize, stream: [*]const u8, stream_len: usize, result: *[*]const u8, result_len: *usize) callconv(.c) void {
    const inject = operation == registry.indexOf("feeds.trap").?;
    ServiceAbi.dispatch(operation, payload, if (inject) 9007199254740992 else payload_len, cancel, cancel_len, stream, stream_len, result, result_len);
}
