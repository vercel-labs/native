//! The generated wiring for a TypeScript app core — staged (never written
//! into the app) by the framework build when the tree carries src/core.ts:
//! the build transpiles the core beside this file as core.zig, copies the
//! app's src/app.native beside it too, and roots the app module here. The
//! app tree stays three files of truth — core.ts (logic), app.native
//! (view), app.zon (manifest) — and every value below derives from them at
//! comptime:
//!
//!   scene / canvas   app.zon's `.shell` through `shellConfigFrom`; the
//!                    canvas is the scene's first gpu_surface view.
//!   identity         app.zon's `.id`/`.name`/`.display_name`.
//!   security         app.zon's `.permissions` and navigation origins.
//!   theme            app.zon's `.theme` pack; the stock tokens compose
//!                    it with the live system appearance. `.theme_accent`
//!                    layers the manifest's one-accent brand override
//!                    (`canvas.accentOverrides`) over the pack.
//!   audio cache      the platform caches directory (app_dirs `.cache`),
//!                    resolved at launch so a core's URL audio playback
//!                    caches under the conventional content-addressed
//!                    path with no `cachePath` in the core.
//!   update loop      the transpiled core through `TsUiApp(core)` — the
//!                    committed TS model IS the app model.
//!   view             app.native over the model's own field names (the
//!                    emitted Zig keeps the TS spellings), hot-reloaded
//!                    from src/app.native in Debug.
//!   menus/shortcuts  a core exporting `commandMsg(name): Msg | null`
//!                    receives command events (menus, shortcuts, chrome
//!                    tabs, status-item rows) as ordinary Msgs; without
//!                    the export command events stay host-handled only.
//!   status item      a core exporting `statusItem(model)` supplies the
//!                    install-time icon/click hooks and live menu-bar
//!                    presentation + rows; the adapter patches the two
//!                    live parts independently after committed updates.
//!   host events      the adapter wires the core's opt-in channels from
//!                    its exports (export exists -> wired): `frameMsg`
//!                    (presented frames), `keyMsg` (the app-level key
//!                    fallback), `appearanceMsg`/`chromeMsg` (Msg arms
//!                    the host fills structurally), and `dropMsg`
//!                    (native file drops with source, point, and paths).
//!   images           app.zon's `.assets.images` entries (`.{ .id = 1,
//!                    .path = "assets/..." }`) are read once at launch
//!                    (from `Contents/Resources` in a packaged macOS app)
//!                    and registered on the installing frame — the ids
//!                    are the `ImageId`s markup avatar bindings use. A
//!                    missing file or failed decode skips the entry
//!                    (views keep the initials fallback).
//!   environment      a core exporting `envMsgs` receives each named
//!                    variable present at launch as one journaled Msg on
//!                    its bytes arm, right after the boot command — the
//!                    core itself never reads the environment (NS1005),
//!                    and replay carries the recorded values. The runner
//!                    synthesizes `NATIVE_SDK_APP_DATA_DIR` from app_dirs
//!                    when a core requests it, so packaged apps never
//!                    depend on their process working directory for
//!                    durable files.
//!
//! Editing this file is never core-level work: it carries no app logic and
//! regenerates from the SDK on every build.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const manifest = @import("app_manifest_zon");
pub const core = @import("core.zig");
const services = @import("services.zig");
const service_carrier = @import("service_carrier.zig");
const relational_migrations = @import("migrations.zig");
const window_views = @import("window_views.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

/// Re-exported so the model-contract step (and any test) reflects the
/// core's real surface: `native check` verifies app.native against it.
pub const Model = core.Model;
pub const Msg = core.Msg;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;

const shell_scene = native_sdk.app_manifest.shellConfigFrom(manifest);
const canvas_label = native_sdk.app_manifest.firstGpuSurfaceLabel(shell_scene);
pub const app_markup = @embedFile("app.native");

const app_permissions = manifestStringList(manifest, "permissions");
const allowed_origins = manifestAllowedOrigins();
const app_data_dir_env = "NATIVE_SDK_APP_DATA_DIR";

pub fn main(init: std.process.Init) !void {
    var options: Adapter.Options = .{
        .name = manifest.name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
        // app.zon's theme pack; unthemed manifests get the house register.
        // The stock tokens compose the pack with the LIVE system
        // appearance, so TS apps follow the OS light/dark flip with no
        // core code. `theme_accent` is the manifest's one-accent brand
        // override, layered over the pack by the runtime (skipped under
        // high contrast — accessibility beats brand).
        .theme = comptime runner.manifestThemePack(),
        .theme_accent = comptime runner.manifestThemeAccent(),
    };
    if (comptime @hasDecl(core.Model, "windows")) {
        options.window_view = window_views.build;
        options.fragment_watch = .{ .fragments = &window_views.fragments, .io = init.io };
    }
    if (comptime @hasDecl(core, "commandMsg")) {
        // Menus, shortcuts, and chrome tabs dispatch through the core's
        // exported command mapper.
        options.on_command = core.commandMsg;
    }
    // The platform caches directory for this app: when the core's
    // `Cmd.audioPlay` names a URL with no cachePath, the bridge derives
    // the conventional content-addressed path under this directory —
    // resolved once at launch (never inside update), so replay's
    // deterministic-init contract holds. Resolution failure just disables
    // the cache: streams still play, they re-download.
    var cache_dir_buffer: [512]u8 = undefined;
    const audio_cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = manifest.name },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    // The durable per-app data directory, resolved by the platform app-data
    // convention and keyed by the manifest's stable bundle identity. TS cores
    // request it through the ordinary journaled envMsgs boundary under
    // `app_data_dir_env`; it is framework-provided rather than trusted from
    // the ambient environment, so package launch cwd and env differences
    // disappear.
    var data_dir_buffer: [512]u8 = undefined;
    const app_data_dir = native_sdk.app_dirs.resolveOne(
        // Durable state follows the reverse-DNS bundle identity, not the
        // mutable short machine name. Two installed apps may share a name;
        // their manifest ids are the stable isolation boundary.
        .{ .name = manifest.id },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .data,
        &data_dir_buffer,
    ) catch "";
    if (app_data_dir.len > 0) std.Io.Dir.cwd().createDirPath(init.io, app_data_dir) catch {};

    // TypeScript services, on the build-selected carrier (service_carrier.zig).
    // In-process (explicit opt-in): the service archive is linked into this
    // binary and ServicePool runs one instance per worker thread. Child (the
    // auto/default carrier): a lazily-spawned sibling executable with an
    // explicit environment allowlist and the app data directory as its cwd.
    // Either way, replay never calls the binding, so nothing starts under replay.
    const use_pool = comptime (services.enabled and service_carrier.kind == .in_process);
    const use_child = comptime (services.enabled and !use_pool);
    var service_env = std.process.Environ.Map.init(std.heap.page_allocator);
    defer service_env.deinit();
    var service_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ChildTransport = native_sdk.ServiceHost(services);
    const PoolTransport = native_sdk.ServicePool(services);
    var child_transport: if (use_child) ChildTransport else void = undefined;
    var pool_transport: if (use_pool) PoolTransport else void = undefined;
    if (comptime use_child) {
        const env_keys = init.environ_map.keys();
        const env_values = init.environ_map.values();
        for (env_keys, env_values) |key, value| {
            if (native_sdk.serviceEnvironmentVariableAllowed(key)) service_env.put(key, value) catch {};
        }
        const service_path = siblingServiceHostPath(init.io, &service_path_buffer);
        child_transport = ChildTransport.init(
            std.heap.page_allocator,
            init.io,
            service_path,
            app_data_dir,
            &service_env,
        );
    }
    if (comptime use_pool) {
        // The pool's cwd holds the cooperative-cancellation markers and
        // stream-relay files; the service operations themselves run with the
        // app process's own working directory.
        pool_transport = PoolTransport.init(
            std.heap.page_allocator,
            init.io,
            app_data_dir,
            .{ .max_workers = service_carrier.pool_workers },
        );
    }
    defer if (comptime use_child) child_transport.deinit();
    defer if (comptime use_pool) pool_transport.deinit();
    // app.zon-declared images, read once at launch (bounded; a missing or
    // over-bound file skips its entry and the views keep their fallback)
    // and registered by the adapter on the installing frame.
    const manifest_images = comptime manifestImages();
    var boot_images_buffer: [manifest_images.len]Adapter.BootImage = undefined;
    var boot_image_count: usize = 0;
    inline for (manifest_images) |asset| {
        if (runner.app_assets.readFileAlloc(init.io, asset.path, std.heap.page_allocator, .limited(max_boot_image_bytes))) |bytes| {
            boot_images_buffer[boot_image_count] = .{ .id = asset.id, .bytes = bytes };
            boot_image_count += 1;
        } else |_| {}
    }

    // The core's launch-time environment channel (`envMsgs`): read each
    // named variable once, here at the boundary — never inside update —
    // and hand the present values to the adapter, which dispatches them
    // as ordinary journaled Msgs right after the boot command.
    var env_values_buffer: [envMsgsLen()]Adapter.EnvValue = undefined;
    var env_value_count: usize = 0;
    if (comptime @hasDecl(core, "envMsgs")) {
        inline for (core.envMsgs) |entry| {
            if (std.mem.eql(u8, entry.env, app_data_dir_env)) {
                if (app_data_dir.len > 0) {
                    env_values_buffer[env_value_count] = .{ .msg = entry.msg, .value = app_data_dir };
                    env_value_count += 1;
                }
            } else if (init.environ_map.get(entry.env)) |value| {
                env_values_buffer[env_value_count] = .{ .msg = entry.msg, .value = value };
                env_value_count += 1;
            }
        }
    }

    // Model persistence is a build-time capability: without `"persist"`
    // this branch (store, paths, binding) is not analyzed into the app. A
    // replay launch never reads the live snapshot; its journal feeds the
    // recorded restore result before the installing app-start event.
    var persist_store_value: native_sdk.PersistStore = undefined;
    var persist_coordinator_value: native_sdk.persist_store.Coordinator = undefined;
    var persist_coordinator_started = false;
    var persist_host_value: PersistHost = .{};
    var persist_outcome_handle: native_sdk.ChannelHandle = .{};
    var persist_restore_value: native_sdk.persist_store.RestoreResult = .{ .outcome = .none };
    var persist_options: ?Adapter.PersistOptions = null;
    if (comptime manifestDeclaresPersist()) {
        const config = comptime manifestPersistConfig();
        comptime Adapter.validatePersistRoutes(.{
            .ok = config.restore.ok,
            .none = config.restore.none,
            .err = config.restore.err,
        });
        const replay = init.environ_map.get("NATIVE_SDK_SESSION_REPLAY") != null;
        persist_store_value = native_sdk.PersistStore.init(init.io, std.heap.page_allocator, app_data_dir, .{
            .schema_version = config.version,
            .model_fingerprint = core.sidecar_model_fingerprint,
            .snapshot_format = core.sidecar_snapshot_format,
        });
        persist_host_value.outcome_handle = &persist_outcome_handle;
        if (!replay) {
            persist_restore_value = persist_store_value.restore();
            if (persist_restore_value.used_backup) {
                std.log.warn("model persistence: primary snapshot unavailable or corrupt; restored snapshot.nsd.bak", .{});
            }
            try persist_coordinator_value.startWithOutcomeHandler(
                persist_store_value,
                manifestPersistDebounce(config),
                .{ .context = &persist_host_value, .report_fn = PersistHost.reportOutcome },
            );
            persist_coordinator_started = true;
            persist_host_value.coordinator = &persist_coordinator_value;
        }
        persist_options = .{
            // Replay binds the same named service to a no-op host. The
            // command remains on the wire for fingerprint parity but can
            // never mutate the live snapshot.
            .binding = persist_host_value.binding(),
            .routes = .{
                .ok = config.restore.ok,
                .none = config.restore.none,
                .err = config.restore.err,
            },
            .restore = .{
                .outcome = persist_restore_value.outcome,
                .bytes = persist_restore_value.bytes,
                .migration_from_version = persist_restore_value.migration_from_version,
            },
            .outcome_handle = &persist_outcome_handle,
        };
    }
    defer if (comptime manifestDeclaresPersist()) persist_restore_value.deinit(std.heap.page_allocator);
    defer if (persist_coordinator_started) persist_coordinator_value.deinit();

    // The app struct (and any real model) is multi-MB: `create`
    // heap-allocates and constructs in place, so neither rides the stack.
    const app_state = try Adapter.create(std.heap.page_allocator, .{
        .audio_cache_dir = audio_cache_dir,
        // Image loads share the same launch-resolved caches directory:
        // the bridge keys the two caches into their own segments
        // (audio/ and images/), so one directory serves both.
        .image_cache_dir = audio_cache_dir,
        .boot_images = boot_images_buffer[0..boot_image_count],
        .env_values = env_values_buffer[0..env_value_count],
        .host_calls = if (comptime use_pool)
            pool_transport.binding()
        else if (comptime use_child)
            child_transport.binding()
        else
            null,
        .service_results = if (comptime services.enabled) .{
            .index_fn = services.indexOf,
            .streaming_fn = services.isStreaming,
            .decode_fn = services.resultDecoder(core),
        } else null,
        .persist = persist_options,
    }, options);
    defer app_state.destroy();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = manifest.name,
        .window_title = comptime windowTitle(),
        .bundle_id = manifest.id,
        .icon_path = "assets/icon.png",
        .default_frame = comptime defaultFrame(),
        .restore_state = comptime startupRestoreState(),
        .js_window_api = false,
        .security = .{
            .permissions = app_permissions,
            .navigation = .{ .allowed_origins = allowed_origins },
        },
        .relational_migrations = &relational_migrations.migrations,
    }, init);
}

fn siblingServiceHostPath(io: std.Io, buffer: []u8) []const u8 {
    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.process.executablePath(io, &executable_buffer) catch return "";
    const dir = std.fs.path.dirname(executable_buffer[0..len]) orelse return "";
    const suffix = if (@import("builtin").os.tag == .windows) ".exe" else "";
    return std.fmt.bufPrint(buffer, "{s}/{s}_services{s}", .{ dir, manifest.name, suffix }) catch "";
}

const PersistHost = struct {
    coordinator: ?*native_sdk.persist_store.Coordinator = null,
    outcome_handle: ?*native_sdk.ChannelHandle = null,

    fn binding(self: *PersistHost) native_sdk.HostCallBinding {
        return .{ .context = self, .send_fn = send, .request_fn = request };
    }

    fn send(context: *anyopaque, name: []const u8, snapshot: []const u8) void {
        const self: *PersistHost = @ptrCast(@alignCast(context));
        const coordinator = self.coordinator orelse return;
        if (std.mem.eql(u8, name, "core.persist.flush")) {
            coordinator.flush();
            return;
        }
        if (!std.mem.eql(u8, name, "core.persist")) return;
        const outcome = coordinator.enqueue(snapshot);
        if (outcome != .ok) reportOutcome(context, outcome);
    }

    fn reportOutcome(context: *anyopaque, outcome: native_sdk.persist_store.Outcome) void {
        if (outcome == .ok) return;
        const self: *PersistHost = @ptrCast(@alignCast(context));
        const handle = self.outcome_handle orelse {
            std.log.err("model persistence write failed before its result channel installed: {s}", .{@tagName(outcome)});
            return;
        };
        switch (handle.post(@tagName(outcome))) {
            .accepted => {},
            .dropped_full, .dropped_oversized, .closed => {
                std.log.err("model persistence write failed after its result channel closed: {s}", .{@tagName(outcome)});
            },
        }
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = key;
        _ = payload;
    }
};

/// The startup window title: the scene's first window title, else the
/// manifest display name, else the app name.
fn windowTitle() []const u8 {
    if (shell_scene.windows.len > 0) {
        if (shell_scene.windows[0].title) |title| return title;
    }
    if (@hasField(@TypeOf(manifest), "display_name")) return manifest.display_name;
    return manifest.name;
}

fn defaultFrame() native_sdk.geometry.RectF {
    if (shell_scene.windows.len > 0) {
        const window = shell_scene.windows[0];
        return native_sdk.geometry.RectF.init(window.x orelse 0, window.y orelse 0, window.width, window.height);
    }
    return native_sdk.geometry.RectF.init(0, 0, 720, 480);
}

fn startupRestoreState() bool {
    if (shell_scene.windows.len > 0) return shell_scene.windows[0].restore_state;
    return true;
}

/// One app.zon `.assets.images` entry: the encoded file the wiring reads
/// at launch and the `ImageId` markup avatar bindings reference.
const ImageAsset = struct {
    id: u64,
    path: []const u8,
};

/// Encoded-size bound for one boot image: over-bound files skip their
/// entry (the views keep the initials fallback) instead of holding the
/// launch path hostage to a mis-sized asset.
const max_boot_image_bytes: usize = 4 * 1024 * 1024;

fn manifestImages() []const ImageAsset {
    comptime {
        if (!@hasField(@TypeOf(manifest), "assets")) return &.{};
        if (!@hasField(@TypeOf(manifest.assets), "images")) return &.{};
        var out: []const ImageAsset = &.{};
        for (manifest.assets.images) |entry| {
            out = out ++ &[_]ImageAsset{.{ .id = entry.id, .path = entry.path }};
        }
        return out;
    }
}

fn envMsgsLen() usize {
    comptime {
        if (!@hasDecl(core, "envMsgs")) return 0;
        return core.envMsgs.len;
    }
}

fn manifestStringList(comptime m: anytype, comptime field: []const u8) []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(m), field)) return &.{};
        var out: []const []const u8 = &.{};
        for (@field(m, field)) |entry| {
            const name: []const u8 = entry;
            out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

fn manifestDeclaresPersist() bool {
    comptime {
        for (manifestStringList(manifest, "capabilities")) |capability| {
            if (std.mem.eql(u8, capability, "persist")) {
                if (!@hasField(@TypeOf(manifest), "persist")) {
                    @compileError("app.zon declares the persist capability but has no .persist = .{ .version, .restore = .{ .ok, .none, .err } } configuration");
                }
                return true;
            }
        }
        if (@hasField(@TypeOf(manifest), "persist")) {
            @compileError("app.zon configures .persist but does not declare \"persist\" in .capabilities");
        }
        return false;
    }
}

fn ManifestPersistType() type {
    if (@hasField(@TypeOf(manifest), "persist")) return @TypeOf(manifest.persist);
    return void;
}

fn manifestPersistConfig() ManifestPersistType() {
    comptime {
        if (!manifestDeclaresPersist()) unreachable;
        if (manifest.persist.version == 0 or manifest.persist.version > 9_007_199_254_740_991) {
            @compileError("app.zon .persist.version must be a positive exact integer and monotonically increased for every Model shape change");
        }
        if (@hasField(@TypeOf(manifest.persist), "debounce_ms") and manifest.persist.debounce_ms > 60_000) {
            @compileError("app.zon .persist.debounce_ms must be at most 60000");
        }
        validatePersistRoutes(manifest.persist.restore);
        return manifest.persist;
    }
}

fn manifestPersistDebounce(comptime config: anytype) u32 {
    if (@hasField(@TypeOf(config), "debounce_ms")) return config.debounce_ms;
    return 500;
}

fn validatePersistRoutes(comptime routes: anytype) void {
    if (!persistRouteMatches(routes.ok, void)) {
        @compileError("app.zon .persist.restore.ok must name a void Msg arm in src/core.ts");
    }
    if (!persistRouteMatches(routes.none, void)) {
        @compileError("app.zon .persist.restore.none must name a void Msg arm in src/core.ts");
    }
    if (!persistRouteMatches(routes.err, []const u8)) {
        @compileError("app.zon .persist.restore.err must name a one-Uint8Array-field Msg arm in src/core.ts");
    }
}

fn persistRouteMatches(comptime name: []const u8, comptime Payload: type) bool {
    const info = @typeInfo(core.Msg);
    if (info != .@"union") return false;
    inline for (info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type == Payload;
    }
    return false;
}

fn manifestAllowedOrigins() []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(manifest), "security")) return &.{};
        if (!@hasField(@TypeOf(manifest.security), "navigation")) return &.{};
        return manifestStringList(manifest.security.navigation, "allowed_origins");
    }
}
