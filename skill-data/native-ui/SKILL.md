---
name: native-ui
description: Authoring guide for native-rendered zero-native apps - declarative .zml markup views plus Zig logic on the UiApp loop. Use when building or modifying native UI (widgets, layout, bindings, messages), writing .zml files, wiring Model/Msg/update, testing markup views, or verifying a native app through the automation harness.
---

# Author native UI with markup + Zig

A native-rendered zero-native app is a markup view plus Zig logic:

- `src/<view>.zml` — the entire UI: elements, layout, bindings, message dispatch.
- `src/main.zig` — `Model` (plain struct), `Msg` (tagged union), `update(model, msg)`, and a `main` that hands them to `zero_native.UiApp(Model, Msg)`.

The markup compiles to the same widget tree a hand-written `canvas.Ui(Msg)` builder view would produce: identical structural widget ids, identical typed handler table. Markup can never mutate state — it binds values and dispatches messages; all logic lives in Zig.

Editors highlight `.zml` well in HTML mode — projects ship `.vscode/settings.json` with `"files.associations": {"*.zml": "html"}` (add it if missing).

Start a new app by copying `examples/habits/` (smallest) or `examples/ui-inbox/`: change `app_exe_name` in build.zig, the name/id in app.zon, and put `0x0` as the fingerprint in build.zig.zon — the first build error prints the correct value to paste in. `src/runner.zig` and `assets/` copy verbatim.

## App wiring

```zig
const HabitsApp = zero_native.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(HabitsApp); // multi-MB struct: never on the stack
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = HabitsApp.init(std.heap.page_allocator, initialModel(), .{
        .name = "habits",
        .scene = shell_scene,             // one window, one gpu_surface view
        .canvas_label = "habits-canvas",  // must match the ShellView label
        .update = update,
        .markup = .{
            .source = @embedFile("habits.zml"),
            .watch_path = "src/habits.zml", // dev hot reload; omit in release
            .io = init.io,
        },
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{ ... }, init);
}
```

The runtime owns the loop: install on first GPU frame, presentation, resize, pointer/keyboard dispatch into `update` + rebuild. With `watch_path` set, editing the `.zml` while the app runs hot-reloads the view within ~2s, preserving model state and widget ids; parse failures keep the last good view and set `app_state.markup_diagnostic` (line/column/message).

**Release: compile the markup at comptime.** `canvas.CompiledMarkupView(Model, Msg, source).build` parses the `.zml` entirely at compile time and produces the identical tree (same ids, handlers, dispatch) with no parser in the binary; markup or binding mistakes become compile errors with line/column. Hand it to `.view`, and gate the runtime engine per build mode:

```zig
const dev = @import("builtin").mode == .Debug;
const App = zero_native.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev });
const CompiledView = canvas.CompiledMarkupView(Model, Msg, @embedFile("habits.zml"));
// options:
.view = CompiledView.build,
.markup = if (dev) .{ .source = ..., .watch_path = "src/habits.zml", .io = init.io } else null,
```

With both set (dev), the compiled view renders until the watched file first changes, then the interpreter hot-reloads it. See `examples/habits` for the full pattern.

## Elements

| Markup | Widget | Notes |
| --- | --- | --- |
| `row`, `column` | flex containers | main axis horizontal / vertical |
| `stack`, `panel`, `card` | overlay containers | children stack on top of each other |
| `scroll` | scroll_view | wrap multiple children in a `column` inside it |
| `list`, `grid` | list, grid | vertical stack / cell grid |
| `tabs`, `toggle-group`, `button-group`, `radio-group`, `breadcrumb`, `pagination` | row containers | children flow horizontally (tab buttons, toggle-buttons, radios, ...) |
| `table` > `table-row` > `table-cell` | table, data_row, data_cell | rows only inside a table, cells only inside a row (for/if wrappers are fine); cells are text leaves, dispatch with `on-press` |
| `dropdown-menu` | dropdown_menu | vertical menu surface; children are `menu-item`s |
| `accordion` | accordion | header via `text` attr; children show while `selected`, dispatch `on-toggle` |
| `alert`, `bubble` | surfaces | `alert` title via `text` attr; children stack inside |
| `dialog`, `drawer`, `sheet` | modal surfaces | rendered in place — title via `text` attr, wrap in `<if>` to show conditionally |
| `resizable` | resizable | engine-managed drag handle; `width` sets the initial width |
| `text`, `badge`, `tooltip` | text leaves | text content, `{}` interpolation allowed |
| `button`, `toggle-button`, `list-item`, `menu-item`, `toggle`, `switch`, `select`, `avatar` | text-bearing controls | label is the text content; `select` shows `placeholder` while empty and dispatches `on-press`; `avatar` renders initials |
| `checkbox`, `radio`, `slider`, `progress` | value controls | `checked`, `value` |
| `text-field`, `input`, `search-field`, `combobox`, `textarea` | text entry | `placeholder`; edits via `on-input`, enter via `on-submit` |
| `status-bar` | status bar | text leaf: content only, no children |
| `separator`, `spacer` | separator, flexible space | give `spacer` a `grow` |
| `skeleton`, `spinner` | loading leaves | size `skeleton` with `width`/`height` |

Not markup-expressible (deliberately — write these as Zig view functions with `canvas.Ui`): `icon`, `image`, and icon buttons (need ImageId asset references), `data_grid` (per-column cell templates), `popover`/`menu_surface` (anchored to runtime geometry), `segmented_control` (shell chrome kind; use `tabs`/`toggle-group`).

## Attributes

Layout: `gap`, `padding` (uniform), `grow`, `width`, `height`, `main` (start|center|end|space_between), `cross` (stretch|start|center|end), `virtualized`, `virtual-item-extent`.
Appearance/state: `variant` (default|primary|secondary|outline|ghost|destructive), `size` (default|sm|lg|icon), `disabled`, `checked`, `selected`, `value`, `placeholder`.
Semantics: `role` (listitem, button, ...), `label` (accessible name).
Identity: `key` (sibling-scoped), `global-key` (parent-independent — use for items that move between containers, e.g. board cards; ids then survive reparenting).

Numbers are plain (`gap="12"`), booleans are `true`/`false` or a binding.

## Style token attributes

Color and radius come from the design tokens, referenced by token NAME — literals only, no bindings, no raw colors (dynamic styling stays in Zig via `ElementOptions.style`):

- Color attributes: `background`, `foreground`, `accent`, `accent-foreground`, `border-color`, `focus-ring`. Values are `canvas.ColorTokens` field names — the complete list: `background`, `surface`, `surface_subtle`, `surface_pressed`, `text`, `text_muted`, `border`, `accent`, `accent_text`, `destructive`, `destructive_text`, `focus_ring`, `shadow`, `disabled`. (`border-color`, not bare `border` — that name is reserved for a future width shorthand.)
- `radius` — `canvas.RadiusTokens` field names: `sm`, `md`, `lg`, `xl`.

```html
<row background="surface" radius="md" padding="8">
  <text foreground="text_muted">Muted caption</text>
</row>
```

References resolve against the app's LIVE tokens on every rebuild (`finalizeWithTokens`), so a themed app (`tokens`/`tokens_fn`) re-resolves them when the theme changes — dark mode flips `surface` automatically. An explicit `style` value set in Zig always wins over a token ref on the same field. Unknown token names are validation/compile errors.

## Expressions — the complete list

Attribute values take a literal or exactly ONE expression; there are only three forms:

1. `{path.to.value}` — a binding
2. `{a == b}` — equality (the only comparison; for `selected` states)
3. on `on-*` attributes: `msg` or `msg:{path}` — message tag plus optional payload binding

Text content (in text-bearing elements) additionally supports interpolation: `{open_count} open · {done_count} done`.

There is NO `!=`, `<`, `>`, arithmetic, function calls with arguments, or ternaries — by design. Any derived value or condition beyond these is a Zig model function you bind to (`{doneEmpty}`, `each="visible"`).

## Binding resolution rules

A path like `{h.streak}` resolves left to right, starting from the model or a `for` variable:

- struct fields bind directly: `{habit_count}`, `{h.done}`
- zero-arg pub methods bind like fields: `{totalDays}` calls `pub fn totalDays(m: *const Model) usize`
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

A one-off formatted line that plain interpolation can't express (e.g. a currency total in a summary) is the same pattern with a single-element slice:

```zig
pub const SummaryLine = struct { text: []const u8 };
pub fn summary(model: *const Model, arena: std.mem.Allocator) []const SummaryLine {
    const text = std.fmt.allocPrint(arena, "{d} expenses · {s} total", .{
        model.visibleCount(), formatCents(arena, model.visibleCents()),
    }) catch return &.{};
    const out = arena.alloc(SummaryLine, 1) catch return &.{};
    out[0] = .{ .text = text };
    return out;
}
```

```html
<for each="summary" as="s"><status-bar>{s.text}</status-bar></for>
```

## Messages

`on-press`, `on-toggle`, `on-change`, `on-submit` (enter in a text field) take `tag` or `tag:{payload}`. The tag must be a variant of your `Msg` union; payload bindings coerce to the variant's payload type: integers, floats, enums (from tag names), `[]const u8`, bool. `on-input` is special: name a `Msg` variant whose payload is `canvas.TextInputEvent` and the runtime delivers each text edit in it.

## Text fields: the elm-style mirror pattern

The model applies every edit event and is the source of truth; the runtime keeps caret/selection while your source text matches, and a source-side change (like clearing on submit) wins:

```html
<text-field text="{draft}" placeholder="New task…" on-input="draft_edit" on-submit="add" grow="1" />
```

```zig
draft: canvas.TextBuffer(64) = .{},                   // model field: text + selection + composition
.draft_edit => |edit| model.draft.apply(edit),        // mirror every edit
.add => { model.addTask(model.draft.text()); model.draft.clear(); },  // clearing the source clears the field
```

See `examples/ui-inbox` for the complete pattern.

## Effects: subprocesses from update

`update` can take a third parameter — the effects channel — by declaring `.update_fx` instead of `.update` (existing two-argument apps are untouched; set exactly one):

```zig
const App = zero_native.UiApp(Model, Msg);
const Effects = App.Effects;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void { ... }
// options: .update_fx = update,
```

`fx.spawn` runs a subprocess on a runtime-owned worker thread and streams each stdout line back as a typed Msg; the exit arrives as one more Msg. Keys are caller-chosen `u64`s you keep in the model — no handles:

```zig
pub const Msg = union(enum) {
    start,
    cancel,
    line: zero_native.EffectLine,     // payload types are fixed
    exited: zero_native.EffectExit,
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
- Overflow is never silent: a full completion queue drops lines but the next delivered line's `dropped_before` and the exit's `dropped_lines` carry the count; over-long lines arrive truncated with `truncated = true`. Capacities: 16 in-flight effects, 4 KiB per line, 64 queued completions.

Test effects with the fake executor — deterministic, no processes:

```zig
app_state.effects.executor = .fake;             // before dispatching
try app_state.dispatch(&harness.runtime, 1, .start);
const request = app_state.effects.pendingSpawnAt(0).?;   // assert key/argv
try app_state.effects.feedLine(stream_key, "stream line 1");
try app_state.effects.feedExit(stream_key, 0);
try harness.runtime.dispatchPlatformEvent(app, .wake);   // drain -> update
```

The `.wake` platform event is how live platforms marshal worker completions onto the loop thread (macOS main-queue dispatch, GTK `g_idle_add`, Win32 `PostMessage`); dispatching it in tests exercises the same drain path. See `examples/effects-probe` for the complete pattern, including the live cancel flow.

## Structure tags

```html
<for each="visible" key="id" as="t"> <row>...</row> </for>   <!-- exactly one element child; key names an item field -->
<if test="{c.movable}"> <button ...>Move</button> </if>
<else> <text>Done!</text> </else>                             <!-- must directly follow the if -->
```

## Templates: `<template>` + `<use>`

When the same subtree repeats with different data (board columns, dashboard sections), define it ONCE at the top of the file — zero or more `<template>` definitions, then exactly one view root:

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

- A template takes `name` (kebab-case), optional `args` (space-separated names), and exactly one element child. `<use template="name">` is allowed anywhere an element is (including as a `for` child or the view root); its other attributes must match the template's `args` exactly — missing or extra args are errors.
- The template body is built IN PLACE of the `<use>`: structural widget ids hash through the parent chain at the expansion site, exactly as if you had written the body inline. Two uses at different sites get different ids; the same site is stable across rebuilds. Rewriting copy-pasted markup as a template does not change any widget id.
- Args bind like `for` variables: an arg whose value is a `{binding}` naming an iterable (model slice/array field, pub decl, or model fn — the same set `for each` accepts) is iterable inside the template (`<for each="cards" ...>`); any other arg (literal or scalar binding) is a value usable in bindings, interpolation, and equality (`{title}`, `label="{title}"`). Args are evaluated at the use site; inside the body only the args, the model, and the body's own loop variables are in scope. Value args are scalars — `{arg.field}` is an error.
- Uses inside a template body may only reference templates defined EARLIER in the file (this also makes recursion impossible). Bindings stay zero-argument: the template deduplicates the view, the per-case query stays a named model function.

Both engines implement templates: the interpreter expands at build time, `CompiledMarkupView` inlines each use at comptime with the identical result. See `examples/kanban/src/board.zml`.

## Validate without building

`zero-native markup check src/view.zml` — instant grammar/structure validation with `file:line:column` errors. Binding paths and message tags are checked against your actual Model/Msg when the app builds (and on hot reload).

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

Runtime-integration tests use `zero_native.TestHarness()` on the null platform; heap-allocate both the harness and the app struct (they are multi-megabyte; stack allocation crashes).

## Verify live through the automation harness

```bash
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/<app> &   # run from the example directory
zero-native automate wait                     # blocks until ready=true
cat .zig-cache/zero-native-automation/snapshot.txt   # widgets with ids, roles, names, bounds, state
zero-native automate widget-click <canvas-label> <id>   # id is the bare number (snapshot prints #id)
```

Snapshots expose the same structural widget ids your tests see, so live assertions are greps: click by id, re-read the snapshot, and check names/values/counts changed. Widget ids are stable across rebuilds, reorders, and hot reloads — asserting an id stayed constant while its bounds or state changed is the standard way to prove keyed identity.
