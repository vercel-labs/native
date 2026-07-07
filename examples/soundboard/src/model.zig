//! soundboard model: a fixed local music library plus the playback,
//! search, navigation, and theming state the views bind to.
//!
//! Playback is an honest simulation: pressing play starts a repeating
//! runtime timer effect (`fx.startTimer`) and each fire advances the
//! elapsed counter; no audio is decoded or played. Everything the views
//! show that is computable — filtered lists, progress fractions, time
//! labels — is derived per rebuild into the build arena, never stored.
//!
//! Fixed capacities (loud by design, documented in the README):
//!   - 8 albums x 6 tracks (comptime library data)
//!   - 8 registered cover images (of the runtime's 16 image slots)
//!   - 16-entry play-next queue (a full queue drops the request, noted
//!     in `queue_dropped` so the UI could surface it)
//!   - 48-byte search buffer

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------------ library

pub const Album = struct {
    /// 1-based id; the registered cover `ImageId` matches it.
    id: u8,
    title: []const u8,
    artist: []const u8,
    year: u16,
    /// Cover fallback initials while the image is unregistered.
    initials: []const u8,
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

pub const albums = [_]Album{
    .{ .id = 1, .title = "Midnight Voltage", .artist = "Neon Cascade", .year = 2021, .initials = "MV" },
    .{ .id = 2, .title = "Glass Horizon", .artist = "Aurora Fields", .year = 2019, .initials = "GH" },
    .{ .id = 3, .title = "Ember Lines", .artist = "Cinder & Sage", .year = 2022, .initials = "EL" },
    .{ .id = 4, .title = "Slow Light", .artist = "Marlowe", .year = 2018, .initials = "SL" },
    .{ .id = 5, .title = "Northern Loops", .artist = "Polar Echo", .year = 2023, .initials = "NL" },
    .{ .id = 6, .title = "Paper Planets", .artist = "The Cartographers", .year = 2020, .initials = "PP" },
    .{ .id = 7, .title = "Velvet Static", .artist = "Ivy Meridian", .year = 2024, .initials = "VS" },
    .{ .id = 8, .title = "Salt & Signal", .artist = "Harbor Lights", .year = 2017, .initials = "SS" },
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
/// The header bar's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests). Matches the tall hidden-inset band the
/// system reports through `on_chrome` — the band must not be taller
/// than the OS band, or the header's controls center below the traffic
/// lights the system centers within its own band.
pub const header_natural_height: f32 = 52;
pub const tick_ms: u32 = 500;

/// Effect keys, model-owned identity (effect-key style).
pub const progress_timer_key: u64 = 1;
pub const copy_key: u64 = 2;

// ------------------------------------------------------------------- model

pub const Tab = enum { albums, songs };

pub const Msg = union(enum) {
    show_albums,
    show_songs,
    set_appearance: native_sdk.Appearance,
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,
    search_edit: canvas.TextInputEvent,
    open_album: u8,
    close_album,
    play_album: u8,
    play_track: u8,
    toggle_play,
    next_track,
    prev_track,
    /// Seek slider changed; the reconciled value arrives through the
    /// `sync` hook (`seek_fraction`) before this message is applied.
    seeked,
    tick: native_sdk.EffectTimer,
    /// Controlled scroll: each region's applied offset lands here and the
    /// view echoes it back, so a rebuild mid-gesture can never reset it.
    grid_scrolled: canvas.ScrollState,
    detail_scrolled: canvas.ScrollState,
    songs_scrolled: canvas.ScrollState,
    /// Context menu: queue a track to play after the current one.
    queue_track: u8,
    /// Context menu: copy the track title to the clipboard via `pbcopy`
    /// (the effects channel has no clipboard call today).
    copy_title: u8,
    copied: native_sdk.EffectExit,
};

pub const Model = struct {
    // Source-of-truth state only; everything else is derived per rebuild.
    tab: Tab = .albums,
    appearance: native_sdk.Appearance = .{},
    open_album: ?u8 = null,
    /// Controlled scroll offsets (album grid, album detail, all songs):
    /// the model observes the applied offset and echoes it back.
    grid_scroll: f32 = 0,
    detail_scroll: f32 = 0,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band. Both fall back to the natural header when no band
    /// overlays the content (fullscreen, standard chrome, tests).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,
    songs_scroll: f32 = 0,
    now: ?u8 = null, // playing track id
    playing: bool = false,
    elapsed_ms: u32 = 0,
    queue: [max_queue]u8 = @splat(0),
    queue_len: usize = 0,
    queue_dropped: u32 = 0,
    search_buffer: canvas.TextBuffer(max_search) = .{},
    /// Seek slider value, mirrored from the runtime through `sync`.
    seek_fraction: f32 = 0,
    /// Registered cover ImageIds, index = album id - 1; 0 while the
    /// decode/registration has not succeeded (avatars fall back to
    /// initials, so a failed decode can never break the UI).
    covers: [albums.len]canvas.ImageId = @splat(0),
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

    pub fn albumsShowing(model: *const Model) bool {
        return model.tab == .albums;
    }

    pub fn songsShowing(model: *const Model) bool {
        return model.tab == .songs;
    }

    pub fn colorScheme(model: *const Model) native_sdk.ColorScheme {
        return model.appearance.color_scheme;
    }

    pub fn coverFor(model: *const Model, album_id: u8) canvas.ImageId {
        return model.covers[album_id - 1];
    }

    pub fn nowTrack(model: *const Model) ?*const Track {
        const id = model.now orelse return null;
        return trackById(id);
    }

    /// The open album's title, for the detail page's markup heading
    /// (album_title.native binds it). Total over the model on purpose —
    /// markup bindings resolve on every rebuild — so it answers "" when
    /// no album is open (the grid page, where the fragment is not
    /// composed).
    pub fn openAlbumTitle(model: *const Model) []const u8 {
        const id = model.open_album orelse return "";
        return albumById(id).title;
    }

    pub fn hasNowPlaying(model: *const Model) bool {
        return model.now != null;
    }

    pub fn idle(model: *const Model) bool {
        return model.now == null;
    }

    /// Data-driven icon choice for the transport's primary button: the
    /// markup binds `icon="{playPauseIcon}"`, so ONE button swaps its
    /// glyph with playback state - no if/else arms, no shared key to
    /// keep its identity stable.
    pub fn playPauseIcon(model: *const Model) []const u8 {
        return if (model.playing) "pause" else "play";
    }

    pub fn nowPlayingCover(model: *const Model) canvas.ImageId {
        const track = model.nowTrack() orelse return 0;
        return model.coverFor(track.album);
    }

    pub fn nowPlayingInitials(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "--";
        return albumById(track.album).initials;
    }

    pub fn nowPlayingTitle(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "Nothing playing";
        return track.title;
    }

    pub fn nowPlayingArtist(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "Pick an album or a song to start";
        return albumById(track.album).artist;
    }

    pub fn progressFraction(model: *const Model) f32 {
        const track = model.nowTrack() orelse return 0;
        if (track.duration_ms == 0) return 0;
        const fraction = @as(f32, @floatFromInt(model.elapsed_ms)) / @as(f32, @floatFromInt(track.duration_ms));
        return std.math.clamp(fraction, 0, 1);
    }

    pub fn elapsedLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.now == null) return "-:--";
        return formatMs(arena, model.elapsed_ms);
    }

    pub fn durationLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const track = model.nowTrack() orelse return "-:--";
        return formatMs(arena, track.duration_ms);
    }

    /// Albums matching the search query, derived into the build arena.
    pub fn visibleAlbums(model: *const Model, arena: std.mem.Allocator) []const AlbumCell {
        const out = arena.alloc(AlbumCell, albums.len) catch return &.{};
        var count: usize = 0;
        for (&albums) |*album| {
            if (!model.albumMatches(album)) continue;
            out[count] = .{
                .id = album.id,
                .title = album.title,
                .artist = album.artist,
                .initials = album.initials,
                .cover = model.coverFor(album.id),
                .playing = model.playingAlbum() == album.id,
            };
            count += 1;
        }
        return out[0..count];
    }

    /// Library tracks matching the search query (title, artist, or album),
    /// derived into the build arena.
    pub fn visibleTracks(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const out = arena.alloc(TrackRow, tracks.len) catch return &.{};
        var count: usize = 0;
        for (&tracks) |*track| {
            if (!model.trackMatches(track)) continue;
            out[count] = model.trackRow(arena, track, .with_album);
            count += 1;
        }
        return out[0..count];
    }

    /// One album's tracks for the detail view (never search-filtered: the
    /// detail page is the whole record).
    pub fn albumTrackRows(model: *const Model, arena: std.mem.Allocator, album_id: u8) []const TrackRow {
        const album_tracks = albumTracks(album_id);
        const out = arena.alloc(TrackRow, album_tracks.len) catch return &.{};
        for (album_tracks, 0..) |*track, index| {
            out[index] = model.trackRow(arena, track, .number_only);
        }
        return out;
    }

    pub fn playingAlbum(model: *const Model) u8 {
        const track = model.nowTrack() orelse return 0;
        return if (model.playing) track.album else 0;
    }

    fn albumMatches(model: *const Model, album: *const Album) bool {
        const query = model.search();
        if (query.len == 0) return true;
        return containsIgnoreCase(album.title, query) or containsIgnoreCase(album.artist, query);
    }

    fn trackMatches(model: *const Model, track: *const Track) bool {
        const query = model.search();
        if (query.len == 0) return true;
        const album = albumById(track.album);
        return containsIgnoreCase(track.title, query) or
            containsIgnoreCase(album.artist, query) or
            containsIgnoreCase(album.title, query);
    }

    const TrackRowStyle = enum { with_album, number_only };

    fn trackRow(model: *const Model, arena: std.mem.Allocator, track: *const Track, style: TrackRowStyle) TrackRow {
        const album = albumById(track.album);
        return .{
            .id = track.id,
            .number = std.fmt.allocPrint(arena, "{d}", .{track.number}) catch "",
            .title = track.title,
            .subtitle = switch (style) {
                .with_album => std.fmt.allocPrint(arena, "{s} — {s}", .{ album.artist, album.title }) catch "",
                .number_only => "",
            },
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

pub const AlbumCell = struct {
    id: u8,
    title: []const u8,
    artist: []const u8,
    initials: []const u8,
    cover: canvas.ImageId,
    playing: bool,
};

pub const TrackRow = struct {
    id: u8,
    number: []const u8,
    title: []const u8,
    subtitle: []const u8,
    duration: []const u8,
    /// This track is loaded in the now-playing bar (playing or paused).
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

// ------------------------------------------------------------------ update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .show_albums => model.tab = .albums,
        .show_songs => model.tab = .songs,
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            // Match the header to the titlebar band so its centered
            // controls share the traffic lights' centerline; the natural
            // height is the floor when no band overlays the content.
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
        .search_edit => |edit| model.search_buffer.apply(edit),
        .grid_scrolled => |state| model.grid_scroll = state.offset,
        .detail_scrolled => |state| model.detail_scroll = state.offset,
        .songs_scrolled => |state| model.songs_scroll = state.offset,
        .open_album => |id| {
            model.open_album = id;
            model.tab = .albums;
            // A fresh record opens at its top.
            model.detail_scroll = 0;
        },
        .close_album => model.open_album = null,
        .play_album => |id| startTrack(model, fx, albumTracks(id)[0].id),
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
    // `elapsed_ms` restarts here and advances by tick — it is also the
    // motion clock for the now-playing slide-in window, so animation
    // gating replays deterministically (no live clock read anywhere).
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
