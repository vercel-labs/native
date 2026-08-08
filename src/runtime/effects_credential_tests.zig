//! Zig `UiApp` credential-effect coverage. Platform credential storage
//! already exists; these tests cover the typed effect API, fake executor,
//! session-journal boundary, and real null-platform round trips.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const session_journal = @import("session_journal.zig");

const canvas_label = "credential-canvas";
const credential_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const credential_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Credentials",
    .width = 400,
    .height = 300,
    .views = &credential_views,
}};
const credential_scene: app_manifest.ShellConfig = .{ .windows = &credential_windows };

const CredentialModel = struct {
    result_count: usize = 0,
    last_op: ?effects_mod.EffectCredentialOp = null,
    last_outcome: ?effects_mod.EffectCredentialOutcome = null,
    secret: [128]u8 = undefined,
    secret_len: usize = 0,

    fn record(model: *CredentialModel, result: effects_mod.EffectCredentialResult) void {
        model.result_count += 1;
        model.last_op = result.op;
        model.last_outcome = result.outcome;
        model.secret_len = @min(result.secret.len, model.secret.len);
        @memcpy(model.secret[0..model.secret_len], result.secret[0..model.secret_len]);
    }

    fn secretSlice(model: *const CredentialModel) []const u8 {
        return model.secret[0..model.secret_len];
    }
};

const CredentialMsg = union(enum) {
    set,
    get,
    delete,
    stop,
    result: effects_mod.EffectCredentialResult,
};

const CredentialApp = ui_app_model.UiApp(CredentialModel, CredentialMsg);
const CredentialEffects = CredentialApp.Effects;
const credential_key: u64 = 73;

var test_service: []const u8 = "dev.native-sdk.credentials";
var test_account: []const u8 = "default";
var test_secret: []const u8 = "test-secret";

fn credentialUpdate(model: *CredentialModel, msg: CredentialMsg, fx: *CredentialEffects) void {
    switch (msg) {
        .set => fx.setCredential(.{
            .key = credential_key,
            .service = test_service,
            .account = test_account,
            .secret = test_secret,
            .on_result = CredentialEffects.credentialMsg(.result),
        }),
        .get => fx.getCredential(.{
            .key = credential_key,
            .service = test_service,
            .account = test_account,
            .on_result = CredentialEffects.credentialMsg(.result),
        }),
        .delete => fx.deleteCredential(.{
            .key = credential_key,
            .service = test_service,
            .account = test_account,
            .on_result = CredentialEffects.credentialMsg(.result),
        }),
        .stop => fx.cancel(credential_key),
        .result => |result| model.record(result),
    }
}

fn credentialView(ui: *CredentialApp.Ui, model: *const CredentialModel) CredentialApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results", .{model.result_count})),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *CredentialApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(CredentialApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = CredentialApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-credentials",
            .scene = credential_scene,
            .canvas_label = canvas_label,
            .update_fx = credentialUpdate,
            .view = credentialView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

test "fake credential executor copies requests and feeds typed results" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    var service = [_]u8{ 's', 'v', 'c' };
    var account = [_]u8{ 'a', 'c', 'c', 't' };
    var secret = [_]u8{ 't', 'o', 'k', 'e', 'n' };
    test_service = &service;
    test_account = &account;
    test_secret = &secret;
    try h.app_state.dispatch(&h.harness.runtime, 1, .set);
    @memset(&service, 'x');
    @memset(&account, 'y');
    @memset(&secret, 'z');

    try std.testing.expectEqual(@as(usize, 1), fx.pendingCredentialCount());
    const request = fx.pendingCredentialAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.set, request.op);
    try std.testing.expectEqualStrings("svc", request.service);
    try std.testing.expectEqualStrings("acct", request.account);
    try std.testing.expectEqualStrings("token", request.secret);
    try fx.feedCredentialResult(credential_key, .ok, "ignored");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.secret_len);

    test_service = "svc";
    test_account = "acct";
    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try fx.feedCredentialResult(credential_key, .ok, "retrieved-token");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.get, h.app_state.model.last_op.?);
    try std.testing.expectEqualStrings("retrieved-token", h.app_state.model.secretSlice());

    try h.app_state.dispatch(&h.harness.runtime, 1, .delete);
    try fx.feedCredentialResult(credential_key, .not_found, "ignored");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.not_found, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.secret_len);
}

test "credential validation duplicate keys and fake cancellation are explicit" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_service = "";
    test_account = "default";
    test_secret = "secret";
    try h.app_state.dispatch(&h.harness.runtime, 1, .set);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingCredentialCount());

    test_service = "dev.native-sdk.credentials";
    try h.app_state.dispatch(&h.harness.runtime, 1, .set);
    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.get, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingCredentialCount());

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.cancelled, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingCredentialCount());
}

test "real credential effects set get delete and report missing values" {
    var h = try Harness.create();
    defer h.destroy();
    test_service = "com.example.notes.openai";
    test_account = "default";
    test_secret = "sk-local-test";

    try h.app_state.dispatch(&h.harness.runtime, 1, .set);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqualStrings(test_service, h.harness.null_platform.lastCredentialService());
    try std.testing.expectEqualStrings(test_account, h.harness.null_platform.lastCredentialAccount());
    try std.testing.expectEqualStrings(test_secret, h.harness.null_platform.lastCredentialSecret());

    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try h.drainWakes();
    try std.testing.expectEqualStrings(test_secret, h.app_state.model.secretSlice());

    try h.app_state.dispatch(&h.harness.runtime, 1, .delete);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.ok, h.app_state.model.last_outcome.?);
    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.not_found, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.secret_len);
}

test "session recording rejects reads and journals no secret bytes" {
    var h = try Harness.create();
    defer h.destroy();
    test_service = "com.example.notes.openai";
    test_account = "default";
    test_secret = "journal-secret-canary";

    const Capture = struct {
        var records: [4]effects_mod.EffectResultRecord = undefined;
        var count: usize = 0;
        fn note(context: *anyopaque, record: effects_mod.EffectResultRecord) void {
            _ = context;
            records[count] = record;
            count += 1;
        }
    };
    Capture.count = 0;
    var context: u8 = 0;
    h.app_state.effects.bindJournal(.{ .context = &context, .record_fn = Capture.note });

    // Writes remain available, but their secret never enters the effect
    // record. Reads return a metadata-only terminal without consulting
    // the store.
    try h.app_state.dispatch(&h.harness.runtime, 1, .set);
    try h.drainWakes();
    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try h.drainWakes();

    try std.testing.expectEqual(@as(usize, 2), Capture.count);
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.set, Capture.records[0].credential_op);
    try std.testing.expectEqualStrings("", Capture.records[0].payload);
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.get, Capture.records[1].credential_op);
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.recording_unsupported, Capture.records[1].credential_outcome);
    try std.testing.expectEqualStrings("", Capture.records[1].payload);
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.recording_unsupported, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.secret_len);

    var encoded_storage: [512]u8 = undefined;
    for (Capture.records[0..Capture.count]) |record| {
        const encoded = try session_journal.encodeEffect(record, &encoded_storage);
        try std.testing.expect(std.mem.indexOf(u8, encoded, test_secret) == null);
    }
}

test "credential journal codec round trips metadata without secret material" {
    const secret = "codec-secret-canary";
    var buffer: [512]u8 = undefined;
    const encoded = try session_journal.encodeEffect(.{
        .kind = .credential,
        .key = 99,
        .credential_op = .get,
        .credential_outcome = .recording_unsupported,
    }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, encoded, secret) == null);
    const decoded = try session_journal.decodeEffect(encoded);
    try std.testing.expectEqual(effects_mod.EffectResultKind.credential, decoded.kind);
    try std.testing.expectEqual(@as(u64, 99), decoded.key);
    try std.testing.expectEqual(effects_mod.EffectCredentialOp.get, decoded.credential_op);
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.recording_unsupported, decoded.credential_outcome);
    try std.testing.expectEqualStrings("", decoded.payload);
}

test "session replay parks credential reads until the recorded rejection feeds" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.armReplay();
    test_service = "com.example.notes.openai";
    test_account = "default";

    try h.app_state.dispatch(&h.harness.runtime, 1, .get);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingCredentialCount());
    try fx.feedCredentialResult(credential_key, .recording_unsupported, "");
    try h.drainWakes();
    try std.testing.expectEqual(effects_mod.EffectCredentialOutcome.recording_unsupported, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingCredentialCount());
}
