//! The generated mobile wiring for a TypeScript app core — staged (never
//! written into the app) by the framework build beside the desktop entry
//! when the tree carries src/core.ts and the target is iOS or Android. The
//! embed static library's `app` module roots here: the file satisfies the
//! embed host's AppDef contract (`Model`, `Msg`, `initModel`,
//! `mobileOptions` — see `src/embed/ui_host.zig`) over the same staged
//! mirror (core.zig), markup (app.native), service registry (services.zig),
//! and carrier constant (service_carrier.zig) the desktop wiring uses.
//!
//! What differs from ts_core_main.zig is only the shell:
//!
//!   scene     the canonical single-surface mobile scene (window 1, one
//!             gpu_surface labeled "mobile-surface") plus the app.zon
//!             shell's declared platform chrome (tabs, primary action) —
//!             the toolkit hosts project those as real system controls.
//!   services  the in-process pool is the ONLY carrier on mobile (no
//!             child processes exist there); the build graph resolves
//!             auto to in_process, and this file refuses a staged child
//!             selection at comptime. The pool's marker/relay files live
//!             in the OS app-data directory the shim installs through
//!             `native_sdk_app_set_data_root` (the `serviceDataRoot`
//!             hook below).
//!   data dir  a core exporting `envMsgs` with `NATIVE_SDK_APP_DATA_DIR`
//!             receives the same shim-installed directory as a journaled
//!             Msg right after the boot command.
//!
//! Model persistence (`persist`), boot images, and URL media caching are
//! not wired on mobile yet; the corresponding core commands degrade the
//! way the adapter documents (snapshots never write, views keep their
//! fallbacks, URL playback re-streams).
//!
//! Editing this file is never core-level work: it carries no app logic and
//! regenerates from the SDK on every build.

const std = @import("std");
const native_sdk = @import("native_sdk");
const manifest = @import("app_manifest_zon");
pub const core = @import("core.zig");
const services = @import("services.zig");
const service_carrier = @import("service_carrier.zig");

const Adapter = native_sdk.TsUiApp(core);

/// Re-exported for the embed host's AppDef contract (and any test that
/// reflects the core's real surface).
pub const Model = core.Model;
pub const Msg = core.Msg;

pub const app_markup = @embedFile("app.native");

comptime {
    // The build graph resolves the carrier before staging this file; a
    // staged child selection on a mobile target is a build-graph defect,
    // not an app author's error.
    if (services.enabled and service_carrier.kind == .child) {
        @compileError("mobile TypeScript services run on the in-process pool; the child carrier cannot be staged here");
    }
}

const use_pool = services.enabled and service_carrier.kind == .in_process;
const PoolTransport = native_sdk.ServicePool(services);

const app_data_dir_env = "NATIVE_SDK_APP_DATA_DIR";

const shell_scene = native_sdk.app_manifest.shellConfigFrom(manifest);

/// The canonical mobile surface plus the app's declared platform chrome.
const mobile_scene: native_sdk.app_manifest.ShellConfig = .{
    .windows = native_sdk.embed.mobile_shell_scene.windows,
    .chrome = shell_scene.chrome,
};

// Adapter-held mobile state (container-level, like the adapter's own
// install stores — one live app per core module is the v1 contract): the
// pool, its executor, and the shim-installed app-data directory.
var pool_io_state: std.Io.Threaded = undefined;
var pool_transport: PoolTransport = undefined;
var data_root_buffer: [512]u8 = undefined;
var data_root_len: usize = 0;
var env_entries = [_]Adapter.EnvValue{.{ .msg = dataDirMsgArm(), .value = "" }};

/// The embed host calls `mobileOptions()` first (UiAppHost.create), so the
/// boot model is committed by the time `initModel` reads it.
pub fn initModel() Model {
    return Adapter.Host.model().*;
}

pub fn mobileOptions() Adapter.Options {
    var options: Adapter.Options = .{
        .name = manifest.name,
        .scene = mobile_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .markup = .{ .source = app_markup },
        // app.zon's theme pack and one-accent override, same as desktop.
        .theme = comptime manifestThemePack(),
        .theme_accent = comptime manifestThemeAccent(),
    };
    if (comptime @hasDecl(core, "commandMsg")) {
        // Projected chrome (tabs, primary action) dispatches through the
        // core's exported command mapper.
        options.on_command = core.commandMsg;
    }
    return Adapter.mobileOptions(coreOptions(), options);
}

fn coreOptions() Adapter.CoreOptions {
    var core_options: Adapter.CoreOptions = .{};
    if (comptime use_pool) {
        // The pool's own executor: mobile has no `std.process.Init` to
        // thread an Io from. Nothing starts before the first real request,
        // so constructing the pool here keeps replay semantics intact.
        pool_io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
        pool_transport = PoolTransport.init(
            std.heap.page_allocator,
            pool_io_state.io(),
            "",
            .{ .max_workers = service_carrier.pool_workers },
        );
        core_options.host_calls = pool_transport.binding();
    }
    if (comptime services.enabled) {
        core_options.service_results = .{
            .index_fn = services.indexOf,
            .streaming_fn = services.isStreaming,
            .decode_fn = services.resultDecoder(core),
        };
    }
    if (comptime coreWantsDataDir()) {
        core_options.env_values = env_entries[0..1];
    }
    return core_options;
}

/// Embed-host hook (`native_sdk_app_set_data_root`, before start): the
/// OS-owned app-data directory. The pool's cooperative-cancellation
/// markers and stream-relay files move here — the one writable directory
/// both mobile sandboxes guarantee — and a core's `envMsgs` request for
/// the data directory resolves to it.
pub fn serviceDataRoot(root: []const u8) void {
    const len = @min(root.len, data_root_buffer.len);
    @memcpy(data_root_buffer[0..len], root[0..len]);
    data_root_len = len;
    if (comptime use_pool) pool_transport.cwd = data_root_buffer[0..len];
    if (comptime coreWantsDataDir()) env_entries[0].value = data_root_buffer[0..len];
}

/// Embed-host hook (destroy): the pool's shutdown already ran through the
/// effects binding; this returns its queues and executor.
pub fn serviceTeardown() void {
    if (comptime use_pool) {
        pool_transport.deinit();
        pool_io_state.deinit();
    }
}

fn coreWantsDataDir() bool {
    comptime {
        if (!@hasDecl(core, "envMsgs")) return false;
        for (core.envMsgs) |entry| {
            if (std.mem.eql(u8, entry.env, app_data_dir_env)) return true;
        }
        return false;
    }
}

fn dataDirMsgArm() []const u8 {
    comptime {
        if (!@hasDecl(core, "envMsgs")) return "";
        for (core.envMsgs) |entry| {
            if (std.mem.eql(u8, entry.env, app_data_dir_env)) return entry.msg;
        }
        return "";
    }
}

/// app.zon's theme pack, resolved at comptime (the desktop runner's
/// `manifestThemePack`, restated here because the mobile module never
/// links the runner).
fn manifestThemePack() native_sdk.canvas.ThemePack {
    if (comptime !@hasField(@TypeOf(manifest), "theme")) return .house;
    const name: []const u8 = manifest.theme;
    return comptime native_sdk.canvas.ThemePack.fromName(name) orelse
        @compileError("unknown app.zon theme \"" ++ name ++ "\" — expected one of: house, geist");
}

/// app.zon's one-accent brand override, resolved at comptime (the desktop
/// runner's `manifestThemeAccent`).
fn manifestThemeAccent() ?native_sdk.canvas.Color {
    if (comptime !@hasField(@TypeOf(manifest), "theme_accent")) return null;
    const value: []const u8 = manifest.theme_accent;
    return comptime parseHexColor(value) orelse
        @compileError("invalid app.zon theme_accent \"" ++ value ++ "\" — expected a #rrggbb hex color");
}

fn parseHexColor(comptime value: []const u8) ?native_sdk.canvas.Color {
    comptime {
        if (value.len != 7 or value[0] != '#') return null;
        var channels: [3]u8 = undefined;
        for (&channels, 0..) |*channel, index| {
            channel.* = std.fmt.parseInt(u8, value[1 + index * 2 .. 3 + index * 2], 16) catch return null;
        }
        return native_sdk.canvas.Color.rgb8(channels[0], channels[1], channels[2]);
    }
}
