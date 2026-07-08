//! soundboard views: ONE catalog of content pieces, TWO shells.
//!
//! The content pieces — album tiles, track rows, the album detail
//! heading, section headings, the empty state, the adaptive grid — are
//! shared functions used by BOTH shells; the markup fragments
//! (header.native / nowplaying.native / album_title.native) are the
//! desktop bars plus the shared detail title. The DESKTOP shell composes
//! them into the wide shape (header bar, adaptive multi-column grid,
//! now-playing rail); the COMPACT shell recomposes the same pieces for
//! phone-class surfaces (stacked touch header, single-column content,
//! a mini player, safe-area padding). The root view switches on the
//! model's form factor (host-reported size class when present, the
//! width derivation as the fallback) — shell branching is Zig's job by
//! design; the closed markup grammar has no conditionals.
//!
//! Zig-only sections remain what markup cannot express: rounded-square
//! cover images (`ElementOptions.image` outside the avatar), the album
//! grid's width-derived column count, per-track native context menus,
//! and now the shell switch itself.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const FormFactor = model_mod.FormFactor;
pub const Ui = canvas.Ui(Msg);

pub const header_markup = @embedFile("header.native");
pub const nowplaying_markup = @embedFile("nowplaying.native");
pub const CompiledHeaderView = canvas.CompiledMarkupView(Model, Msg, header_markup);
pub const CompiledNowPlayingView = canvas.CompiledMarkupView(Model, Msg, nowplaying_markup);

// The album detail heading: a markup span paragraph (one bold 1.9x-scaled
// run bound to the open album's title), compiled like the other fragments
// and composed into BOTH shells' detail columns. The tests hold it
// widget-for-widget equal to the builder paragraph it replaced.
pub const AlbumTitleView = canvas.CompiledMarkupView(Model, Msg, @embedFile("album_title.native"));

// The album grid is ADAPTIVE: the layout system's grid takes a fixed
// column count (rows and columns never flow-wrap children), so the
// column count is derived here, per rebuild, from the canvas width the
// model tracks (`canvas_resized`, mirrored from presented frames). The
// rule is the standard adaptive-grid register: as many min-width tiles
// as fit the row, the leftover split evenly — tiles grow modestly until
// one more column fits, then snap back toward the minimum. Each shell
// states its own tile minimum and content padding; the rule is one
// function.
/// The narrowest a DESKTOP album tile may get. Sized so the cover (tile
/// width minus the hover-wash inset on both sides) never drops below the
/// generous cover the fixed four-column grid established.
const min_tile_width: f32 = 232;
/// Gap between bare tiles. Tighter than the old carded grid on purpose:
/// with no card chrome the gap IS the whole separation between covers,
/// and the bare music-library register reads best with covers closer
/// together than boxed cards were.
const grid_gap: f32 = 12;
/// Inset between the tile's hover/press wash and the cover art: on a
/// bare tile the wash must show AROUND the art to read at all (the art
/// would paint over a same-sized wash), so each tile keeps a thin halo.
const tile_padding: f32 = 8;
/// Vertical gap between the cover and the title/artist block.
const cover_text_gap: f32 = 8;
/// The title + artist block's height (one body line over one small
/// line), used to derive the tile's total height from its width.
const tile_text_height: f32 = 36;
const detail_cover_size: f32 = 184;
const content_padding: f32 = 24;

// ---------------------------------------------------- compact constants

/// The compact shell's content padding: tighter than the desktop's 24 —
/// phone points are scarce — while still clearing curved screen corners.
const compact_padding: f32 = 16;
/// The narrowest a COMPACT album tile may get: two columns on mainstream
/// phone-portrait widths (390–430pt), one column below ~330pt, and a
/// whole tile is a generous touch target either way.
const compact_min_tile_width: f32 = 150;
/// The compact album detail cover: full-surface page, one big square.
const compact_detail_cover_size: f32 = 200;
/// Compact track rows: taller than the desktop's 44 pointer rows so a
/// thumb lands cleanly between neighbors.
const compact_row_height: f32 = 56;
/// The mini player's bar height: a 44pt cover thumb plus breathing room.
const mini_bar_height: f32 = 64;

/// The width→columns rule, answered for one canvas width.
pub const GridFit = struct {
    /// How many min-width tiles (plus gaps) fit the content row.
    columns: usize,
    /// The evenly-grown tile width at that column count.
    tile_width: f32,
};

/// Columns = how many minimum-width tiles fit the padded content row;
/// tile width = the row split evenly at that count. Never below one
/// column, and the floor guard keeps the math total for degenerate
/// widths (a zero-sized test surface).
fn fitColumns(canvas_width: f32, min_tile: f32, padding: f32) GridFit {
    const available = @max(min_tile, canvas_width - padding * 2);
    const fitting = @floor((available + grid_gap) / (min_tile + grid_gap));
    const columns: usize = @intFromFloat(@max(1, fitting));
    const gaps = grid_gap * @as(f32, @floatFromInt(columns - 1));
    const tile_width = (available - gaps) / @as(f32, @floatFromInt(columns));
    return .{ .columns = columns, .tile_width = tile_width };
}

/// The desktop shell's grid fit (232pt tile floor, 24pt padding).
pub fn gridFit(canvas_width: f32) GridFit {
    return fitColumns(canvas_width, min_tile_width, content_padding);
}

/// The compact shell's grid fit (150pt tile floor, 16pt padding): two
/// touch-sized columns on phone-portrait widths.
pub fn compactGridFit(canvas_width: f32) GridFit {
    return fitColumns(canvas_width, compact_min_tile_width, compact_padding);
}

// ------------------------------------------------------------------ root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    // The shell switch, on the model's form factor: the host-reported
    // size class when one arrived over the window-chrome channel, the
    // width derivation as the fallback (`Model.formFactor` owns the
    // rule). This switch and both shells take the model unchanged, so
    // the views never reshaped when the host report landed.
    return switch (model.formFactor()) {
        .regular => desktopShell(ui, model),
        .compact => compactShell(ui, model),
    };
}

/// The desktop composition, exactly as the app has always shipped it:
/// the markup header bar (titlebar drag surface, chrome-inset padding),
/// the content switch, and the markup now-playing rail.
fn desktopShell(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        CompiledHeaderView.build(ui, model),
        contentView(ui, model),
        CompiledNowPlayingView.build(ui, model),
    });
}

fn contentView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.tab) {
        .albums => if (model.open_album) |album_id|
            albumDetailView(ui, model, album_id)
        else
            albumGridView(ui, model),
        .songs => songsView(ui, model),
    };
}

// ------------------------------------------------------------- album grid

fn albumGridView(ui: *Ui, model: *const Model) Ui.Node {
    const cells = model.visibleAlbums(ui.arena);
    // Controlled scroll: the model stores the applied offset
    // (`grid_scrolled`) and echoes it back, so a rebuild mid-gesture
    // (a progress tick, a search keystroke) can never reset the region.
    return ui.scroll(.{
        .grow = 1,
        .value = model.grid_scroll,
        .on_scroll = Ui.scrollMsg(.grid_scrolled),
        .semantics = .{ .label = "Album grid" },
    }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        sectionHeading(ui, "Albums", ui.fmt("{d} of {d}", .{ cells.len, model_mod.albums.len })),
        if (cells.len == 0) emptyState(ui, model) else albumGrid(ui, gridFit(model.canvas_width), .regular, cells),
    }));
}

/// The shared adaptive grid body: one bare tile per visible album, sized
/// by the caller's fit. Used by both shells (each hands its own fit and
/// form factor).
fn albumGrid(ui: *Ui, fit: GridFit, form: FormFactor, cells: []const model_mod.AlbumCell) Ui.Node {
    // The grid node is EXPLICITLY sized to its shown columns rather than
    // stretched to the row, because the engine divides the grid's width
    // evenly among its columns: an exact width makes each cell exactly
    // one tile wide, and a short result set (a narrow search) keeps
    // tile-sized covers left-aligned instead of ballooning across the
    // row. The tail row left-aligns the same way — cells fill in row
    // order from the leading edge.
    const columns = @min(fit.columns, cells.len);
    const row_width = @as(f32, @floatFromInt(columns)) * (fit.tile_width + grid_gap) - grid_gap;
    return ui.el(.grid, .{
        .width = row_width,
        .columns = columns,
        .gap = grid_gap,
        .semantics = .{ .role = .list, .label = "Albums" },
    }, ui.eachCtx(TileContext{ .fit = fit, .form = form }, cells, albumKey, albumTile));
}

fn albumKey(cell: *const model_mod.AlbumCell) canvas.UiKey {
    return canvas.uiKey(cell.id);
}

/// The per-tile context `eachCtx` threads through: the grid's fit (tile
/// width) plus the shell's form factor (gesture vocabulary).
const TileContext = struct {
    fit: GridFit,
    form: FormFactor,
};

/// One bare album tile: the cover IS the tile — no card fill, border, or
/// shadow around it (the flat `list_item` composite, the same chromeless
/// register the track rows use). Hover is QUIET: the pointer rests on
/// cover art, not a control register, so hovering changes nothing
/// visually (the pointer cursor is the whole hover affordance) — the
/// quiet-surface style knob below states exactly that. A press still
/// paints the standard pressed wash (the visible moment of commitment),
/// keyboard focus still draws the standard ring, and the whole tile —
/// art and text — stays one hit target with the album-by-artist
/// accessible label. Shared by both shells; only the context menu is
/// desktop vocabulary (right/ctrl-click has no honest touch equivalent
/// on the phone hosts, so the compact tile mounts none).
fn albumTile(ui: *Ui, context: TileContext, cell: *const model_mod.AlbumCell) Ui.Node {
    const cover = context.fit.tile_width - tile_padding * 2;
    const desktop_menu = [_]Ui.ContextMenuItem{
        .{ .label = "Play Album", .msg = Msg{ .play_album = cell.id } },
        .{ .label = "Open Album", .msg = Msg{ .open_album = cell.id } },
    };
    return ui.el(.list_item, .{
        // Height derives from width: the square cover plus the text
        // block and paddings, so tiles stay uniform as they grow
        // between column-count breakpoints.
        .height = tile_padding * 2 + cover + cover_text_gap + tile_text_height,
        .padding = tile_padding,
        // The quiet-surface knob: no hover wash on an image-forward
        // tile. Press feedback, cursor intent, the focus ring, and hit
        // testing all keep their own channels.
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .open_album = cell.id },
        .context_menu = if (context.form == .regular) &desktop_menu else &.{},
        .semantics = .{ .role = .listitem, .label = ui.fmt("{s} by {s}", .{ cell.title, cell.artist }) },
    }, .{
        // list_item flows children horizontally; the single grown column
        // carries the vertical cover-over-text stack.
        ui.column(.{ .gap = cover_text_gap, .grow = 1 }, .{
            ui.avatar(.{
                .image = cell.cover,
                .width = cover,
                .height = cover,
                .style = .{ .radius = 8 },
                .semantics = .{ .label = ui.fmt("{s} cover", .{cell.title}) },
            }, cell.initials),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.column(.{ .gap = 1, .grow = 1 }, .{
                    // One-line title/artist by design: elide behind a
                    // trailing ellipsis at the tile width, never wrap
                    // over the line below.
                    ui.text(.{ .wrap = false }, cell.title),
                    ui.text(.{ .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, cell.artist),
                }),
                if (cell.playing)
                    ui.el(.badge, .{ .variant = .primary, .text = "Playing" }, .{})
                else
                    ui.el(.stack, .{}, .{}),
            }),
        }),
    });
}

fn emptyState(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .padding = 24,
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .label = "No albums match" },
    }, ui.column(.{ .gap = 6 }, .{
        ui.text(.{}, ui.fmt("No matches for \"{s}\"", .{model.search()})),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Try an album, artist, or song title."),
    }));
}

// ----------------------------------------------------------- album detail

fn albumDetailView(ui: *Ui, model: *const Model, album_id: u8) Ui.Node {
    const album = model_mod.albumById(album_id);
    const rows = model.albumTrackRows(ui.arena, album_id);
    return ui.scroll(.{
        .grow = 1,
        .value = model.detail_scroll,
        .on_scroll = Ui.scrollMsg(.detail_scrolled),
        .semantics = .{ .label = "Album detail" },
    }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        ui.row(.{}, .{
            backButton(ui, .regular),
            ui.spacer(1),
        }),
        ui.row(.{ .gap = 20 }, .{
            detailCover(ui, model, album, detail_cover_size),
            detailHeading(ui, model, album, rows.len, .regular),
        }),
        trackList(ui, rows, "Album tracks", .regular),
    }));
}

/// The album detail cover, shared by both shells: the rounded square at
/// whatever size the shell's composition affords.
fn detailCover(ui: *Ui, model: *const Model, album: *const model_mod.Album, size: f32) Ui.Node {
    return ui.avatar(.{
        .image = model.coverFor(album.id),
        .width = size,
        .height = size,
        .style = .{ .radius = 10 },
        .semantics = .{ .label = ui.fmt("{s} cover", .{album.title}) },
    }, album.initials);
}

/// The album detail heading block, shared by both shells: the "Album"
/// eyebrow, the markup title fragment, the artist/year/track-count line,
/// and the play control. The desktop shell grows it beside the cover and
/// bottom-aligns (main .end); the compact shell stacks it full-width
/// under the cover at touch control size.
fn detailHeading(ui: *Ui, model: *const Model, album: *const model_mod.Album, track_count: usize, form: FormFactor) Ui.Node {
    return ui.column(.{
        .gap = 8,
        .grow = if (form == .regular) 1 else 0,
        .main = if (form == .regular) .end else .start,
    }, .{
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Album"),
        AlbumTitleView.build(ui, model),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{s} · {d} · {d} tracks", .{ album.artist, album.year, track_count })),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            playAlbumButton(ui, album.id, form),
            ui.spacer(1),
        }),
    });
}

/// Icon+text buttons via `ElementOptions.icon`: the icon is part of the
/// button's own rendering, so each control is ONE widget — one hit
/// target, no duplicated on_press, and the icon follows the button's
/// enabled/disabled tint for free. (These replaced the old overlay-stack
/// idiom the moment icon-in-button landed.) Both shells share the
/// control; the form factor picks the size register — the compact shell
/// takes lg so the target clears the touch floor.
fn backButton(ui: *Ui, form: FormFactor) Ui.Node {
    return ui.button(.{
        .variant = .ghost,
        .size = if (form == .regular) .sm else .lg,
        .icon = "chevron-left",
        .on_press = .close_album,
        .semantics = .{ .label = "Back to albums" },
    }, "Back to albums");
}

fn playAlbumButton(ui: *Ui, album_id: u8, form: FormFactor) Ui.Node {
    return ui.button(.{
        .variant = .primary,
        .size = if (form == .regular) .default else .lg,
        .icon = "play",
        .on_press = Msg{ .play_album = album_id },
        .semantics = .{ .label = "Play album" },
    }, "Play album");
}

// ------------------------------------------------------------------ songs

fn songsView(ui: *Ui, model: *const Model) Ui.Node {
    const rows = model.visibleTracks(ui.arena);
    return ui.scroll(.{
        .grow = 1,
        .value = model.songs_scroll,
        .on_scroll = Ui.scrollMsg(.songs_scrolled),
        .semantics = .{ .label = "All songs" },
    }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        sectionHeading(ui, "Songs", ui.fmt("{d} of {d}", .{ rows.len, model_mod.tracks.len })),
        if (rows.len == 0) emptyState(ui, model) else trackList(ui, rows, "Songs", .regular),
    }));
}

// ------------------------------------------------------------- track rows

/// The shared track list: flat house rows with no inter-row gaps — the
/// rows' washes are the only separation. The form factor picks the
/// gesture vocabulary and row height (see `trackRowView`).
fn trackList(ui: *Ui, rows: []const model_mod.TrackRow, label: []const u8, form: FormFactor) Ui.Node {
    return ui.el(.list, .{
        .semantics = .{ .role = .list, .label = label },
    }, ui.eachCtx(form, rows, trackKey, trackRowView));
}

fn trackKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(row.id);
}

/// One pressable track row: a FLAT list row (the list_item composite —
/// no border, no card chrome; hover is a full-width wash), with custom
/// children flowing horizontally inside it. The content is shared; the
/// GESTURES follow the shell:
///
/// - `.regular` is the desktop list convention: a single click (or
///   Space on a ring-focused row) SELECTS, the double click (or Enter,
///   via `on_submit`) PLAYS, and right/ctrl-click presents the native
///   context menu whose items dispatch typed Msgs exactly like a press.
/// - `.compact` is the touch convention: one tap PLAYS (double taps and
///   hover affordances are pointer vocabulary, and the phone hosts model
///   no long-press, so the row mounts no context menu). Enter still
///   plays via `on_submit` for attached keyboards.
///
/// The selection wears the inverted register in both shells — accent
/// fill under the accent's knockout ink (`accent_text`, the same token
/// the filled Play Album button pairs with the accent, white under this
/// theme in both schemes), stated per-widget through style tokens so
/// the unselected rows keep their neutral hover/press washes.
fn trackRowView(ui: *Ui, form: FormFactor, row: *const model_mod.TrackRow) Ui.Node {
    const touch = form == .compact;
    // Two items per row on purpose: the per-view context-menu budget is
    // 512 items (canvas_limits), and the all-songs list mounts every
    // catalog track as a row — two items per row keeps a comfortable
    // margin even as the manifest grows.
    const desktop_menu = [_]Ui.ContextMenuItem{
        .{ .label = "Play Next", .msg = Msg{ .queue_track = row.id } },
        .{ .label = "Copy Title", .msg = Msg{ .copy_title = row.id } },
    };
    return ui.el(.list_item, .{
        .global_key = canvas.uiKey(@as(u32, row.id)),
        .height = if (touch) compact_row_height else 44,
        .padding = 10,
        .gap = 12,
        .cross = .center,
        .selected = row.selected,
        .style_tokens = if (row.selected) .{ .background = .accent } else .{},
        .on_press = if (touch) Msg{ .play_track = row.id } else Msg{ .select_track = row.id },
        .on_double_press = if (touch) null else Msg{ .play_track = row.id },
        .on_submit = Msg{ .play_track = row.id },
        .context_menu = if (touch) &.{} else &desktop_menu,
        .semantics = .{ .role = .listitem, .label = row.title },
    }, .{
        trackIndicator(ui, row),
        if (row.subtitle.len == 0)
            ui.text(.{ .grow = 1, .style_tokens = rowTitleTokens(row) }, row.title)
        else
            ui.column(.{ .gap = 1, .grow = 1 }, .{
                ui.text(.{ .style_tokens = rowTitleTokens(row) }, row.title),
                ui.text(.{ .size = .sm, .style_tokens = rowMutedTokens(row) }, row.subtitle),
            }),
        if (row.queued)
            ui.el(.badge, .{ .variant = .secondary, .text = "Up next" }, .{})
        else
            ui.el(.stack, .{}, .{}),
        durationText(ui, row),
    });
}

/// Row title ink: the accent's knockout ink (`accent_text`) on the
/// selected (accent) row — the inverted register. The window-background
/// token this used to take is only light-scheme white; in dark mode it
/// resolves near-black and vanished into the accent fill, while
/// `accent_text` is the ink the theme pairs with the accent in BOTH
/// schemes (the filled Play Album button's white). Accent on the loaded
/// track's row, default otherwise.
fn rowTitleTokens(row: *const model_mod.TrackRow) canvas.StyleTokenRefs {
    if (row.selected) return .{ .foreground = .accent_text };
    if (row.now) return .{ .foreground = .accent };
    return .{};
}

/// Row secondary ink (subtitle, duration, track number): muted at rest,
/// the accent's knockout ink on the selected row — muted gray on the
/// accent fill would fail the contrast the inverted register exists to
/// keep, and only `accent_text` keeps that promise in both schemes.
fn rowMutedTokens(row: *const model_mod.TrackRow) canvas.StyleTokenRefs {
    if (row.selected) return .{ .foreground = .accent_text };
    return .{ .foreground = .text_muted };
}

/// The leading track-row slot: a STATE icon on the loaded track's row —
/// the pause glyph while audio is playing, the play glyph while it is
/// paused (the icon names the state, matching the transport button's
/// convention) — and the track number everywhere else. Icons are
/// decoration (never hit-tested), so the row's press handling is
/// untouched; the fixed 24px slot keeps the number column's alignment.
/// On the selected row the icon takes the inverted ink like the text —
/// an accent glyph would vanish into the accent fill.
fn trackIndicator(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    if (!row.now) {
        return ui.text(.{ .width = 24, .size = .sm, .style_tokens = rowMutedTokens(row) }, row.number);
    }
    const icon_tokens: canvas.StyleTokenRefs = if (row.selected)
        .{ .foreground = .accent_text }
    else if (row.playing)
        .{ .foreground = .accent }
    else
        .{ .foreground = .text_muted };
    return ui.row(.{ .width = 24, .cross = .center }, .{
        if (row.playing)
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = icon_tokens }, "pause")
        else
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = icon_tokens }, "play"),
    });
}

/// Right-aligned fixed-width duration. The fixed width is a column: it
/// keeps every row's duration right edge aligned regardless of digit
/// count ("8:05" vs "12:41"), sized for the widest plausible value.
fn durationText(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    var node = ui.text(.{ .width = 44, .size = .sm, .style_tokens = rowMutedTokens(row) }, row.duration);
    node.widget.text_alignment = .end;
    return node;
}

// ---------------------------------------------------------------- shared

fn sectionHeading(ui: *Ui, title: []const u8, count: []const u8) Ui.Node {
    // Intrinsic width: layout measures with the bundled face's real
    // advances and the packet host draws the engine's lines verbatim,
    // so the old slack-width workaround (needed when the estimator
    // diverged from real glyph metrics) is gone.
    return ui.row(.{ .gap = 10, .cross = .center }, .{
        ui.paragraph(.{ .semantics = .{ .label = title } }, &.{
            .{ .text = title, .weight = .bold, .scale = 1.45 },
        }),
        ui.el(.badge, .{ .variant = .secondary, .text = count }, .{}),
        ui.spacer(1),
    });
}

// --------------------------------------------------------- compact shell

/// The phone composition: the same content pieces in a single column,
/// padded by the safe areas the window-chrome channel reports (status
/// bar / Dynamic Island above, home indicator below, notch side bands in
/// landscape). No window-drag regions, no titlebar assumptions, no
/// hover-dependent affordances — every control clears the 44pt touch
/// floor, and the mini player keeps playback visible on every page.
fn compactShell(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        // Top safe area: the status bar / Dynamic Island band. Raw from
        // `on_chrome` — the compact shell has no header floor to apply.
        ui.el(.stack, .{ .height = model.chrome_top }, .{}),
        ui.row(.{ .grow = 1 }, .{
            // Side safe areas: zero in portrait; the notch band in
            // landscape arrives on whichever edge it occupies.
            ui.el(.stack, .{ .width = model.chrome_leading }, .{}),
            ui.column(.{ .grow = 1 }, .{
                compactHeader(ui, model),
                compactContent(ui, model),
                if (model.miniBarVisible()) miniBar(ui, model) else ui.el(.stack, .{}, .{}),
            }),
            ui.el(.stack, .{ .width = model.chrome_trailing }, .{}),
        }),
        // Bottom safe area: the home indicator band, under the mini bar.
        ui.el(.stack, .{ .height = model.chrome_bottom }, .{}),
    });
}

/// The compact header: the same Albums/Songs switcher the desktop header
/// carries plus the same search binding, restated at touch size in a
/// stacked column — the markup header is a desktop surface (window-drag
/// band, traffic-light spacers, a fixed trailing search column), so the
/// compact shell composes its own. Search takes a full-width row of its
/// own: reachable on every page without a persistent wide bar.
///
/// While the host projects the declared tab set as a REAL native tab
/// bar (`model.native_tabs`, from the window-chrome channel), the
/// in-canvas switcher yields — the system bar is the one tab affordance
/// on screen — and only the search row remains. Everywhere the
/// declaration is inert (no projecting host), the switcher stays.
fn compactHeader(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .semantics = .{ .label = "Compact header" } }, .{
        ui.column(.{ .padding = compact_padding, .gap = 10 }, .{
            if (model.native_tabs)
                ui.el(.stack, .{}, .{})
            else
                ui.row(.{ .cross = .center }, .{
                    ui.el(.button_group, .{}, .{
                        ui.button(.{ .size = .lg, .selected = model.albumsShowing(), .on_press = .show_albums }, "Albums"),
                        ui.button(.{ .size = .lg, .selected = model.songsShowing(), .on_press = .show_songs }, "Songs"),
                    }),
                    ui.spacer(1),
                }),
            // The search field carries the built-in trailing clear
            // affordance whenever it holds text, same as the desktop
            // header's field — one binding, two shells.
            ui.el(.search_field, .{
                .size = .lg,
                .text = model.search(),
                .placeholder = "Search albums, artists, songs…",
                .on_input = Ui.inputMsg(.search_edit),
                .semantics = .{ .label = "Search library" },
            }, .{}),
        }),
        ui.separator(.{}),
    });
}

/// The same page switch the desktop shell drives — one model, one
/// navigation state, two compositions.
fn compactContent(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.tab) {
        .albums => if (model.open_album) |album_id|
            compactAlbumDetail(ui, model, album_id)
        else
            compactAlbumGrid(ui, model),
        .songs => compactSongs(ui, model),
    };
}

fn compactAlbumGrid(ui: *Ui, model: *const Model) Ui.Node {
    const cells = model.visibleAlbums(ui.arena);
    return ui.scroll(.{
        .grow = 1,
        .value = model.grid_scroll,
        .on_scroll = Ui.scrollMsg(.grid_scrolled),
        .semantics = .{ .label = "Album grid" },
    }, ui.column(.{ .padding = compact_padding, .gap = 16 }, .{
        sectionHeading(ui, "Albums", ui.fmt("{d} of {d}", .{ cells.len, model_mod.albums.len })),
        if (cells.len == 0) emptyState(ui, model) else albumGrid(ui, compactGridFit(model.canvas_width), .compact, cells),
    }));
}

/// The compact album detail: a full-surface page — back navigation on
/// top (model-driven, the same `close_album` state the desktop back
/// button drives), the cover stacked over the shared heading block, then
/// the record's rows at touch size.
fn compactAlbumDetail(ui: *Ui, model: *const Model, album_id: u8) Ui.Node {
    const album = model_mod.albumById(album_id);
    const rows = model.albumTrackRows(ui.arena, album_id);
    return ui.scroll(.{
        .grow = 1,
        .value = model.detail_scroll,
        .on_scroll = Ui.scrollMsg(.detail_scrolled),
        .semantics = .{ .label = "Album detail" },
    }, ui.column(.{ .padding = compact_padding, .gap = 16 }, .{
        ui.row(.{}, .{
            backButton(ui, .compact),
            ui.spacer(1),
        }),
        ui.column(.{ .cross = .center }, .{
            detailCover(ui, model, album, compact_detail_cover_size),
        }),
        detailHeading(ui, model, album, rows.len, .compact),
        trackList(ui, rows, "Album tracks", .compact),
    }));
}

fn compactSongs(ui: *Ui, model: *const Model) Ui.Node {
    const rows = model.visibleTracks(ui.arena);
    return ui.scroll(.{
        .grow = 1,
        .value = model.songs_scroll,
        .on_scroll = Ui.scrollMsg(.songs_scrolled),
        .semantics = .{ .label = "All songs" },
    }, ui.column(.{ .padding = compact_padding, .gap = 16 }, .{
        sectionHeading(ui, "Songs", ui.fmt("{d} of {d}", .{ rows.len, model_mod.tracks.len })),
        if (rows.len == 0) emptyState(ui, model) else trackList(ui, rows, "Songs", .compact),
    }));
}

/// The mini player: cover thumb, title/artist, and one lg play/pause
/// control — always on screen while a track is loaded (playing OR
/// paused) or a degraded playback notice needs a surface, sitting above
/// the home-indicator band. The title/cover keep the desktop bar's
/// semantic labels ("Now playing title" / "Now playing cover") so the
/// track-change slide-in animation targets them in either shell, and the
/// title/artist bindings double as the status surface exactly like the
/// desktop bar (assets notice, stream notice, buffering).
fn miniBar(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .semantics = .{ .label = "Now playing mini bar" } }, .{
        ui.separator(.{}),
        ui.row(.{ .height = mini_bar_height, .padding = 10, .gap = 12, .cross = .center, .style_tokens = .{ .background = .surface } }, .{
            ui.avatar(.{
                .image = model.nowPlayingCover(),
                .width = 44,
                .height = 44,
                .style = .{ .radius = 6 },
                .semantics = .{ .label = "Now playing cover" },
            }, model.nowPlayingInitials()),
            ui.column(.{ .gap = 1, .grow = 1 }, .{
                ui.text(.{ .wrap = false, .semantics = .{ .label = "Now playing title" } }, model.nowPlayingTitle()),
                ui.text(.{ .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, model.nowPlayingArtist()),
            }),
            ui.button(.{
                .variant = .ghost,
                .size = .lg,
                .icon = model.playPauseIcon(),
                .on_press = .toggle_play,
                .semantics = .{ .label = "Play or pause" },
            }, ""),
        }),
    });
}
