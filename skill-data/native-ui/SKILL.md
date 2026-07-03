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
| `text`, `badge`, `tooltip` | text leaves | text content, `{}` interpolation allowed; `text` is single-line unless `wrap="true"` |
| `button`, `toggle-button`, `list-item`, `menu-item`, `toggle`, `switch`, `select`, `avatar` | text-bearing controls | label is the text content; `select` shows `placeholder` while empty and dispatches `on-press`; `avatar` renders initials |
| `checkbox`, `radio`, `slider`, `progress` | value controls | `checked`, `value` |
| `text-field`, `input`, `search-field`, `combobox`, `textarea` | text entry | `placeholder`; edits via `on-input`, enter via `on-submit` |
| `status-bar` | status bar | text leaf: content only, no children |
| `separator`, `spacer` | separator, flexible space | `separator` is axis-aware: a horizontal rule in a `column`, a thin vertical divider in a `row`; give `spacer` a `grow` |
| `skeleton`, `spinner` | loading leaves | size `skeleton` with `width`/`height` |
| `markdown` | rendered markdown subtree | leaf; `source` is one `{binding}` — see "Markdown in markup" |
| `stepper` > `step` | composite stage track | `active="{index}"` (required) derives each step's completed/active/pending state; steps are text leaves (no attributes) joined by connectors; stepper also takes `key`, `global-key`, `label` |
| `timeline` > `timeline-item` | composite ledger list | items only inside a timeline (for/if fine); items are leaves — `title` (required), `description`, `meta`, `indicator`, `variant`, `connector="false"` on the last item, `selected`; `on-press` makes the whole item pressable with a trailing chevron |

Not markup-expressible (deliberately — write these as Zig view functions with `canvas.Ui`): `icon`, `image`, and icon buttons (need `ImageId` pixel references, runtime-registered — see the Images section), `data_grid` (per-column cell templates), `popover`/`menu_surface` (anchored to runtime geometry), `segmented_control` (shell chrome kind; use `tabs`/`toggle-group`). An `avatar` with an image is likewise Zig-only (`ui.avatar(.{ .image = id }, "ZN")`); the markup element renders initials.

## Attributes

Layout: `gap`, `padding` (uniform), `grow`, `width`, `height` (definite: the element is exactly that size — intrinsic content neither shrinks nor silently overflows it; `resizable` treats `width` as the initial width), `wrap` (`text` only: `wrap="true"` word-wraps at the width the element receives and reserves the wrapped height in columns; default is single-line), `main` (start|center|end|space_between), `cross` (stretch|start|center|end), `virtualized`, `virtual-item-extent`.
Appearance/state: `variant` (default|primary|secondary|outline|ghost|destructive), `size` (default|sm|lg|icon), `disabled`, `checked`, `selected`, `value`, `placeholder`.
Semantics: `role` (listitem, button, ...), `label` (accessible name).
Identity: `key` (sibling-scoped), `global-key` (parent-independent — use for items that move between containers, e.g. board cards; ids then survive reparenting).

Numbers are plain (`gap="12"`), booleans are `true`/`false` or a binding.

When children's minimum sizes exceed their container, debug builds log a `zero_canvas_layout` diagnostic naming the container, axis, and overflow in pixels — flex overflow is never silent.

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
- arena-taking scalar methods bind the same way: `{summary}` calls `pub fn summary(m: *const Model, arena: std.mem.Allocator) []const u8` — format derived display strings straight into the build arena (it lives exactly one view build). Works anywhere a scalar binding does — text interpolation, attribute values, message payloads — EXCEPT inside `{a == b}` equality, which rejects arena-computed values with a teaching error: compare the source fields, or bind a `pub fn ... bool`
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

`on-press`, `on-toggle`, `on-change`, `on-submit` (enter in a text field) take `tag` or `tag:{payload}`. The tag must be a variant of your `Msg` union; payload bindings coerce to the variant's payload type: integers, floats, enums (from tag names), `[]const u8`, bool. `on-input` is special: name a `Msg` variant whose payload is `canvas.TextInputEvent` and the runtime delivers each text edit in it.

A handler or update error DEGRADES, it does not exit the app: dispatch catches it, records it in a bounded ring (`runtime.dispatchErrors()`, the `error event=... name=...` lines and `dispatch_errors=` count in automation snapshots, and a `dispatch.error` trace record at error level), and the app keeps running. Trace-sink capacity failures likewise never fail dispatch — dropped records are counted (`dropped_trace_records=`), not fatal. Design for it: an arm that can fail should still surface its own status in the model; the error ring is the safety net, not the UX.

Handlers only work on HIT-TARGET elements. Layout containers (`row`, `column`, `stack`, `spacer`, `grid`, `list`, `table`, `table-row`, `tabs`, `toggle-group`, `button-group`, `radio-group`, `breadcrumb`, `pagination`) and decoration leaves (`badge`, `avatar`, `tooltip`, `separator`, `skeleton`, `spinner`) are never hit-tested — the engine routes pointer events through them to what they contain, so an `on-*` there could never fire. Both engines and `markup check` reject it with a teaching error instead of accepting a dead handler: put the handler on a leaf like `list-item` or `text`, or on a control inside the container. (A whole-row press target is a `list-item`; surfaces like `card`, `panel`, `scroll`, and the modal kinds ARE hit targets.)

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

### Clipboard and selection (free — do not reimplement)

The runtime owns cmd/ctrl+C/X/V in editable text: copy writes the current selection to the system clipboard, cut copies then delivers the removal to your `on-input` handler as an `insert_text ""` edit, and paste arrives as an ordinary `insert_text` edit — the TEA mirror above stays consistent with zero extra code. Paste is clamped to the view's text capacity: when bytes were dropped, the keyboard event carries `edit_truncated = true` and your `TextBuffer` mirror sets its own `truncated` flag (check it if lost paste bytes matter to your UX; `TextBuffer` clamps oversized insertions at a UTF-8 boundary rather than dropping the edit). Shift+arrows/home/end extend the selection from the keyboard.

Static text is selectable too: click-drag inside one `text` leaf or `paragraph` (markdown bodies included) selects with a highlight, cmd/ctrl+C copies it, and pressing anywhere else clears it. Selection is per-widget by design — there is no document model ordering text across widgets, so a drag cannot span two paragraphs (copy per paragraph). The selection survives rebuilds while that widget's text bytes are unchanged, and shows up in semantics/automation snapshots as `selection=a..b` on the widget line. Direct clipboard access for app logic is `runtime.readClipboard(&buffer)` / `runtime.writeClipboard(text)`.

## Effects: subprocesses and HTTP from update

`update` can take a third parameter — the effects channel — by declaring `.update_fx` instead of `.update` (existing two-argument apps are untouched; set exactly one):

```zig
const App = zero_native.UiApp(Model, Msg);
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
- Overflow is never silent: a full completion queue drops lines but the next delivered line's `dropped_before` and the exit's `dropped_lines` carry the count; over-long lines arrive truncated with `truncated = true`. Capacities: 16 in-flight effects, 4 KiB per line by default, 64 queued completions.
- Agent CLIs emit whole events as single NDJSON lines far beyond 4 KiB (`claude -p --output-format stream-json` repeats the entire answer on one line). Raise the bound per spawn with `.max_line_bytes = 64 * 1024` — anything up to `max_effect_line_bytes_ceiling` (256 KiB); requests above the ceiling (or zero) are rejected through `on_exit`, never silently clamped. Lines beyond the granted bound still arrive truncated and flagged. The ceiling has envelope headroom: a stream that WRAPS another stream's lines (sandbox exec NDJSON envelopes carrying JSON-escaped agent events) can carry a full 64 KiB inner line with escaping overhead to spare — size the outer bound at roughly 2-3x the inner one.
- JSON-over-stdout (`gh --json`, `jq -c`, `curl`) emits one giant line the 4 KiB line cap would destroy. Spawn with `.output = .collect` instead of the default `.lines`: whole stdout (up to 512 KiB) arrives ONCE on the exit Msg as `exit.output`, plus the child's stderr tail (last 4 KiB) in `exit.stderr_tail` — check it when `exit.code != 0` (auth errors, usage messages). No `on_line` Msgs fire for a collect spawn; overflow arrives cut with `output_truncated`/`stderr_truncated` set, never silently. COPY `exit.output`/`exit.stderr_tail` in update — drain scratch like `line.line`; the scalar exit fields stay plain data, safe to store. (`.lines` mode still ignores stderr entirely; use `.collect`, or an sh `2>&1` re-route if you truly need interleaved streaming.)

`fx.fetch` runs one HTTP(S) request on a worker thread and delivers its terminal outcome — response, classified failure, timeout, or cancel — as exactly ONE Msg:

```zig
pub const Msg = union(enum) {
    load,
    stop,
    fetched: zero_native.EffectResponse,   // the fixed payload type
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
    saved: zero_native.EffectFileResult,   // the fixed payload type
    loaded: zero_native.EffectFileResult,
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

## Time: wall clock + monotonic, with a testable seam

Zig 0.16 puts `std.time.milliTimestamp` behind `std.Io`, which `update` never sees — do NOT call `clock_gettime` yourself. The facade owns the clocks:

```zig
zero_native.nowMs()                  // wall ms since the Unix epoch (i64) — ledger timestamps
zero_native.nowNanoseconds()         // wall ns (i128)
zero_native.monotonicMs()            // duration clock (u64, arbitrary origin, never goes backwards)
zero_native.monotonicNanoseconds()   // subtract two reads for an elapsed time
```

Time-DEPENDENT logic (elapsed-time display, timeouts driven from update) should hold the seam in the model instead of calling the free functions, so tests stay deterministic:

```zig
pub const Model = struct { clock: zero_native.Clock = .system, ... };
.step_started => model.entry.started_ms = model.clock.wallMs(),

// in tests:
var test_clock: zero_native.TestClock = .{};
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
// Zig views (image content is markup-excluded):
ui.avatar(.{ .image = model.avatar_image, .semantics = .{ .label = "Octocat" } }, "OC"),
ui.image(.{ .image = model.chart_image, .width = 120, .height = 80, .semantics = .{ .label = "Chart" } }),
```

Rules:

- `fx.registerImage(id, w, h, rgba8)` takes already-decoded straight-alpha RGBA8 (exactly `w*h*4` bytes; the runtime copies — your buffer is free on return). `fx.registerImageBytes(id, bytes)` decodes first. `fx.unregisterImage(id)` frees the slot. Outside UiApp: `Runtime.registerCanvasImage` / `registerCanvasImageBytes` / `unregisterCanvasImage`.
- Re-registering an id replaces the pixels; every view repaints and GPU caches re-upload off the changed content fingerprint — no invalidation calls.
- Bounded and loud (`canvas_limits`): 16 slots (`max_registered_canvas_images`), 1 MiB per image (`max_registered_canvas_image_pixel_bytes`, 512×512 RGBA8 — avatar/icon scale). Errors: `error.ImageRegistryFull`, `error.ImageTooLarge`, `error.ImageDecodeFailed`, `error.InvalidImageId`/`InvalidImageDimensions`, `error.UnsupportedService` (codec-less platform).
- A draw referencing an unregistered id skips — a transient loading state can never fail presentation. `ui.avatar` clips a set image to the circle (`cover` fit) and renders the initials argument otherwise.
- Registered images render in live presentation AND `renderCanvasScreenshot`/automation screenshots, so goldens can assert on them.
- Deterministic tests: `harness.null_platform.image_decode = true` enables a strict decoder for the exact PNG subset `canvas.png.writeRgba8` emits — encode a raw RGBA fixture with the canvas PNG writer and drive the full decode→register→draw path with no bundled codec (`src/runtime/canvas_image_tests.zig` is the reference).

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

## Markdown in markup: `<markdown>`

A leaf element that renders a markdown string (the GFM subset below) as ordinary widgets, wiring `zero_native.markdown` for you — both engines implement it identically:

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
- Timeline item: leading badge (dot colored by `variant`, or `indicator` text like `"✓"`), connector rail (`connector="false"` ends it), bold title, wrapped muted description, muted meta line. With `on-press` the item gains a trailing chevron and a full-area press hotspot (role `listitem`, focusable, labeled by the title) — click anywhere dispatches. No hover fill or description line-clamp in v1.
- Zig: `ui.stepper(.{ .active = ... }, &.{ .{ .label = "Work" }, ... })`, `ui.timeline(options, items)`, `ui.timelineItem(.{ .title = ..., .on_press = ... })`.
- Nav (Zig-only; markup swaps with `<if>`): `ui.nav(.{ .active = model.nav_depth, .retain = true }, .{ pageA, pageB })` — the model owns the stack; pages are index-keyed so widget ids (and engine scroll/text state) are stable across swaps; `retain=true` keeps inactive pages mounted-but-hidden (state preserved, excluded from render/hit-test/focus/semantics), default unmounts. Instant swap, no animation in v1; move focus in `update` when pushing/popping if the focused widget lives on the outgoing page.

## Rich text: inline spans and markdown (Zig views)

Mixed-style text inside ONE wrapped paragraph is a Zig-builder feature (markup exposure is planned; the grammar is currently frozen):

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
const Md = zero_native.markdown.Markdown(Msg);
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

Two `msgForPointer` traps: a **disabled** control yields `null` (assert `== null` rather than unwrapping when testing disabled states), and the tree is a snapshot — after each dispatch, rebuild the view before pressing anything again.

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

For scripted checks (and the CI workflow `zero-native init` scaffolds), replace grep-and-sleep with `zero-native automate assert`: each argument is a regex that must match the snapshot, polled up to `--timeout-ms` (default 30000), with `--absent` inverting the check. Failure names the missing patterns and prints the snapshot tail.

```bash
zero-native automate assert 'gpu_nonblank=true' 'role=button name="Reset"' 'count: 0'
zero-native automate assert --absent 'error event='
```
