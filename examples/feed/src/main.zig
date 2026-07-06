//! feed: the infinite-scroll timeline, proving the windowed virtual list.
//!
//! A 100k-post synthetic corpus (every post derives deterministically
//! from its index — no network, no storage) scrolls through ONE
//! `ui.virtualList`: the view asks `ui.virtualWindow` which rows are
//! visible, builds ONLY those (a handful of rows plus overscan, never
//! the dataset), and the runtime owns the scroll — engine wheel and
//! kinetic physics everywhere, the native scroll driver on macOS, with
//! the scrollbar spanning the full virtual extent. Approaching the end
//! dispatches `on_reach_end` (once per approach, hysteresis built in)
//! and `update` appends the next batch, so the timeline grows to the
//! whole corpus as you ride it.
//!
//! Per-post interaction state (likes, boosts, the selected row) lives in
//! the MODEL keyed by post index — rows scroll away, state does not.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "feed-canvas";
pub const window_width: f32 = 520;
pub const window_height: f32 = 760;
/// Content min-size floor the window enforces: the feed column is
/// designed at exactly the window width (fixed-extent rows, a one-line
/// status strip budgeted for long content), so the width floor is the
/// designed width itself; only the height gives — proven by the layout
/// audit sweep in tests.zig, which sweeps from exactly this floor.
pub const window_min_width: f32 = window_width;
pub const window_min_height: f32 = 480;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Feed timeline canvas", .accessibility_label = "Feed", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Feed",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ----------------------------------------------------------------- corpus

/// The whole demo corpus: posts exist as arithmetic, never as storage.
pub const max_posts: usize = 100_000;
/// Posts visible in the model at boot.
pub const initial_batch: usize = 500;
/// Posts each reach-end fetch appends.
pub const fetch_batch: usize = 500;
/// The fixed row extent — the windowed virtual list's v1 contract:
/// uniform rows, so 100k of them are pure arithmetic.
pub const post_row_extent: f32 = 84;
/// Rows built beyond the visible range on each side.
pub const post_overscan: usize = 4;

const author_names = [_][]const u8{
    "Ada Byron",     "Alan Kay",       "Annie Easley",   "Barbara Liskov",
    "Dennis Wilson", "Edith Clarke",   "Grace Murray",   "Hedy Keller",
    "Ivan Marsh",    "Katherine Ross", "Lin Chen",       "Mary Allen",
    "Niklaus Wirth", "Radia Perl",     "Sofia Kovaleva", "Vera Cortez",
};
const author_handles = [_][]const u8{
    "@ada",    "@kay",    "@easley", "@liskov",
    "@dwilson", "@edith",  "@gmurray", "@hedy",
    "@ivanm",  "@kross",  "@linchen", "@mallen",
    "@wirth",  "@radia",  "@sofia",   "@vera",
};
const author_initials = [_][]const u8{
    "AB", "AK", "AE", "BL",
    "DW", "EC", "GM", "HK",
    "IM", "KR", "LC", "MA",
    "NW", "RP", "SK", "VC",
};

const openers = [_][]const u8{
    "Shipping it:",
    "Today I learned that",
    "Hot take:",
    "Field note —",
    "Small win:",
    "Debugging diary:",
    "Reading group takeaway:",
    "Draft thought:",
};
const subjects = [_][]const u8{
    "the retained tree keeps row state by identity",
    "fixed budgets make failure modes honest",
    "a flat list reads faster than a wall of cards",
    "the scrollbar should always tell the truth",
    "uniform row heights turn layout into arithmetic",
    "the model owns the data, the runtime owns the viewport",
    "overscan is the difference between smooth and shimmer",
    "one keyed node per visible row is all a feed needs",
    "deterministic fixtures beat recorded network traffic",
    "an approach-end signal wants hysteresis, not a timer",
    "typed messages make dispatch a compiler problem",
    "windowed builds keep the arena small and warm",
};
const closers = [_][]const u8{
    "More tomorrow.",
    "Notes in the repo.",
    "Convince me otherwise.",
    "It held up under 100k rows.",
    "The gate agrees.",
    "Still chewing on it.",
    "Benchmarks pending.",
    "Filed under obvious-in-hindsight.",
};

/// Everything a post row shows, derived from the post index alone.
pub const Post = struct {
    author: []const u8,
    handle: []const u8,
    initials: []const u8,
    opener: []const u8,
    subject: []const u8,
    closer: []const u8,
    minutes_ago: u32,
    likes: u32,
    boosts: u32,
    replies: u32,
};

/// Deterministic post derivation: the same index always yields the same
/// post, on every build and every platform — the corpus is a function,
/// not a table.
pub fn postAt(index: usize) Post {
    const seed = std.hash.Wyhash.hash(0xfeed_0001, std.mem.asBytes(&@as(u64, index)));
    return .{
        .author = author_names[seed % author_names.len],
        .handle = author_handles[seed % author_handles.len],
        .initials = author_initials[seed % author_initials.len],
        .opener = openers[(seed >> 8) % openers.len],
        .subject = subjects[(seed >> 16) % subjects.len],
        .closer = closers[(seed >> 24) % closers.len],
        .minutes_ago = @intCast(index % (60 * 24)),
        .likes = @intCast((seed >> 32) % 900),
        .boosts = @intCast((seed >> 40) % 120),
        .replies = @intCast((seed >> 48) % 40),
    };
}

pub fn postTimeLabel(arena: std.mem.Allocator, minutes_ago: u32) []const u8 {
    if (minutes_ago < 60) return std.fmt.allocPrint(arena, "{d}m", .{minutes_ago}) catch "now";
    return std.fmt.allocPrint(arena, "{d}h", .{minutes_ago / 60}) catch "today";
}

// ------------------------------------------------------------------ model

const LikedSet = std.StaticBitSet(max_posts);

pub const Model = struct {
    /// Posts currently loaded into the timeline; reach-end fetches grow
    /// it toward `max_posts`.
    loaded: usize = initial_batch,
    /// Reach-end dispatches observed (including at the corpus end).
    fetches: u32 = 0,
    /// Per-post interaction state, keyed by post INDEX — the identity
    /// that outlives every window shift.
    liked: LikedSet = LikedSet.initEmpty(),
    boosted: LikedSet = LikedSet.initEmpty(),
    selected: ?usize = null,
    system_scheme: canvas.ColorScheme = .light,

    pub fn likeCount(model: *const Model, index: usize) u32 {
        return postAt(index).likes + @as(u32, @intFromBool(model.liked.isSet(index)));
    }

    pub fn boostCount(model: *const Model, index: usize) u32 {
        return postAt(index).boosts + @as(u32, @intFromBool(model.boosted.isSet(index)));
    }

    pub fn atCorpusEnd(model: *const Model) bool {
        return model.loaded >= max_posts;
    }
};

pub const Msg = union(enum) {
    /// The approach-end signal (`on_reach_end`): append the next batch.
    load_more,
    toggle_like: usize,
    toggle_boost: usize,
    select_post: usize,
    system_scheme: canvas.ColorScheme,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .load_more => {
            model.fetches += 1;
            if (model.loaded < max_posts) {
                model.loaded = @min(max_posts, model.loaded + fetch_batch);
            }
        },
        .toggle_like => |index| if (index < max_posts) model.liked.toggle(index),
        .toggle_boost => |index| if (index < max_posts) model.boosted.toggle(index),
        .select_post => |index| model.selected = if (model.selected != null and model.selected.? == index) null else index,
        .system_scheme => |scheme| model.system_scheme = scheme,
    }
}

// ------------------------------------------------------------------ theme

/// House bar: stock tokens, system scheme, flat rows — no custom palette.
pub fn feedTokens(model: *const Model) canvas.DesignTokens {
    return canvas.DesignTokens.theme(.{ .color_scheme = model.system_scheme });
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .system_scheme = switch (appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    } };
}

// ------------------------------------------------------------------- view

pub const FeedUi = canvas.Ui(Msg);

/// The one options value both `virtualWindow` and `virtualList` read:
/// the MODEL owns the data (`item_count` is what's loaded right now),
/// the runtime owns the viewport math behind the window request.
pub fn timelineOptions(model: *const Model) FeedUi.VirtualListOptions {
    return .{
        .id = "timeline",
        .item_count = model.loaded,
        .item_extent = post_row_extent,
        .overscan = post_overscan,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Timeline" },
        .on_reach_end = .load_more,
    };
}

pub fn view(ui: *FeedUi, model: *const Model) FeedUi.Node {
    const options = timelineOptions(model);
    // The data-window seam: the runtime resolves scroll offset +
    // viewport into the visible index range; the view builds only that.
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(FeedUi.Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (rows, 0..) |*row, offset| row.* = postRow(ui, model, window.start_index + offset);

    return ui.column(.{ .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .height = 52, .padding = 12, .gap = 10, .cross = .center, .style_tokens = .{ .background = .surface }, .semantics = .{ .label = "Feed header" } }, .{
            ui.el(.badge, .{ .variant = .primary, .text = "Feed" }, .{}),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Native SDK"),
            ui.spacer(1),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d} of {d} posts", .{ model.loaded, max_posts })),
        }),
        ui.separator(.{}),
        ui.virtualList(options, window, .{rows}),
        ui.statusBar(.{}, statusLine(ui, model, window)),
    });
}

fn statusLine(ui: *FeedUi, model: *const Model, window: canvas.VirtualListRange) []const u8 {
    const tail: []const u8 = if (model.atCorpusEnd()) "end of corpus" else "scroll for more";
    // Status bars paint one line and never elide, so this label budgets
    // for the window's min width with long-content headroom: the visible
    // range, the loaded total, and the tail — mounted/fetch counters
    // live in the model (and the tests), not the strip.
    return ui.fmt("posts {d}\u{2013}{d} \u{00b7} {d} loaded \u{00b7} {s}", .{
        window.first_visible_index,
        window.last_visible_index,
        model.loaded,
        tail,
    });
}

/// One timeline row: avatar, author line, single-line body, actions.
/// Fixed 84pt extent (the v1 uniform-height contract), a FLAT list row
/// (the list_item composite — no border, no card chrome; hover and the
/// selection are full-width washes).
fn postRow(ui: *FeedUi, model: *const Model, index: usize) FeedUi.Node {
    const post = postAt(index);
    var node = ui.el(.list_item, .{
        .height = post_row_extent,
        .padding = 12,
        .selected = model.selected != null and model.selected.? == index,
        .on_press = Msg{ .select_post = index },
        // The label carries the post identity, not just the author:
        // authors repeat across the timeline, and a screen reader needs
        // adjacent rows to announce differently (the a11y audit's
        // duplicate-sibling-label rule holds this honest).
        .semantics = .{ .role = .listitem, .label = ui.fmt("Post {d} by {s}", .{ index, post.author }), .focusable = true },
    }, .{
        ui.row(.{ .grow = 1, .gap = 10 }, .{
            ui.avatar(.{ .width = 36, .height = 36 }, post.initials),
            ui.column(.{ .grow = 1, .gap = 3 }, .{
                ui.row(.{ .gap = 6, .cross = .center }, .{
                    ui.paragraph(.{}, &.{.{ .text = post.author, .weight = .bold }}),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, post.handle),
                    ui.spacer(1),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, postTimeLabel(ui.arena, post.minutes_ago)),
                }),
                ui.text(.{ .wrap = false }, ui.fmt("{s} {s} {s}", .{ post.opener, post.subject, post.closer })),
                ui.row(.{ .gap = 14, .cross = .center }, .{
                    actionChip(ui, "arrow-up", model.likeCount(index), model.liked.isSet(index), Msg{ .toggle_like = index }, ui.fmt("Like post {d}", .{index})),
                    actionChip(ui, "repeat", model.boostCount(index), model.boosted.isSet(index), Msg{ .toggle_boost = index }, ui.fmt("Boost post {d}", .{index})),
                    ui.row(.{ .gap = 4, .cross = .center }, .{
                        ui.icon(.{ .width = 13, .height = 13, .style_tokens = .{ .foreground = .text_muted } }, "send"),
                        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d}", .{post.replies})),
                    }),
                }),
            }),
        }),
    });
    // Per-item identity: the post index keys the row, so its structural
    // id — and every piece of engine/model state hanging off it — is
    // the same whenever this post window in.
    node.key = .{ .int = @intCast(index) };
    return node;
}

fn actionChip(ui: *FeedUi, comptime icon_name: []const u8, count: u32, active: bool, msg: Msg, label: []const u8) FeedUi.Node {
    var chip = ui.el(.toggle_button, .{
        .size = .sm,
        .variant = if (active) canvas.WidgetVariant.secondary else .ghost,
        .icon = icon_name,
        .selected = active,
        .on_toggle = msg,
        .semantics = .{ .label = label },
    }, .{});
    chip.widget.text = ui.fmt("{d}", .{count});
    return chip;
}

// -------------------------------------------------------------------- app

const FeedApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(FeedApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = FeedApp.init(std.heap.page_allocator, .{}, .{
        .name = "feed",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .tokens_fn = feedTokens,
        .on_appearance = onAppearance,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "feed",
        .window_title = "Native SDK Feed",
        .bundle_id = "dev.native_sdk.feed",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
