---
name: native-ui
description: Authoring guide for native-rendered Native SDK apps - declarative Native markup (.native) views plus Zig logic on the UiApp loop. Use when building or modifying native UI (widgets, layout, bindings, messages), writing .native files, wiring Model/Msg/update, testing markup views, or verifying a native app through the automation harness.
---

# Author native UI with markup + Zig

A native-rendered Native SDK app is a markup view plus Zig logic:

- `src/<view>.native` — the entire UI: elements, layout, bindings, message dispatch.
- `src/main.zig` — `Model` (plain struct), `Msg` (tagged union), `update(model, msg)`, and a `main` that hands them to `native_sdk.UiApp(Model, Msg)`.

The markup compiles to the same widget tree a hand-written `canvas.Ui(Msg)` builder view would produce: identical structural widget ids, identical typed handler table. Markup can never mutate state — it binds values and dispatches messages; all logic lives in Zig.

Editors highlight `.native` markup well in HTML mode — the default scaffold writes no editor config, so add `.vscode/settings.json` with `"files.associations": {"*.native": "html"}` yourself, or scaffold with `native init --full`, which writes it.

Start a new app with `native init` (zero-config: app.zon + src + assets, the CLI generates the build graph), or copy `examples/habits/` (smallest): change the name/id in app.zon and `assets/` copies verbatim — there are no build files to edit. The `native dev|test|build` verbs drive any app directory shaped this way.

## App wiring

```zig
const HabitsApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    // `create` heap-allocates the multi-MB app struct and constructs the
    // Model in place — neither ever rides the stack (avoid `App.init(alloc,
    // model, ...)`: its by-value Model is a stack-overflow trap once the
    // Model grows).
    const app_state = try HabitsApp.create(std.heap.page_allocator, .{
        .name = "habits",
        .scene = shell_scene,             // one window, one gpu_surface view
        .canvas_label = "habits-canvas",  // must match the ShellView label
        .update = update,
        .markup = .{
            .source = @embedFile("habits.native"),
            .watch_path = "src/habits.native", // dev hot reload; omit in release
            .io = init.io,
        },
    });
    defer app_state.destroy();
    app_state.model = initialModel(); // boot state: assign through the pointer
    try runner.runWithOptions(app_state.app(), .{ ... }, init);
}
```

(`create` requires every Model field to carry a default; the model starts as `.{}` and boot state is assigned through the returned pointer. Tests that instantiate the app per fixture should use `create`/`destroy` too — a runtime-built Model passed to `init` by value crashes the test stack once models get large.)

The runtime owns the loop: install on first GPU frame, presentation, resize, pointer/keyboard dispatch into `update` + rebuild. With `watch_path` set, editing the `.native` file while the app runs hot-reloads the view within ~2s, preserving model state and widget ids; parse failures keep the last good view and set `app_state.markup_diagnostic` (line/column/message).

**Release: compile the markup at comptime.** `canvas.CompiledMarkupView(Model, Msg, source).build` parses the `.native` source entirely at compile time and produces the identical tree (same ids, handlers, dispatch) with no parser in the binary; markup or binding mistakes become compile errors with line/column. Hand it to `.view`, and gate the runtime engine per build mode:

```zig
const dev = @import("builtin").mode == .Debug;
const App = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev });
const CompiledView = canvas.CompiledMarkupView(Model, Msg, @embedFile("habits.native"));
// options:
.view = CompiledView.build,
.markup = if (dev) .{ .source = ..., .watch_path = "src/habits.native", .io = init.io } else null,
```

With both set (dev), the compiled view renders until the watched file first changes, then the interpreter hot-reloads it. See `examples/habits` for the full pattern.

### Webview panes: canvas + live web content in one window

Declare the webview in the scene next to the gpu_surface (parent it to the canvas view), reserve its region with an empty panel carrying a semantics label, and let `Options.web_panes` snap the webview to that widget's layout frame while the model drives navigation:

```zig
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "app-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
    .{ .label = "preview", .kind = .webview, .parent = "app-canvas", .url = "https://example.com/", .x = 240, .y = 76, .width = 704, .height = 548 },
};
// view: ui.panel(.{ .grow = 1, .semantics = .{ .label = "preview-pane" } }, .{})
fn panes(model: *const Model, out: []App.WebViewPane) usize {
    out[0] = .{ .label = "preview", .anchor = "preview-pane", .url = model.url(), .reload_token = model.reload_token };
    return 1;
}
// options: .web_panes = panes,
```

URL changes navigate; bumping `reload_token` reloads the same URL (the CenterPane/Preview-tab shape). Pane URLs must pass `security.navigation.allowed_origins`. Panes reconcile against the runtime's live webview state on every rebuild and presented frame, so shell relayouts cannot detach them. `examples/canvas-preview` is the live reference; `zig build test-canvas-preview-smoke` verifies it.

### Menu-bar extra (status item)

`Options.status_item` installs a macOS `NSStatusItem` once, on the installing frame; its menu items dispatch commands through the same `on_command` mapping the toolbar and menus use (source `.tray`):

```zig
.status_item = .{ .title = "ZN", .tooltip = "My App", .items = &.{
    .{ .id = 1, .label = "Refresh", .command = "app.refresh" },
    .{ .separator = true },
    .{ .id = 2, .label = "Quit", .command = "app.quit" },
} },
```

For a LIVE menu-bar extra (an open-count badge in the title, a latest-items dropdown), add `Options.status_item_fn` — the `web_panes` pattern: consulted on install and after every rebuild, re-applied only when its output changed (title and menu patch independently; the static `status_item` keeps icon/tooltip). Format derived strings into the provided scratch; item `command`s dispatch through `on_command` exactly like static items:

```zig
fn statusItem(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
    const title = std.fmt.bufPrint(&scratch.title_buffer, "ZN {d}", .{model.open_count}) catch "ZN";
    scratch.items[0] = .{ .id = 1, .label = "Refresh", .command = "app.refresh" };
    var count: usize = 1;
    for (model.latest(), 0..) |issue, i| { // per-row commands: map "issue.select.N" in on_command
        scratch.items[count] = .{ .id = @intCast(10 + i), .label = issue.title, .command = issue.select_command };
        count += 1;
    }
    return .{ .title = title, .items = scratch.items[0..count] };
}
// options: .status_item_fn = statusItem,
```

Title updates retitle the live `NSStatusItem` button without re-creating it; platforms without a tray-title seam keep menu updates and log the title gap once.

### Native scrolling (macOS)

Zero app code: on macOS every non-virtualized `scroll` region — and every windowed virtual list (`ui.virtualList`), whose driver content size is the full virtual extent — is driven by an invisible `NSScrollView` — OS momentum and the system overlay scrollbar — while the engine renders the content. `widget.value` stays the offset of record, so the rebuild reconcile rule ("user offset survives rebuilds until the source offset changes"), automation snapshot offsets (`scroll=[offset=..]`), and `Options.sync` all work exactly as before; the engine-drawn scrollbar simply stops painting for natively driven regions. Programmatic scrolls still work: change the source offset (or scroll via keyboard/automation) and the runtime pushes it into the native scroller. GTK/Win32 and mobile embeds keep the engine's wheel physics unchanged. Nested-scroll saturation handoff (inner region exhausted, outer continues) is per-region native today: the inner region stops at its edge like a standalone scroller.

**Overscroll is off by default, per region, on both paths.** Scroll regions pin at their content edges — the native scroller gets non-elastic edges, the engine's wheel/kinetic physics clamp, and kinetic motion stops cleanly at the boundary. Bouncing is a per-region opt-in: `overscroll="rubber_band"` in markup (the `scroll` element only — the validator rejects it elsewhere with a teaching error) or `ElementOptions.overscroll = .rubber_band` in Zig views. The `ScrollPhysics.overscroll` design token (`ScrollPhysicsOverrides` in a theme) flips the app-wide default; per-region values override it, and `.none` pins a region regardless of the token. The rubber-band shape — excursion bound, resistance, spring-back rate — stays themable through the `rubberband_*` physics tokens.

### Context menus: one declared menu, platform-decided presentation

Authors write ONE menu; the platform decides how it presents. The default is the real OS context menu — on macOS a right/ctrl-click presents an `NSMenu` at the pointer and the selection dispatches the item's typed `Msg`. On hosts without a native menu presenter (Linux GTK and Windows Win32 today — their popover/`TrackPopupMenu` seams are documented future work), the SAME declared items present automatically as an anchored canvas surface floated against the declaring widget, with the standard anchored-surface behavior (Escape and outside-click dismiss, late z-pass, window clipping). Never two authored menus, never a canvas imitation where the OS menu exists.

Markup declares the menu as a `<context-menu>` element — a DIRECT child of the pressable element whose right-click it answers (a hit target, or an element with a bound `on-press`/`on-hold`). It is metadata, not content: it renders nothing in the row's flow. Children are `menu-item`s (`on-press` required, `disabled` optional, the text content is the label) and bare `<separator/>`s, with `if`/`else`/`for` around them to swap or repeat items — a menu whose items all evaporate at runtime simply declares no menu (the All Notes row pattern). Conditional MENUS are spelled as conditional ITEMS: the `<context-menu>` itself takes no attributes and cannot sit behind a structure tag. No submenus: the platform channel carries flat items (label, enabled, separator) only.

```html
<list-item on-press="open_note:{n.id}" label="{n.title}">
  <text grow="1">{n.title}</text>
  <context-menu>
    <if test="{n.deleted}">
      <menu-item on-press="restore_note:{n.id}">Restore</menu-item>
      <menu-item on-press="purge_note:{n.id}">Delete Permanently</menu-item>
    </if>
    <else>
      <menu-item on-press="copy_note_id:{n.id}">Copy</menu-item>
      <menu-item on-press="trash_note:{n.id}">Delete</menu-item>
    </else>
  </context-menu>
</list-item>
```

The Zig builder's mirror is `ElementOptions.context_menu` — per-widget items in the chrome-menu shape with typed messages:

```zig
ui.listItem(.{
    .on_press = Msg{ .select = entry.index },
    .context_menu = &.{
        .{ .label = "Open Section", .msg = Msg{ .select = entry.index } },
        .{ .separator = true },
        .{ .label = "Refresh Dashboard", .msg = .refresh },
    },
}, entry.title)
```

The deepest declaring widget on the hit route wins; disabled items and separators are fine (`enabled = false`, `.separator = true`). Zero-code defaults need no declaration: editable text fields present the standard Cut / Copy / Paste / Select All menu wired to the existing clipboard actions, and a selected static text presents Copy (these defaults are presenter-only — without an OS menu they degrade to the keyboard clipboard paths). Touch long-press is design-noted for the mobile embeds: the iOS host's under-slop `Pending` touch state is the timer seam, pending a secondary-button leg in the embed ABI and `UIEditMenuInteraction` presentation.

Automation drives the native path honestly: snapshots list every widget's declared items in invocation order (`context_menu=["Rename","Delete"]`, separators keep their slots, disabled items say so), `widget-context-press <view> <id>` performs the real secondary click (presenting the menu), and `widget-context-menu <view> <id> <item-index>` invokes an item — the selection dispatches as the same `context_menu_action` platform event a real pick produces (so it journals and replays), because the OS menu's tracking loop cannot be driven programmatically. Dead invocations fail by name (undeclared menu, index out of range, separator slot, disabled item). `examples/notes` row menus and `examples/gpu-dashboard` nav rows carry live menus; `zig build test-example-notes`, `test-example-gpu-dashboard`, and the runtime context-menu suite verify dispatch, the fallback surface, and the verb.

## Elements

| Markup | Widget | Notes |
| --- | --- | --- |
| `row`, `column` | flex containers | main axis horizontal / vertical |
| `stack`, `panel`, `card` | overlay containers | children stack on top of each other — `gap` can never space them and is a validation error (put a `column`/`row` inside for flow) |
| `scroll` | scroll_view | wrap multiple children in a `column` inside it |
| `list`, `grid` | list, grid | vertical stack / cell grid |
| `tabs`, `toggle-group`, `button-group`, `radio-group`, `breadcrumb`, `pagination` | row containers | children flow horizontally (tab buttons, toggle-buttons, radios, ...) |
| `table` > `table-row` > `table-cell` | table, data_row, data_cell | rows only inside a table, cells only inside a row (for/if wrappers are fine); cells are text leaves, dispatch with `on-press` |
| `dropdown-menu` | dropdown_menu | vertical menu surface; children are `menu-item`s. `anchor="below\|above"` floats it against its PARENT's frame (see Pickers): late z-pass above the whole tree, window-clipped, auto-flipping at the window edges, zero flow space. Pair with `on-dismiss` |
| `accordion` | accordion | header via `text` attr; children show while `selected`, dispatch `on-toggle` |
| `alert`, `bubble` | surfaces | `alert` title via `text` attr; children stack inside. `bubble` hugs its message up to 80% of the thread (`ghost` exempt; explicit `width` wins) and takes one `<reactions>` child — the reaction pill straddling its bottom edge, one text run, dock via `text-alignment` (default `end`); `text=` on bubble itself is a teaching error (that channel belongs to the pill). Grouped runs are spacing, not vocabulary: 8 gap within a sender's run, 32 between turns |
| `dialog`, `drawer`, `sheet` | modal surfaces | rendered in place — title via `text` attr, wrap in `<if>` to show conditionally |
| `resizable` | resizable | engine-managed drag handle; `width` sets the initial width |
| `split` | split | two-pane horizontal splitter: exactly two element children (nest splits for more panes), the engine synthesizes the draggable divider between them. `value` binds the model-owned first-pane fraction (0 lays out at 0.5), `on-resize` names an f32 Msg variant dispatched with every applied fraction (echo it back through `value` — see Splitters), `min-width` on the panes bounds the drag, `gap` sets the divider band thickness. The divider is focusable: Left/Right (Shift for bigger steps) adjust, Home/End jump to the clamp edges |
| `tree` | tree | disclosure-tree container (vertical flow): descendant rows carrying `role="treeitem"` — at ANY nesting depth — form one roving keyboard focus set with the ARIA tree keymap. Up/Down walk visible rows (selection follows focus through each row's `on-press`), Left collapses an expanded row or moves to the parent row, Right expands a collapsed row or moves to the first child row, Home/End jump to the edges, Enter/Space activate. Expandable rows bind `expanded` and `on-toggle`; the model owns selection and expansion (collapsed children are simply not rendered) |
| `text`, `badge`, `tooltip` | text leaves | text content, `{}` interpolation allowed; `text` line policy via `wrap` (`"true"` word-wraps; `"false"`/unset paint one honest line, overflow eliding by default — `overflow="clip"` opts out), and `text` alone takes the typography rungs `size="heading"`/`size="display"` (themable token steps above title — section headings, hero stats, timer numerals). `tooltip` with `anchor="above\|below"` floats against its parent (the stack wrapping trigger + tooltip, the dropdown pattern) and the RUNTIME owns its visibility — hover intent on the trigger: shows after `tooltip-delay` ms (default 600; `"0"` = instant) and immediately on keyboard focus; hides on leave, focus departure, Escape, or a press of the trigger (a press also closes the warm window), and a shared 400ms warm window after a pointer-hovered tooltip hides on leave (the only hide that warms) shows the next trigger's tooltip instantly; the model never hears hover. These are shadcn/ui's defaults (Base UI). Without `anchor` it stays a static leaf that paints whenever the view renders it |
| `text` > `span` | inline styled runs | mixed-style text in ONE wrapped paragraph: span children style runs with `weight="regular\|medium\|bold"`, `mono`, `italic`, `scale` (a positive multiplier on the paragraph's base size — inline headings, hero stats), `underline`, `foreground` (token name); `{bindings}` interpolate inside spans; whitespace between runs collapses to a single space (none = the runs abut); spans do not nest, take no events, and the paragraph announces as one text run — see "Rich text" |
| `button`, `toggle-button`, `list-item`, `menu-item`, `toggle`, `switch`, `select`, `avatar` | text-bearing controls | label is the text content; `button`, `toggle-button`, `list-item`, and `menu-item` also take `icon="save"` — a vector icon drawn inline (buttons/toggle-buttons before the label, icon-only when the content is empty: add a `label`; list/menu items as a leading slot), ONE hit target whose icon follows the element's enabled/disabled tint (no overlay stacking, no duplicated `on-press`); tab strips are `toggle-button` children, so tabs get icons this way; `select` shows `placeholder` while empty and dispatches `on-press`; `avatar` renders initials, or a runtime image via `image="{binding}"` (see the Images section) |
| `checkbox`, `radio`, `slider`, `progress` | value controls | `checked`, `value` (a 0..1 fraction on slider and progress; progress clamps out-of-range values at render, never an error); the checkbox/radio label rides `text="..."` — these are not text-bearing elements, so text content is a teaching error (`label=` alone names one for accessibility without a visible label); a slider's `value` follows the source when it MOVES (model-driven progress renders every rebuild) and keeps the user's drag while the source replays the same value — use `slider` for seek bars, `progress` for display-only; a markup slider's `on-change` dispatches a PLAIN Msg with no value payload — mirror the applied value into the model with `Options.sync` (the Zig builder's `on_value = Ui.valueMsg(.tag)` does deliver the applied f32) |
| `text-field`, `input`, `search-field`, `combobox`, `textarea` | text entry | `placeholder`; edits via `on-input`, enter via `on-submit` on single-line kinds; in a `textarea`, Enter (and Shift+Enter) inserts a newline and `on-submit` dispatches on primary+Enter (cmd on macOS, ctrl elsewhere); `search-field` carries a built-in trailing clear affordance whenever it holds text (press the x, or Escape while focused — both clear through the text-edit path, so `on-input` hears it; no attribute, no external Clear button needed) |
| `status-bar` | status bar | text leaf: content only, no children |
| `separator`, `spacer` | separator, flexible space | `separator` is axis-aware: a horizontal rule in a `column`, a thin vertical divider in a `row`; give `spacer` a `grow` |
| `skeleton`, `spinner` | loading leaves | size `skeleton` with `width`/`height` |
| `icon` | vector icon leaf | `name` picks the icon: a bare literal is a curated built-in stroke icon (compile-checked; 49 names: search, plus, x, x-circle, check, check-circle, chevron-up/down/left/right, arrow-up/down/right, menu, panel-left, panel-right, settings, terminal, wrench, trash, edit, copy, external-link, play, pause, skip-back/forward, shuffle, repeat, music, volume, info, alert, download, save, folder, folder-open, file-text, sun, moon, eye, clock, git-pull-request, git-merge, git-branch, circle-dot, archive, refresh-cw, send); `app:<name>` reaches an icon the app registered at boot with `canvas.icons.registerAppIcons` (declare the table as `pub const app_icons` on the app root so `native check` verifies the name against the model contract), and one `{binding}` defers the choice to model data - an unknown resolved name draws the missing-icon fallback (a slashed circle) with a Debug warning naming the value, never a silent gap; tint with `foreground`, size with `width`/`height` |
| `media-surface` | media surface leaf | composites a texture produced OUTSIDE the widget tree (video decoder, camera, an external renderer like mpv) into the layout like any widget — clipped, z-ordered, rounded. `surface="{binding}"` (required) binds the model-owned u64 surface id a Zig-tier producer targets (`runtime.acquireMediaSurfaceProducer` pushes RGBA8 frames, latest-wins, paced by the presented-frame clock; 0 = unbound, draws nothing; usable ids are nonzero values below the reserved bit 63). No intrinsic size — give it `width`/`height` or `grow`; display-only (presses fall through); `label` it (pictorial content). Texture contents are presentation chrome: goldens, reference screenshots, and session replay show the deterministic id-derived placeholder, never producer frames |
| `markdown` | rendered markdown subtree | leaf; `source` is one `{binding}` — see "Markdown in markup" |
| `stepper` > `step` | composite stage track | `active="{index}"` (required) derives each step's completed/active/pending state; steps are text leaves (no attributes) joined by connectors; stepper also takes `key`, `global-key`, `label` |
| `timeline` > `timeline-item` | composite ledger list | items only inside a timeline (for/if fine); items are leaves — `title` (required), `description`, `meta`, `indicator`, `variant`, `connector="false"` on the last item, `selected`; `on-press` makes the whole item pressable with a trailing chevron |
| `chart` > `series` | composite data chart | series only inside a chart, and only series (the set is static — data varies through bindings); each series is a leaf — `values="{binding}"` (required) names a model `[]const f32` iterable, `kind` is `line`/`area`/`bar` (literal), `color` a token name, `label` the semantics name; chart takes `y-min`, `y-max`, `grid-lines`, `baseline`, `x-labels`, `y-labels`, `hover-details`, `stroke-width`, box options, `label` — see "Charts" |
| `context-menu` | consumed by its parent | right-click menu on its DIRECT parent (a hit target or an element with `on-press`/`on-hold`); metadata, never a flow child. Children: `menu-item`s (`on-press` required, `disabled` optional, no `icon`) and bare `separator`s, with `if`/`else`/`for` around them. Attribute-less; presents natively where the host has a menu presenter, as an anchored surface elsewhere — see "Context menus" |
| `input-group` > `textarea` + `input-group-actions` | composite grouped input | the composer shape: ONE bordered field wrapping exactly one `textarea` (first — document order is focus order) plus an optional `input-group-actions` row of controls inside the same border. The group wears the focus ring for its focused descendant and the textarea's own chrome dissolves automatically, so the whole group reads as one field; the textarea keeps its full behavior (`text`, `placeholder`, `on-input`, `on-submit`, `autofocus`). Group takes `label`, `width`, `height`, `min-width`, `grow`, `key`, `global-key`; the actions row takes `gap` and holds ordinary elements (`if`/`else`/`for` work — swap send for stop while streaming) — put a `<spacer grow="1"/>` between leading and trailing controls (`Ui.inputGroup`/`Ui.inputGroupActions` are the Zig-view equivalents) |

Not markup-expressible (deliberately — write these as Zig view functions with `canvas.Ui`): `image` (needs `ImageId` pixel references, runtime-registered — see the Images section), `icon_button` (`<button icon="...">` with empty content is the declarative icon button), `data_grid` (per-column cell templates), `popover`/`menu_surface` (anchored to runtime geometry), `segmented_control` (use `tabs`/`toggle-group`: `<button>` children of `<tabs>` lower to segmented triggers automatically, so the active tab lifts per the house treatment). Charts ARE expressible: `<chart>` with `<series values="{binding}">` children binding model f32 iterables — see the Charts section (`.band` series and dynamic series composition stay with `ui.chart`). Built-in vector icons ARE expressible: `<icon name="search"/>` (closed, compile-checked name set; `Ui.icon` is the Zig-view equivalent). App-authored icons: `canvas.svg_icon.parseComptime(@embedFile("icons/logo.svg"))` parses any SVG in the common 24x24 stroke-icon dialect at comptime; register the parsed table once at boot with `canvas.icons.registerAppIcons(&table)` and draw by name via `ui.appIcon(.{...}, "logo")` or `ElementOptions.icon` — registered names render exactly like built-ins on every draw path. Markup `<icon>`/`<button icon>` stay built-in-only (the compiled engine validates names at comptime, where runtime registrations cannot exist — engine parity). The one image binding markup DOES carry is the avatar's: `<avatar image="{user_image}">CT</avatar>` binds a `u64` ImageId model field/fn (the id is just model data; 0 keeps the initials fallback) — the embedded-asset exclusion stays.

## Attributes

Layout: `gap` (flow containers only — stacking containers `stack`/`panel`/`card`/`alert`/`bubble`/`dialog`/`drawer`/`sheet`/`resizable` layer their children, so `gap` there is a validation error, not silence: wrap the children in a `column`/`row` inside; on `split` it sets the divider band thickness), `padding` (uniform), `grow`, `width`, `height` (definite: the element is exactly that size — intrinsic content neither shrinks nor silently overflows it; `resizable` treats `width` as the initial width), `min-width` (a floor WITHOUT `width`'s definite max — the element may grow past it but never shrink below; on split panes it bounds the divider drag), `wrap` (`text` only: `wrap="true"` word-wraps at the width the element receives and reserves the wrapped height in columns; `wrap="false"` and unset are honest single-line — one line whose overflow follows `overflow`), `overflow` (`text` only, a teaching error elsewhere: what a single line does with content that does not fit — `ellipsis`, the default, elides behind a trailing … measured with the same metrics paint uses, right for width-constrained list-row titles; `clip` hard-cuts at the frame for fixed-format content like a duration column where "1…" beats nothing; there is deliberately no overflow-visible), `text-alignment` (start|center|end — text leaves, status bars, surface titles; controls that own their label placement ignore it), `columns` (`grid` only: fixed column count, omit for the derived near-square grid; a teaching error elsewhere), `main` (start|center|end|space_between), `cross` (stretch|start|center|end), `virtualized`, `virtual-item-extent`, `anchor` (`dropdown-menu` and `tooltip`, literal `below`/`above`: floats the surface against its parent instead of the flow — auto-flips when the preferred side does not fit, height clamps to the chosen side, x clamps into the window; an anchored tooltip's visibility is runtime-owned hover intent, unlike the model-owned dropdown), `anchor-alignment` (with `anchor`: `start`/`end`/`stretch` — stretch also widens the surface to at least the anchor's width, the select-menu look), `anchor-offset` (with `anchor`: literal gap in points, default 4), `tooltip-delay` (`tooltip` only, beside `anchor` — a teaching error elsewhere or without it: hover-intent show delay in ms, default 600, `"0"` = instant; keyboard-focus reveals are always immediate), `overscroll` (`scroll` only, a teaching error elsewhere: `none` pins the region at its content edges — the shipped default via the `ScrollPhysics.overscroll` token — `rubber_band` lets it bounce past them on both the engine and native paths, `default` follows the token).
Appearance/state: `variant` (default|primary|secondary|outline|ghost|destructive), `size` (the control scale default|sm|lg|icon on every sized element; on `text` also the typography rungs heading|display — named typography token steps (`heading_size` 28, `display_size` 48, themable like every token) for section headings and hero stats/timer numerals. The two axes stay apart: heading/display on a control is a teaching error naming text as their home, unknown values list the vocabulary, and numeric sizes are refused by design — retheme the typography tokens to move the whole scale), `disabled`, `checked`, `selected`, `value`, `placeholder`, `icon` (`button`, `toggle-button`, `list-item`, `menu-item`: vector icon drawn inline — buttons/toggle-buttons before the label, list/menu items as a leading slot; a teaching error anywhere else. A built-in name, `app:<name>`, or one `{binding}` resolving to such a name). **One size register per row**: every control class shares the control height at a given register (default 36, sm 31.5, lg 40.5 before density), so a toolbar/filter row reads as one height exactly when every control in it carries the SAME `size` — mixing `size="sm"` buttons with a default field renders two heights in one row, and hand-sized pressable panels (`height="30"`) never land on the scale; compose rows from real controls at one register.
Focus: `autofocus` (focusable controls only — a teaching error elsewhere): moves keyboard focus to the element when it MOUNTS or when the bound value turns on, edge-triggered so holding it true never re-steals focus from the user. The TEA way to focus an editor on note-create (`<text-field autofocus="{editing}" ...>` or mount the field under an `<if>` with `autofocus="true"`; Zig views use `ElementOptions.autofocus`) and to give keyboard-first apps their first focus without a click.
Semantics: `role` (listitem, treeitem, button, ...; `treeitem` also makes the row part of its tree's roving keyboard focus set), `label` (accessible name — it REPLACES the element's text content as the announced name, so snapshot greps and screen readers see the label, never the text; don't `label` an element whose visible text you grep for), `expanded` (tree rows: disclosure state, model-owned — omit on leaves). Accessible names are ENFORCED: an interactive control with no text content, no `text=`, and no `label=` is a validation error (icon-only controls need `label`; text-entry controls need `label` or `placeholder`), unknown/misused literal roles are errors (`role="tree"` on a text leaf can never hold rows), unnamed avatars and labels duplicating the text content are warnings (`label=""` marks an image decorative). Zig-built trees get the same discipline from `canvas.expectA11yAuditSweepClean` (missing names as the bridges would announce them, focusables clipped out of keyboard reach, identically labeled siblings) — adopt it next to the layout sweep.
Identity: `key` (sibling-scoped), `global-key` (parent-independent — use for items that move between containers, e.g. board cards; ids then survive reparenting).
Window chrome: `window-drag="true"` (Zig: `.window_drag = true`) marks the element as a window-drag surface for hidden-titlebar windows — pressing its background or plain text/icons inside moves the WINDOW (drag starts only on actual movement), double-click zooms per the OS convention, and press-claiming children (buttons, fields) stay fully interactive via the ordinary press fall-through. macOS-only; elsewhere the press is dead space. See "Hidden titlebar" below.
Render channel (Zig-only, no markup attributes): `ElementOptions.opacity` and `ElementOptions.transform` wrap the element's emitted commands without reflowing siblings — the defaults (1, identity) emit nothing, opacity 0 culls painting (pair with `disabled` when fading interactive content), and a transform moves both rendering and pointer hit-testing while accessibility frames stay at the layout frame. Pair with `UiApp.Options.animations` for tweening.

Numbers are plain (`gap="12"`), booleans are `true`/`false` or a binding.

When children's minimum sizes exceed their container, debug builds log a `zero_canvas_layout` diagnostic naming the container, axis, and overflow in pixels — flex overflow is never silent. In Zig views, `.gap` on a stacking kind (`ui.panel(.{ .gap = 8 }, ...)`) logs a `zero_canvas_ui` warning in debug builds with the same lesson — it never fails the build.

### Chips: exclusive selection with `selected=`

The chip pattern — an exclusive group where the model owns which one is active — is a `toggle-group` of `toggle-button`s (or plain `button`s) whose `selected=` binds the model:

```html
<toggle-group gap="2" label="Theme">
  <for each="theme_prefs" as="p">
    <toggle-button size="sm" selected="{p == theme_pref}" on-toggle="set_theme:{p}">{p}</toggle-button>
  </for>
</toggle-group>
```

A `toggle-button` whose source asserts `selected` (this rebuild or the previous one) is model-driven: the source wins over the runtime's retained toggle on every rebuild, so exactly the model's selection is active — pressing a chip dispatches the Msg, the model moves the selection, and the old chip deactivates. Without a `selected=` that ever asserts, a `toggle-button` is uncontrolled: the runtime retains its pressed state across rebuilds (the multi-select formatting-bar case — bold/italic chips with zero app wiring). `button` with `selected=` is always model-driven (buttons never retain state) and dispatches `on-press`; `toggle-button` dispatches `on-toggle` (its activation is the toggle intent — an `on-press` there never fires). Model-driven chips need a handler that actually moves the model: a chip whose Msg is ignored keeps its retained press until the model asserts its `selected=`.

### Pickers: select is the trigger — compose the options as an ANCHORED dropdown

`select` and `combobox` are trigger controls, not complete pickers: `select` renders the closed dropdown shape (current value as content, `placeholder` while empty, `on-press` to open) and `combobox` is a text entry with a menu chevron — neither owns an options list. There is no `options=` attribute (the closed grammar has no list-valued attributes — list-shaped vocabulary is element children, the way `<context-menu>` declares its items); the options ARE the composition — a `dropdown-menu` of `menu-item`s under an `if`, beside the trigger inside a `stack`, floated with `anchor`:

```html
<stack>
  <select placeholder="Pick a repo" text="{current_repo}" on-press="toggle_repo_picker"/>
  <if test="{repo_picker_open}">
    <dropdown-menu anchor="below" anchor-alignment="stretch" on-dismiss="close_repo_picker">
      <for each="repos" key="name" as="r">
        <menu-item on-press="pick_repo:{r.name}" selected="{r.name == current_repo}">{r.name}</menu-item>
      </for>
    </dropdown-menu>
  </if>
</stack>
```

How the pieces fit, all model-owned (TEA):

- **Open state is the model's.** `toggle_repo_picker` flips the bool; the surface exists only while the `if` renders it. There is no hidden engine open flag.
- **`anchor` floats the menu.** The dropdown positions against its PARENT's frame (the `stack`, sized by the trigger): below it by default, flipping above when it doesn't fit and the other side has more room, height clamped to the chosen side, x clamped into the window. It consumes NO space in the flow (siblings never reflow), paints in a late z-pass above the whole tree, and escapes every ancestor scroll/clip region — window-clipped, not pane-clipped. `anchor-alignment="stretch"` widens it to at least the trigger's width (the select look).
- **`on-dismiss` closes it model-side.** Escape and a click outside the menu dismiss the surface and dispatch the Msg; `close_repo_picker` clears the bool. Escape works even when the trigger took no focus (a plain-text crumb): with no relevant focus chain it dismisses the topmost mounted anchored surface. The engine hides the surface immediately (the optimistic echo), and the next rebuild's source tree is truth — a model that keeps `open` true gets it back. Clicking the TRIGGER while open never double-fires: the anchor region owns its surface's toggling, so only `toggle_repo_picker` dispatches.
- **Items close on pick.** `pick_repo` sets the value AND clears the open flag — a click inside the surface never dismisses.
- **Keyboard**: once focus is in the menu (tab into it), tab wraps inside the surface (the floating focus scope) and Enter/Space activate items; Escape dismisses from the trigger or the menu.
- **Automation sees everything**: the floating menu and its items appear in widget snapshots at their real frames and `widget-click <item-id>` works while it is open.

`combobox` composes the same way (the model filters the `for` source as the user types via `on-input`). The Zig mirror is `ElementOptions.anchor`/`anchor_alignment`/`anchor_offset` + `on_dismiss` on a `dropdown_menu` (or `popover`/`menu_surface`, which stay Zig-only) built with `ui.eachCtx` for the options. Budget: at most 16 anchored surfaces may be mounted per view (`max_canvas_widget_anchored_per_view`, loud `error.WidgetAnchoredSurfaceLimitReached`) — an `anchor` inside a `<for>` body is almost always a mistake.

### Splitters: split panes with a model-owned fraction

`split` is the resizable two-pane seam: exactly two element children, and the engine synthesizes the draggable divider between them (resize cursor, focusable, ARIA separator whose value is the fraction). The fraction is MODEL-OWNED — the runtime applies each drag/keyboard step as an optimistic echo, dispatches `on-resize` with the applied fraction, and the model echoes it back through `value` so the next rebuild lays the panes exactly there:

```html
<split value="{sidebar_split}" on-resize="sidebar_resized">
  <column min-width="150">…sidebar…</column>
  <split value="{list_split}" on-resize="list_resized">
    <column min-width="220">…list…</column>
    <column min-width="280">…editor…</column>
  </split>
</split>
```

- **`on-resize` names an f32 Msg variant** (`sidebar_resized: f32`); `update` stores it (`model.sidebar_split = fraction`). The delivered fraction is the value the runtime already applied and clamped, so echoing it never fights the reconcile.
- **`min-width` on the panes bounds the drag** — the divider clamps so neither pane shrinks below its floor, on drag, keyboard, and layout alike.
- **Uncontrolled works too**: without `on-resize`, the divider position survives rebuilds under the source-wins reconcile (a source-side `value` change wins), but pane CONTENT lays out at the declared fraction until the model echoes — bind the handler for the exact controlled loop.
- **Keyboard**: Tab reaches the divider; Left/Right step the fraction (Shift for 2x), Home/End jump to the clamp edges. Automation drives it with `widget-drag`/`widget-key`, and snapshots show the divider as `role=separator` with the fraction as its value.
- **Animated resize**: `resize-duration="180"` (milliseconds, `split` only — a teaching error elsewhere) makes the bound `value` a target — a model-driven move (a collapse toggle, not a drag echo) eases the rendered fraction there one presented frame at a time instead of snapping, dispatching the same `on-resize` echoes a drag would; `resize-easing` (`linear`/`standard`/`emphasized`/`spring`) shapes the ramp and needs the nonzero duration beside it (alone it is a teaching error), and reduced-motion appearances snap automatically — apps declare nothing extra.
- Three panes = nested splits, as above. More than two children is a validation error (put conditional content inside a pane).

### Trees: disclosure rows with the ARIA tree keymap

`tree` turns a rail of pressable rows into a keyboard-navigable disclosure tree. Rows are ROLE-driven: any pressable element carrying `role="treeitem"` — at any nesting depth under the tree — joins one roving focus set:

```html
<tree gap="2" label="Folders">
  <for each="folderRows" key="id" as="f">
    <panel role="treeitem" expanded="{f.expanded}" on-press="select_folder:{f.id}" on-toggle="toggle_folder:{f.id}" label="{f.label}">
      <row gap="8" cross="center"><icon name="folder"/><text grow="1">{f.name}</text></row>
    </panel>
  </for>
</tree>
```

- **Up/Down walk the visible rows** in tree order, across nesting levels. Selection follows focus: each move dispatches the landed row's `on-press`, so the model owns the selection exactly like a click.
- **Left/Right are disclosure keys**: Left on an expanded row dispatches its `on-toggle` (collapse); on a collapsed row or leaf it moves focus to the PARENT row. Right on a collapsed row dispatches `on-toggle` (expand); on an expanded row it moves to the first child row.
- **Home/End** jump to the scope's first/last row; **Enter/Space** activate (`on-press`).
- **Expansion is model-owned**: expandable rows bind `expanded` (omit it on leaves) and the model renders child rows only while expanded — collapsed subtrees are simply not in the tree, so "visible rows" needs no engine bookkeeping. Flat rails (the notes folder list) are honest trees of leaves: Up/Down/Home/End/Enter work, Left/Right are inert.
- Single-select: selecting a row clears the previous selection across the WHOLE tree scope (rows nest, so this is not per-parent).

### Press-and-hold: on-hold

`on-hold` is the click-acts, hold-reveals menu-button shape — a control that acts on click and offers more on hold: a pointer held ~350 ms dispatches the hold Msg (the release then presses nothing), a quick click dispatches `on-press` as usual, and a right/ctrl-click whose route offers no context menu dispatches the hold Msg immediately (a declared `<context-menu>` always wins the right-click — hold is the primary-button gesture, not the context-menu channel). Like `on-press`, binding it makes any element pressable. The breadcrumb-switcher pattern: `on-press` selects the crumb, `on-hold` opens an anchored `dropdown-menu` of its siblings — an app-designed hold-reveal surface, distinct from the row's right-click menu. Both legs are live-drivable: `native automate widget-hold <view> <id>` runs the pointer+timer gesture, `widget-context-press <view> <id>` the secondary click.

```html
<button on-press="select_crumb:{c.id}" on-hold="open_crumb_menu:{c.id}">{c.name}</button>
```

### Select, then act: double press and row-level Enter

The desktop list convention — click selects, the primary action (open the record, play the track) rides the double click and Enter — is two bindings on the same row. `on_double_press` (Zig views only — `ElementOptions.on_double_press`; the closed markup grammar has no double-click event) dispatches on the release whose runtime-derived click count reached 2, in place of a second press: the first click still dispatches `on_press` on its own release, so the pairing is additive, never a delay — no press timer, no swallowed first click. Like `on_press`, binding it makes the element a hit target; a widget with no double handler treats a double click as two single clicks. The keyboard mirror is row-level Enter: on a `list-item`, `on-submit` grows a second home beyond text entry — with a submit handler bound, plain Enter on a keyboard-focused row dispatches it as the row's PRIMARY action while Space keeps the select activation (`on-press`); rows without one resolve Enter as select, unchanged. It works from markup (`<list-item on-press="select_track:{t.id}" on-submit="play_track:{t.id}">{t.title}</list-item>`) and Zig views alike, and tests drive it through `msgForKeyboard` (an Enter event resolves the submit handler, Space the press). `examples/soundboard`'s track rows are the live reference: `on_press` select, `on_double_press` play, `on_submit` play.

## Widget budgets and virtualization

Every view has fixed per-view capacities (`src/runtime/canvas_limits.zig`): **1024 retained widget nodes** (`max_canvas_widget_nodes_per_view` — the budget that matters for tree design; semantics and spans match it), 64 KiB retained widget text, **512 declared context-menu items** summed across all widgets of the view (`max_canvas_widget_context_menu_items_per_view` — separators count as items), **64 chart series / 16384 chart points** summed across all charts of the view (`max_canvas_widget_chart_*` — `ui.chart` downsamples every series to 256 points, so this is 64 maximal series or hundreds of sparklines), and per-frame content budgets (2048 commands, 8192 glyphs, 32 KiB frame text, 2048 path elements shared by icons and charts). Overflow is loud: `error.WidgetLayoutListFull` / `error.WidgetNodeLimitReached` / `error.WidgetContextMenuLimitReached` / `error.WidgetAnchoredSurfaceLimitReached` (at most **16 anchored floating surfaces** mounted per view — `max_canvas_widget_anchored_per_view`) fail tests under the harness's propagate policy and log a teaching diagnostic naming the budget in production (the app degrades to the previous frame). Watch headroom without overflowing: automation snapshots report `widget_nodes=N/1024 widget_semantics=N/1024 context_menu_items=N/512` on every gpu_surface view line.

Budget rules of thumb: 1024 nodes is roomy for a three-pane desktop app (~500 nodes measured for a dense sidebar + markdown detail + run surface), but node count scales with what is MOUNTED, not what is visible — so bound every unbounded collection:

- **Dataset-scale uniform rows (feeds, logs, tables of thousands+): use the WINDOWED virtual list** (`ui.virtualWindow` + `ui.virtualList`, Zig views — see the next section). The view builds only the visible window; the runtime owns the scroll; budgets stay viewport-sized at 100k items.
- `virtualized` on `scroll`/`list`/`grid`/`table` (with `virtual-item-extent` for fixed-extent items) lays out only the visible window + overscan; a 10,000-item list materializes ~viewport/extent nodes. It bounds NODES, not your source data: the builder still walks every item, so it suits row sets the model already holds (hundreds). Legacy virtualized containers without a declared item count are app-driven for scrolling (wheel offsets do not mutate them).
- For non-uniform content (chat transcripts, ledgers, diffs), keep a bounded window in the model and slide it with `on-scroll` (see Messages) or explicit paging — the window follows the scrollbar instead of mounting everything.
- Remember multi-node rows multiply: a 4-node row × 50 mounted rows is 200 nodes before chrome.

## Windowed virtual lists (Zig views): 100k rows, viewport-sized budgets

The honest infinite-scroll primitive. The RUNTIME owns the viewport math (retained scroll offset + viewport → visible index range, from a fixed per-item extent), the MODEL owns the data, and the view is the seam between them: ask `ui.virtualWindow` for the visible range, build ONE keyed node per item in it, hand both to `ui.virtualList`. The list is a runtime-scrolled scroll region — engine wheel/kinetic/keyboard everywhere, the native scroll driver on macOS — whose scrollbar spans the FULL virtual extent (`item_count × stride`), and every scroll observation re-derives the view so the window follows the offset with no app wiring.

```zig
const options = Ui.VirtualListOptions{
    .id = "timeline",            // stable identity: global key + scroll-state lookup
    .item_count = model.loaded,  // TOTAL items the model holds right now
    .item_extent = 84,           // fixed row height (v1 contract: uniform rows)
    .overscan = 4,
    .grow = 1,
    .on_reach_end = .load_more,  // infinite fetch: update appends the next batch
};
const window = ui.virtualWindow(options);
const rows = ui.arena.alloc(Ui.Node, window.itemCount()) catch { ui.failed = true; return ui.column(.{}, .{}); };
for (rows, 0..) |*row, offset| {
    const index = window.start_index + offset;
    var node = rowView(ui, model, index);
    node.key = .{ .int = @intCast(index) };  // identity = the ITEM, not the slot
    row.* = node;
}
return ui.virtualList(options, window, .{rows});
```

Rules:

- **Key every row by item identity** (index or id). A row that scrolls away and back returns under the same structural id, so engine-owned row state and model-owned per-item state (selection washes, like counts keyed by index in the model) survive window shifts.
- **No `on_scroll` needed.** The runtime re-derives the view on scroll for mounted virtual lists; bind `on_scroll` only when the model wants to observe the position. Do not echo an offset into `value` — `virtualList` mirrors the runtime offset itself.
- **`on_reach_end` has hysteresis built in**: fires once when a scroll comes within one viewport of the end, re-arms past 1.5 viewports — which appending a batch causes on its own by growing the extent. One Msg per approach, never a fetch storm. It works on ANY scroll container (`on-reach-end` on `scroll` in markup). `on_reach_start` is the exact mirror for the content START (load older history; Zig views only).
- **Uniform rows are the fast path**: a non-zero `item_extent` makes 100k rows pure arithmetic. Give such rows single-line text (`wrap = false`) or fixed sub-layouts that fit the extent.
- **Variable-extent rows (chat transcripts, mixed-height feeds, markdown-bearing lists)**: set `extent_estimate` (a cheap pure fn: `fn (context, logical_index) f32`, derived from model facts like line/byte counts — NEVER from layout) and leave `item_extent` 0. Rows lay out at their intrinsic wrapped heights; the engine measures mounted rows and corrects an internal offset table, so the scrollbar geometry CONVERGES to truth as the user scrolls. Corrections are anchored on the first visible row — the scrollbar may drift as estimates correct (the honest behavior), but visible content NEVER jumps. Rough estimates are fine; wildly wrong ones just mean more scrollbar drift.
- **Tail anchoring (the chat contract)**: `anchor = .trailing` opens the list at the bottom and keeps it pinned there while the user sits at the bottom (appends never yank a scrolled-away viewport). Works for uniform rows too (`item_extent` doubles as the estimate).
- **Prepending history**: give items LOGICAL indices via `index_base` (e.g. the first loaded message's sequence number) and key rows by `index_base + physical`. To load older history, decrease `index_base` by the prepended count in `update` — row identity, measured extents, and the viewport anchor all survive, and the offset grows by the prepended extent so the user keeps reading the same rows. `on_reach_start` re-arms from that growth exactly like `on_reach_end` re-arms from an append.
- **First build / resize converge automatically**: `UiApp` resolves the window against retained scroll state, and re-derives once against the fresh geometry when a build's window under-covers it (first build, window grew) or a measured correction is pending.
- **Markup exclusion (documented call)**: the closed grammar has no channel for a `for` binding to receive the runtime's range request, nor a binding form for the extent-estimate fn, so the windowed list (uniform and variable) is builder-only; markup keeps bounded `<list virtualized>` (layout-culled) plus `on-reach-end` on `scroll` for honest infinite fetch.

The `examples/feed` app is the reference: a 100,000-post deterministic MIXED-HEIGHT corpus (one-liners to long-form walls, estimate from body length), reach-end batching, per-post state by index, a zero-jump scroll-storm test, and snapshot telemetry (`widget_nodes=`) proving the window stays viewport-sized.

## Style token attributes

Color and radius come from the design tokens, referenced by token NAME — literals only, no bindings, no raw colors (dynamic styling stays in Zig via `ElementOptions.style`):

- Color attributes: `background`, `foreground`, `accent`, `accent-foreground`, `border-color`, `focus-ring`. Values are `canvas.ColorTokens` field names — the complete list: `background`, `surface`, `surface_subtle`, `surface_pressed`, `text`, `text_muted`, `border`, `accent`, `accent_text`, `destructive`, `destructive_text`, `success`, `success_text`, `warning`, `warning_text`, `info`, `info_text`, `focus_ring`, `shadow`, `disabled`. `info` is the violet identity hue beside the status trio (merged PR badges, "new" chips). (`border-color`, not bare `border` — that name is reserved for a future width shorthand.)
- `radius` — `canvas.RadiusTokens` field names: `sm`, `md`, `lg`, `xl`.

```html
<row background="surface" radius="md" padding="8">
  <text foreground="text_muted">Muted caption</text>
</row>
```

References resolve against the app's LIVE tokens on every rebuild (`finalizeWithTokens`), so a themed app (`tokens`/`tokens_fn`) re-resolves them when the theme changes — dark mode flips `surface` automatically. The DEFAULT theme follows the system appearance: an app that sets neither `tokens` nor `tokens_fn` derives the stock tokens from the OS light/dark setting (plus high-contrast and reduce-motion) and re-themes live when the user flips it. Pass explicit `tokens` for a fixed look, or `tokens_fn` for model-owned theming (custom palettes usually still follow the system scheme through `on_appearance`). An explicit `style` value set in Zig always wins over a token ref on the same field. Unknown token names are validation/compile errors.

One Zig-only style knob rides beside the tokens: `ElementOptions.style = .{ .quiet_hover = true }` silences a pressable surface's pointer HOVER wash only — press and selection fills, the focus ring, cursor intent, and hit testing stay — for image-forward content tiles (cover art, photo cards) where the pointer rests on content rather than a control register. Acting controls (list rows, menu items, buttons, tab triggers) keep their washes: there the hover fill IS the affordance.

## Expressions — the complete grammar

Attribute values take a literal or exactly ONE `{expression}`; text content interpolates any number (`{open_count} open · {done_count} done`). An expression is PURE and TOTAL — spreadsheet power, never a programming language: no user-defined functions, no effects, no computed message names, guaranteed termination.

- Operands: binding paths (`{c.title}`), numbers (`3`, `0.5` — no exponents), `'strings'` (single quotes, no escapes), `true`/`false`.
- Arithmetic `+ - * /`: numbers only (int op int stays int; any float promotes; `/` ALWAYS produces a float — wrap in `round()`/`floor()`/`ceil()` for whole-number attributes). Division by zero, integer overflow, and non-finite float results are loud errors, never silent zeros/NaN/inf.
- Comparison `== != < <= > >=`: ordering takes numbers only; equality compares any two values (different types are simply NOT equal; int/float compare numerically). Comparisons do not chain (`a < b < c` is an error — use `and`). Comparison operands reject arena-computed bindings (compare source fields, or bind a `pub fn ... bool`).
- Boolean `and` / `or` / `not`: booleans only — write `{count > 0}`, not `{count}`. Both sides always evaluate (pure, so only errors observable).
- `++` concatenation: joins ANY values as display text, formatted exactly like interpolation (`{'$' ++ fixed(price, 2)}`).
- `msg` or `msg:{path}` on `on-*` attributes stays its own form: tags and payloads are paths, never expressions.

The function library is CLOSED (17 functions; adding one is a toolkit change — anything else is a model fn):

| fn | notes |
|---|---|
| `fixed(x, digits)` | exact decimals, digits 0-6, half-away rounding (`fixed(3.14159, 2)` → `3.14`) |
| `thousands(n)` | whole number with `,` separators (`1,234,567`) |
| `percent(fraction, digits?)` | `percent(0.42)` → `42%`; digits default 0 |
| `date(ts)` / `time(ts)` / `datetime(ts)` | unix SECONDS from the model, formatted UTC (`2026-07-05`, `14:03`); formatting model time is pure — `now()` is a teaching error: reading the clock is an effect, keep a timestamp field updated by update/fx |
| `upper(s)` / `lower(s)` / `trim(s)` | ASCII case map / whitespace trim; non-ASCII passes through unchanged |
| `min(a, b)` / `max(a, b)` / `abs(x)` | numbers; int stays int |
| `round(x)` / `floor(x)` / `ceil(x)` | number → whole number |
| `plural(count, singular, plural)` | count exactly 1 picks singular (`{plural(n, 'item', 'items')}`) |
| `pad(x, width)` | zero-pads the integer value of x to `width` digits (`pad(7, 2)` → `07`); a negative sign precedes the zeros and does not count toward width; numbers wider than width print in full — the mm:ss counter fn (`{pad(minutes, 2)}:{pad(seconds, 2)}`) |

Bounds (taught one past): 256 bytes, 64 terms, 16 nesting levels per expression. Where expressions are allowed: text interpolation, attribute values, `if` tests, template args at use sites. Path-only by design: message tags/payloads, `for each` iterables, import paths. Both engines evaluate through ONE shared evaluator — results are bit-for-bit identical, floats included — and `native markup check` validates syntax, bounds, function names (with did-you-mean), arity, and literal types without needing the model.

Anything stateful or beyond the grammar is a Zig model function you bind to (`each="visible"`, `{summaryLine}`).

Where the line sits between inline arithmetic and a model fn: inline expression arithmetic is sanctioned for ONE-OFF presentation-level derivation — `{percent(done / total)}` on the single readout that shows it is exactly what expressions are for. The moment a derivation is REUSED in a second binding, deserves a NAME, or carries meaning the model owns (a threshold, a rule, a policy), it belongs in a named model function: `{completionRate}` reads at the binding site, tests in Zig, and changes in one place.

## Binding resolution rules

A path like `{h.streak}` resolves left to right, starting from the model or a `for` variable:

- everything bindable is declared INSIDE the Model struct: fields, and `pub fn` METHODS in the struct body. A file-scope `pub fn visibleRows(model: *const Model, ...)` written NEXT TO the struct is invisible to bindings and `for each` — a model-free `native markup check` still passes (grammar-only), and the view then fails at test/run time with "each does not name an iterable"; with a fresh model contract (refreshed by `native test`), `native check` catches it instantly with a did-you-mean. If a binding or `each` cannot find your fn, first check it lives inside `pub const Model = struct { ... }`
- struct fields bind directly: `{habit_count}`, `{h.done}`
- zero-arg pub methods bind like fields: `{totalDays}` calls `pub fn totalDays(m: *const Model) usize`
- arena-taking scalar methods bind the same way: `{summary}` calls `pub fn summary(m: *const Model, arena: std.mem.Allocator) []const u8` — format derived display strings straight into the build arena (it lives exactly one view build). Works anywhere a scalar binding does — text interpolation, attribute values, message payloads, expression function arguments (`{upper(summary)}`) — EXCEPT as a comparison operand (`==`, `<`, ...), which rejects arena-computed values with a teaching error: compare the source fields, or bind a `pub fn ... bool`
- enums resolve to their tag name — so `{f}` renders "active", `{f == filter}` compares tags, and `set_filter:{f}` coerces the tag back into an enum payload
- `for each="name"` resolves, in order: a Model field that is a slice/array, a pub array/slice decl (`pub const filters = [_]Filter{...}`), a pub fn `(*const Model) []const T`, or a pub fn `(*const Model, std.mem.Allocator) []const T` — the allocator variant is how filtered/derived lists work (allocate from the passed arena)
- item methods work too: `{h.name}` may be a field or `pub fn name(h: *const Habit) []const u8`

Bindings are zero-argument. A parameterized query (cards of column X) becomes one model function per case.

## Derive, don't store

The model stores source-of-truth state ONLY: the raw items, the current filter, the draft text. Anything the view shows that is computable from those — counts, sums, filtered views, formatted strings — is a pub method the markup binds to, never a model field. A cached derivable must be re-maintained in every `update` arm and goes stale the moment one is missed; a derived method cannot.

```zig
// WRONG: derived state cached in the model, maintained by hand in update()
visible_count: usize,
summary_storage: [64]u8,   // preformatted display string

// RIGHT: the model keeps integers + the filter; methods derive per rebuild
pub fn visibleCount(model: *const Model) usize { ... }
pub fn visibleCents(model: *const Model) u64 { ... }
```

Derived numbers need no allocation: bind the methods and let text interpolation compose the line — this is exactly how the examples' status bars work (`examples/habits`):

```html
<status-bar>{habit_count} habits · {totalDays} total days</status-bar>
```

Computed strings (money, dates, percentages) are formatted into the BUILD ARENA inside the `for each` allocator fn — derive display rows whose string fields are `allocPrint`ed there. The arena lives for exactly one view build, so nothing is stored and nothing goes stale. Store amounts as integer cents; format at view time:

```zig
pub const VisibleExpense = struct { id: u32, date: []const u8, amount: []const u8 };

// A METHOD — declared inside `pub const Model = struct { ... }`. Bindings and
// `for each` resolve Model decls only; the same fn at file scope is invisible.
pub fn visible(model: *const Model, arena: std.mem.Allocator) []const VisibleExpense {
    const out = arena.alloc(VisibleExpense, model.expense_count) catch return &.{};
    var count: usize = 0;
    for (model.expenses[0..model.expense_count]) |*e| {
        if (!model.matches(e.*)) continue;
        out[count] = .{
            .id = e.id,
            .date = e.date(),
            .amount = std.fmt.allocPrint(arena, "${d}.{d:0>2}", .{ e.amount_cents / 100, e.amount_cents % 100 }) catch "",
        };
        count += 1;
    }
    return out[0..count];
}
```

A one-off formatted line that plain interpolation can't express (e.g. a currency total in a summary) is an arena-taking scalar fn bound directly:

```zig
pub fn summary(model: *const Model, arena: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(arena, "{d} expenses · {s} total", .{
        model.visibleCount(), formatCents(arena, model.visibleCents()),
    }) catch "";
}
```

```html
<status-bar>{summary}</status-bar>
```

(The old workaround — wrapping the string in a one-element slice and iterating it with `<for each="summary" as="s">` — is no longer needed; bind the fn directly. Item methods take the arena too: `{e.amount}` may call `pub fn amount(e: *const Expense, arena: std.mem.Allocator) []const u8`.)

For `<if test>`, prefer an explicit boolean predicate method over numeric truthiness: `test="{hasHabits}"` with `pub fn hasHabits(m: *const Model) bool` states the condition; `test="{habit_count}"` works (non-zero is truthy, non-empty strings too) but hides it.

## Messages

`on-press`, `on-toggle`, `on-change`, `on-submit` (enter in a text field; primary+enter in a textarea, where enter inserts a newline), `on-dismiss` (dismissible surfaces: dialog, drawer, sheet, dropdown-menu — dispatched when Escape or a click outside dismisses the surface, so the model owns the close), and `on-hold` (press-and-hold, see the Pickers section) take `tag` or `tag:{payload}`. The tag must be a variant of your `Msg` union; payload bindings coerce to the variant's payload type: integers, floats, enums (from tag names), `[]const u8`, bool. `on-input` is special: name a `Msg` variant whose payload is `canvas.TextInputEvent` and the runtime delivers each text edit in it. `on-scroll` (the `scroll` element only) is the same shape: name a `Msg` variant whose payload is `canvas.ScrollState` and the runtime delivers the post-scroll state — `offset`, `viewport_extent`, `content_extent`, `maxOffset()` — after every user scroll (wheel, kinetic momentum steps, keyboard, accessibility). In Zig views the constructors are `Ui.inputMsg(.tag)` / `Ui.scrollMsg(.tag)` on `on_input` / `on_scroll`. `on-reach-end` (the `scroll` element only; `on_reach_end` in Zig views, any scroll container including the windowed virtual list) is a plain Msg dispatched when a user scroll comes within one viewport of the content end — the infinite-fetch signal, fired once per approach with hysteresis (re-arms past 1.5 viewports, which appending a batch causes by growing the extent). A programmatic jump to the end fires once and NEVER re-arms while the offset stays near the end — re-arming needs a post-scroll observation at least 1.5 viewports from it.

Scroll offsets follow the same mirror discipline as text: the Msg carries the offset the runtime ALREADY applied, so store it in the model and echo it back through the scroll's `value` — the echoed source value equals the runtime offset, which the scroll reconcile rule treats as "unchanged", so rebuilds never stomp live scrolling. `on-scroll` is how long content pages or lazy-loads: keep a bounded window in the model and slide it from `offset` (near-end when `offset + viewport_extent` approaches `content_extent`).

A handler or update error DEGRADES, it does not exit the app: dispatch catches it, records it in a bounded ring (`runtime.dispatchErrors()`, the `error event=... name=...` lines and `dispatch_errors=` count in automation snapshots, and a `dispatch.error` trace record at error level), and the app keeps running. Trace-sink capacity failures likewise never fail dispatch — dropped records are counted (`dropped_trace_records=`), not fatal. Design for it: an arm that can fail should still surface its own status in the model; the error ring is the safety net, not the UX.

Presses follow ONE rule: a click lands on the nearest pressable widget under the pointer — plain text, icons, images, badges, and layout containers let it fall through to their closest pressable ancestor, and dragging still selects text. "Pressable" means an interactive kind (button, checkbox, list-item, ...) or ANY element with a bound `on-press`/`on-toggle` — the handler itself makes the element a hit target, so a pressable row is just `<panel on-press="open:{id}">` (or `<row on-press=...>`, `ui.row(.{ .on_press = ... })`) with plain text children: no empty-text overlays, no duplicating the handler onto every text leaf. Nested pressables resolve to the deepest one (a button inside a pressable row wins over the row); editable text fields, scroll containers, and modal surfaces (dialog, drawer, sheet, popover, menus) always claim their own presses, so a click in a field inside a pressable row places the caret instead of activating the row. The value/text handlers (`on-change`, `on-submit`, `on-input`) still only belong on controls — both engines and `markup check` reject them on layout/decoration elements with a teaching error.

### Keys: quiet list rows and the app-level fallback

Keyboard focus has two registers. RING focus is the keyboard contract: Tab/Shift+Tab walk the focusables and draw the visible ring, and a ring-focused widget owns its keys in full — activation, group arrows, Home/End. QUIET focus is bookkeeping: a pointer press records which widget the user last touched, with no ring drawn (editable text kinds are the exception — a caret is a visible promise, so they show it however focus arrives). A key event resolves top to bottom, the focused widget always outranking the app: (1) the focused widget's bound handler; (2) structural consume — any key on an editable text kind (typing stays typing, checked by widget KIND, so a focused search field blocks app shortcuts without knowing they exist) and any key the widget's kind maps as a control intent; (3) only an unclaimed key_down reaches `Options.on_key`, the app-level fallback (a target-less event — nothing focused — skips straight there). The fallback is a plain function from the key event to an optional Msg:

```zig
// options: .on_key = onKey,
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .select_next;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .select_previous;
    return null;
}
```

One rule bridges the registers: quiet focus on a plain `list-item` routes NO keys — arrows, Enter, and Space on a row the user merely clicked all fall through to the fallback exactly as if nothing were focused. The why is selection-follows-intent apps: in a music library the selection is MODEL state — a click selects a row, and the arrows should keep moving that app-owned selection through the fallback (`select_next`/`select_previous` above), not silently start walking engine focus from whichever row was clicked last. Tab restores the full row contract (arrows walk the rows, Space selects, Enter submits — see "Select, then act"), rows carrying `role="treeitem"` keep the tree keymap under either register, and every other widget kind keeps its keys under quiet focus (a quietly focused button still presses on Space). The fallback fn is directly unit-testable (feed it key events, assert the Msgs), and `examples/soundboard` pins the whole pattern: Space toggles the transport from anywhere, a tabbed-to row takes Space for select and Enter for play, and the search field takes every key as typing.

## Text fields: the elm-style mirror pattern

The model applies every edit event and is the source of truth; the runtime keeps caret/selection while your source text matches, and a source-side change (like clearing on submit) wins:

```html
<text-field text="{draft}" placeholder="New task…" on-input="draft_edit" on-submit="add" grow="1" />
```

```zig
draft_buffer: canvas.TextBuffer(64) = .{},            // model field: text + selection + composition
pub fn draft(model: *const Model) []const u8 {        // the fn the markup's text= binds
    return model.draft_buffer.text();
}
.draft_edit => |edit| model.draft_buffer.apply(edit), // mirror every edit
.add => { model.addTask(model.draft_buffer.text()); model.draft_buffer.clear(); },  // clearing the source clears the field
```

The markup binds the FN (`text="{draft}"`), never the buffer: binding a `TextBuffer` model FIELD directly is a teaching error pointing at this pattern — the buffer holds editor state, and the binding wants the text it derives. See `examples/ui-inbox` for the complete pattern.

### Clipboard and selection (free — do not reimplement)

The runtime owns cmd/ctrl+C/X/V in editable text: copy writes the current selection to the system clipboard, cut copies then delivers the removal to your `on-input` handler as an `insert_text ""` edit, and paste arrives as an ordinary `insert_text` edit — the TEA mirror above stays consistent with zero extra code. Paste is clamped to the view's text capacity: when bytes were dropped, the keyboard event carries `edit_truncated = true` and your `TextBuffer` mirror sets its own `truncated` flag (check it if lost paste bytes matter to your UX; `TextBuffer` clamps oversized insertions at a UTF-8 boundary rather than dropping the edit). Shift+arrows/home/end extend the selection from the keyboard.

Static text is selectable too: click-drag inside one `text` leaf or `paragraph` (markdown bodies included) selects with a highlight, cmd/ctrl+C copies it, and pressing anywhere else clears it. Selection and pressing coexist inside pressable rows — dragging selects (and presses nothing), a plain click collapses the selection and lands on the row's `on-press`. Selection is per-widget by design — there is no document model ordering text across widgets, so a drag cannot span two paragraphs (copy per paragraph). The selection survives rebuilds while that widget's text bytes are unchanged, and shows up in semantics/automation snapshots as `selection=a..b` on the widget line. Clipboard access from `update` is `fx.writeClipboard` / `fx.readClipboard` on the effects channel (see Effects) — never a `pbcopy` spawn; `runtime.readClipboard(&buffer)` / `runtime.writeClipboard(text)` remain for code that holds the runtime.

## Effects: subprocesses and HTTP from update

`update` can take a third parameter — the effects channel — by declaring `.update_fx` instead of `.update` (existing two-argument apps are untouched; set exactly one):

```zig
const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void { ... }
// options: .update_fx = update,
```

Boot-time effects — fetching the data the app opens with — go in `.init_fx`, TEA's init command. It runs exactly once, on the installing frame, before the first view build, so a loading flag set there is in the very first paint; results arrive as ordinary Msgs. This is THE way to boot-fetch — never a guarded `on_frame` (`on_frame` is the per-frame hook for renderer diagnostics and presented-frame reactions, and unguarded spawning from it refires forever):

```zig
fn boot(model: *Model, fx: *Effects) void {
    model.loading = true;
    fx.spawn(.{
        .key = issues_key,
        .argv = &.{ "gh", "issue", "list", "--json", "number,title" },
        .output = .collect,                        // whole JSON on the exit Msg
        .on_exit = Effects.exitMsg(.issues_loaded),
    });
}
// options: .init_fx = boot,   (works with either update form)
```

`fx.spawn` runs a subprocess on a runtime-owned worker thread and streams each stdout line back as a typed Msg; the exit arrives as one more Msg. Keys are caller-chosen `u64`s you keep in the model — no handles:

```zig
pub const Msg = union(enum) {
    start,
    cancel,
    line: native_sdk.EffectLine,     // payload types are fixed
    exited: native_sdk.EffectExit,
};

.start => fx.spawn(.{
    .key = stream_key,                          // model-stored identity
    .argv = &.{ "gh", "issue", "list" },
    .stdin = null,                              // optional, written once
    .on_line = Effects.lineMsg(.line),          // comptime constructors,
    .on_exit = Effects.exitMsg(.exited),        // like ui.inputMsg(.tag)
}),
.cancel => fx.cancel(stream_key),
.line => |line| model.recordLine(line),         // COPY line.line — it is
                                                // drain scratch, dead after
                                                // this update call
.exited => |exit| model.finish(exit),           // exit.reason, exit.code
```

Rules that keep this honest:

- Effects are update-side ONLY. The view never spawns anything — a button dispatches a Msg, and that Msg's update arm spawns. Markup stays declarative.
- One `on_exit` Msg per spawn, always. A spawn that cannot run (all `max_effects = 16` slots busy, duplicate active key, argv over capacity) still delivers it, with reason `.rejected`. Reasons: `exited` (code is real), `signaled`, `cancelled`, `rejected`, `spawn_failed`.
- After `fx.cancel(key)` returns, no further `on_line` Msgs for that spawn arrive; exactly one `.cancelled` exit follows. The process is killed and reaped — no zombies. Streaming a chat agent's stdout for minutes and cancelling mid-stream is the designed-for case.
- Overflow is never silent: a full completion queue drops lines but the next delivered line's `dropped_before` and the exit's `dropped_lines` carry the count; over-long lines arrive truncated with `truncated = true`. Capacities: 16 in-flight effects, 4 KiB per line by default, 64 queued completions.
- Agent CLIs emit whole events as single NDJSON lines far beyond 4 KiB (`claude -p --output-format stream-json` repeats the entire answer on one line). Raise the bound per spawn with `.max_line_bytes = 64 * 1024` — anything up to `max_effect_line_bytes_ceiling` (256 KiB); requests above the ceiling (or zero) are rejected through `on_exit`, never silently clamped. Lines beyond the granted bound still arrive truncated and flagged. The ceiling has envelope headroom: a stream that WRAPS another stream's lines (sandbox exec NDJSON envelopes carrying JSON-escaped agent events) can carry a full 64 KiB inner line with escaping overhead to spare — size the outer bound at roughly 2-3x the inner one.
- JSON-over-stdout (`gh --json`, `jq -c`, `curl`) emits one giant line the 4 KiB line cap would destroy. Spawn with `.output = .collect` instead of the default `.lines`: whole stdout (up to 512 KiB) arrives ONCE on the exit Msg as `exit.output`, plus the child's stderr tail (last 4 KiB) in `exit.stderr_tail` — check it when `exit.code != 0` (auth errors, usage messages). No `on_line` Msgs fire for a collect spawn; overflow arrives cut with `output_truncated`/`stderr_truncated` set, never silently. COPY `exit.output`/`exit.stderr_tail` in update — drain scratch like `line.line`; the scalar exit fields stay plain data, safe to store. (`.lines` mode still ignores stderr entirely; use `.collect`, or an sh `2>&1` re-route if you truly need interleaved streaming.)

`fx.fetch` runs one HTTP(S) request on a worker thread and delivers its terminal outcome — response, classified failure, timeout, or cancel — as exactly ONE Msg:

```zig
pub const Msg = union(enum) {
    load,
    stop,
    fetched: native_sdk.EffectResponse,   // the fixed payload type
};

.load => fx.fetch(.{
    .key = search_key,                     // same key space + 16 slots as spawns
    .method = .POST,                       // std.http.Method; default .GET
    .url = "https://api.example.com/run",  // http:// or https:// only
    .headers = &.{.{ .name = "authorization", .value = "Bearer abc" }},
    .body = "{\"q\":\"zig\"}",             // optional request payload
    .timeout_ms = 10_000,                  // whole exchange; default 30 s
    .on_response = Effects.responseMsg(.fetched),
}),
.stop => fx.cancel(search_key),
.fetched => |response| model.record(response),  // COPY response.body — drain
                                                // scratch, dead after this call
```

Fetch rules:

- Exactly one `on_response` Msg per fetch, always terminal. `response.outcome` says what happened: `.ok` (real HTTP status in `.status` — non-2xx included; an HTTP-level error is still a delivered response), `.rejected` (never started: slots busy, duplicate active key, malformed URL or non-http(s) scheme, over-capacity URL/headers/payload), `.connect_failed` (DNS or TCP), `.tls_failed`, `.protocol_failed` (mid-exchange), `.timed_out`, `.cancelled`.
- `response.body` is binary-safe bytes (zeros and high bits round-trip). Bodies over 256 KiB arrive cut at that bound with `truncated = true` — never silently. Capacities: 2 KiB URLs, 8 extra headers (1 KiB of names+values total), 64 KiB request payloads.
- `fx.cancel(key)` keeps the spawn promise: exactly one `.cancelled` response Msg, nothing for that fetch after it.

Streaming responses (`.response = .stream`) frame the body into `on_line` Msgs as lines arrive — the spawn `.lines` contract over HTTP. This is THE mode for NDJSON/SSE endpoints that hold the connection open for a command's whole lifetime (Vercel Sandbox `POST .../cmd` with wait+logs, agent event streams):

```zig
.run => fx.fetch(.{
    .key = exec_key,
    .method = .POST,
    .url = sandbox_cmd_url,
    .headers = &.{.{ .name = "authorization", .value = token }},
    .body = cmd_json,
    .timeout_ms = 600_000,                 // covers the STREAM's whole lifetime
    .response = .stream,                   // body arrives as on_line Msgs
    .max_line_bytes = 256 * 1024,          // envelope lines WRAP agent events
                                           // (JSON-escaped): size the outer
                                           // bound 2-3x the inner one
    .on_line = Effects.lineMsg(.exec_event),
    .on_response = Effects.responseMsg(.exec_done),
}),
.exec_event => |line| model.recordEvent(line),  // COPY line.line — drain scratch
.exec_done => |response| model.finish(response), // status set, body always empty
```

Stream rules: each body line is one `on_line` Msg (same payload type and copy rule as spawn lines; `max_line_bytes` mirrors the spawn override with the same 256 KiB ceiling); the terminal `on_response` Msg carries the real HTTP status with an empty body; `fx.cancel(key)` mid-stream stops the lines and delivers exactly one `.cancelled` terminal; the whole-exchange `timeout_ms` covers the stream's full lifetime, so raise it for long-running commands; lines dropped on a full queue that no later line reported ride the terminal's `response.dropped_before`. In the fake executor, `feedLine` feeds a stream fetch's lines and `feedResponse(key, status, "")` delivers its terminal.

`fx.writeFile` / `fx.readFile` are TEA-friendly file persistence — session snapshots, app state — without smuggling an `Io` handle from `main` into `update`. Same discipline as spawn and fetch: bounded, key-based (shared key space and 16 slots), exactly one terminal Msg with an explicit outcome:

```zig
pub const Msg = union(enum) {
    save,
    boot,
    saved: native_sdk.EffectFileResult,   // the fixed payload type
    loaded: native_sdk.EffectFileResult,
};

.save => fx.writeFile(.{
    .key = save_key,
    .path = model.sessionPath(),           // ≤ 1 KiB; parent dirs are created
    .bytes = model.snapshotJson(),         // ≤ 1 MiB, copied at call time
    .on_result = Effects.fileMsg(.saved),
}),
.boot => fx.readFile(.{
    .key = load_key,
    .path = model.sessionPath(),
    .on_result = Effects.fileMsg(.loaded),
}),
.saved => |result| model.noteSaved(result.outcome),
.loaded => |result| model.restore(result),  // COPY result.bytes — drain scratch
```

File rules:

- `result.outcome` is explicit: `.ok` (a read's whole content in `result.bytes`; a write fully on disk), `.not_found` (reads only — writes create the path, parent directories included), `.io_failed` (permissions, path is a directory, disk), `.truncated` (the file exceeds the 1 MiB `max_effect_file_bytes`; `result.bytes` is the first bound bytes — its own outcome, not a flag, because a cut JSON snapshot must not parse as whole), `.rejected` (never ran: slots busy, duplicate key, empty/over-long path, write bytes over the bound — an over-bound WRITE is rejected outright since a partial write would corrupt the file), `.cancelled`.
- Writes replace the file whole; `writeFile` bytes are copied at call time so the caller's buffer is immediately reusable. Reads deliver drain-scratch bytes — copy what the model keeps.
- In the fake executor: `pendingFileAt(0)` records `key`/`op`/`path`/`bytes` for assertions; `feedFileResult(key, .ok, "{...}")` answers a read (over-bound content is cut and rewritten to `.truncated`, mirroring the real reader), `feedFileResult(key, .ok, "")` acknowledges a write; failure outcomes pass through as fed.

`fx.writeClipboard` / `fx.readClipboard` put text on (and read it from) the system clipboard through the platform pasteboard — the same seam the runtime's cmd+C copy uses. Never spawn `pbcopy`/`pbpaste`/`xclip` for this. Same discipline: key-based (shared key space and 16 slots), exactly one terminal Msg with an explicit outcome. The pasteboard call is synchronous on the loop thread (no worker), but the result still arrives as an ordinary Msg on the next drain:

```zig
pub const Msg = union(enum) {
    share,
    copied: native_sdk.EffectClipboardResult,   // the fixed payload type
};

.share => fx.writeClipboard(.{
    .key = share_key,
    .text = model.shareLine(),             // ≤ 64 KiB, copied at call time
    .on_result = Effects.clipboardMsg(.copied),
}),
.copied => |result| model.noteCopied(result.outcome),
```

Clipboard rules:

- `result.outcome` is explicit: `.ok` (a write is on the clipboard whole; a read's content is in `result.text` — drain scratch, copy what the model keeps), `.failed` (the platform refused: no clipboard service on the host, read content over the 64 KiB `max_effect_clipboard_bytes`, pasteboard error — a read never arrives cut), `.rejected` (never ran: slots busy, duplicate key, write text over the bound), `.cancelled`.
- Writes are text/plain and replace the clipboard whole; rich-data clipboard stays on the runtime API (`runtime.writeClipboardData`).
- In the fake executor: `pendingClipboardAt(0)` records `key`/`op`/`text` for assertions; `feedClipboardResult(key, .ok, "pasted")` answers a read, `feedClipboardResult(key, .ok, "")` acknowledges a write; failure outcomes pass through as fed. Under the real executor the test harness's null platform records the write — assert `harness.null_platform.lastClipboardData()`.

`fx.startTimer` / `fx.cancelTimer` are key-based timers on the same channel — an auto-refresh, a poll, a debounce — one-shot or repeating, each fire delivered as one `on_fire` Msg. Timers are their own fixed table (16, `max_effect_timers`) and their own key namespace: they consume none of the 16 effect slots and never collide with spawn/fetch/file keys:

```zig
pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,    // the fixed payload type
    ...
};

fx.startTimer(.{
    .key = refresh_key,
    .interval_ms = 30_000,
    .mode = .repeating,               // .one_shot (default) fires once, then retires
    .on_fire = Effects.timerMsg(.tick),
}),
.tick => |timer| switch (timer.outcome) {
    .fired => model.refresh(),        // timer.timestamp_ns is the platform fire time
    .rejected => model.noteTimerRejected(timer.key),
},
```

Timer rules: starting a key that is already an active timer REPLACES it (interval/mode/`on_fire` update in place — the friendly behavior for an auto-refresh whose cadence changes); `fx.cancelTimer(key)` stops it, unknown keys are a no-op; rejection is never silent — a full timer table, a zero `interval_ms`, or a platform without a timer service delivers exactly one Msg with outcome `.rejected`. In the fake executor, `pendingTimerAt(0)` records `key`/`interval_ms`/`mode` and `fireTimer(key)` fires by hand (one-shot slots retire after the fire), draining through the same `.wake` path as `feedExit`. The mode enum is public as `native_sdk.TimerMode` (`.one_shot`/`.repeating`) — asserting a recorded request's mode must qualify it (`try testing.expectEqual(native_sdk.TimerMode.repeating, request.mode)`; a bare `.repeating` as `expectEqual`'s first argument does not infer).

`fx.playAudio` plays a track through the platform's single audio player (macOS: AVAudioPlayer for local files, AVPlayer for streamed URLs, both in the AppKit host), and the transport rides the same channel: `fx.pauseAudio()` / `fx.resumeAudio()` / `fx.stopAudio()` / `fx.seekAudio(position_ms)` / `fx.setAudioVolume(0.0—1.0)`. Sources resolve in a fixed order — the local `path` first; when it is absent or missing, the `url`, where a verified entry at `cache_path` plays locally (no network) and anything else STREAMS progressively (audible before the download finishes) while the bytes fill the cache for next time (`expected_bytes`, the track's known size from a manifest, is the integrity gate: partial or stale cache entries never play). One player is the whole surface — a new `playAudio` replaces whatever played before, exactly like a music app switching tracks. The audio key is its own namespace (like timer keys) and consumes none of the 16 effect slots; every report arrives as one `on_event` Msg:

```zig
pub const Msg = union(enum) {
    audio_event: native_sdk.EffectAudio,   // the fixed payload type
    ...
};

.play_track => |track| fx.playAudio(.{
    .key = track.id,                        // echoed in every event
    .path = track.path,                     // local file, tried first
    .url = track.url,                       // optional http(s) fallback: cache hit or stream
    .cache_path = track.cache_path,         // empty disables caching (stream-only)
    .expected_bytes = track.bytes,          // cache integrity gate (0 = unknown)
    .on_event = Effects.audioMsg(.audio_event),
}),
.audio_event => |event| switch (event.kind) {
    .loaded => model.duration_ms = event.duration_ms,   // the real decoded duration
    .position => model.elapsed_ms = event.position_ms,  // ~every 500ms while playing
    .completed => model.playNext(fx),                   // exactly once, at natural end
    .failed, .rejected => model.noteAudioUnavailable(), // never a crash, never silence
},
```

Audio rules: `event.kind` is explicit — `.loaded` acknowledges a successful load (position ticks and `.completed` follow only after it), `.position` is a coarse honest readout (~500ms cadence — a readout, not a frame clock; drive animations from your model, not from tick density), `.completed` fires exactly once with position pinned to the duration, `.failed` reports an unreadable file with no url fallback, an async decode error, a network failure mid-stream (or offline with a cold cache), or a platform without audio playback (GTK/Win32 today — named unsupported, not half-implemented), `.rejected` reports loop-side validation (path and url both empty, or any string over `max_effect_audio_path_bytes`). `event.buffering` is the stream's honest stall flag — true while an un-paused stream waits for network bytes (local files and cache hits never buffer); show it as its own UI state, distinct from playing and paused. All payload fields are plain data — safe to store in the model, no drain-scratch copying. Pause/stop/seek/volume never echo events (the caller commanded them); seek and volume work mid-stream; volume is remembered across tracks. The streamed bytes cache at `cache_path` — key it by URL hash with `native_sdk.audioCachePath(&buffer, cache_dir, url)` under the app_dirs `.cache` directory (macOS `~/Library/Caches/<app>/audio/`, Linux `$XDG_CACHE_HOME/<app>/audio/`), so clearing the cache is deleting that one directory. The automation snapshot reports playback honestly (`audio key=... state=playing|paused|buffering source=local|cache|stream position_ms=... duration_ms=...`) — an advancing `position_ms` is the automation-visible evidence music is actually playing, and `source=` proves the resolution order. In the fake executor, `pendingAudio()` records the single channel's `key`/`path`/`url`/`cache_path`/`expected_bytes`/`playing`/`volume`, `feedAudioEvent(.position, 1_500, 89_160, true)` feeds any event by hand (draining through the same `.wake` path; `feedAudioEventBuffering` adds the stall flag), and `audioSnapshot()` exposes the mirrors; under the real executor the test harness's null platform is a deterministic fake player — `setAudioDuration(suffix, ms)` seeds durations, `takeAudioLoaded()` / `advanceAudio(delta_ms)` / `stallAudio()` synthesize the platform events a live host would deliver, position never advances on its own, `audio_local_files = false` models the assets-absent machine (local loads answer `AudioSourceNotFound`, which is what sends the cascade to the url), and a streamed track that runs to completion flips into the fake cache so the next play of the same url resolves `.cache`.

Test effects with the fake executor — deterministic, no processes, no network:

```zig
app_state.effects.executor = .fake;             // before dispatching (and before
                                                // the first frame if using init_fx —
                                                // the boot spawn is then recorded too)
try app_state.dispatch(&harness.runtime, 1, .start);
const request = app_state.effects.pendingSpawnAt(0).?;   // assert key/argv/output mode
try app_state.effects.feedLine(stream_key, "stream line 1");
try app_state.effects.feedExit(stream_key, 0);
try harness.runtime.dispatchPlatformEvent(app, .wake);   // drain -> update

// .collect spawns: feedLine accumulates (bytes + newline, like a real child
// printing that line), feedStderr fills the tail, feedExit delivers both.
try app_state.effects.feedLine(issues_key, "{\"number\":1}");   // no on_line Msg
try app_state.effects.feedStderr(issues_key, "warning: slow\n");
try app_state.effects.feedExit(issues_key, 0);                  // exit.output + exit.stderr_tail

const fetch_req = app_state.effects.pendingFetchAt(0).?; // assert key/method/url/headers/body
try app_state.effects.feedResponse(search_key, 200, "{\"ok\":true}");
try harness.runtime.dispatchPlatformEvent(app, .wake);   // Msg{ .fetched = ... }
```

The `.wake` platform event is how live platforms marshal worker completions onto the loop thread (macOS main-queue dispatch, GTK `g_idle_add`, Win32 `PostMessage`); dispatching it in tests exercises the same drain path. Note that after `fx.cancel(key)` runs in `update`, a subsequent `feedExit(key)` correctly fails with `error.EffectNotFound` — the cancel already delivered the terminal `.cancelled` exit, so there is no active effect left to feed. See `examples/effects-probe` for the complete pattern, including the live cancel flow.

> **Effects test surface — exact signatures.** These are the complete fake-executor entry points; do not excavate the SDK source. Harness and switch: `const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(w, h) });` then `app_state.effects.executor = .fake;` before dispatching. Every `feed*`/`fire*` returns `error{EffectNotFound}!void`; every `pending*At(index: usize)` returns an optional request record; each family's `pending*Count()` returns `usize`.
>
> - Spawn: `pendingSpawnAt(index: usize) ?SpawnRequest` · `feedLine(key: u64, bytes: []const u8)` · `feedStderr(key: u64, bytes: []const u8)` · `feedExit(key: u64, code: i32)` · `feedExitReason(key: u64, code: i32, reason: EffectExitReason)` (`feedExit` is the clean-exit sugar; the reason enum covers `signaled`/`cancelled`/...) · `feedOutput(key: u64, bytes: []const u8)` (raw collect-stdout append, no line framing).
> - Fetch: `pendingFetchAt(index: usize) ?FetchRequest` · `feedResponse(key: u64, status: u16, body: []const u8)` · `feedResponseOutcome(key: u64, outcome: EffectFetchOutcome, status: u16, body: []const u8)`.
> - Files: `pendingFileAt(index: usize) ?FileRequest` · `feedFileResult(key: u64, outcome: EffectFileOutcome, bytes: []const u8)`.
> - Clipboard: `pendingClipboardAt(index: usize) ?ClipboardRequest` · `feedClipboardResult(key: u64, outcome: EffectClipboardOutcome, text: []const u8)`.
> - Host commands: `pendingHostAt(index: usize) ?HostRequest` · `feedHostResult(key: u64, ok: bool, bytes: []const u8)`.
> - Timers: `pendingTimerAt(index: usize) ?TimerRequest` · `fireTimer(key: u64)` (one-shot slots retire after the fire).
> - Audio (one channel): `pendingAudio() ?AudioRequest` · `feedAudioEvent(kind: EffectAudioEventKind, position_ms: u64, duration_ms: u64, playing: bool)` · `feedAudioEventBuffering(kind, position_ms, duration_ms, playing, buffering: bool)` · `feedAudioSpectrum(bands: [32]u8, position_ms: u64, duration_ms: u64)` · `audioSnapshot() AudioSnapshot`.
>
> After feeding, drain with `try harness.runtime.dispatchPlatformEvent(app, .wake);` — results become Msgs through the same path live platforms use.

## Secondary windows: model-declared (`windows_fn` + `window_view`)

Windows are model state, like an anchored surface's open flag. `Options.windows_fn` returns the descriptors that should exist RIGHT NOW (presence is visibility — no `visible` flag; the platform window channel has no hide); `Options.window_view` builds each declared window's whole canvas tree by window label. The runtime reconciles after every dispatch: create the newly declared, close the no-longer-declared, rebuild every open window's view from the same model.

```zig
fn windows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = "settings", .canvas_label = "settings-canvas",
            .title = "Settings", .width = 360, .height = 320,
            .min_width = 320, .min_height = 280, // the WINDOW enforces the floor (macOS contentMinSize)
            .on_close = .settings_closed,   // the user's close button, as a Msg
        };
        count += 1;
    }
    return scratch.windows[0..count];
}
fn windowView(ui: *App.Ui, model: *const Model, window_label: []const u8) App.Ui.Node { ... }
// options: .windows_fn = windows, .window_view = windowView,
```

Rules that matter:
- **Every canvas label must be unique across the app** (main + declared windows); input routes back by it, and automation verbs (`widget-click <canvas-label> <id>`, `screenshot`) address any window's canvas the same way.
- **A user close dispatches `on_close`** (the dismissal precedent): the window is already gone as the optimistic echo; clear the open flag in `update` — or keep declaring the window and the next rebuild brings it back (source wins). A close the model itself initiated never echoes a Msg.
- **Budget**: at most `UiApp.max_ui_windows` (4) declared windows; excess warns and is ignored. Every dispatched Msg rebuilds every open window's view.
- **Present-before-show**: canvas windows (any `gpu_surface` view — startup, scene, and declared windows alike) are created ordered-out and become visible only after their first canvas frame presents, so opening one never flashes blank. Automatic (`WindowOptions.show = .on_first_present`, derived from the views); webview windows show immediately. The null platform records `window_show`, `window_visible`, and present/shown sequence numbers for ordering assertions; `NATIVE_SDK_WINDOW_TIMING=1` logs create→show latency on macOS.
- **Markup binds ONE window's content** — there is no `window` element in the closed grammar. A markup-authored secondary window is a `canvas.CompiledMarkupView` whose `build` `window_view` calls for that label.
- **Min size**: descriptors accept `.min_width`/`.min_height` — a content min-size floor the WINDOW enforces (macOS `contentMinSize`), so a preferences window's resize stops at its honest floor instead of the layout clamping/clipping its panes. Same fields on app.zon windows and `ShellWindow` (the first shell window's declaration threads through the startup create like `titlebar`; negative values fail `zig build validate`). The null platform records `window_min_width`/`window_min_height` for seam assertions.
- **Titlebar**: descriptors accept `.titlebar = .hidden_inset` (content under a transparent titlebar, macOS keeps the traffic lights) or `.hidden_inset_tall` (the taller unified band; macOS centers the lights in it); give the window's header `window-drag="true"` so it moves the window. See "Hidden titlebar" below.
- **Settings windows open the standard way**: the app-menu Settings item and its primary+comma shortcut (an app.zon `.shortcuts` entry mapped in `on_command`), never an in-window settings button. Ship them fixed-size (`.resizable = false`) at exactly the content's box, title them "Settings", and let changes apply live through the shared model — no Apply/OK row, no copy explaining the window.
- Tests: after the open Msg, deliver the new window's `gpu_surface_frame` (its window id from `runtime.listWindows`) to install its tree; simulate a user close by dispatching `.window_frame_changed` with `open = false`. See `examples/system-monitor` (settings shortcut -> settings window).

## Hidden titlebar: `titlebar = "hidden_inset"`/`"hidden_inset_tall"` + `window-drag` + `on_chrome`

The modern editor-app shape — content under a transparent titlebar, the app's header as the working titlebar. Two heights: `hidden_inset` keeps the compact band (~28pt, traffic lights hug the top), `hidden_inset_tall` switches to the unified-toolbar band (~52pt, macOS vertically centers the traffic lights — the tall unified-toolbar look). Pick tall when the header replacing the titlebar is toolbar-height, so the lights center against it. Three parts, all declared:

1. **app.zon**: `.titlebar = "hidden_inset"` or `"hidden_inset_tall"` on the shell window (and the matching `.titlebar = .hidden_inset`/`.hidden_inset_tall` on the `ShellWindow` in main.zig). The first shell window's declaration threads through the STARTUP window create, so the main window's chrome is right from the first frame; `zig build validate` checks the value.
2. **The header row** gets `window-drag="true"`: its background (and plain text/icons inside) moves the window; buttons inside stay buttons; double-click zooms (macOS honors the user's titlebar double-click preference).
3. **`Options.on_chrome`** (`fn (chrome: platform.WindowChrome) ?Msg`) delivers the chrome overlay geometry — `chrome.insets`: titlebar band height on top (compact or tall), traffic-light extent on the leading edge; `chrome.buttons`: the traffic-light cluster's frame in content coordinates (top-left origin), the vertical truth for centering. All-zero in fullscreen, on standard chrome, and on other platforms. It fires BEFORE the first view build and on changes; store the geometry in the model, pad the header with a leading `<spacer width="{chrome_leading}" />`, and with the tall band match the header's height to `insets.top` (floored at its natural height) so `cross="center"` puts its controls on the lights' centerline.

macOS-first like `resizable = false`: GTK/Win32 keep standard chrome and the whole channel is harmless there. Full retrofit: `examples/markdown-viewer` (tall band; toolbar row is the drag region and tracks the band height). Tests: the null platform records `startWindowDrag` calls (`window_drag_starts`), per-window `window_titlebar`, and serves settable `window_chrome` (insets + buttons frame).

## Time: wall clock + monotonic, with a testable seam

Zig 0.16 puts `std.time.milliTimestamp` behind `std.Io`, which `update` never sees — do NOT call `clock_gettime` yourself. The facade owns the clocks:

```zig
native_sdk.nowMs()                  // wall ms since the Unix epoch (i64) — ledger timestamps
native_sdk.nowNanoseconds()         // wall ns (i128)
native_sdk.monotonicMs()            // duration clock (u64, arbitrary origin, never goes backwards)
native_sdk.monotonicNanoseconds()   // subtract two reads for an elapsed time
```

Time-DEPENDENT logic (elapsed-time display, timeouts driven from update) should hold the seam in the model instead of calling the free functions, so tests stay deterministic:

```zig
pub const Model = struct { clock: native_sdk.Clock = .system, ... };
.step_started => model.entry.started_ms = model.clock.wallMs(),

// in tests:
var test_clock: native_sdk.TestClock = .{};
model.clock = test_clock.clock();
test_clock.advanceMs(1500);          // moves wall + monotonic together
test_clock.setWallMs(1_700_000_000_000);  // NTP-style wall jump, monotonic untouched
```

Wall answers "what time is it?" (jumps with OS clock adjustments); monotonic answers "how long did it take?". Don't subtract wall timestamps for durations.
## Images: runtime-registered pixels + the avatar pattern

Image pixels are runtime-registered resources keyed by a caller-chosen `ImageId` (`u64` in the model, effect-key style; 0 = no image). The framework bundles NO codecs — encoded bytes decode through the platform (CGImageSource / gdk-pixbuf / WIC) via `PlatformServices.decode_image_fn`. Registration lives on the effects channel (synchronous calls, not effects — no Msg follows):

```zig
// The fetch-avatar path, one update arm; id reaches the model ONLY on success,
// so the avatar shows initials while loading and after failure.
.fetched => |response| {
    if (response.outcome == .ok and response.status == 200) {
        _ = fx.registerImageBytes(avatar_image_id, response.body) catch return;
        model.avatar_image = avatar_image_id;
    }
},
```

```zig
// Zig views (image and icon content is markup-excluded):
ui.avatar(.{ .image = model.avatar_image, .semantics = .{ .label = "Octocat" } }, "OC"),
ui.image(.{ .image = model.chart_image, .width = 120, .height = 80, .semantics = .{ .label = "Chart" } }),
```

```html
<!-- Markup avatars bind the same model id: one {binding} to the u64 ImageId
     (a field or pub fn — never a literal); 0 renders the initials fallback. -->
<avatar image="{avatar_image}" label="Octocat">OC</avatar>
```

Rules:

- `fx.registerImage(id, w, h, rgba8)` takes already-decoded straight-alpha RGBA8 (exactly `w*h*4` bytes; the runtime copies — your buffer is free on return). `fx.registerImageBytes(id, bytes)` decodes first. `fx.unregisterImage(id)` frees the slot. Outside UiApp: `Runtime.registerCanvasImage` / `registerCanvasImageBytes` / `unregisterCanvasImage`.
- Re-registering an id replaces the pixels; every view repaints and GPU caches re-upload off the changed content fingerprint — no invalidation calls. For caches, mint fresh ids (effect-key style, monotonically increasing) and `unregisterImage` the evictee — never re-key different content onto a live id.
- Bounded and loud (`canvas_limits`): 16 slots (`max_registered_canvas_images`), 1 MiB per image (`max_registered_canvas_image_pixel_bytes`, 512×512 RGBA8 — avatar/icon scale). Errors: `error.ImageRegistryFull`, `error.ImageTooLarge`, `error.ImageDecodeFailed`, `error.InvalidImageId`/`InvalidImageDimensions`, `error.UnsupportedService` (codec-less platform).
- A draw referencing an unregistered id skips — a transient loading state can never fail presentation. `ui.avatar` clips a set image to the circle (`cover` fit) and renders the initials argument otherwise.
- Registered images render in live presentation AND `renderCanvasScreenshot`/automation screenshots, so goldens can assert on them.
- Deterministic tests: `harness.null_platform.image_decode = true` enables a strict decoder for the exact PNG subset `canvas.png.writeRgba8` emits — encode a raw RGBA fixture with the canvas PNG writer and drive the full decode→register→draw path with no bundled codec (`src/runtime/canvas_image_tests.zig` is the reference).

## Structure tags

```html
<for each="visible" key="id" as="t"> <row>...</row> </for>   <!-- one or more element children; key names an item field -->
<if test="{c.movable}"> <button ...>Move</button> </if>
<else> <text>Done!</text> </else>                             <!-- must directly follow the if -->
```

A `<for>` body takes one or more children — elements, `<use>`, `<if>`/`<else>` arms, or nested `<for>`s — so polymorphic rows need no wrapper node: put the `<if>`/`<else>` arms directly in the body and each item emits whichever arm wins. With `key`, every node an item emits shares the item's identity (same-kind siblings within one item are disambiguated automatically); a node's own `key`/`global-key` still wins. Unkeyed same-kind siblings take POSITIONAL identity (sibling index), so an `<if>` that inserts or removes an earlier same-kind sibling re-disambiguates the trailing ones — engine-owned state like carets and scroll offsets can hop; keyed items and keyed ancestors hold identity. An `<else>` directly after a `</for>` renders the empty state when the iterable has no items:

```html
<for each="visible" key="id" as="t">
  <if test="{t.done}"> <badge>done</badge> </if>
  <else> <text>{t.title}</text> </else>
</for>
<else> <text>Nothing yet</text> </else>                       <!-- renders when visible is empty -->
```

There is no `else-if` chain tag: nest an `<if>`/`<else>` inside the `<else>` body instead. `<if>` has no negation operator either — prefer an explicit boolean predicate method on the model per arm.

## Templates: `<template>` + `<use>`

When the same subtree repeats with different data (board columns, dashboard sections), define it ONCE at the top of the file — zero or more `<import>` lines, then zero or more `<template>` definitions, then the view root (a file that is ALL templates is a component file, valid only as an import target):

```html
<template name="board-column" args="title cards">
  <column grow="1" gap="8" label="{title}">
    <text foreground="text_muted">{title}</text>
    <for each="cards" key="id" as="c">
      <row global-key="{c.id}"><text>{c.title}</text></row>
    </for>
  </column>
</template>
<row grow="1" gap="12">
  <use template="board-column" title="Todo"  cards="{todoCards}" />
  <use template="board-column" title="Doing" cards="{doingCards}" />
  <use template="board-column" title="Done"  cards="{doneCards}" />
</row>
```

Rules and semantics:

- A template takes `name` (kebab-case), optional `args` (space-separated names, each optionally `name=default`), and exactly one element child. `<use template="name">` is allowed anywhere an element is (including as a `for` child or the view root); its other attributes must match the template's `args` exactly — missing args without a default and extra args are errors.
- Arg defaults are LITERALS only (`args="title trend=flat count=0"`): a default evaluates in no scope, so `{binding}` defaults are errors. A use site may omit any defaulted arg. `args="name="` declares an EMPTY-STRING default; defaults are unquoted — quotes in a default would be literal characters, so a quoted default (`name='x'`) is a teaching error.
- The template body is built IN PLACE of the `<use>`: structural widget ids hash through the parent chain at the expansion site, exactly as if you had written the body inline. Two uses at different sites get different ids; the same site is stable across rebuilds. Rewriting copy-pasted markup as a template does not change any widget id.
- Args bind like `for` variables: an arg whose value is a `{binding}` naming an iterable (model slice/array field, pub decl, or model fn — the same set `for each` accepts) is iterable inside the template (`<for each="cards" ...>`); any other arg (literal or scalar binding) is a value usable in bindings, interpolation, and equality (`{title}`, `label="{title}"`). Args are evaluated at the use site; inside the body only the args, the model, and the body's own loop variables are in scope. Value args are scalars — `{arg.field}` is an error.
- Uses inside a template body may only reference templates defined EARLIER in the file (this also makes recursion impossible). Bindings stay zero-argument: the template deduplicates the view, the per-case query stays a named model function.
- SLOTS: a template body may contain one `<slot/>` (attribute-less, childless; named slots do not exist). The `<use>` site's children build IN THE CONSUMER'S SCOPE — they see the model paths and loop variables where the use is written — and land at the slot's position; ids hash as if inlined. A use with no children renders the slot empty; children on a slotless template are an error; a `<slot/>` inside use-site children (forwarding) is an error.
- IMPORTS: `<import src="components/cards.native"/>` lines go at the very top of a file, before its templates. Paths are relative to the importing file (subdirectories and transitive imports fine, always under the root view file's directory — absolute paths and escapes are errors). An imported file defines templates ONLY (a component file; a view root inside one is an error, and a component file checks standalone). Importing splices the file's templates (transitively) BEFORE yours, in import order — as if pasted at the import site — so define-before-use stays the only ordering rule. Cycles are reported with the cycle path; duplicate template names are an error naming both definition sites.

Both engines implement templates, defaults, slots, and imports: the interpreter expands at build time (hot reload re-resolves imports from disk, so edits to imported files reload), and the compiled engine inlines at comptime with the identical result. A document with imports compiles through `canvas.CompiledMarkupImports(Model, Msg, "root.native", &sources)` where `sources` is a `canvas.ui_markup.SourceFile` set (`.{ .path = "components/cards.native", .source = @embedFile("components/cards.native") }`, paths relative to the root file's directory); pass the same set on `MarkupOptions.sources` for the runtime engine. See `examples/kanban/src/board.native` + `examples/kanban/src/components/board-column.native`.

## Markdown in markup: `<markdown>`

A leaf element that renders a markdown string (the GFM subset below) as ordinary widgets, wiring `native_sdk.markdown` for you — both engines implement it identically:

```html
<markdown source="{issue_body}" on-link="open_url" on-details="toggle_details" details-expanded="{details_expanded}" />
```

- `source` (required): one `{binding}` producing the markdown text — a `[]const u8` field, zero-arg fn, or arena-taking fn (compose the document into the build arena at view time).
- `on-link` (optional): a BARE Msg tag — no `:{payload}` — whose payload is the pressed link URL; declare `open_url: []const u8` in `Msg`.
- `on-details` (optional): a bare Msg tag whose payload is the `<details>` block's document-order index; declare `toggle_details: usize`.
- `details-expanded` (optional): one `{binding}` naming a `[]const bool` iterable (a model field, pub decl, or fn — the same sources `for each` accepts); flags are read in details-block document order. Keep a bounded `details_expanded: [8]bool` in the model and toggle it in `update`.
- `issue-link-base` (optional): a literal URL prefix or one `{binding}` producing it; `#123` references at word boundaries become links to base ++ number (`issue-link-base="ghissue://"` links `#123` to `ghissue://123` — an app scheme your `on-link` handler intercepts, or a web base like `https://github.com/owner/repo/issues/`). Off by default: resolving a ref needs repo context.
- No children, no text content, no other attributes (teaching errors point at misuse). Without the details wiring, `<details>` blocks render collapsed and inert; without `on-link`, links render styled but inert.

## Pipeline composites: stepper, timeline, nav

Three composites for pipeline/run UIs — pure compositions of existing widgets (no new kinds), identical from markup and `canvas.Ui`:

```html
<stepper active="{stage_index}">
  <step>Work</step><step>Triage</step><step>Review · {round}</step><step>Fix</step><step>Ready</step>
</stepper>
<timeline gap="4">
  <for each="ledger" key="slot" as="entry">
    <timeline-item title="{entry.title}" description="{entry.summary}" meta="{entry.meta}" variant="{entry.tone}" on-press="open_step:{entry.slot}" />
  </for>
</timeline>
```

- Stepper semantics: a `list` of `listitem`s; the active step is `selected` and every label carries its state (`"Review (active)"`) plus list position — assert pipeline stage from automation snapshots by label.
- Timeline item: leading badge (dot colored by `variant`, or `indicator` text like `"✓"`), connector rail (`connector="false"` ends it), bold title, wrapped muted description, muted meta line. With `on-press` the item gains a trailing chevron and the press binds to the item's root (role `listitem`, focusable, labeled by the title) — clicks on the title/description/meta fall through to it, so a click anywhere dispatches and dragging still selects the text. No hover fill or description line-clamp in v1.
- Zig: `ui.stepper(.{ .active = ... }, &.{ .{ .label = "Work" }, ... })`, `ui.timeline(options, items)`, `ui.timelineItem(.{ .title = ..., .on_press = ... })`.
- Nav (Zig-only; markup swaps with `<if>`): `ui.nav(.{ .active = model.nav_depth, .retain = true }, .{ pageA, pageB })` — the model owns the stack; pages are index-keyed so widget ids (and engine scroll/text state) are stable across swaps; `retain=true` keeps inactive pages mounted-but-hidden (state preserved, excluded from render/hit-test/focus/semantics), default unmounts. Instant swap, no animation in v1; move focus in `update` when pushing/popping if the focused widget lives on the outgoing page.

## Charts

`<chart>` is the data-visualization composite: `<series>` children bind model `[]const f32` iterables and draw through the vector path pipeline with token colors — charts retheme with the palette, repaint exactly when their data changes (value equality, not identity), and report series semantics to automation. Both engines lower it through `ui.chart`, so markup charts and Zig charts are pixel- and semantics-identical.

```html
<!-- Star-history: cumulative stars per repo. 10k-point series are fine —
     charts downsample deterministically past 256 points per series. -->
<chart grow="1" height="220" y-min="0" grid-lines="3" label="Star history">
  <series kind="area" values="{sdkStars}" color="accent" label="native-sdk" />
  <series kind="line" values="{examplesStars}" color="info" label="examples" />
</chart>
<!-- Sparkline tile: zero-baseline bars pinned to an absolute 0..1 domain. -->
<chart width="239" height="32" y-min="0" y-max="1" label="CPU history">
  <series kind="bar" values="{cpuSpark}" />
</chart>
```

- Kinds (literal): `line` (polyline; one sample draws a dot), `area` (a line filled to the baseline — the builder's `fill = true`), `bar` (one bar per value, ALWAYS anchored at zero — the auto domain forces 0 in, negatives hang below; a zero value draws nothing).
- Data: `values` takes one `{binding}` naming an f32 iterable — a model field (slice or array), pub decl, or fn (arena fns work), the SAME resolution set as `for each` (slice-valued template args included). Values are y samples at uniform x steps, oldest first. `NaN` = missing sample, draws a gap — pad a filling window with leading `NaN` in a model fn so the trace enters from the right (see examples/system-monitor). The series SET is static: the data varies through bindings, and dynamic series composition stays with the Zig builder.
- Domain: derived per side from the data unless `y-min`/`y-max` pin it (literals or scalar bindings); a flat series expands symmetrically. `grid-lines="N"` draws N horizontal token hairlines (opt-in, none by default); `baseline="true"` marks the zero line; `stroke-width` overrides the 1.5 default.
- Axis labels (opt-in, muted register, reserved gutters): `x-labels="{binding}"` names a model iterable of strings — one category label per sample, oldest first, thinned deterministically to fit the width (dropped entirely when a series downsamples: bucketed indices no longer name the labeled samples). `y-labels="true"` adds numeric ticks on a nice-step lattice (1/2/5 × 10^k — labels exact at their precision); with `grid-lines` set the gridlines ride the same lattice so grid and labels agree.
- Hover details: `hover-details="true"` snaps the pointer to the nearest sample and floats a card (sample label + every series' name and value, hairline cursor, dots on line points). Interaction-only chrome — static renders never show it; the chart becomes a hover target but still never claims presses.
- Box: `width`/`height` (definite; omitted keeps the intrinsic 160x48 sparkline default), `grow` (flexes the pane like any element — `grow="1"` is how a chart fills its column), `padding`, `key`/`global-key`, `label`.
- Colors are token names (`accent`, `info`, `success`, `warning`, `destructive`, ...) — never raw colors — so both themes hold up; default `accent`.
- Downsampling: past 256 points per series, deterministic index-bucket min/max decimation (spikes survive; same series → same pixels, golden-testable). The generated semantics summary still describes the SOURCE series.
- Semantics: role `chart`; label = a generated summary (`"chart: stars 10000 pts last 9999.00"`) unless `label` is set; accessibility value = the first series' latest point — assert live data from snapshots without pixels.
- Display-only: no `on-*` events and never a press claimer; clicks fall through to the nearest pressable ancestor, so charts inside pressable rows keep the row clickable (`hover-details` makes it a hover target only).
- Zig escape hatch: `ui.chart(ChartOptions, &.{canvas.ChartSeries...})` is the same code with the same options, plus what markup deliberately excludes — `.band` series (min/max envelope: `values` upper, `low` lower — a PAIRED second slice per point) and series lists composed at view time (`examples/deck` builds its peak-trace series data in the model; a truly dynamic series COUNT is builder territory).

## Rich text: inline spans and markdown

Mixed-style text inside ONE wrapped paragraph: put `<span>` children inside a `<text>` element. Each span styles one run — `weight` (`regular`/`medium` — the semibold rung —/`bold`), `mono`, `italic`, `scale` (a positive multiplier on the paragraph's base size), `underline`, and `foreground` (a color token name) — and the whole thing word-wraps as one paragraph, announcing to assistive tech as ONE text run (spans are visual). Bindings interpolate inside spans like any text:

```html
<text>
  Disk <span weight="bold">{diskUsed}</span> of
  <span foreground="text_muted">{diskTotal}</span> — run
  <span mono="true">native doctor</span> if this looks wrong.
</text>
```

- Whitespace between runs collapses to a single space; runs written with NO whitespace between them abut (`<span mono="true">init.zig</span>.` puts the period flush against the mono run).
- Spans do not nest and take no events or keys — layout (`width`, `grow`, `text-alignment`), identity, and `label` stay on the enclosing `<text>`. A span paragraph always word-wraps, so `wrap`/`overflow` on it are teaching errors.
- `scale` multiplies the base size the paragraph's typography resolves to — `size="heading"` with `scale="1.5"` draws heading × 1.5 — and line breaking measures scaled runs at their scaled size, so the wrap is honest. Only positive finite multipliers are accepted (a literal number or one `{binding}` producing one); zero/negative/non-numeric scales are teaching errors. One limit to design around: the paragraph reserves ONE uniform line height sized by its largest scale and every run shares that baseline — use mixed scale for inline headings and hero stats beside their captions, not to stack independent text sizes.
- `underline` is a pure decoration (true/false or a `{binding}`) — it does not make the run a link.
- Markup exposes the span model's weight/mono/italic/scale/underline/color channels; `strikethrough`, `background` highlights, and `link` spans stay Zig-builder territory (below).

The same paragraph from a Zig view, plus the builder-only channels:

```zig
const spans = [_]canvas.TextSpan{
    .{ .text = "Ship the " },
    .{ .text = "bold", .weight = .bold },
    .{ .text = " parts, run " },
    .{ .text = "zig build test", .monospace = true },
    .{ .text = ", then read " },
    .{ .text = "the guide", .link = "https://example.com/guide" },
};
ui.paragraph(.{ .on_link = Ui.linkMsg(.open_url) }, &spans)
```

- Each span carries `weight` (regular/medium/bold), `italic`, `monospace`, `color` (a `ColorTokens` field name), `underline`, `strikethrough`, `scale` (size multiplier vs the body token — how headings work), and `link`.
- Wrapping is span-aware and measured with the same provider the platform draws with; a paragraph reserves its real wrapped height when stacked in a column.
- Link spans are hit-testable: they appear in automation snapshots as `role=link` named by their visible text, show a pointer cursor, and pressing one dispatches `on_link(span.link)` — declare `open_url: []const u8` in `Msg` and pair with `Ui.linkMsg(.open_url)`.
- Capacities: `canvas.max_text_spans_per_paragraph` (32) spans per paragraph; overflow truncates deterministically.

Markdown (GitHub-flavored subset) maps onto the same widgets. In markup use the `<markdown>` element above; from a Zig view call it directly:

```zig
const Md = native_sdk.markdown.Markdown(Msg);
// inside view():
Md.view(ui, model.body_markdown, .{
    .on_link = Ui.linkMsg(.open_url),
    .on_details = Md.detailsMsg(.toggle_details),   // Msg{ .toggle_details = usize }
    .details_expanded = &model.details_expanded,     // caller-owned [N]bool
})
```

- Supported: `#`–`###` headings, paragraphs with `**bold**`/`*italic*`/`` `code` ``/`~~strike~~`/`[links](url)`, bare `http(s)://` URLs (autolink, trailing punctuation trimmed), `#123` issue refs (opt-in: set `Options.issue_link_base` and the ref links to base ++ number), bullet + ordered + task lists (task checkboxes are display-only, disabled), fenced code blocks, `> blockquotes`, `---` rules, GFM pipe tables (header bold, `:---`/`:--:`/`---:` column alignment, inline spans + clickable links inside cells, `\|` escapes a pipe in a cell; columns share width equally, and a missing/mismatched delimiter row degrades the block to paragraphs), `<details><summary>`.
- Not in v1 (degrades to plain text, never fails): reference links, raw HTML, footnotes, backslash escapes (except `\|` in table rows).
- `<details>` state is elm-style: the CALLER owns the expanded flags. Keep a bounded `details_expanded: [8]bool` in the model, toggle it in `update` on the details message, and pass the slice back in.

## Zig 0.16, not 0.15: the std idioms that changed

The toolkit requires Zig 0.16.0, and code written from memory of older Zig fails with "no member named" errors on std APIs. The recurring ones, old → current:

| Compile error says | Old idiom | Write instead |
| --- | --- | --- |
| `struct 'array_list.Aligned(u8,null)' has no member named 'init'` | `std.ArrayList(T).init(allocator)`, `list.append(x)` | `var list: std.ArrayList(T) = .empty;` then `list.append(allocator, x)`, `list.deinit(allocator)` — the allocator rides every call |
| `struct 'heap' has no member named 'GeneralPurposeAllocator'` | hand-built GPA in `main` | `pub fn main(init: std.process.Init) !void` — use `init.gpa`, `init.arena.allocator()`, `init.io` (the generated `main` already does) |
| `struct 'fs' has no member named 'cwd'` | `std.fs.cwd().openFile(path, .{})` | `std.Io.Dir.cwd().openFile(io, path, .{})` — file IO lives on `std.Io.Dir` and takes an `io`; in `update` use `fx.readFile`/`fx.writeFile` instead |
| `struct 'std' has no member named 'io'` | `std.io.getStdOut().writer()` | `std.Io.File.stdout().writer(io, &buffer)` then print through `&writer.interface` and `flush()`; `std.debug.print` is unchanged |
| `struct 'time' has no member named 'sleep'`/`'milliTimestamp'` | `std.time.sleep(ns)`, `std.time.milliTimestamp()` | clocks live on `Io` — in app code use `fx.wallMs()` / `native_sdk.nowMs()` / `fx.startTimer` (see Time above), in tests `std.Io.sleep(std.testing.io, ...)` |
| `invalid format string 's' for type '...'` | `{s}` on an enum | `{t}` prints the tag name; custom `format` methods take `(self, writer: *std.Io.Writer)` and print with `{f}` |
| `struct 'process.Child' has no member named 'init'` | `Child.init` + `child.spawn()` | `fx.spawn` in apps; `std.process.spawn(io, .{ .argv = ... })` + `child.wait(io)` in tools |

Tests that touch files or clocks get their `Io` from `std.testing.io`. The full catalog — env/args, sockets, readers, `build.zig` shapes, each with the SDK's live reference file — is its own skill: `native skills get zig`.

## Validate without building

`native markup check src/view.native` — instant grammar/structure validation with `file:line:column` errors, including the font-coverage tofu guard: literal text with a codepoint outside the bundled face (⌘, ✓, ⑂, dingbats, CJK) is a teaching error naming the character, because it renders as a tofu box on the reference/screenshot and mobile paths — register a font that covers it (`UiApp.Options.fonts`) and bind the text from the model (the guard skips `{bindings}`), or use a vector icon (`icon=` / `<icon name>`) or plain words. Dynamic strings get the same lesson as a Debug-build `zero_canvas_ui` diagnostic when the view builds. The accessibility lint rides the same pass: unnamed interactive controls and role misuse are errors, unnamed images and redundant labels are warnings (`--strict` promotes).

The model side checks at check time too: the model-contract step (refreshed by `native test`, or run directly as `zig build model-contract` in an app that owns its build) reflects Model/Msg into `zig-out/model-contract.zon`, and `native check` (or `markup check` run in the app directory) then verifies every binding path, iterable, `key` field, message tag, payload type, and expression type against the app's real surface — did-you-mean over your actual field names, and type errors naming the field's Zig type. It also WARNS on model state and Msg tags no view uses; opt update-only names out with `pub const view_unbound = .{ "next_id" };` on Model or Msg (`--strict` turns the warnings into failures) — state consumed only by a Zig-BUILT view needs `view_unbound` too, because the markup checker cannot see Zig view reads. A stale artifact degrades to grammar-only checking with a loud note ("model contract: not yet built - bindings checked structurally only; run `native test` to enable typed checks"); binding paths and message tags are always re-enforced when the app builds (and on hot reload).

## Testing pattern

Unit tests exercise the real dispatch path — no GUI needed:

```zig
var view = try canvas.MarkupView(Model, Msg).init(arena, main.habits_markup);
var ui = canvas.Ui(Msg).init(arena);
const tree = try ui.finalize(try view.build(&ui, &model));
const button = findByText(tree.root, .button, "Done today").?;   // walk tree.root
main.update(&model, tree.msgForPointer(button.id, .up).?);        // dispatch exactly like the runtime
// rebuild and assert: text updated, widget ids stable
```

Two `msgForPointer` traps: a **disabled** control yields `null` (assert `== null` rather than unwrapping when testing disabled states), and the tree is a snapshot — after each dispatch, rebuild the view before pressing anything again.

One widget-field trap: there is no `Widget.enabled` — enabled-ness is spelled `widget.state.disabled` (a `bool`, disabled-positive), so a test asserts `try testing.expect(!button.state.disabled);` for an enabled control and `try testing.expect(save.state.disabled);` for a disabled one.

`msgForPointer` has a sibling for every handler channel — use the one matching the interaction under test, all on the finalized `Tree`: `msgForKeyboard(id, keyboard_event)` (activation keys, slider steps, enter-to-submit, text edits), `msgForResize(id, fraction)` (the split-divider round-trip: dispatch the fraction, assert the model stored it, rebuild, assert the `value` echo), `msgForDismiss(id)` (an anchored surface's `on-dismiss`), `msgForHold(id)` (`on-hold`), `msgForTextEdit(id, edit)` (text entry), `msgForValue(id, value)` (BUILDER views only — it fires the `on_value` constructor, so it returns null for a markup slider; a markup slider binds a plain `on-change`, so assert its dispatch with `msgFor(id, .change)` — the accessibility set-value intent falls back to the same handler), `msgForScroll(id, state)`, and `msgForContextMenu(id, item_index)`. For tree keyboard NAVIGATION there is nothing app-side to unit test: Up/Down/Left/Right/Home/End run engine-side over `role="treeitem"` rows and dispatch the landed row's `on-press`/`on-toggle` — assert those Msgs (via `msgForPointer`/`msgFor(id, .toggle)`) and the model transitions; the keymap itself is runtime behavior (drive it live with `native automate widget-key`).

Runtime-integration tests use `native_sdk.TestHarness()` on the null platform; heap-allocate both the harness and the app struct (they are multi-megabyte; stack allocation crashes).

## Verify live through the automation harness

```bash
native build -Dautomation=true
./zig-out/bin/<app> &   # run from the example directory
native automate wait                     # blocks until ready=true
cat .zig-cache/native-sdk-automation/snapshot.txt   # widgets with ids, roles, names, bounds, state
native automate widget-click <canvas-label> <id>   # id is the bare number (snapshot prints #id)
native automate widget-hold <canvas-label> <id>    # press-and-hold: drives on_hold via the real timer path
native automate widget-context-press <canvas-label> <id>   # right-click: context menu, or on_hold when none
```

Snapshots expose the same structural widget ids your tests see, so live assertions are greps: click by id, re-read the snapshot, and check names/values/counts changed. Widget ids are stable across rebuilds, reorders, and hot reloads — asserting an id stayed constant while its bounds or state changed is the standard way to prove keyed identity.

For scripted checks (and the CI workflow `native init --full` scaffolds), replace grep-and-sleep with `native automate assert`: each argument is a regex that must match the snapshot, polled up to `--timeout-ms` (default 30000), with `--absent` inverting the check. Failure names the missing patterns and prints the snapshot tail.

```bash
native automate assert 'gpu_nonblank=true' 'role=button name="Reset"' 'count: 0'
native automate assert --absent 'error event='
```
