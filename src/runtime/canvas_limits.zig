// Per-view canvas budgets. Fixed, documented, loud: capacities are compile
// time constants sized for a dense desktop view, overflow errors name the
// budget, and the automation snapshot reports headroom (widget_nodes=N/MAX).
//
// Raised after measuring a real three-pane desktop app (sidebar tree +
// markdown detail pane + run surface): it spent more design effort
// budgeting nodes than building UI at the old 256-node cap. The
// widget-node budget quadrupled (256 -> 1024: the measured worst realistic
// three-pane view is ~500 nodes, so 1024 leaves comfortable headroom), and
// the frame-content budgets doubled (commands 1024 -> 2048, glyphs
// 4096 -> 8192, text 16 KiB -> 32 KiB: visible content per frame grows with
// surface density, not with the retained-node cap — a full-height monospace
// diff pane is ~7200 glyphs). Memory cost is fixed-capacity address space
// in the Runtime (in-place constructed, large fields left uninitialized),
// measured at 61.3 MiB -> 119.3 MiB (RuntimeView 1.12 MiB -> 2.65 MiB x 32
// view slots); pages are only touched as views use their capacity.
pub const max_canvas_commands_per_view: usize = 2048;
pub const max_canvas_gradient_stops_per_view: usize = 64;
// Raised 128 -> 2048 with icon-in-button and the 41-icon registry: vector
// icons are path commands, and a curated stroke icon lowers to ~10-25
// elements (folder 10, sun 21, settings 25). A realistic dense view — a
// sidebar of icon rows, an icon toolbar, a transport — shows ~40 icons,
// ~800 elements; the notes example hit the old 128 the moment its folder
// rows wore icons. 2048 also gives path-drawn charts real room (three
// 60-point polylines ~ 360 elements — the system-monitor sparklines had
// to become bars under the old cap). Memory is fixed-capacity address
// space: one PathElement is 28 B, so 2048 x 28 B = 56 KiB per view for
// each of the two per-view arrays (retained canvas + display-list
// scratch), x 32 view slots ~ 3.6 MiB total, pages touched only as views
// draw paths.
pub const max_canvas_path_elements_per_view: usize = 2048;
pub const max_canvas_glyphs_per_view: usize = 8192;
pub const max_canvas_text_bytes_per_view: usize = 32768;
// Retained packet commands per gpu-surface view: the host-side command
// dictionary that incremental (`patch`) presents edit, and the engine's
// per-view key+fingerprint mirror that derives those patches. Derived
// from the command budget because every retained command is born from
// exactly one display-list command — the command budget fails first,
// loudly, before this one can. The AppKit host pins the same value
// (NATIVE_SDK_PACKET_RETAINED_COMMAND_CAP in appkit_host.m); a frame past
// either side's cap presents FULL (and the host drops its retained
// state), never a partial dictionary. Engine memory is two u64 arrays:
// 16 B x 2048 = 32 KiB per view x 32 view slots = 1 MiB fixed address
// space; host memory is the decoded command dictionaries, realistically
// a few hundred KB for a dense view.
pub const max_canvas_retained_packet_commands_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_diff_changes_per_view: usize = max_canvas_commands_per_view * 2 + 1;
pub const max_canvas_render_animations_per_view: usize = max_canvas_commands_per_view;
// Sized to the widget loop-animation budget below plus caret headroom:
// every armed loop registers its command's bounds here so damage stays
// tight, and a segmented spinner alone registers one entry per segment.
// (Damage stays CORRECT past the cap — the general override diff in
// canvas_frame.zig recomputes changed-command bounds from the commands
// themselves — this registry just keeps the fast path covering them.)
pub const max_canvas_render_animation_dirty_bounds_per_view: usize = 72;
pub const max_canvas_render_overrides_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_pipelines_per_view: usize = 8;
pub const max_canvas_pipeline_cache_actions_per_view: usize = max_canvas_pipelines_per_view * 2;
pub const max_canvas_path_geometries_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_path_geometry_cache_actions_per_view: usize = max_canvas_path_geometries_per_view * 2;
pub const max_canvas_images_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_image_cache_actions_per_view: usize = max_canvas_images_per_view * 2;
pub const max_canvas_layers_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_layer_cache_actions_per_view: usize = max_canvas_layers_per_view * 2;
pub const max_canvas_resources_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_resource_cache_actions_per_view: usize = max_canvas_resources_per_view * 2;
pub const max_canvas_visual_effects_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_visual_effect_cache_actions_per_view: usize = max_canvas_visual_effects_per_view * 2;
// Text layout plans per frame. Raised because a real agent transcript
// (long wrapped chat turns in a 380px pane) put >512 draw_text
// commands in one frame and killed renders with TextLayoutPlanListFull,
// invisible outside one log line. Every plan is born from exactly one
// `draw_text` command in a display list bounded by the command budget, so
// deriving this from `max_canvas_commands_per_view` makes plan-list
// overflow structurally unreachable — the command budget fails first,
// loudly, at build time. Memory is scratch + per-view cache: the
// per-frame planning arrays are threadlocal (TextLayoutPlan 96 B x 2048 =
// 192 KiB, cache entries 96 B x 2048 = 192 KiB, cache actions 96 B x
// 4096 = 384 KiB — ~0.8 MiB once per thread, was ~0.2 MiB), and each
// RuntimeView retains one cache-entry array (96 B x 2048 = 192 KiB x 32
// view slots = 6 MiB fixed address space, was 1.5 MiB; pages touch only
// as views lay out text).
pub const max_canvas_text_layouts_per_view: usize = max_canvas_commands_per_view;
// Wrapped text lines across all of a frame's layout plans (the plan
// arrays above index into one shared line pool). Sized with the
// long-transcript shape in mind — a long agent transcript's wrapped lines
// are what blew the old shared cap: plans grow with COMMAND count, lines
// grow with WRAP count — a
// 32 KiB frame-text budget wrapped at ~50 chars/line in a narrow pane is
// ~650 lines, so 8192 (matching the frame glyph budget: a rendered line
// costs at least one glyph) gives >10x headroom over the worst measured
// real view. TextLine is 56 B: 56 B x 8192 = 448 KiB of threadlocal
// scratch (was 28 KiB at the old shared 512 cap). Overflow stays a loud
// `TextLayoutLineListFull` with a teaching diagnostic naming this budget.
pub const max_canvas_text_layout_lines_per_view: usize = 8192;

// Runtime-registered canvas images: decoded RGBA pixel buffers apps
// register under a caller-chosen ImageId and reference from image/icon/
// avatar widgets. Slots are runtime-wide (all views share the registry;
// the frame planner threads it into every view's `image_resources`), and
// the runtime owns the pixel copies — the app's source buffer is free the
// moment registration returns. The per-image ceiling is avatar/icon
// scale (512x512 RGBA8), not photo scale; oversized registrations and
// decodes fail loudly with `error.ImageTooLarge`.
pub const max_registered_canvas_images: usize = 16;
pub const max_registered_canvas_image_pixel_bytes: usize = 1024 * 1024;

// Runtime-registered font faces: TrueType bytes apps register under a
// caller-chosen FontId (>= canvas.min_registered_font_id) so their own
// typefaces resolve everywhere a font id rides — token overrides, text
// runs, atlas keys, fingerprints, both renderers. Slots are runtime-wide
// and the runtime owns the byte copies (an app may register from a
// transient buffer, not just @embedFile). Registration is startup-shaped
// and permanent for the runtime's lifetime: glyph atlas and text-layout
// caches key glyphs by (font id, glyph id) with no content fingerprint,
// so re-registering an id with different bytes would serve stale glyphs —
// re-use of a registered id fails loudly instead (`error.FontIdInUse`).
// The slot count covers a real brand set (a text family in 2-3 weights
// plus a display and a mono face); the per-font bound fits full CJK
// faces — the glyph pipeline is sized for them (canvas.font_ttf budgets)
// and the canonical Google Fonts TrueType builds measure 9.6 MB (Noto
// Sans JP), 10.4 (KR), 11.9 (TC), 13.6 (Noto Serif JP), and 17.8 (Noto
// Sans SC), so 24 MiB covers the largest measured with ~1.4x headroom.
// Latin UI faces stay a few hundred KB (the bundled faces are 71/116 KB).
// Memory is fixed-capacity address space in the Runtime: 8 x 24 MiB =
// 192 MiB, pages touched only as fonts register (and only as many pages
// as the file fills); oversized files and a ninth font fail loudly
// (`error.FontTooLarge` / `error.FontRegistryFull`). The gpu-surface
// registration side-channel bound
// (`platform.max_gpu_surface_font_bytes`) pins the same value.
pub const max_registered_canvas_fonts: usize = 8;
pub const max_registered_canvas_font_bytes: usize = 24 * 1024 * 1024;

// The retained widget-tree budgets (raised 256 -> 1024; see the header
// comment). `automation.snapshot.max_widgets_per_view`
// mirrors the node cap so snapshots never silently truncate widget
// enumeration; a test in canvas_widget_layout_tests.zig keeps them in
// lockstep.
pub const max_canvas_widget_nodes_per_view: usize = 1024;
pub const max_canvas_widget_semantics_per_view: usize = 1024;
// Raised from 2048 with the inline-span/markdown work: a rendered document
// retains its full plain text (paragraph bytes are stored once; span slices
// rebase into them) plus link payloads, and 2048 bytes could not hold a
// README-sized document. Raised again with the node-budget raise:
// a 1024-node view retains proportionally more text.
pub const max_canvas_widget_text_bytes_per_view: usize = 65536;
pub const max_canvas_widget_source_text_entries_per_view: usize = 256;
// Inline styled runs retained across all `.text` widgets of a view. Each
// span is a small struct (style flags + slices into the widget text
// bytes); per-paragraph capacity is `canvas.max_text_spans_per_paragraph`.
pub const max_canvas_widget_spans_per_view: usize = 1024;
// Declared native context-menu entries retained across all widgets of a
// view (labels live in the widget text bytes). Raised because the budget
// sums across every widget of the view, and a real desktop view hit 128
// fast — a 24-row sidebar with 4 items + separator per row, a detail-pane
// menu, and per-step ledger menus measured 124/128 before the app was
// finished. Quadrupled (128 -> 512)
// so declared menus scale with the 1024-node budget instead of becoming
// the next design-effort cliff. Memory cost is one 24-byte entry (a
// 16-byte label slice + enabled/separator flags) per slot: 24 B x 512 =
// 12 KiB per view (was 3 KiB at 128), x 32 view slots = 384 KiB total
// (was 96 KiB) of fixed-capacity address space; label bytes come out of
// the existing widget-text budget, and pages are only touched as views
// declare menus. Distinct from the platform's `max_context_menu_items`
// (32), which caps ONE presented menu (a single NSMenu popped at the
// pointer, truncated at presentation) — that stays small deliberately
// because a menu nobody can scan is a design bug, while this budget
// bounds the retained declarations across all widgets of the view.
pub const max_canvas_widget_context_menu_items_per_view: usize = 512;
// Window-drag region mirror per view (the Windows WM_NCHITTEST seam):
// drag-region rects plus the press-claiming exclusions inside them. A
// hidden-titlebar app has ONE header band and a handful of controls in
// it; 32 leaves room for split headers without retaining a second
// widget tree. Overflow drops the drag REGION rects beyond the cap
// (never the exclusions inside kept rects — see the collector), so a
// too-busy tree degrades to fewer draggable bands, never to stolen
// widget presses.
pub const max_canvas_widget_window_drag_regions_per_view: usize = 32;
// Chart series and points retained across all `.chart` widgets of a
// view. `Ui.chart` downsamples every series to
// `canvas.max_chart_points_per_series` (256) before it reaches the
// retained tree, so the points pool is sized as 64 maximal line/bar
// series: a dashboard of 16 charts x 3 series x 256 points fills it
// exactly, and realistic sparkline tiles (60 points) fit hundreds of
// series. Band series charge the pool twice (values + low), so 32
// maximal bands also fill it — the points budget can overflow before
// the series budget through bands, and the teaching error names the
// right cliff (pinned in canvas_budget_edge_tests.zig). Memory
// is fixed-capacity address space: series entries are ~64 B (slices +
// flags) x 64 = 4 KiB per view, points are 4 B x 16384 = 64 KiB per
// view, x 32 view slots = ~2.1 MiB total, pages touched only as views
// chart. Overflow is loud (`WidgetChartSeriesLimitReached` /
// `WidgetChartPointsLimitReached`), same contract as every widget budget;
// series labels ride the existing widget-text budget.
pub const max_canvas_widget_chart_series_per_view: usize = 64;
pub const max_canvas_widget_chart_points_per_view: usize = 16384;
// Chart x-axis category labels retained across all `.chart` widgets of
// a view: one entry per labeled sample (a slice header; the bytes ride
// the widget-text budget like series labels). `Ui.chart` drops labels
// on any downsampled series, so a labeled chart carries at most
// `canvas.max_chart_points_per_series` (256) of them — two maximal
// labeled charts fill the pool, a dashboard of month-scale charts (12
// labels) fits dozens. Entries are 16 B x 512 = 8 KiB per view.
// Overflow is loud (`WidgetChartLabelsLimitReached`).
pub const max_canvas_widget_chart_x_labels_per_view: usize = 512;
pub const max_canvas_widget_invalidations_per_view: usize = max_canvas_widget_nodes_per_view * 2 + 1;
// Scroll containers whose offset changed since the last app dispatch:
// entries are node ids, deduped, and the dispatched event reads the
// CURRENT scroll state, so coalescing wheel + kinetic steps into one
// pending entry is lossless. A view realistically has 1-2 concurrently
// moving scrollables; ids past the bound are dropped (the offsets still
// apply and repaint — only the observation Msg is skipped).
pub const max_canvas_widget_scroll_events_per_view: usize = 8;
// Split containers whose fraction changed since the last app dispatch
// (divider drag, keyboard adjustment, assistive increment/decrement):
// same shape as the scroll-event set above — entries are split node
// ids, deduped, and the dispatched event reads the CURRENT fraction, so
// coalescing several drag steps into one pending entry is lossless. A
// pointer drags exactly one divider at a time, so 4 covers every
// realistic view (nested splits still resize one seam per input); ids
// past the bound are dropped (the fraction still applies and repaints —
// only the observation Msg is skipped).
pub const max_canvas_widget_resize_events_per_view: usize = 4;
// Sliders whose value changed from a pointer gesture since the last app
// dispatch (rail click, thumb drag): same shape as the scroll- and
// resize-event sets above — entries are slider node ids, deduped, and
// the dispatched event reads the CURRENT value, so coalescing several
// drag steps into one pending entry is lossless. A pointer scrubs
// exactly one slider at a time, so 4 covers every realistic view; ids
// past the bound are dropped (the value still applies and repaints —
// only the observation Msg is skipped).
pub const max_canvas_widget_change_events_per_view: usize = 4;

// Anchored floating surfaces (widgets with `layout.anchor` set: anchored
// dropdown menus, popovers) mounted at once per view. Not a memory bound —
// the render and hit-test hoists scan the existing node array, no extra
// storage — but an honesty bound: realistically 1-3 anchored surfaces are
// ever open (a picker, maybe a nested submenu), each one costs the late
// z-pass and hit-test pre-pass a full-tree scan, and the likely way past
// 16 is an `anchor` accidentally inside a `<for>` body (one floating menu
// PER ROW). That mistake fails loudly at layout apply
// (`error.WidgetAnchoredSurfaceLimitReached`), never degrades every frame.
pub const max_canvas_widget_anchored_per_view: usize = 16;

/// Autofocus requests tracked per view for edge detection: the ids whose
/// SOURCE `autofocus` flag was set on the last applied layout, so a
/// rebuild only moves focus when the flag TURNS ON (or its widget
/// mounts), never while it merely stays on. 8 B x 16 x 32 view slots =
/// 4 KiB fixed address space; layouts declaring more than 16 autofocus
/// widgets track the first 16 (one focus target per rebuild wins
/// anyway).
pub const max_canvas_widget_autofocus_per_view: usize = 16;

/// COMMANDS carrying an engine-armed LOOPING render animation per view
/// (spinner rotations, per-segment spinner opacity loops, skeleton
/// pulses). Each armed command is one render animation slot plus one
/// dirty-bounds entry, sampled every frame while visible. An arc
/// spinner or skeleton arms one loop, but a segmented-register spinner
/// arms one loop PER SEGMENT (up to 15) — 64 covers a handful of
/// simultaneous indicators in either register; showing more at once is
/// a design smell, so the extras render static instead of degrading
/// the frame budget. Memory is one ObjectId per slot (64 x 8 B x 32
/// view slots = 16 KiB fixed address space).
pub const max_canvas_widget_loop_animations_per_view: usize = 64;

/// Concurrent runtime-driven LAYOUT tweens per view (split fractions
/// animating toward declared targets). Layout tweens are gesture-scale
/// — a pane collapse, a drawer slide — so a handful covers real apps;
/// a start past the budget snaps the value to its target instead of
/// dropping the state change (motion degrades, truth never does).
pub const max_canvas_widget_layout_tweens_per_view: usize = 8;

/// Nodes one disclosure tween may move per view: a disclosure flip
/// reflows the flipped item plus everything stacked below it (siblings,
/// content-hugging ancestors, and THEIR following siblings), and the
/// tween replays exactly that recorded reflow. A flip that moves more
/// nodes than this snaps to its target instead of animating a partial
/// pose (motion degrades under pressure, the state change always
/// lands).
pub const max_canvas_widget_disclosure_moves_per_view: usize = 256;

/// Disclosure widgets one rebuild may animate at once (an exclusive
/// accordion closes one section while opening another — two; a "expand
/// all" affordance can flip more). Flips past the budget snap the whole
/// rebuild: a half-animated, half-snapped reflow would tear.
pub const max_canvas_widget_disclosure_flips_per_view: usize = 8;

// Widget provenance (write-back's read half; `UiApp` retains it only in
// markup-interpreter builds, and only fills it when automation is on).
// One record per markup-authored widget of the main canvas view, so the
// cap mirrors the layout node budget -- layout rejects a deeper tree
// before the provenance pool can saturate, which a lockstep test pins.
pub const max_canvas_widget_provenance_records_per_view: usize = max_canvas_widget_nodes_per_view;
// Source files a provenance table can name: the markup root plus the
// import-closure cap (`canvas.ui_markup.max_imported_files`).
pub const max_canvas_widget_provenance_files: usize = 33;
// Per-entry path storage: `canvas.ui_markup.max_import_path_len` plus
// headroom for the watch-path prefix the app joins on.
pub const max_canvas_widget_provenance_path_bytes: usize = 240;
// Template instantiation chain depth a record reports (outermost use
// sites first). Deeper chains truncate the REPORT, never identity: four
// levels names the whole chain for every real component tree while
// keeping the record small enough to retain per widget.
pub const max_canvas_widget_provenance_chain: usize = 4;
// Rendered iteration-key text per record ("card-12/3"): keys beyond
// this truncate with an honest marker in the record.
pub const max_canvas_widget_provenance_key_bytes: usize = 48;

// Model-declared secondary windows per `UiApp` (`Options.windows_fn`
// descriptors — settings, about, inspectors), on top of the scene's main
// window. Sized for the classic desktop-client shape: one settings window,
// maybe an auxiliary panel or two, never a window per document (that is
// a different architecture — one Runtime hosts `platform.max_windows`
// = 16 windows total, and the startup window plus tool windows must all
// fit). The cost is NOT the runtime window (those are platform-capped):
// each UiApp slot retains two arena allocators whose high-water mark is
// that window's built view, plus a retained widget tree, and EVERY
// dispatched Msg rebuilds every open window's view — 4 keeps the
// rebuild-per-Msg bill visible-by-construction. Declaring more windows
// than this warns loudly (naming this budget) and ignores the excess;
// it never takes the render loop down.
pub const max_ui_app_windows: usize = 4;
