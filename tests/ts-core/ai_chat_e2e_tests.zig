//! End-to-end proof battery for examples/chatbot — the "can I call an
//! AI API?" answer as a real app: a streaming Vercel AI Gateway chat
//! client authored in TypeScript + Native markup with
//! ZERO hand-written Zig. The build compiles the example's REAL core through the external core compiler
//! (examples/chatbot/src/core.ts + src/api.ts) and this suite drives
//! it through `TsUiApp` with the example's SHIPPING markup (app.native,
//! staged beside this file), so every pin here is the product path:
//!
//!   - the API key and optional initial model override ride the envMsgs
//!     channel, the prompt-group picker lists Luna, Terra, then Sol,
//!     while the teaching state holds (with ZERO fetches) until the API
//!     key is present;
//!   - a scripted two-turn conversation drives the whole loop through
//!     the fake fetch feed: the composer's byte-splice text engine, the
//!     Send press, the EXACT streaming request (the fixed Gateway URL,
//!     runtime-built `authorization: Bearer <key>`, SSE accept header,
//!     and JSON body — system prompt first, history growing turn by
//!     turn), then asserts each SSE delta appears before the terminal;
//!   - the in-flight guard: a second send while one request is out
//!     issues nothing and loses nothing (the draft survives);
//!   - every failure shape lands in the failed state with a reason and
//!     KEEPS the history: a 500 with an error line (the Gateway's own
//!     error.message surfaces), a stream missing [DONE], a bare non-200,
//!     a transport failure — and Retry re-sends the same conversation;
//!   - a recorded conversation REPLAYS BYTE-IDENTICALLY with zero host
//!     calls — no network in the room (the journaled fetch
//!     results feed the replayed requests), and with ZERO env reads:
//!     the launch configuration is journaled (`.env` records) at record
//!     time, so the replay launches with the variables UNSET and again
//!     with them CHANGED and both replay identically — the
//!     announcement's replay-an-AI-conversation trick, pinned.
//!
//! Only this TEST wiring is Zig — the command mapper below exists so the
//! suite can dispatch send/retry/clear through the journaled
//! menu-command path where a scripted session needs it (the app itself
//! dispatches them from markup).

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_ai_chat_core");

const runtime_ns = native_sdk.runtime;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;

const app_markup = @embedFile("app.native");
const CompiledAppView = canvas.CompiledMarkupView(core.Model, core.Msg, app_markup);

const canvas_label = "chat-canvas";

/// The one fetch key's engine slot: the "chat" request is the first (and
/// only) stream the core issues, so it takes stream-table slot 0,
/// deterministically in issue order.
const chat_fetch_key: u64 = runtime_ns.ts_core_spawn_key_base + 0;

const test_endpoint = "https://ai-gateway.vercel.sh/v1/chat/completions";
const sol_model_name = "openai/gpt-5.6-sol";
const default_model_name = "openai/gpt-5.6-luna";
const default_model_label = "GPT-5.6 Luna";
const terra_model_label = "GPT-5.6 Terra";
const sol_model_label = "GPT-5.6 Sol";
const test_model_name = "test-model";
const test_api_key = "test-key";

const app_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const app_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Chatbot",
    .width = 760,
    .height = 640,
    .titlebar = .hidden_inset_tall,
    .views = &app_views,
}};
const app_scene: native_sdk.ShellConfig = .{ .windows = &app_windows };
const test_window_chrome: native_sdk.WindowChrome = .{
    .insets = .{ .top = 52, .left = 78 },
    .buttons = geometry.RectF.init(12, 18, 54, 16),
};

/// TEST-ONLY command mapper: the journaled menu-command path for the
/// void arms (record/replay needs every input in the journal; the app
/// itself dispatches these from markup presses).
fn testCommand(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "chat.send")) return .send;
    if (std.mem.eql(u8, name, "chat.retry")) return .retry;
    if (std.mem.eql(u8, name, "chat.clear")) return .clear;
    // The recorded session's composer input, as journaled commands: the
    // synthesized pointer/text events a click-and-type gesture journals
    // carry wall-clock timestamps, so the byte-identity pin below drives
    // the SAME draft_edit path through the timestamp-free menu channel
    // (the real input path is pinned by the conversation tests above).
    if (std.mem.eql(u8, name, "chat.say.one")) return .{ .draft_edit = .{ .insert_text = "Say hi in two words" } };
    if (std.mem.eql(u8, name, "chat.say.two")) return .{ .draft_edit = .{ .insert_text = "And a follow-up?" } };
    return null;
}

fn appOptions() App.Options {
    return .{
        .name = "chatbot-e2e",
        .scene = app_scene,
        .canvas_label = canvas_label,
        // The comptime-compiled engine over the example's shipping markup
        // — the whole view tier of the app under test.
        .view = CompiledAppView.build,
        .on_command = testCommand,
    };
}

/// The full launch configuration — every variable present.
const configured_env = [_]Adapter.EnvValue{
    .{ .msg = "model_set", .value = test_model_name },
    .{ .msg = "key_set", .value = test_api_key },
};

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    clock: native_sdk.TestClock,

    /// A configured app on the FAKE effects executor: fetch requests
    /// park in fake slots for scripted SSE lines and terminals instead
    /// of reaching a network.
    fn create() !*Harness {
        return createConfigured(null, &configured_env);
    }

    fn createConfigured(recorder: ?*runtime_ns.SessionRecorder, env_values: []const Adapter.EnvValue) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.clock = .{};
        self.clock.setWallMs(60_000);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = geometry.SizeF.init(760, 640),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.null_platform.window_chrome = test_window_chrome;
        // Match the shipping desktop path: conversation scroll regions
        // are backed by native scroll drivers, not the engine fallback.
        self.harness.null_platform.gpu_surface_scroll_drivers = true;
        self.harness.runtime.options.session_recorder = recorder;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{ .env_values = env_values }, appOptions());
        self.app_state.effects.executor = .fake;
        self.app_state.effects.clock = self.clock.clock();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(760, 640),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.app_state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    fn findId(self: *Harness, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findKindText(self.app_state.tree.?.root, kind, text);
    }

    fn findLabel(self: *Harness, label: []const u8) ?canvas.ObjectId {
        return findByLabel(self.app_state.tree.?.root, label);
    }

    fn focusedWidgetId(self: *Harness) canvas.ObjectId {
        for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |view| {
            if (std.mem.eql(u8, view.label, canvas_label)) return view.canvas_widget_focused_id;
        }
        return 0;
    }

    /// Click a rendered widget through the automation verb — the same
    /// headless path `native automate` drives.
    fn click(self: *Harness, id: canvas.ObjectId) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn textInput(self: *Harness, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .text_input,
            .text = text,
        } });
    }

    fn keyDown(self: *Harness, key: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .key_down,
            .key = key,
        } });
    }

    fn keyDownShift(self: *Harness, key: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .key_down,
            .key = key,
            .modifiers = .{ .shift = true },
        } });
    }

    /// Focus the composer, type the message, and press Send — the whole
    /// user gesture through the real input path.
    fn say(self: *Harness, text: []const u8) !void {
        try self.click(self.findLabel("Message").?);
        try self.textInput(text);
        try self.click(self.findLabel("Send message").?);
    }

    /// Deliver one complete response line and rebuild immediately —
    /// this is the observable token-by-token path under test.
    fn line(self: *Harness, bytes: []const u8) !void {
        try self.app_state.effects.feedLine(chat_fetch_key, bytes);
        try self.wake();
    }

    /// Deliver the stream's terminal status (stream terminals have no
    /// body) and rebuild.
    fn finish(self: *Harness, status: u16) !void {
        try self.app_state.effects.feedResponse(chat_fetch_key, status, "");
        try self.wake();
    }

    /// Complete a normal one-delta Gateway response. Tests that assert
    /// incremental rendering feed their own lines instead.
    fn complete(self: *Harness, delta_line: []const u8) !void {
        try self.line(delta_line);
        try self.line("data: [DONE]");
        try self.finish(200);
    }
};

fn findKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindText(child, kind, text)) |id| return id;
    }
    return null;
}

fn findWidgetKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findWidgetKindText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.ObjectId {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget.id;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |id| return id;
    }
    return null;
}

fn findWidgetByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findWidgetByLabel(child, label)) |found| return found;
    }
    return null;
}

// The pinned request bodies: the system prompt first, then the history,
// oldest first — growing turn by turn. Byte-exact, because the encoder
// is deterministic byte math (that is what makes replay work).
const first_request_body =
    "{\"model\":\"test-model\",\"messages\":[" ++
    "{\"role\":\"system\",\"content\":\"You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.\"}," ++
    "{\"role\":\"user\",\"content\":\"Say hi in two words\"}],\"stream\":true}";
const second_request_body =
    "{\"model\":\"test-model\",\"messages\":[" ++
    "{\"role\":\"system\",\"content\":\"You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.\"}," ++
    "{\"role\":\"user\",\"content\":\"Say hi in two words\"}," ++
    "{\"role\":\"assistant\",\"content\":\"Hi there!\"}," ++
    "{\"role\":\"user\",\"content\":\"Now say it in Zig \\\"strings\\\"\"}],\"stream\":true}";
const default_request_body =
    "{\"model\":\"openai/gpt-5.6-luna\",\"messages\":[" ++
    "{\"role\":\"system\",\"content\":\"You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.\"}," ++
    "{\"role\":\"user\",\"content\":\"Use the default\"}],\"stream\":true}";
const sol_request_body =
    "{\"model\":\"openai/gpt-5.6-sol\",\"messages\":[" ++
    "{\"role\":\"system\",\"content\":\"You are a helpful assistant inside a native desktop app. Answer concisely, in plain text.\"}," ++
    "{\"role\":\"user\",\"content\":\"Use Sol\"}],\"stream\":true}";

// ---------------------------------------------------- the teaching state

test "the teaching state only requires the Gateway key and the model has a working default" {
    // No variables at all: the setup panel teaches the required key and
    // names the built-in model plus its optional override.
    {
        const h = try Harness.createConfigured(null, &.{});
        defer h.destroy();
        try std.testing.expect(h.hasText("Connect a model"));
        try std.testing.expect(h.hasText("NATIVE_SDK_CHAT_MODEL"));
        try std.testing.expect(h.hasText("AI_GATEWAY_API_KEY"));
        try std.testing.expect(h.hasText(default_model_name));
        // The composer does not exist in the teaching state, and even a
        // journaled send dispatch issues nothing.
        try std.testing.expect(h.findLabel("Message") == null);
        try h.menu("chat.send");
        try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingFetchCount());
    }

    // Model present, the key EMPTY (the variable exists but holds
    // nothing): still the teaching state, still zero fetches — an
    // unkeyed app never dials the Gateway.
    {
        const partial_env = [_]Adapter.EnvValue{
            .{ .msg = "model_set", .value = test_model_name },
            .{ .msg = "key_set", .value = "" },
        };
        const h = try Harness.createConfigured(null, &partial_env);
        defer h.destroy();
        try std.testing.expect(h.hasText("Connect a model"));
        // The optional override landed in the model; the prompt group is
        // absent until configured, and the key row still teaches.
        try std.testing.expect(h.hasText("missing"));
        try std.testing.expectEqualStrings(test_model_name, Bridge.model().modelName);
        try std.testing.expect(!h.hasText(test_model_name));
        try h.menu("chat.send");
        try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingFetchCount());
        try std.testing.expect(Bridge.model().unconfigured());
    }

    // With only the required key, the teaching state clears and the
    // first request uses the built-in model byte-for-byte.
    {
        const key_only_env = [_]Adapter.EnvValue{
            .{ .msg = "key_set", .value = test_api_key },
        };
        const h = try Harness.createConfigured(null, &key_only_env);
        defer h.destroy();
        try std.testing.expect(!h.hasText("Connect a model"));
        try std.testing.expectEqualStrings(default_model_name, Bridge.model().modelName);
        try std.testing.expect(h.hasText(default_model_label));
        try std.testing.expect(!Bridge.model().unconfigured());
        try h.say("Use the default");
        try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingFetchCount());
        try std.testing.expectEqualStrings(default_request_body, h.app_state.effects.pendingFetchAt(0).?.body);
    }
}

test "the prompt-group model selector changes the model used by the next request" {
    const key_only_env = [_]Adapter.EnvValue{
        .{ .msg = "key_set", .value = test_api_key },
    };
    const h = try Harness.createConfigured(null, &key_only_env);
    defer h.destroy();

    const prompt = findWidgetByLabel(h.app_state.tree.?.root, "Prompt composer").?;
    const selector = findWidgetByLabel(prompt, "Model selector").?;
    try std.testing.expectEqual(canvas.WidgetKind.select, selector.kind);
    try std.testing.expect(!selector.state.disabled);
    try std.testing.expectEqualStrings(default_model_label, selector.text);
    try h.click(selector.id);
    try std.testing.expect(Bridge.model().modelPickerOpen);

    const models = findWidgetByLabel(h.app_state.tree.?.root, "Models").?;
    try std.testing.expectEqual(@as(usize, 3), models.children.len);
    try std.testing.expectEqualStrings(default_model_label, models.children[0].text);
    try std.testing.expectEqualStrings(terra_model_label, models.children[1].text);
    try std.testing.expectEqualStrings(sol_model_label, models.children[2].text);
    const luna = findWidgetKindText(models, .menu_item, default_model_label).?;
    const terra = findWidgetKindText(models, .menu_item, terra_model_label).?;
    const sol = findWidgetKindText(models, .menu_item, sol_model_label).?;
    try std.testing.expect(!sol.state.selected);
    try std.testing.expect(luna.state.selected);
    try std.testing.expect(!terra.state.selected);
    const picker_layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const selector_frame = picker_layout.findById(selector.id).?.frame.normalized();
    const models_frame = picker_layout.findById(models.id).?.frame.normalized();
    try std.testing.expectEqual(@as(f32, 148), selector_frame.width);
    try std.testing.expectEqual(@as(f32, 148), models_frame.width);

    try h.click(sol.id);
    try std.testing.expect(!Bridge.model().modelPickerOpen);
    try std.testing.expectEqualStrings(sol_model_name, Bridge.model().modelName);
    try std.testing.expect(h.findId(.menu_item, sol_model_label) == null);
    try std.testing.expectEqual(h.findLabel("Message").?, h.focusedWidgetId());

    try h.say("Use Sol");
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingFetchCount());
    try std.testing.expectEqualStrings(sol_request_body, h.app_state.effects.pendingFetchAt(0).?.body);
}

test "the runtime markup interpreter builds the emitted model exactly like the compiled engine" {
    // The PRODUCT wiring runs app.native through the runtime interpreter
    // (hot reload); this suite compiles it at comptime. Hold the two
    // engines text-identical over the booted model so the product path
    // can never drift from the tested one.
    const h = try Harness.create();
    defer h.destroy();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = h.app_state.model;
    const AppUi = canvas.Ui(core.Msg);
    var interpreter_view = try canvas.MarkupView(core.Model, core.Msg).init(arena, app_markup);
    var interpreter_ui = AppUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = AppUi.init(arena);
    const compiled = try compiled_ui.finalize(CompiledAppView.build(&compiled_ui, &model));

    var interpreted_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer interpreted_texts.deinit(std.testing.allocator);
    var compiled_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer compiled_texts.deinit(std.testing.allocator);
    try collectTexts(interpreted.root, &interpreted_texts, std.testing.allocator);
    try collectTexts(compiled.root, &compiled_texts, std.testing.allocator);
    try std.testing.expectEqualStrings(interpreted_texts.items, compiled_texts.items);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "What can I help with?") != null);
}

fn collectTexts(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, widget.text);
    try out.append(allocator, '\n');
    for (widget.children) |child| {
        try collectTexts(child, out, allocator);
    }
}

// ------------------------------------------------------ the conversation

test "chat content fills narrow windows and caps centered below the full-width titlebar" {
    const h = try Harness.create();
    defer h.destroy();

    const narrow = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const narrow_header = narrow.findById(h.findLabel("Chat header").?).?.frame.normalized();
    const narrow_content = narrow.findById(h.findLabel("Chat content").?).?.frame.normalized();
    try std.testing.expectEqual(@as(f32, 760), narrow_header.width);
    try std.testing.expectEqual(@as(f32, 760), narrow_content.width);
    try std.testing.expectEqual(@as(f32, 0), narrow_content.x);

    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(1600, 640),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    const wide = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const wide_header = wide.findById(h.findLabel("Chat header").?).?.frame.normalized();
    const wide_content = wide.findById(h.findLabel("Chat content").?).?.frame.normalized();
    try std.testing.expectEqual(@as(f32, 1600), wide_header.width);
    try std.testing.expectEqual(@as(f32, 960), wide_content.width);
    try std.testing.expectEqual(@as(f32, 320), wide_content.x);
}

test "a scripted conversation pins the Gateway request and renders each SSE delta before completion" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // The configured idle state: a text-free custom titlebar and the
    // empty-conversation hint. The New chat button is nested inside the
    // draggable row but remains its own interactive exclusion.
    const header = findWidgetByLabel(h.app_state.tree.?.root, "Chat header").?;
    try std.testing.expect(header.window_drag);
    try std.testing.expectEqual(@as(f64, 78), Bridge.model().chromeLeading);
    try std.testing.expectEqual(@as(f64, 52), Bridge.model().headerHeight);
    const new_chat = findWidgetByLabel(h.app_state.tree.?.root, "New chat").?;
    try std.testing.expect(!new_chat.state.disabled);
    try std.testing.expect(!h.hasText("Chatbot"));
    try std.testing.expect(h.hasText(test_model_name));
    try std.testing.expect(h.hasText("What can I help with?"));
    try std.testing.expect(h.hasText("Ask a question, write code, or explore ideas."));
    const empty_state = findWidgetByLabel(h.app_state.tree.?.root, "Empty conversation").?;
    try std.testing.expectEqual(canvas.WidgetMainAlignment.center, empty_state.layout.main_alignment);
    try std.testing.expectEqual(canvas.WidgetCrossAlignment.center, empty_state.layout.cross_alignment);

    // The prompt is one grouped field: a multiline entry first, then the
    // model selector and icon-only arrow submit action inside its border.
    const prompt = findWidgetByLabel(h.app_state.tree.?.root, "Prompt composer").?;
    try std.testing.expectEqual(canvas.WidgetKind.input_group, prompt.kind);
    try std.testing.expectEqual(@as(usize, 2), prompt.children.len);
    try std.testing.expect(findWidgetByLabel(prompt, "Model selector") != null);
    const message_entry = findWidgetByLabel(prompt, "Message").?;
    try std.testing.expectEqual(canvas.WidgetKind.textarea, message_entry.kind);
    try std.testing.expect(message_entry.submit_on_enter);
    const send_button = findWidgetByLabel(prompt, "Send message").?;
    try std.testing.expectEqual(canvas.WidgetKind.button, send_button.kind);
    try std.testing.expectEqualStrings("arrow-up", send_button.icon);
    try std.testing.expectEqualStrings("", send_button.text);

    // The composer takes focus when the configured app mounts, so text
    // input lands there without a click. Type through that real input
    // path (the core's byte-splice engine) and press plain Enter. The
    // engine channel holds the request whole: POST, the fixed Vercel AI
    // Gateway endpoint, and the runtime-built
    // `authorization: Bearer <key>` header (header VALUES
    // may be runtime bytes; the key never rides the URL), the SSE accept
    // header and JSON content type in name-sort order, and the byte-exact
    // body with `stream: true`.
    const composer_id = h.findLabel("Message").?;
    try std.testing.expectEqual(composer_id, h.focusedWidgetId());
    try h.textInput("Say hi in two words");
    try h.keyDown("enter");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0).?;
    try std.testing.expectEqual(chat_fetch_key, request.key);
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqual(runtime_ns.FetchResponseMode.stream, request.response);
    try std.testing.expectEqual(@as(usize, 65_536), request.max_line_bytes);
    try std.testing.expectEqualStrings(test_endpoint, request.url);
    try std.testing.expectEqual(@as(usize, 3), request.headers.len);
    try std.testing.expectEqualStrings("accept", request.headers[0].name);
    try std.testing.expectEqualStrings("text/event-stream", request.headers[0].value);
    try std.testing.expectEqualStrings("authorization", request.headers[1].name);
    try std.testing.expectEqualStrings("Bearer " ++ test_api_key, request.headers[1].value);
    try std.testing.expectEqualStrings("content-type", request.headers[2].name);
    try std.testing.expectEqualStrings("application/json", request.headers[2].value);
    try std.testing.expectEqualStrings(first_request_body, request.body);

    // The optimistic model: the user turn committed, the draft cleared,
    // the honest sending state on screen.
    try std.testing.expectEqual(@as(usize, 1), Bridge.model().turns.len);
    try std.testing.expect(Bridge.model().turns[0].role == .user);
    try std.testing.expectEqualStrings("Say hi in two words", Bridge.model().turns[0].text);
    try std.testing.expect(Bridge.model().phase == .sending);
    {
        var draft_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer draft_arena.deinit();
        try std.testing.expectEqual(@as(usize, 0), Bridge.model().draftText(draft_arena.allocator()).len);
    }
    try std.testing.expectEqual(composer_id, h.focusedWidgetId());
    const submitted_layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(0), submitted_layout.findById(composer_id).?.widget.text_selection.?);
    try std.testing.expect(h.hasText("…"));
    {
        const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
        const conversation = layout.findById(h.findLabel("Conversation").?).?;
        const history = findWidgetByLabel(h.app_state.tree.?.root, "Conversation history").?;
        const prompt_frame = layout.findById(h.findLabel("Prompt composer").?).?.frame.normalized();
        const user_turn = layout.findById(h.findLabel("You said").?).?;
        try std.testing.expectEqual(@as(f32, 24), history.layout.padding.bottom);
        try std.testing.expectApproxEqAbs(conversation.frame.normalized().maxY(), prompt_frame.y, 0.01);
        try std.testing.expect(conversation.frame.intersects(user_turn.frame));
    }

    // A role-only chunk is a valid no-op. Then each content delta lands
    // in committed pendingReply and is visible BEFORE [DONE] or the HTTP
    // terminal — this is the behavior an AI chat UI needs.
    try h.line("data: {\"id\":\"c-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}");
    try std.testing.expectEqualStrings("", Bridge.model().pendingReply);
    try h.line("data: {\"id\":\"c-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi \"}}]}");
    try std.testing.expect(Bridge.model().phase == .sending);
    try std.testing.expectEqualStrings("Hi ", Bridge.model().pendingReply);
    try std.testing.expect(h.hasText("Hi "));
    {
        const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
        const conversation = layout.findById(h.findLabel("Conversation").?).?;
        const pending_reply = layout.findById(h.findLabel("Reply pending").?).?;
        try std.testing.expect(conversation.frame.intersects(pending_reply.frame));
    }
    try h.line("data:{\"choices\":[{\"delta\":{\"content\":\"there!\"},\"finish_reason\":\"stop\"}]}\r");
    try std.testing.expectEqualStrings("Hi there!", Bridge.model().pendingReply);
    try std.testing.expect(h.hasText("Hi there!"));
    try h.line("data: [DONE]");
    try std.testing.expect(Bridge.model().phase == .sending);
    try std.testing.expect(Bridge.model().streamDone);
    try h.finish(200);
    try std.testing.expect(Bridge.model().phase == .idle);
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().turns.len);
    try std.testing.expect(Bridge.model().turns[1].role == .assistant);
    try std.testing.expectEqualStrings("Hi there!", Bridge.model().turns[1].text);
    try std.testing.expect(h.hasText("Hi there!"));

    // Turn two: the request body carries the WHOLE history — system
    // prompt, both turns, the new user message with its escapes encoded.
    try h.say("Now say it in Zig \"strings\"");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqualStrings(second_request_body, fx.pendingFetchAt(0).?.body);

    // Deltas whose content carries JSON escapes decode into real bytes:
    // the \n and the \" land in the committed turn after [DONE].
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"const hi =\\n    \\\"hi\\\";\"}}]}");
    try std.testing.expectEqual(@as(usize, 4), Bridge.model().turns.len);
    try std.testing.expectEqualStrings("const hi =\n    \"hi\";", Bridge.model().turns[3].text);
}

test "long streamed replies wrap inside the conversation instead of overflowing on x" {
    const h = try Harness.create();
    defer h.destroy();

    const long_reply =
        "Every night, Lina left a cup of tea on her windowsill for the moon, " ++
        "because her grandmother had once said that kindness travels farther " ++
        "than footsteps and always finds its way home before morning.";
    const long_reply_event =
        "data: {\"choices\":[{\"delta\":{\"content\":\"" ++ long_reply ++ "\"}}]}";

    try h.say("tell me a story");
    try h.line(long_reply_event);
    try std.testing.expectEqualStrings(long_reply, Bridge.model().pendingReply);

    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const conversation = layout.findById(h.findLabel("Conversation").?).?.frame.normalized();
    const reply_text = layout.findById(h.findId(.text, long_reply).?).?.frame.normalized();
    try std.testing.expect(reply_text.x >= conversation.x);
    try std.testing.expect(reply_text.maxX() <= conversation.maxX());
    try std.testing.expect(reply_text.width < conversation.width);
    try std.testing.expect(reply_text.height > 20);

    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\" done\"}}]}");
}

test "a streamed reply paints its visible tail beyond the paragraph page cap" {
    const h = try Harness.create();
    defer h.destroy();

    const long_reply =
        ("The lantern kept watch through the night.\n" ** 150) ++
        "TAIL_SENTINEL";
    const long_reply_event =
        "data: {\"choices\":[{\"delta\":{\"content\":\"" ++
        ("The lantern kept watch through the night.\\n" ** 150) ++
        "TAIL_SENTINEL\"}}]}";

    try h.say("tell me a long story");
    try h.line(long_reply_event);
    try std.testing.expectEqualStrings(long_reply, Bridge.model().pendingReply);

    // The chat's controlled scroll follows each streamed delta to the
    // bottom. The visible display list must therefore contain the final
    // response page, not just reserve its height beneath the first 128
    // painted visual lines.
    const layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, layout, .{});
    var saw_tail = false;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.indexOf(u8, command.draw_text.text, "TAIL_SENTINEL") != null) {
            saw_tail = true;
        }
    }
    try std.testing.expect(saw_tail);

    try h.line("data: [DONE]");
    try h.finish(200);

    const finished_layout = try h.harness.runtime.canvasWidgetLayout(1, canvas_label);
    const finished_reply = finished_layout.findById(h.findLabel("The model said").?).?.frame.normalized();
    const tail_padding = finished_layout.findById(h.findLabel("Conversation tail padding").?).?.frame.normalized();
    const prompt = finished_layout.findById(h.findLabel("Prompt composer").?).?.frame.normalized();
    try std.testing.expectEqual(@as(f32, 24), tail_padding.height);
    try std.testing.expect(finished_reply.maxY() <= tail_padding.y);
    try std.testing.expectApproxEqAbs(prompt.y, tail_padding.maxY(), 0.01);
}

test "long visible history sends a recent suffix within the fetch body bound" {
    const h = try Harness.create();
    defer h.destroy();

    // Each wire pair decodes to one quote. Two individually valid SSE
    // lines build a 40 KiB visible assistant turn which needs more than
    // 80 KiB when JSON escaping puts it into the next request.
    const escaped_quotes = "\\\"" ** (20 * 1024);
    const quote_event =
        "data: {\"choices\":[{\"delta\":{\"content\":\"" ++
        escaped_quotes ++
        "\"}}]}";

    try h.say("quote something");
    try h.line(quote_event);
    try h.line(quote_event);
    try h.line("data: [DONE]");
    try h.finish(200);
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().turns.len);
    try std.testing.expectEqual(@as(usize, 40 * 1024), Bridge.model().turns[1].text.len);

    // Full history remains committed and visible, while only the newest
    // user-led suffix rides the bounded provider request.
    try h.say("follow up");
    try std.testing.expectEqual(@as(usize, 3), Bridge.model().turns.len);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingFetchCount());
    const request = h.app_state.effects.pendingFetchAt(0).?;
    try std.testing.expect(request.body.len <= 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "follow up") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "quote something") == null);

    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"still here\"}}]}");
}

test "the in-flight guard: a second send issues nothing and loses nothing" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    try h.say("first question");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 1), Bridge.model().turns.len);

    // Model choice stays live while this request streams. The already
    // issued request keeps its captured model; the new choice is state
    // for the next prompt only.
    const selector = findWidgetByLabel(h.app_state.tree.?.root, "Model selector").?;
    try std.testing.expect(!selector.state.disabled);
    try h.click(selector.id);
    const models = findWidgetByLabel(h.app_state.tree.?.root, "Models").?;
    const sol = findWidgetKindText(models, .menu_item, sol_model_label).?;
    try h.click(sol.id);
    try std.testing.expectEqualStrings(sol_model_name, Bridge.model().modelName);
    const in_flight = fx.pendingFetchAt(0).?;
    try std.testing.expect(std.mem.indexOf(u8, in_flight.body, "\"model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, in_flight.body, sol_model_name) == null);

    // Type a follow-up while the request is out: the Send action has
    // become an enabled Stop action, while the update guard still makes
    // even a journaled send a no-op — no second fetch, no phantom turn,
    // and the draft SURVIVES (a blocked send loses nothing).
    try h.click(h.findLabel("Message").?);
    try h.textInput("eager follow-up");
    try std.testing.expect(findWidgetByLabel(h.app_state.tree.?.root, "Send message") == null);
    const stop_button = findWidgetByLabel(h.app_state.tree.?.root, "Stop generating").?;
    try std.testing.expect(!stop_button.state.disabled);
    try std.testing.expectEqualStrings("x", stop_button.icon);
    try h.menu("chat.send");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 1), Bridge.model().turns.len);
    {
        var draft_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer draft_arena.deinit();
        try std.testing.expectEqualStrings("eager follow-up", Bridge.model().draftText(draft_arena.allocator()));
    }

    // The reply lands and the guard lifts: the surviving draft sends
    // through the journaled command path.
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}");
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().turns.len);
    try h.menu("chat.send");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expect(std.mem.indexOf(u8, fx.pendingFetchAt(0).?.body, "\"model\":\"openai/gpt-5.6-sol\"") != null);
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}");
    try std.testing.expectEqual(@as(usize, 4), Bridge.model().turns.len);
    try h.click(h.findLabel("Message").?);
    try h.textInput("   ");
    try h.click(h.findLabel("Send message").?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 4), Bridge.model().turns.len);

    // Shift+Enter inserts a real LF in the textarea. General whitespace
    // trimming must still reject the draft instead of issuing a blank turn.
    try h.click(h.findLabel("Message").?);
    try h.keyDownShift("enter");
    {
        var draft_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer draft_arena.deinit();
        try std.testing.expectEqualStrings("   \n", Bridge.model().draftText(draft_arena.allocator()));
    }
    try h.click(h.findLabel("Send message").?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 4), Bridge.model().turns.len);

    // New chat remains available during a live reply: it cancels the
    // keyed stream and resets both history and the composer immediately.
    try h.say("cancel this reply");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try h.click(h.findLabel("New chat").?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 0), Bridge.model().turns.len);
    try std.testing.expect(Bridge.model().phase == .idle);
    {
        var draft_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer draft_arena.deinit();
        try std.testing.expectEqualStrings("", Bridge.model().draftText(draft_arena.allocator()));
    }
}

test "Stop cancels the live stream immediately and keeps its partial response" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    try h.say("write a long answer");
    try h.line("data: {\"choices\":[{\"delta\":{\"content\":\"A partial answer\"}}]}");
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqualStrings("A partial answer", Bridge.model().pendingReply);

    const stop_button = findWidgetByLabel(h.app_state.tree.?.root, "Stop generating").?;
    try h.click(stop_button.id);

    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expect(Bridge.model().phase == .idle);
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().turns.len);
    try std.testing.expect(Bridge.model().turns[0].role == .user);
    try std.testing.expect(Bridge.model().turns[1].role == .assistant);
    try std.testing.expectEqualStrings("A partial answer", Bridge.model().turns[1].text);
    try std.testing.expectEqual(@as(usize, 0), Bridge.model().pendingReply.len);
    try std.testing.expect(h.hasText("A partial answer"));
    try std.testing.expect(findWidgetByLabel(h.app_state.tree.?.root, "Stop generating") == null);
    try std.testing.expect(!findWidgetByLabel(h.app_state.tree.?.root, "Send message").?.state.disabled);
    try std.testing.expectEqual(h.findLabel("Message").?, h.focusedWidgetId());
}

// ---------------------------------------------------------- failure paths

test "every failure shape lands in the failed state with a reason and keeps the history" {
    const h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;

    // A 500 with a chat-completions error line: the Gateway's own
    // error.message surfaces, and the unanswered user turn stays.
    try h.say("hello?");
    try h.line("{ \"error\": { \"message\": \"model overloaded\", \"type\": \"server_error\" } }");
    try h.finish(500);
    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("model overloaded", Bridge.model().failReason);
    try std.testing.expectEqual(@as(usize, 1), Bridge.model().turns.len);
    try std.testing.expect(h.hasText("Request failed"));
    try std.testing.expect(h.hasText("model overloaded"));
    try std.testing.expect(h.hasText("hello?"));

    // Retry re-sends the SAME conversation (no new turn, same history)
    // and a success resolves it.
    try h.click(h.findLabel("Retry request").?);
    try std.testing.expect(Bridge.model().phase == .sending);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(usize, 1), Bridge.model().turns.len);
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}");
    try std.testing.expect(Bridge.model().phase == .idle);
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().turns.len);

    // A 200 stream that ends without the protocol's [DONE] marker is
    // failed, never a silently accepted partial conversation.
    try h.say("again");
    try h.line("<html>gateway error</html>");
    try h.finish(200);
    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("the response stream ended before [DONE]", Bridge.model().failReason);
    try std.testing.expectEqual(@as(usize, 3), Bridge.model().turns.len);

    // A non-200 without an error body reads as its status line.
    try h.click(h.findLabel("Retry request").?);
    try h.line("not found");
    try h.finish(404);
    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("Vercel AI Gateway answered HTTP 404", Bridge.model().failReason);

    // A transport failure surfaces the engine's machine-readable reason.
    try h.click(h.findLabel("Retry request").?);
    try fx.feedResponseOutcome(chat_fetch_key, .timed_out, 0, "");
    try h.wake();
    try std.testing.expect(Bridge.model().phase == .failed);
    try std.testing.expectEqualStrings("timed_out", Bridge.model().failReason);
    try std.testing.expect(h.hasText("timed_out"));

    // The history survived the whole gauntlet, and the titlebar's New
    // chat button resets it through the real markup press path.
    try std.testing.expectEqual(@as(usize, 3), Bridge.model().turns.len);
    const new_chat = findWidgetByLabel(h.app_state.tree.?.root, "New chat").?;
    try std.testing.expect(!new_chat.state.disabled);
    try h.click(new_chat.id);
    try std.testing.expectEqual(@as(usize, 0), Bridge.model().turns.len);
    try std.testing.expect(Bridge.model().phase == .idle);
    try std.testing.expect(h.hasText("What can I help with?"));
}

// -------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [512 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) runtime_ns.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A value snapshot of the committed chat model (committed slices live
/// in the core's heap — copy what outlives a session).
const ChatSnapshot = struct {
    turns_len: usize,
    next_id: i64,
    phase: core.Phase,
    last_turn: [256]u8,
    last_turn_len: usize,

    fn take() ChatSnapshot {
        const m = Bridge.model();
        var self: ChatSnapshot = .{
            .turns_len = m.turns.len,
            .next_id = m.nextId,
            .phase = m.phase,
            .last_turn = undefined,
            .last_turn_len = 0,
        };
        if (m.turns.len > 0) {
            const text = m.turns[m.turns.len - 1].text;
            self.last_turn_len = @min(text.len, self.last_turn.len);
            @memcpy(self.last_turn[0..self.last_turn_len], text[0..self.last_turn_len]);
        }
        return self;
    }
};

/// One reference session: journaled user input (draft edits and sends
/// through the timestamp-free menu-command path — see testCommand) plus
/// the scripted fetch feed — a two-turn conversation with one
/// mid-session transport failure and its retry.
fn recordSession(buffer: *JournalBuffer) !ChatSnapshot {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "chatbot-e2e", .window_width = 760, .window_height = 640 });

    const h = try Harness.createConfigured(recorder, &configured_env);
    defer h.destroy();

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try h.menu("chat.say.one");
    try h.menu("chat.send");
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"Hi there!\"}}]}");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // A transport failure and its retry are part of the recorded truth.
    try h.menu("chat.say.two");
    try h.menu("chat.send");
    try h.app_state.effects.feedResponseOutcome(chat_fetch_key, .timed_out, 0, "");
    try h.wake();
    try h.menu("chat.retry");
    try h.complete("data: {\"choices\":[{\"delta\":{\"content\":\"Certainly.\"}}]}");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return ChatSnapshot.take();
}

/// Replay the recorded journal into a fresh app launched with the given
/// env configuration. Its own function so each replay's multi-MB app
/// temporary lives in a transient frame, never stacked up in the test's.
fn replayWithEnv(journal_bytes: []const u8, env_values: []const Adapter.EnvValue) !runtime_ns.ReplayReport {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(760, 640),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    // Replay must expose the same shell geometry and native-scroll
    // capabilities as recording; both affect the rendered checkpoint.
    harness.null_platform.window_chrome = test_window_chrome;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{ .env_values = env_values }, appOptions());
    defer app_state.deinit();
    return try runtime_ns.replaySession(&harness.runtime, app_state.app(), journal_bytes, .{
        .verify = true,
        .require_same_platform = false,
    });
}

test "a recorded conversation replays byte-identically with zero host calls" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordSession(buffer);
    try std.testing.expectEqual(@as(usize, 4), recorded.turns_len);
    try std.testing.expect(recorded.phase == .idle);
    try std.testing.expectEqualStrings("Certainly.", recorded.last_turn[0..recorded.last_turn_len]);

    // Determinism pin: the same driven session records byte-identical
    // journal bytes.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const recorded_again = try recordSession(second);
    try std.testing.expectEqualDeep(recorded, recorded_again);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app with the variables UNSET: the journaled
    // fetch results feed the re-issued (parked) requests in recorded
    // order — no network and no host calls — and the launch
    // configuration feeds from the journal's `.env` records, so replay
    // performs ZERO env reads. A machine with none of the variables set
    // replays the recorded conversation byte-identically.
    {
        const report = try replayWithEnv(buffer.journalBytes(), &.{});
        try std.testing.expect(report.ok());
        try std.testing.expect(report.events_replayed > 0);
        // Each success is a delta line, [DONE], and terminal; add the
        // timeout plus the two env deliveries.
        try std.testing.expectEqual(@as(u64, 9), report.effects_fed);
        try std.testing.expectEqualDeep(recorded, ChatSnapshot.take());
    }

    // Replay again with the variables CHANGED at replay launch: the
    // journaled values still win (the recorded model/key drive
    // the replay, never the replay launch's environment) — the recorded
    // truth is immune to the machine it replays on.
    {
        const changed_env = [_]Adapter.EnvValue{
            .{ .msg = "model_set", .value = "other-model" },
            .{ .msg = "key_set", .value = "other-key" },
        };
        const report = try replayWithEnv(buffer.journalBytes(), &changed_env);
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(@as(u64, 9), report.effects_fed);
        try std.testing.expectEqualDeep(recorded, ChatSnapshot.take());
        // The recorded configuration, not the changed launch's, is the
        // replayed model's.
        try std.testing.expectEqualStrings(test_model_name, Bridge.model().modelName);
    }
}
