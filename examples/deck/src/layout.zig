//! deck chassis layout: THE single dimensions table. Both the widget
//! views (`view.zig`) and the sculpted chrome pass (`chrome.zig`) machine
//! against these constants — nothing below is allowed to hand-copy a
//! coordinate, so the enamel work cannot drift from the controls it hugs.
//!
//! Everything snaps to one 4px chassis grid: window margins, glass bays,
//! glass insets, key plates, wells, gaps, and the transport row's derived
//! x-positions (accumulated here exactly the way the widget row flows
//! them). Comptime asserts at the bottom hold the sums: the transport row
//! must fit its container with slack for the queue badge, and the
//! vertical rhythm must land exactly on the window edge.

/// The chassis grid: every plate edge, well lip, key, gap, and glass
/// inset below is a multiple of this.
pub const grid: f32 = 4;

// ------------------------------------------------------------- window

/// Main window (the rack unit): a fixed-size enamel faceplate — FIXED
/// SIZE (resizable = false), so all machining is absolute geometry.
pub const window_width: f32 = 512;
pub const window_height: f32 = 264;

/// The enamel cap band across the top: the drag region (`window_drag`)
/// with the embossed brand plate and — the window is chromeless, no OS
/// controls exist — the skin's own close and minimize keys.
pub const cap_height: f32 = 30;

/// Faceplate margin: glass bays, the seek fader, and the key row all
/// keep this distance from the window edges.
pub const pad: f32 = 12;

/// The cap band's row gap: the view flows the window keys, the brand
/// stamp, and the trailing lamps with this gap, and the chrome offsets
/// its plates by the same amount so plate and stamp align.
pub const cap_gap: f32 = 8;

/// The cap band's window keys (close, then minimize): square enamel
/// keys at the leading edge — the fully-skinned replacement for the
/// traffic lights, wired to the runtime's REAL window-action effects.
pub const cap_key_size: f32 = 20;
pub const cap_key_y: f32 = (cap_height - cap_key_size) / 2; // 5
pub const cap_close_x: f32 = pad; // 12
pub const cap_min_x: f32 = cap_close_x + cap_key_size + cap_gap; // 40

/// The raised brand plate on the cap band: the chrome draws the plate
/// (fill + bevel) and the view centers its "D E C K" stamp on the same
/// width — both flow after the window keys, so the stamp and its plate
/// align by construction (chromeless window: no live chrome inset, the
/// x is a constant).
pub const brand_width: f32 = 64;
pub const brand_height: f32 = 20;
pub const brand_y: f32 = (cap_height - brand_height) / 2; // 5
pub const brand_x: f32 = cap_min_x + cap_key_size + cap_gap; // 68

/// The rhythm gap between the stacked rows (glass / seek / transport)
/// and between bays on the same row.
pub const gap: f32 = 8;

/// Every glass bay pads its widgets by this inset; the chrome's bevel
/// frames sit exactly on the bay rects.
pub const glass_inset: f32 = 8;

// ------------------------------------------------------ vertical rhythm

pub const row1_y: f32 = cap_height + pad; // 42
/// ONE glass row: the display bay (the deck's single LED section —
/// segment clock, spectrum, marquee, channel/source lines) beside the
/// art bay.
pub const row1_height: f32 = 140;
pub const seek_y: f32 = row1_y + row1_height + gap; // 190
pub const seek_height: f32 = 18; // cases the fader's squared thumb
pub const transport_y: f32 = seek_y + seek_height + gap; // 216
pub const transport_height: f32 = 36;

// ------------------------------------------------------------ glass row

/// The art bay: the loaded record's cover in its own glass window,
/// square at the glass row's full height.
pub const art_size: f32 = row1_height; // 140
pub const art_x: f32 = window_width - pad - art_size; // 360
/// The main display bay fills the rest of the row — the ONE LED glass
/// section on the fascia.
pub const display_width: f32 = window_width - pad * 2 - art_size - gap; // 340
/// Clear glass reserved at the display's top-left for the chrome-drawn
/// seven-segment elapsed readout; the spectrum chart fills the rest of
/// the same row.
pub const segment_area_width: f32 = 96;
/// The display bay's top row (segment readout | spectrum chart); the
/// chrome centers the segment digits vertically in it.
pub const display_top_row_height: f32 = 40;
/// The display column's row gap (top row / marquee / channel / source):
/// tighter than the chassis `gap` so the four rows sit inside the glass
/// interior with honest slack for the pixel face's line boxes.
pub const display_row_gap: f32 = 2;

// ----------------------------------------------------------- transport
// The transport row flows left-to-right with `gap` between items; the
// x-positions accumulate here so the chrome's raised bevels and wells
// land exactly on the widget plates. The queue region grows, so the PL
// key is right-aligned at `pl_x` by construction.

pub const key_height: f32 = 26;
pub const key_y: f32 = transport_y + (transport_height - key_height) / 2; // 221

pub const btn_prev_width: f32 = 32;
pub const btn_play_width: f32 = 44;
pub const btn_pause_width: f32 = 32;
pub const btn_stop_width: f32 = 32;
pub const btn_next_width: f32 = 32;
pub const btn_pl_width: f32 = 44;
/// Fixed spacer between the transport cluster and the output block, so
/// their wells separate cleanly.
pub const cluster_spacer: f32 = 8;
/// Cases "VOL" at the pixel face's readout pitch.
pub const vol_caption_width: f32 = 28;
/// The rotary volume control: a real slider widget of this square-ish
/// footprint; the chrome draws the knob face over it (see chrome.zig).
pub const knob_width: f32 = 40;
pub const knob_size: f32 = 34; // the drawn knob's diameter

pub const prev_x: f32 = pad; // 12
pub const play_x: f32 = prev_x + btn_prev_width + gap; // 52
pub const pause_x: f32 = play_x + btn_play_width + gap; // 104
pub const stop_x: f32 = pause_x + btn_pause_width + gap; // 144
pub const next_x: f32 = stop_x + btn_stop_width + gap; // 184
pub const vol_x: f32 = next_x + btn_next_width + gap + cluster_spacer + gap; // 240
pub const knob_x: f32 = vol_x + vol_caption_width + gap; // 276
pub const pl_x: f32 = window_width - pad - btn_pl_width; // 456

/// Recessed pockets behind the key cluster and the output block: one
/// grid unit of lip around the plates they case.
pub const well_lip: f32 = grid;
pub const transport_well_x: f32 = prev_x - well_lip; // 8
pub const transport_well_width: f32 = next_x + btn_next_width + well_lip - transport_well_x; // 212
pub const output_well_x: f32 = vol_x - well_lip; // 236
pub const output_well_width: f32 = knob_x + knob_width + well_lip - output_well_x; // 84
pub const well_y: f32 = transport_y; // 216
pub const well_height: f32 = transport_height; // 36

// ------------------------------------------------------------- playlist

/// Playlist window (the matching rack unit below the deck): SAME width
/// as the player — the two units stack flush in the rack.
pub const playlist_width: f32 = window_width; // 512
pub const playlist_height: f32 = 440;
/// The rack's cap strip: same height as the player's enamel cap, and
/// the same skin-native close/minimize keys at its leading edge (the
/// window is chromeless too).
pub const playlist_header_height: f32 = 30;
/// Rack padding: the ledger, the cue strip's leading edge, and the
/// status strip all inset content by this much.
pub const rack_pad: f32 = 8;
pub const statusbar_height: f32 = 39; // 38 strip + 1 separator
/// The bottom deck strip: the loaded record's sleeve window plus the
/// up-next cues. Tall enough to case the sleeve with the strip's own
/// padding as its lip.
pub const cue_strip_height: f32 = 50;
pub const cue_strip_pad: f32 = 4;
/// The sleeve window: the current album's committed cover (or its
/// engraved fallback plate) at the strip's left.
pub const sleeve_size: f32 = cue_strip_height - cue_strip_pad * 2; // 42
pub const ledger_caption_height: f32 = 16;
pub const ledger_row_height: f32 = 27;
/// The hairline divider BETWEEN ledger rows (no per-row plates — the
/// bay is one glass table ruled by single hairlines; the first row has
/// no rule above it and the last none below).
pub const ledger_divider_height: f32 = 1;

/// Ledger columns (the rack is ONE flat song list at full width): the
/// track number slot, the growing title, then artist, the fixed cue
/// slot (the amber Q plate), and the right-aligned duration. Number and
/// duration slots case the pixel face's wider digits.
pub const ledger_number_width: f32 = 20;
pub const ledger_artist_width: f32 = 132;
pub const ledger_cue_width: f32 = 20;
pub const ledger_duration_width: f32 = 40;
/// Trailing in-row slot reserving the overlay scrollbar's lane (density
/// inset 3 + ~5.5 thickness): it keeps the duration digits clear of the
/// thumb while the rows keep their full width.
pub const ledger_scroll_lane: f32 = 2;

/// The ledger's scroll viewport, derived the way the playlist column
/// stacks: header, hairline, ledger (rack_pad + caption + gap + rows +
/// rack_pad), cue strip, status strip.
pub const ledger_viewport_height: f32 = playlist_height -
    playlist_header_height - 1 - cue_strip_height - statusbar_height -
    rack_pad * 2 - ledger_caption_height - gap; // 280 (ten whole rows)

// ------------------------------------------------------------- asserts

comptime {
    // The vertical rhythm lands exactly on the window edge.
    if (transport_y + transport_height + pad != window_height)
        @compileError("player rows do not fill the fixed window height");
    // The transport row fits its container with room for the queue badge
    // (widest label: "QUEUE 16") between the output block and the PL key.
    const queue_min: f32 = 80;
    if (knob_x + knob_width + gap + queue_min + gap > pl_x)
        @compileError("transport row overflows the fixed window width");
    // The ledger viewport folds on a whole row: N rows plus their
    // dividers fit with less than one row pitch of slack, so no row is
    // ever cut mid-glyph at the fold.
    const pitch = ledger_row_height + ledger_divider_height;
    const rows = @floor(ledger_viewport_height / pitch);
    if (ledger_viewport_height - rows * pitch > 2)
        @compileError("ledger viewport cuts a row at the fold");
}
