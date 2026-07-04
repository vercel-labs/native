//! deck chassis layout: THE single dimensions table. Both the widget
//! views (`view.zig`) and the sculpted chrome pass (`chrome.zig`) machine
//! against these constants — nothing below is allowed to hand-copy a
//! coordinate, so the metalwork cannot drift from the controls it hugs.
//!
//! Everything snaps to one 4px chassis grid: window margins, glass
//! panels, glass insets, key plates, wells, gaps, and the transport
//! cluster's derived x-positions (accumulated here exactly the way the
//! widget row flows them). Comptime asserts at the bottom hold the sums:
//! the transport row must fit its container with slack for the queue
//! badge, and the vertical rhythm must land exactly on the window edge.

/// The chassis grid: every plate edge, well lip, key, gap, and glass
/// inset below is a multiple of this.
pub const grid: f32 = 4;

// ------------------------------------------------------------- window

/// Main window (the player): the classic main-window proportions
/// (275x116 chassis) scaled for a modern display. FIXED SIZE
/// (resizable = false), so all machining is absolute geometry.
pub const window_width: f32 = 460;
pub const window_height: f32 = 180;

/// The gold cap band across the top: the drag region (`window_drag`) and
/// the brand engraving. Tall enough that the hidden-inset traffic lights
/// sit ON the gold, like machine screws.
pub const cap_height: f32 = 28;

/// Faceplate margin: glass panels, the seek fader, and the key row all
/// keep this distance from the window edges.
pub const pad: f32 = 12;

/// The rhythm gap between the stacked rows (glass / seek / transport)
/// and between panels on the same row.
pub const gap: f32 = 8;

/// Every glass panel (VFD, spectrum) pads its widgets by this inset; the
/// chrome's bevel frames sit exactly on the panel rects.
pub const glass_inset: f32 = 8;

// ------------------------------------------------------ vertical rhythm

pub const row1_y: f32 = cap_height + pad; // 40
pub const row1_height: f32 = 60; // the VFD + spectrum glass row
pub const seek_y: f32 = row1_y + row1_height + gap; // 108
pub const seek_height: f32 = 20; // tall enough to case the 14px thumb
pub const transport_y: f32 = seek_y + seek_height + gap; // 136
pub const transport_height: f32 = 32;

// ------------------------------------------------------------ row one

pub const spectrum_width: f32 = 132;
pub const vfd_width: f32 = window_width - pad * 2 - spectrum_width - gap; // 296
/// Clear glass reserved at the VFD's left for the chrome-drawn
/// seven-segment readout.
pub const segment_area_width: f32 = 96;

// ----------------------------------------------------------- transport
// The transport row flows left-to-right with `gap` between items; the
// x-positions accumulate here so the chrome's raised bevels and wells
// land exactly on the widget plates. The queue region grows, so the PL
// key is right-aligned at `pl_x` by construction.

pub const key_height: f32 = 24;
pub const key_y: f32 = transport_y + (transport_height - key_height) / 2; // 140

pub const btn_prev_width: f32 = 32;
pub const btn_play_width: f32 = 48;
pub const btn_next_width: f32 = 32;
pub const btn_pl_width: f32 = 44;
/// Fixed spacer between the transport cluster and the output block, so
/// their wells separate cleanly.
pub const cluster_spacer: f32 = 8;
pub const vol_caption_width: f32 = 24;
pub const volume_width: f32 = 64;
pub const meter_width: f32 = 32;

pub const prev_x: f32 = pad; // 12
pub const play_x: f32 = prev_x + btn_prev_width + gap; // 52
pub const next_x: f32 = play_x + btn_play_width + gap; // 108
pub const vol_x: f32 = next_x + btn_next_width + gap + cluster_spacer + gap; // 164
pub const volume_x: f32 = vol_x + vol_caption_width + gap; // 196
pub const meter_x: f32 = volume_x + volume_width + gap; // 268
pub const pl_x: f32 = window_width - pad - btn_pl_width; // 404

/// Recessed pockets behind the key cluster and the output block: one
/// grid unit of lip around the plates they case.
pub const well_lip: f32 = grid;
pub const transport_well_x: f32 = prev_x - well_lip; // 8
pub const transport_well_width: f32 = next_x + btn_next_width + well_lip - transport_well_x; // 136
pub const output_well_x: f32 = vol_x - well_lip; // 160
pub const output_well_width: f32 = meter_x + meter_width + well_lip - output_well_x; // 144
pub const well_y: f32 = transport_y; // 136 (key band +/- lip)
pub const well_height: f32 = transport_height; // 32

// ------------------------------------------------------------- playlist

/// Playlist window (the rack unit).
pub const playlist_width: f32 = 460;
pub const playlist_height: f32 = 440;
/// The rack's cap strip: same height as the player's gold cap.
pub const playlist_header_height: f32 = 28;
/// Leading pad clearing the playlist window's traffic lights. Hardcoded:
/// `on_chrome` insets reach the MAIN canvas only (secondary windows have
/// no inset hook yet), so this is the compact-titlebar constant.
pub const playlist_chrome_leading: f32 = 62;
pub const rail_width: f32 = 152;
/// Rack padding: the rail, the ledger, the cue strip's leading edge, and
/// the status strip all inset content by this much.
pub const rack_pad: f32 = 8;
pub const statusbar_height: f32 = 39; // 38 strip + 1 separator
pub const cue_strip_height: f32 = 24;
pub const ledger_caption_height: f32 = 16;
pub const ledger_row_height: f32 = 27;
pub const ledger_row_gap: f32 = 1;
pub const rail_row_height: f32 = 28;

/// The ledger's scroll viewport, derived the way the playlist column
/// stacks: header, hairline, ledger (rack_pad + caption + gap + rows +
/// rack_pad), cue strip, status strip.
pub const ledger_viewport_height: f32 = playlist_height -
    playlist_header_height - 1 - cue_strip_height - statusbar_height -
    rack_pad * 2 - ledger_caption_height - gap; // 308

// ------------------------------------------------------------- asserts

comptime {
    // The vertical rhythm lands exactly on the window edge.
    if (transport_y + transport_height + pad != window_height)
        @compileError("player rows do not fill the fixed window height");
    // The transport row fits its container with room for the queue badge
    // (widest label: "QUEUE 16") between the output block and the PL key.
    const queue_min: f32 = 80;
    if (meter_x + meter_width + gap + queue_min + gap > pl_x)
        @compileError("transport row overflows the fixed window width");
    // The ledger viewport folds on a whole row: N rows plus their gaps
    // fit with less than one row pitch of slack, so no row is ever cut
    // mid-glyph at the fold.
    const pitch = ledger_row_height + ledger_row_gap;
    const rows = @floor(ledger_viewport_height / pitch);
    if (ledger_viewport_height - rows * pitch > 2)
        @compileError("ledger viewport cuts a row at the fold");
}
