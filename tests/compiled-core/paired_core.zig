//! The lockstep pair of a transpiled core and a compiled-core mirror:
//! one module surface, two lanes under it. `PairedCore(ts_lane,
//! shim_lane)` exposes the transpiled-core ABI (`Model`/`Msg`/
//! `initialModel`/`update`/`commitModelRoot`/`subscriptions`/the
//! host-event channels/`rt`), forwards every call to BOTH lanes — the
//! transpiled module and the corewire mirror dispatching into a linked
//! compiled-core archive — and panics on the first observable-byte
//! divergence:
//!
//!   - command bytes per dispatch (and the boot command),
//!   - the committed-model snapshot: the archive's raw snapshot bytes
//!     against the canonical encoding of the transpiled lane's
//!     committed model,
//!   - subscription bytes per reconcile,
//!   - channel results (produced/gated agreement, then canonical
//!     message bytes),
//!   - every exported model helper's result bytes per commit.
//!
//! The transpiled lane's values are what the caller sees, so a fixture
//! app's whole e2e battery runs UNCHANGED over the pair: every
//! behavioral assertion passes through the compiled core with byte
//! parity checked at each seam. The staged `paired.zig` root (emitted
//! by gen_paired.zig from the transpiled module's own export surface)
//! re-exports exactly the decls the fixture declares, so the host
//! adapter's export-presence channel detection sees the fixture's true
//! surface.
//!
//! Process contract: like the mirror it wraps, a pair is one live core
//! per process — the archive owns one committed state.

const std = @import("std");
const core_abi = @import("core_abi");
const corewire_rt = @import("corewire_rt");
const convertValue = @import("mirror_value.zig").convertValue;

pub fn PairedCore(comptime ts_lane: type, comptime shim_lane: type) type {
    return struct {
        const abi = core_abi.Bindings("nsc_core_");

        /// Every dispatch through this module runs BOTH lanes and
        /// byte-compares them at each seam; perf pins that budget a single
        /// core's dispatch cost can read this to scale their expectations.
        pub const paired_lanes = true;

        pub const Model = ts_lane.Model;
        pub const Msg = ts_lane.Msg;

        const ts_update_returns_cmd =
            @typeInfo(@TypeOf(ts_lane.update)).@"fn".return_type.? != *const Model;
        const ts_init_returns_cmd =
            @typeInfo(@TypeOf(ts_lane.initialModel)).@"fn".return_type.? != *const Model;

        // The two lanes must declare one contract: every comptime
        // channel const the transpiled module exports, the mirror must
        // export equal (and vice versa — the mirror's surface is the
        // sidecar's, so a mismatch means the archive was compiled from
        // a different fixture generation).
        comptime {
            for ([_][]const u8{ "appearanceMsg", "chromeMsg" }) |name| {
                if (@hasDecl(ts_lane, name) != @hasDecl(shim_lane, name)) {
                    @compileError("paired core: the two lanes disagree about the " ++ name ++ " channel — rebuild the archive from the current fixture");
                }
                if (@hasDecl(ts_lane, name)) {
                    if (!std.mem.eql(u8, @field(ts_lane, name), @field(shim_lane, name))) {
                        @compileError("paired core: the two lanes name different " ++ name ++ " arms — rebuild the archive from the current fixture");
                    }
                }
            }
            if (@hasDecl(ts_lane, "envMsgs") != @hasDecl(shim_lane, "envMsgs")) {
                @compileError("paired core: the two lanes disagree about the envMsgs channel — rebuild the archive from the current fixture");
            }
            if (@hasDecl(ts_lane, "envMsgs")) {
                if (ts_lane.envMsgs.len != shim_lane.envMsgs.len) {
                    @compileError("paired core: the two lanes declare different envMsgs entries — rebuild the archive from the current fixture");
                }
                for (ts_lane.envMsgs, shim_lane.envMsgs) |ts_entry, shim_entry| {
                    if (!std.mem.eql(u8, ts_entry.env, shim_entry.env) or !std.mem.eql(u8, ts_entry.msg, shim_entry.msg)) {
                        @compileError("paired core: the two lanes declare different envMsgs entries — rebuild the archive from the current fixture");
                    }
                }
            }
        }

        /// The mirror's decoded committed root — a valid model pointer
        /// for the mirror entry points whose signatures carry one (the
        /// archive derives everything from its own committed state).
        var shim_root: ?*const shim_lane.Model = null;

        /// Conversion/encoding scratch, reset with every frame reset.
        var arena_state: ?std.heap.ArenaAllocator = null;

        fn arena() std.mem.Allocator {
            if (arena_state == null) {
                arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            }
            return arena_state.?.allocator();
        }

        fn resetArena() void {
            if (arena_state) |*state| _ = state.reset(.retain_capacity);
        }

        fn shimRoot() *const shim_lane.Model {
            return shim_root orelse @panic("paired core: a lane entry ran before initialModel — the host adapter boots the core first");
        }

        /// The archive's raw committed-model snapshot bytes (result-
        /// arena resident: consumed before the next reset).
        fn rawSnapshot() []const u8 {
            var ptr: [*]const u8 = undefined;
            var len: usize = 0;
            abi.model_snapshot(&ptr, &len);
            return ptr[0..len];
        }

        /// A transpiled-lane value re-expressed in the mirror's
        /// sidecar-classed layout and canonically encoded.
        fn referenceBytes(comptime T: type, value: anytype) []const u8 {
            const converted = convertValue(T, value, arena()) catch @panic("paired core: out of conversion memory");
            return corewire_rt.encodeAlloc(T, converted, arena());
        }

        fn checkBytes(expected: []const u8, actual: []const u8, comptime what: []const u8) void {
            if (std.mem.eql(u8, expected, actual)) return;
            std.debug.print(
                "paired core: {s} diverges between the transpiled lane and the compiled core\n  transpiled ({d} bytes): {x}\n  compiled   ({d} bytes): {x}\n",
                .{ what, expected.len, expected, actual.len, actual },
            );
            @panic("paired core: " ++ what ++ " diverges between the transpiled lane and the compiled core");
        }

        pub const rt = struct {
            pub const Cmd = []const u8;
            pub const Sub = []const u8;
            pub const cmd_none: Cmd = &.{};
            pub const sub_none: Sub = &.{};
            pub fn frameAlloc(comptime T: type, n: usize) []T {
                return ts_lane.rt.frameAlloc(T, n);
            }
            pub fn frameCreate(comptime T: type, value: T) *T {
                return ts_lane.rt.frameCreate(T, value);
            }
            pub fn frameReset() void {
                ts_lane.rt.frameReset();
                shim_lane.rt.frameReset();
                resetArena();
            }
            pub fn resetAll() void {
                ts_lane.rt.resetAll();
                shim_lane.rt.resetAll();
                resetArena();
            }
        };

        pub fn initialModel() @typeInfo(@TypeOf(ts_lane.initialModel)).@"fn".return_type.? {
            const ts_init = ts_lane.initialModel();
            const shim_init = shim_lane.initialModel();
            if (comptime ts_init_returns_cmd) {
                shim_root = shim_init.model;
                checkBytes(ts_init.cmd, shim_init.cmd, "the boot command");
            } else {
                shim_root = shim_init;
            }
            return ts_init;
        }

        pub fn update(model: *const Model, msg: Msg) @typeInfo(@TypeOf(ts_lane.update)).@"fn".return_type.? {
            const shim_msg = convertValue(shim_lane.Msg, msg, arena()) catch @panic("paired core: out of conversion memory");
            const ts_out = ts_lane.update(model, msg);
            const shim_out = shim_lane.update(shimRoot(), shim_msg);
            shim_root = shim_out.model;
            if (comptime ts_update_returns_cmd) {
                checkBytes(ts_out.cmd, shim_out.cmd, "a dispatch's command bytes");
            } else {
                checkBytes(&.{}, shim_out.cmd, "a dispatch's command bytes");
            }
            return ts_out;
        }

        pub fn commitModelRoot(next: *const Model) *const Model {
            const committed = ts_lane.commitModelRoot(next);
            checkBytes(referenceBytes(shim_lane.Model, committed.*), rawSnapshot(), "the committed-model snapshot");
            helperParity(committed);
            return committed;
        }

        /// Every exported model helper, both lanes, compared by the
        /// canonical encoding of the mirror-classed result. The mirror's
        /// Model methods route helper_call into the archive; the
        /// transpiled Model carries the same names as direct methods.
        /// Each lane's call shape follows ITS OWN declaration (a
        /// compiled contract may class an allocation-needing helper
        /// arena-taking where the transpiled lane returns frame-arena
        /// slices without one).
        fn helperParity(committed: *const Model) void {
            inline for (@typeInfo(shim_lane.Model).@"struct".decls) |decl| {
                const DeclType = @TypeOf(@field(shim_lane.Model, decl.name));
                if (@typeInfo(DeclType) == .@"fn") {
                    const fn_info = @typeInfo(DeclType).@"fn";
                    const Ret = fn_info.return_type.?;
                    if (fn_info.params.len >= 1 and fn_info.params[0].type == *const shim_lane.Model and
                        (fn_info.params.len == 1 or (fn_info.params.len == 2 and fn_info.params[1].type == std.mem.Allocator)))
                    {
                        const shim_result = if (fn_info.params.len == 2)
                            @field(shim_lane.Model, decl.name)(shimRoot(), arena())
                        else
                            @field(shim_lane.Model, decl.name)(shimRoot());
                        const ts_fn_info = @typeInfo(@TypeOf(@field(Model, decl.name))).@"fn";
                        const ts_result = if (ts_fn_info.params.len == 2)
                            @field(Model, decl.name)(committed, arena())
                        else
                            @field(Model, decl.name)(committed);
                        checkBytes(
                            referenceBytes(Ret, ts_result),
                            corewire_rt.encodeAlloc(Ret, shim_result, arena()),
                            "the model helper " ++ decl.name,
                        );
                    }
                }
            }
        }

        pub fn subscriptions(model: *const Model) []const u8 {
            const ts_subs = ts_lane.subscriptions(model);
            const shim_subs = shim_lane.subscriptions(shimRoot());
            checkBytes(ts_subs, shim_subs, "the subscription bytes");
            return ts_subs;
        }

        /// Both lanes must gate or produce together, and a produced
        /// message must carry one value (compared as canonical bytes in
        /// the mirror's layout).
        fn checkChannel(ts_msg: ?Msg, shim_msg: ?shim_lane.Msg, comptime what: []const u8) void {
            if ((ts_msg == null) != (shim_msg == null)) {
                @panic("paired core: " ++ what ++ " gates in one lane and produces in the other — the two lanes disagree");
            }
            if (ts_msg) |produced| {
                checkBytes(
                    referenceBytes(shim_lane.Msg, produced),
                    corewire_rt.encodeAlloc(shim_lane.Msg, shim_msg.?, arena()),
                    what ++ "'s produced message",
                );
            }
        }

        pub fn frameMsg(model: *const Model, frame: FrameEventOf(ts_lane)) ?Msg {
            const shim_frame = convertValue(FrameEventOf(shim_lane), frame, arena()) catch @panic("paired core: out of conversion memory");
            const ts_msg = ts_lane.frameMsg(model, frame);
            const shim_msg = shim_lane.frameMsg(shimRoot(), shim_frame);
            checkChannel(ts_msg, shim_msg, "the frame channel");
            return ts_msg;
        }

        pub fn keyMsg(key: KeyEventOf(ts_lane)) ?Msg {
            const shim_key = convertValue(KeyEventOf(shim_lane), key, arena()) catch @panic("paired core: out of conversion memory");
            const ts_msg = ts_lane.keyMsg(key);
            const shim_msg = shim_lane.keyMsg(shim_key);
            checkChannel(ts_msg, shim_msg, "the key channel");
            return ts_msg;
        }

        pub fn pinchMsg(pinch: PinchEventOf(ts_lane)) ?Msg {
            const shim_pinch = convertValue(PinchEventOf(shim_lane), pinch, arena()) catch @panic("paired core: out of conversion memory");
            const ts_msg = ts_lane.pinchMsg(pinch);
            const shim_msg = shim_lane.pinchMsg(shim_pinch);
            checkChannel(ts_msg, shim_msg, "the pinch channel");
            return ts_msg;
        }

        pub fn commandMsg(name: []const u8) ?Msg {
            const ts_msg = ts_lane.commandMsg(name);
            const shim_msg = shim_lane.commandMsg(name);
            checkChannel(ts_msg, shim_msg, "the command channel");
            return ts_msg;
        }

        fn FrameEventOf(comptime lane: type) type {
            return @typeInfo(@TypeOf(lane.frameMsg)).@"fn".params[1].type.?;
        }

        fn KeyEventOf(comptime lane: type) type {
            return @typeInfo(@TypeOf(lane.keyMsg)).@"fn".params[0].type.?;
        }

        fn PinchEventOf(comptime lane: type) type {
            return @typeInfo(@TypeOf(lane.pinchMsg)).@"fn".params[0].type.?;
        }
    };
}
