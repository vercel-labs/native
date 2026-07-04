//! deck model: the same fixed local music library as `examples/soundboard`
//! (the "same app, different identity" contrast is the point) plus the
//! playback, queue, search, and view state the deck's chrome binds to.
//!
//! Playback is an honest simulation, soundboard's contract: pressing play
//! starts a repeating runtime timer effect (`fx.startTimer`) and each fire
//! advances the elapsed counter; no audio is decoded or played. Everything
//! the views show that is computable — the filtered ledger, timecode
//! labels, the 32-band spectrum — is derived per rebuild into the build
//! arena, never stored.
//!
//! The spectrum is a pure function of (track id, elapsed ms): sum-of-sines
//! shaped by a per-track seed and a mid-weighted envelope. Deterministic by
//! construction — the same model state always yields the same bars, pause
//! freezes them because the progress clock stops, idle shows the noise
//! floor. The suite asserts all three.
//!
//! Fixed capacities (loud by design, documented in the README):
//!   - 8 albums x 6 tracks (comptime library data)
//!   - 16-entry play-next queue (a full queue drops the request, counted
//!     in `queue_dropped`)
//!   - 48-byte search buffer
//!   - 32 spectrum bands

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------------ library

pub const Album = struct {
    /// 1-based id.
    id: u8,
    title: []const u8,
    artist: []const u8,
    year: u16,
};

pub const Track = struct {
    /// 1-based id, unique across the library.
    id: u8,
    album: u8,
    /// 1-based position within the album.
    number: u8,
    title: []const u8,
    duration_ms: u32,
};

fn minutes(m: u32, s: u32) u32 {
    return (m * 60 + s) * 1000;
}

/// The soundboard fiction, verbatim: sharing the library is what makes the
/// two examples the same app in different skins.
pub const albums = [_]Album{
    .{ .id = 1, .title = "Midnight Voltage", .artist = "Neon Cascade", .year = 2021 },
    .{ .id = 2, .title = "Glass Horizon", .artist = "Aurora Fields", .year = 2019 },
    .{ .id = 3, .title = "Ember Lines", .artist = "Cinder & Sage", .year = 2022 },
    .{ .id = 4, .title = "Slow Light", .artist = "Marlowe", .year = 2018 },
    .{ .id = 5, .title = "Northern Loops", .artist = "Polar Echo", .year = 2023 },
    .{ .id = 6, .title = "Paper Planets", .artist = "The Cartographers", .year = 2020 },
    .{ .id = 7, .title = "Velvet Static", .artist = "Ivy Meridian", .year = 2024 },
    .{ .id = 8, .title = "Salt & Signal", .artist = "Harbor Lights", .year = 2017 },
};

pub const tracks_per_album = 6;

pub const tracks = [_]Track{
    .{ .id = 1, .album = 1, .number = 1, .title = "First Light", .duration_ms = minutes(3, 41) },
    .{ .id = 2, .album = 1, .number = 2, .title = "Voltage", .duration_ms = minutes(4, 5) },
    .{ .id = 3, .album = 1, .number = 3, .title = "Neon Rain", .duration_ms = minutes(3, 18) },
    .{ .id = 4, .album = 1, .number = 4, .title = "Afterglow", .duration_ms = minutes(4, 47) },
    .{ .id = 5, .album = 1, .number = 5, .title = "Slow Circuit", .duration_ms = minutes(3, 2) },
    .{ .id = 6, .album = 1, .number = 6, .title = "Midnight Drive", .duration_ms = minutes(5, 12) },
    .{ .id = 7, .album = 2, .number = 1, .title = "Glass", .duration_ms = minutes(3, 26) },
    .{ .id = 8, .album = 2, .number = 2, .title = "Horizon Line", .duration_ms = minutes(4, 33) },
    .{ .id = 9, .album = 2, .number = 3, .title = "Sea of Static", .duration_ms = minutes(3, 54) },
    .{ .id = 10, .album = 2, .number = 4, .title = "Northern Wind", .duration_ms = minutes(2, 58) },
    .{ .id = 11, .album = 2, .number = 5, .title = "Half Light", .duration_ms = minutes(4, 12) },
    .{ .id = 12, .album = 2, .number = 6, .title = "Undertow", .duration_ms = minutes(5, 3) },
    .{ .id = 13, .album = 3, .number = 1, .title = "Kindling", .duration_ms = minutes(2, 47) },
    .{ .id = 14, .album = 3, .number = 2, .title = "Ember Lines", .duration_ms = minutes(3, 36) },
    .{ .id = 15, .album = 3, .number = 3, .title = "Smoke Signal", .duration_ms = minutes(4, 21) },
    .{ .id = 16, .album = 3, .number = 4, .title = "Cedar", .duration_ms = minutes(3, 9) },
    .{ .id = 17, .album = 3, .number = 5, .title = "Warm Static", .duration_ms = minutes(3, 58) },
    .{ .id = 18, .album = 3, .number = 6, .title = "Ash & Air", .duration_ms = minutes(4, 44) },
    .{ .id = 19, .album = 4, .number = 1, .title = "Golden Hour", .duration_ms = minutes(3, 51) },
    .{ .id = 20, .album = 4, .number = 2, .title = "Slow Light", .duration_ms = minutes(4, 26) },
    .{ .id = 21, .album = 4, .number = 3, .title = "Windowsill", .duration_ms = minutes(2, 54) },
    .{ .id = 22, .album = 4, .number = 4, .title = "Amber", .duration_ms = minutes(3, 33) },
    .{ .id = 23, .album = 4, .number = 5, .title = "Long Shadows", .duration_ms = minutes(4, 58) },
    .{ .id = 24, .album = 4, .number = 6, .title = "Dusk", .duration_ms = minutes(3, 15) },
    .{ .id = 25, .album = 5, .number = 1, .title = "Ice Field", .duration_ms = minutes(3, 22) },
    .{ .id = 26, .album = 5, .number = 2, .title = "Northern Loop", .duration_ms = minutes(4, 17) },
    .{ .id = 27, .album = 5, .number = 3, .title = "Aurora", .duration_ms = minutes(5, 8) },
    .{ .id = 28, .album = 5, .number = 4, .title = "Drift", .duration_ms = minutes(2, 49) },
    .{ .id = 29, .album = 5, .number = 5, .title = "Frozen Frame", .duration_ms = minutes(3, 44) },
    .{ .id = 30, .album = 5, .number = 6, .title = "White Out", .duration_ms = minutes(4, 2) },
    .{ .id = 31, .album = 6, .number = 1, .title = "Atlas", .duration_ms = minutes(3, 12) },
    .{ .id = 32, .album = 6, .number = 2, .title = "Paper Planets", .duration_ms = minutes(4, 8) },
    .{ .id = 33, .album = 6, .number = 3, .title = "Contour", .duration_ms = minutes(3, 37) },
    .{ .id = 34, .album = 6, .number = 4, .title = "Meridian", .duration_ms = minutes(2, 51) },
    .{ .id = 35, .album = 6, .number = 5, .title = "Legend", .duration_ms = minutes(4, 39) },
    .{ .id = 36, .album = 6, .number = 6, .title = "True North", .duration_ms = minutes(5, 21) },
    .{ .id = 37, .album = 7, .number = 1, .title = "Velvet", .duration_ms = minutes(3, 29) },
    .{ .id = 38, .album = 7, .number = 2, .title = "Static Bloom", .duration_ms = minutes(4, 14) },
    .{ .id = 39, .album = 7, .number = 3, .title = "Rose Signal", .duration_ms = minutes(3, 3) },
    .{ .id = 40, .album = 7, .number = 4, .title = "Low Frequency", .duration_ms = minutes(4, 51) },
    .{ .id = 41, .album = 7, .number = 5, .title = "Silk Noise", .duration_ms = minutes(3, 46) },
    .{ .id = 42, .album = 7, .number = 6, .title = "Fade In", .duration_ms = minutes(2, 57) },
    .{ .id = 43, .album = 8, .number = 1, .title = "Breakwater", .duration_ms = minutes(3, 34) },
    .{ .id = 44, .album = 8, .number = 2, .title = "Salt & Signal", .duration_ms = minutes(4, 22) },
    .{ .id = 45, .album = 8, .number = 3, .title = "Lighthouse", .duration_ms = minutes(3, 56) },
    .{ .id = 46, .album = 8, .number = 4, .title = "Tide Chart", .duration_ms = minutes(2, 43) },
    .{ .id = 47, .album = 8, .number = 5, .title = "Mooring", .duration_ms = minutes(4, 36) },
    .{ .id = 48, .album = 8, .number = 6, .title = "Open Water", .duration_ms = minutes(5, 17) },
};

pub fn albumById(id: u8) *const Album {
    return &albums[id - 1];
}

pub fn trackById(id: u8) *const Track {
    return &tracks[id - 1];
}

pub fn albumTracks(album_id: u8) []const Track {
    const start = (@as(usize, album_id) - 1) * tracks_per_album;
    return tracks[start .. start + tracks_per_album];
}

// -------------------------------------------------------------- capacities

pub const max_queue = 16;
pub const max_search = 48;
pub const tick_ms: u32 = 500;
pub const spectrum_bands = 32;

/// Effect keys, model-owned identity (effect-key style).
pub const progress_timer_key: u64 = 1;
pub const copy_key: u64 = 2;

// ------------------------------------------------------------------- model

pub const View = enum { library, performance };

pub const Msg = union(enum) {
    /// Album rail selection; 0 selects the whole library.
    select_album: u8,
    show_library,
    show_performance,
    /// Keyboard face switch (`primary+K`): flips LIB <-> PERF.
    toggle_face,
    set_appearance: native_sdk.Appearance,
    search_edit: canvas.TextInputEvent,
    clear_search,
    play_track: u8,
    toggle_play,
    next_track,
    prev_track,
    /// Seek slider changed; the reconciled value arrives through the
    /// `sync` hook (`seek_fraction`) before this message is applied.
    seeked,
    /// Output volume slider changed; same sync-hook contract
    /// (`volume_fraction`). Display-state only — nothing plays.
    volume_changed,
    tick: native_sdk.EffectTimer,
    /// Context menu: queue a track to play after the current one.
    queue_track: u8,
    /// Context menu: copy the track title to the clipboard via `pbcopy`
    /// (soundboard's effect, unchanged: the effects channel has no
    /// clipboard call today).
    copy_title: u8,
    copied: native_sdk.EffectExit,
};

pub const Model = struct {
    // Source-of-truth state only; everything else is derived per rebuild.
    view: View = .library,
    /// Album rail selection; 0 = the whole library.
    selected_album: u8 = 0,
    appearance: native_sdk.Appearance = .{},
    now: ?u8 = null, // loaded track id
    playing: bool = false,
    elapsed_ms: u32 = 0,
    queue: [max_queue]u8 = @splat(0),
    queue_len: usize = 0,
    queue_dropped: u32 = 0,
    search_buffer: canvas.TextBuffer(max_search) = .{},
    /// Seek slider value, mirrored from the runtime through `sync`.
    seek_fraction: f32 = 0,
    /// Output level, mirrored from the runtime through `sync`.
    volume_fraction: f32 = 0.8,
    /// Copy-to-clipboard bookkeeping: how many pbcopy spawns finished ok.
    copies_done: u32 = 0,
    copy_failed: bool = false,

    // ------------------------------------------------------------- queries

    pub fn search(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn searching(model: *const Model) bool {
        return model.search().len > 0;
    }

    pub fn libraryShowing(model: *const Model) bool {
        return model.view == .library;
    }

    pub fn performanceShowing(model: *const Model) bool {
        return model.view == .performance;
    }

    pub fn nowTrack(model: *const Model) ?*const Track {
        const id = model.now orelse return null;
        return trackById(id);
    }

    pub fn idle(model: *const Model) bool {
        return model.now == null;
    }

    pub fn hasQueue(model: *const Model) bool {
        return model.queue_len > 0;
    }

    pub fn queueLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "QUEUE {d}", .{model.queue_len}) catch "";
    }

    /// Status-strip counter: visible tracks over the library total.
    pub fn statusLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}/{d} TRK", .{ model.visibleTracks(arena).len, tracks.len }) catch "";
    }

    pub fn nowPlayingTitle(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "NO SIGNAL";
        return track.title;
    }

    pub fn nowPlayingArtist(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "load a track from the ledger";
        return albumById(track.album).artist;
    }

    /// VFD channel readout: "TRK 07 · GLASS HORIZON".
    pub fn channelLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const track = model.nowTrack() orelse return "TRK --";
        const album = albumById(track.album);
        var upper_buffer: [64]u8 = undefined;
        return std.fmt.allocPrint(arena, "TRK {d:0>2} · {s}", .{ track.id, upperTo(&upper_buffer, album.title) }) catch "";
    }

    pub fn progressFraction(model: *const Model) f32 {
        const track = model.nowTrack() orelse return 0;
        if (track.duration_ms == 0) return 0;
        const fraction = @as(f32, @floatFromInt(model.elapsed_ms)) / @as(f32, @floatFromInt(track.duration_ms));
        return std.math.clamp(fraction, 0, 1);
    }

    pub fn elapsedLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.now == null) return "--:--";
        return formatMs(arena, model.elapsed_ms);
    }

    pub fn durationLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const track = model.nowTrack() orelse return "--:--";
        return formatMs(arena, track.duration_ms);
    }

    /// The 32 spectrum band levels in [0, 1] — a pure function of the
    /// loaded track and the progress clock (see the module doc). Derived
    /// into the build arena per rebuild.
    pub fn spectrumLevels(model: *const Model, arena: std.mem.Allocator) []const f32 {
        const out = arena.alloc(f32, spectrum_bands) catch return &.{};
        const track = model.nowTrack() orelse {
            // Idle: the noise floor, a fixed comb so the display reads as
            // powered-on hardware rather than a dead widget.
            for (out, 0..) |*level, band| {
                level.* = if (band % 4 == 0) 0.05 else 0.02;
            }
            return out;
        };
        const seed: f32 = @floatFromInt(@as(u32, track.id) * 7 + 3);
        const phase = @as(f32, @floatFromInt(model.elapsed_ms)) / 1000.0;
        for (out, 0..) |*level, band| {
            const x: f32 = @floatFromInt(band);
            // Mid-weighted envelope: lows tall, highs rolled off.
            const envelope = 0.35 + 0.65 * @exp(-x * x / 420.0);
            const wave =
                0.6 * @abs(@sin(phase * (1.3 + seed * 0.01) + x * 0.55 + seed)) +
                0.4 * @abs(@sin(phase * 2.9 + x * 1.35 + seed * 0.5));
            level.* = std.math.clamp(0.06 + envelope * wave * 0.94, 0, 1);
        }
        return out;
    }

    /// Output meter level: the mean of the current spectrum, scaled by
    /// the volume fader — display state for the VU strip.
    pub fn outputLevel(model: *const Model, arena: std.mem.Allocator) f32 {
        const levels = model.spectrumLevels(arena);
        if (levels.len == 0) return 0;
        var sum: f32 = 0;
        for (levels) |level| sum += level;
        const mean = sum / @as(f32, @floatFromInt(levels.len));
        return std.math.clamp(mean * std.math.clamp(model.volume_fraction, 0, 1) * 1.6, 0, 1);
    }

    /// Album cells for the rail (never search-filtered: the rail is the
    /// machine's channel bank; search narrows the ledger).
    pub fn railCells(model: *const Model, arena: std.mem.Allocator) []const RailCell {
        const out = arena.alloc(RailCell, albums.len + 1) catch return &.{};
        out[0] = .{
            .id = 0,
            .number = "00",
            .title = "ALL TRACKS",
            .meta = std.fmt.allocPrint(arena, "{d}", .{tracks.len}) catch "",
            .selected = model.selected_album == 0,
            .live = model.playingAlbum() != 0,
        };
        for (&albums, 1..) |*album, slot| {
            out[slot] = .{
                .id = album.id,
                .number = std.fmt.allocPrint(arena, "{d:0>2}", .{album.id}) catch "",
                .title = album.title,
                .meta = std.fmt.allocPrint(arena, "{d}", .{album.year}) catch "",
                .selected = model.selected_album == album.id,
                .live = model.playingAlbum() == album.id,
            };
        }
        return out;
    }

    /// Ledger rows: the selected album's tracks (or the whole library),
    /// narrowed by the search query, derived into the build arena.
    pub fn visibleTracks(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const source = if (model.selected_album == 0) tracks[0..] else albumTracks(model.selected_album);
        const out = arena.alloc(TrackRow, source.len) catch return &.{};
        var count: usize = 0;
        for (source) |*track| {
            if (!model.trackMatches(track)) continue;
            out[count] = model.trackRow(arena, track);
            count += 1;
        }
        return out[0..count];
    }

    /// Up-next rows for the PERF face, in queue order.
    pub fn queueRows(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const out = arena.alloc(TrackRow, model.queue_len) catch return &.{};
        for (model.queue[0..model.queue_len], 0..) |id, slot| {
            out[slot] = model.trackRow(arena, trackById(id));
        }
        return out;
    }

    pub fn playingAlbum(model: *const Model) u8 {
        const track = model.nowTrack() orelse return 0;
        return if (model.playing) track.album else 0;
    }

    fn trackMatches(model: *const Model, track: *const Track) bool {
        const query = model.search();
        if (query.len == 0) return true;
        const album = albumById(track.album);
        return containsIgnoreCase(track.title, query) or
            containsIgnoreCase(album.artist, query) or
            containsIgnoreCase(album.title, query);
    }

    fn trackRow(model: *const Model, arena: std.mem.Allocator, track: *const Track) TrackRow {
        const album = albumById(track.album);
        return .{
            .id = track.id,
            .number = std.fmt.allocPrint(arena, "{d:0>2}", .{track.id}) catch "",
            .title = track.title,
            .artist = album.artist,
            .duration = formatMs(arena, track.duration_ms),
            .now = model.now == track.id,
            .playing = model.now == track.id and model.playing,
            .queued = model.isQueued(track.id),
        };
    }

    fn isQueued(model: *const Model, track_id: u8) bool {
        for (model.queue[0..model.queue_len]) |queued| {
            if (queued == track_id) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ mutation

    fn pushQueue(model: *Model, track_id: u8) void {
        if (model.isQueued(track_id)) return;
        if (model.queue_len >= max_queue) {
            model.queue_dropped += 1;
            return;
        }
        model.queue[model.queue_len] = track_id;
        model.queue_len += 1;
    }

    fn popQueue(model: *Model) ?u8 {
        if (model.queue_len == 0) return null;
        const next = model.queue[0];
        for (model.queue[1..model.queue_len], 0..) |moved, slot| {
            model.queue[slot] = moved;
        }
        model.queue_len -= 1;
        return next;
    }
};

pub const RailCell = struct {
    id: u8,
    number: []const u8,
    title: []const u8,
    meta: []const u8,
    selected: bool,
    live: bool,
};

pub const TrackRow = struct {
    id: u8,
    number: []const u8,
    title: []const u8,
    artist: []const u8,
    duration: []const u8,
    /// This track is loaded in the deck (playing or paused).
    now: bool,
    playing: bool,
    queued: bool,
};

fn formatMs(arena: std.mem.Allocator, ms: u32) []const u8 {
    const total_seconds = ms / 1000;
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 }) catch "";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

/// ASCII-uppercase into a fixed buffer (library titles are ASCII); the
/// caller's arena copy happens in the formatting call.
fn upperTo(buffer: []u8, source: []const u8) []const u8 {
    const len = @min(buffer.len, source.len);
    for (source[0..len], 0..) |byte, index| {
        buffer[index] = std.ascii.toUpper(byte);
    }
    return buffer[0..len];
}

// ------------------------------------------------------------------ update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .select_album => |id| model.selected_album = id,
        .show_library => model.view = .library,
        .show_performance => model.view = .performance,
        .toggle_face => model.view = if (model.view == .library) .performance else .library,
        .set_appearance => |appearance| model.appearance = appearance,
        .search_edit => |edit| model.search_buffer.apply(edit),
        .clear_search => model.search_buffer.apply(.clear),
        .play_track => |id| {
            if (model.now == id) {
                setPlaying(model, fx, !model.playing);
            } else {
                startTrack(model, fx, id);
            }
        },
        .toggle_play => {
            if (model.now == null) {
                startTrack(model, fx, tracks[0].id);
            } else {
                setPlaying(model, fx, !model.playing);
            }
        },
        .next_track => advance(model, fx),
        .prev_track => previous(model, fx),
        .seeked => {
            if (model.nowTrack()) |track| {
                const duration: f32 = @floatFromInt(track.duration_ms);
                model.elapsed_ms = @intFromFloat(std.math.clamp(model.seek_fraction, 0, 1) * duration);
            }
        },
        .volume_changed => {
            model.volume_fraction = std.math.clamp(model.volume_fraction, 0, 1);
        },
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            const track = model.nowTrack() orelse return;
            if (!model.playing) return;
            model.elapsed_ms += tick_ms;
            if (model.elapsed_ms >= track.duration_ms) advance(model, fx);
        },
        .queue_track => |id| model.pushQueue(id),
        .copy_title => |id| fx.spawn(.{
            .key = copy_key,
            .argv = &.{"/usr/bin/pbcopy"},
            .stdin = trackById(id).title,
            .on_exit = Effects.exitMsg(.copied),
        }),
        .copied => |exit| {
            if (exit.reason == .exited and exit.code == 0) {
                model.copies_done += 1;
                model.copy_failed = false;
            } else {
                model.copy_failed = true;
            }
        },
    }
}

fn startTrack(model: *Model, fx: *Effects, track_id: u8) void {
    model.now = track_id;
    model.elapsed_ms = 0;
    setPlaying(model, fx, true);
}

/// Play/pause both drive the repeating progress timer: starting an active
/// key replaces the timer in place, so resume never double-registers.
fn setPlaying(model: *Model, fx: *Effects, playing: bool) void {
    model.playing = playing;
    if (playing) {
        fx.startTimer(.{
            .key = progress_timer_key,
            .interval_ms = tick_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.tick),
        });
    } else {
        fx.cancelTimer(progress_timer_key);
    }
}

/// The play-next queue wins; otherwise the next track in the same album,
/// wrapping at the end of the record.
fn advance(model: *Model, fx: *Effects) void {
    if (model.popQueue()) |queued| {
        startTrack(model, fx, queued);
        return;
    }
    const track = model.nowTrack() orelse return;
    const album_tracks = albumTracks(track.album);
    const next_index = @as(usize, track.number) % album_tracks.len;
    startTrack(model, fx, album_tracks[next_index].id);
}

/// Restart the current track when it is a few seconds in; otherwise the
/// previous track in the album, wrapping backwards.
fn previous(model: *Model, fx: *Effects) void {
    const track = model.nowTrack() orelse return;
    if (model.elapsed_ms > 3000) {
        model.elapsed_ms = 0;
        return;
    }
    const album_tracks = albumTracks(track.album);
    const prev_index = (@as(usize, track.number) + album_tracks.len - 2) % album_tracks.len;
    startTrack(model, fx, album_tracks[prev_index].id);
}
