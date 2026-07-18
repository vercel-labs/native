//! The native host consumer for transpiled app cores: bridges the
//! versioned command/subscription wire format a transpiled core emits
//! (`packages/core/rt/rt.zig`, `cmd_format_version` 3) onto the
//! real effect engine (`effects.zig`). The transpiler's output is a
//! pure Model/Msg/update core whose effects are INERT BYTES — this
//! module is the one place those bytes become engine calls, so the
//! entire existing effects machinery (executors, keyed slots, the
//! completion queue, the session journal, replay) carries transpiled
//! cores without a parallel engine.
//!
//! `TsCoreHost(core)` is comptime-generic over the emitted core module
//! and expects the emitted ABI:
//!
//!   core.rt              the core's rt kernel: `frameAlloc`,
//!                        `frameReset`, `resetAll`
//!   core.Model           the committed model struct
//!   core.Msg             the app Msg `union(enum)` (wire tags are the
//!                        arms' declaration-order indices)
//!   core.initialModel()  `*const Model`, or `InitResult{ model, cmd }`
//!                        for a boot command
//!   core.update(m, msg)  `*const Model`, or `UpdateResult{ model, cmd }`
//!   core.commitModelRoot the frame-end commit walker
//!   core.subscriptions   optional: `fn (*const Model) []const u8`
//!
//! Like the rt kernel it drives, a host instance is container-level
//! state — the v1 contract is ONE LIVE APP PER CORE MODULE: two apps
//! over the same emitted core in one process would share a committed
//! root and one set of bridge tables. Two DIFFERENT core modules
//! coexist fine (each staged core carries its own rt.zig module
//! instance, so kernels never alias; distinct core types get distinct
//! hosts) — the e2e suite drives two live cores side by side to pin
//! exactly that.
//!
//! THE DISPATCH CYCLE — every Msg runs update → commit → command walk →
//! subscription reconcile → frame reset, in that order, because the
//! command and subscription bytes are frame-arena resident and must be
//! consumed before the reset. Wire records map onto the engine as:
//!
//!   persist     -> `fx.hostSend("core.persist", "")` — the host-
//!                  snapshot verb is a named host service like any
//!                  other; hosts that implement persistence bind it.
//!   now         -> `fx.wallMs()` (the journaled clock read) captured
//!                  during the walk; the named arm dispatches with that
//!                  time SYNCHRONOUSLY — immediately after the issuing
//!                  cycle completes, depth-first, before control
//!                  returns to the drain. This mirrors `fx.wallMs`'s
//!                  same-dispatch semantics for Zig cores and replays
//!                  deterministically through the `.clock` journal.
//!   host        -> `fx.hostSend(name, args)` — fire-and-forget; the
//!                  payload is the record's own arg block (`argc` f64
//!                  little-endian values, no count byte), decoded by
//!                  the named service per its build-time contract.
//!   host_bytes  -> `fx.hostSend(name, payload)` — fire-and-forget.
//!   request     -> `fx.hostRequest` with a bridge-assigned engine key
//!                  (`request_key_base` + table index, deterministic in
//!                  issue order). Completion routes the ok/err arm with
//!                  the result bytes; re-issuing a live wire key
//!                  replaces the pending request (the engine drops the
//!                  old result silently) and `cancel` drops it.
//!   read_file   -> `fx.readFile`; the terminal routes the ok arm with
//!                  the content bytes, or the err arm with the outcome
//!                  name as bytes ("not_found", "io_failed",
//!                  "truncated", "rejected").
//!   write_file  -> `fx.writeFile`; the ok arm carries no payload (a
//!                  void Msg arm), the err arm the outcome name.
//!   fetch       -> `fx.fetch` (buffered); an `.ok` un-truncated
//!                  response routes the ok arm as a two-field record —
//!                  the number field gets the real HTTP status (non-2xx
//!                  included), the bytes field the whole body, matched
//!                  by FIELD TYPE, so arm field names are the app's.
//!                  Every other outcome routes the err arm with the
//!                  outcome name; a truncated body routes err
//!                  ("truncated") rather than passing a silently cut
//!                  body as ok. Wire timeout 0 means the engine
//!                  default.
//!   clip_write  -> `fx.writeClipboard` fire-and-forget (`on_result`
//!                  null): a refused or over-bound write is dropped by
//!                  design — there is no route to report on. Engine
//!                  keys rotate through `clip_write_key_base` +
//!                  issue counter so back-to-back writes never collide.
//!   clip_read   -> `fx.readClipboard`; ok arm gets the text bytes,
//!                  err arm the outcome name ("failed", "rejected").
//!   delay       -> `fx.startTimer` (`.one_shot`) in its own slot table
//!                  (`delay_key_base` + index). Fires once, dispatching
//!                  the named arm with the fire time in fractional ms;
//!                  re-issuing a live delay key re-arms the same slot
//!                  from now (the debounce discipline) and `cancel`
//!                  drops it silently (a cancelled delay just never
//!                  fires).
//!   spawn       -> `fx.spawn` through the STREAM table (`spawn_key_base`
//!                  + index) — the one NON-RETIRING entry kind: unlike a
//!                  named op, whose entry retires on its first (only)
//!                  terminal, a stream entry stays live across
//!                  dispatches while `.lines`-mode stdout lines route
//!                  the line arm (line tag 0xFF = no line routing), and
//!                  retires only when the ONE exit terminal delivers —
//!                  a clean `.exited` end routes the exit arm (line
//!                  mode: the code as its single number payload;
//!                  collect mode: a code/output two-field record
//!                  matched by field TYPE, exactly the fetch record
//!                  mechanism), every other end (`signaled`,
//!                  `cancelled`, `rejected`, `spawn_failed`, and a
//!                  collect stdout over the engine bound, reason
//!                  "truncated") routes the err arm with the reason
//!                  bytes. Line/drop truncation flags are not surfaced
//!                  in v1: an over-bound line arrives cut to the
//!                  engine's 4 KiB line bound.
//!   audio_play  -> `fx.playAudio` on the bridge's single audio entry;
//!                  a URL record carrying no cache path plays under the
//!                  engine's conventional content-addressed cache path
//!                  when the wiring configured a caches directory
//!                  (`setAudioCacheDir` / `TsUiApp`'s `audio_cache_dir`)
//!                  — derived bridge-side from the URL alone, so update
//!                  stays pure and replay re-derives identically. The
//!                  entry itself is `audio_key_base` (the engine has
//!                  ONE player, so the bridge holds one stream),
//!                  non-retiring the spawn way, keyed by the wire key:
//!                  every `EffectAudio` event (loaded/position/
//!                  completed/failed/rejected/spectrum) routes the
//!                  event arm — a six-field record built by field NAME
//!                  (state/positionMs/durationMs/playing/buffering/
//!                  bands; `state`'s enum members are matched by member
//!                  name, so the app's declaration order is free) —
//!                  until audio_ctl `stop` (or a replacing audio_play,
//!                  which re-keys and re-routes the same entry) closes
//!                  it. `completed`/`failed`/`rejected` do NOT retire
//!                  the entry: the platform may still speak (soundboard
//!                  starts the next track from `completed`), and stop
//!                  is the explicit close.
//!   image_load  -> `fx.loadImage` keyed by the app's own numeric
//!                  ImageId (the engine registers the pixels under it,
//!                  so the bridge holds a small id->tag table rather
//!                  than minting an engine key). One terminal per load
//!                  routes the event arm — a five-field record built by
//!                  field NAME (id/state/width/height/status; `state`'s
//!                  enum members are matched by member name, and `id`
//!                  echoes the requested ImageId so concurrent loads
//!                  sharing one arm stay distinguishable) — and the
//!                  entry retires on it. A URL record carrying no cache
//!                  path loads under the engine's conventional
//!                  content-addressed image cache path when the wiring
//!                  configured a caches directory (`setImageCacheDir` /
//!                  `TsUiApp`'s `image_cache_dir`), derived bridge-side
//!                  from the URL alone like the audio cache. A
//!                  duplicate LIVE id rejects the new load (the spawn
//!                  discipline: one load per id, never replaced
//!                  implicitly), dispatching state "rejected" at the
//!                  post-cycle boundary with the refused id echoed; ids
//!                  the wire cannot carry exactly (0, non-integers,
//!                  2^53 and past — the SDK contract is BELOW 2^53)
//!                  reject the same way echoing id 0, and so does a
//!                  17th in-flight load (a full bridge table).
//!                  Image loads are not the string-keyed cancel's to
//!                  end (they are keyed by numeric id, not a wire key)
//!                  — `image_cancel` is their cancel.
//!   image_cancel-> `fx.cancel(id)` on the live load under the id, if
//!                  any: the engine's `.cancelled` terminal routes the
//!                  load's own event arm (state "cancelled") and
//!                  retires the entry, freeing the id for a fresh load
//!                  — LOUD, the spawn cancel discipline. An id naming
//!                  no live load (or one the wire cannot carry exactly)
//!                  is a no-op, audio_ctl's idle rule.
//!   audio_ctl   -> the engine's control verbs (`fx.pauseAudio`/
//!                  `resumeAudio`/`stopAudio`/`seekAudio`/
//!                  `setAudioVolume`), gated by the wire key: a verb
//!                  whose key does not name the open stream is a no-op
//!                  (the playback it aimed at is gone). `stop` also
//!                  retires the bridge entry — no events for that key
//!                  after it.
//!   window_show -> `fx.showWindow(label)` — fire-and-forget, label-
//!                  addressed like the Zig tier's verb: un-hide +
//!                  activate (the tray "Open" consequence of the
//!                  menu-bar-app loop). No result Msg; the window's own
//!                  frame event carries the state.
//!   quit_app    -> `fx.quitApp()` — the graceful terminate through the
//!                  same shutdown path a last-window close takes.
//!   cancel      -> by wire key, first match wins in this order: the
//!                  request table (`fx.cancelHostRequest`, silent), the
//!                  named-op table (the entry is marked dropped and
//!                  `fx.cancel` issued — the engine's `.cancelled`
//!                  terminal retires the entry and the bridge swallows
//!                  it: SILENT, no arm dispatches), the stream table
//!                  (`fx.cancel` — the child dies and its exit routes
//!                  the err arm with "cancelled"; killing a process IS
//!                  an observable event, so spawn's cancel stays loud),
//!                  the delay table (`fx.cancelTimer`, silent). The
//!                  audio stream is not cancel's to end — audio_ctl
//!                  `stop` is its close.
//!
//! THE KEYED-EFFECT DISCIPLINE is ONE rule across request, read_file,
//! write_file, fetch, clip_read, and delay: a keyed effect REPLACES its
//! live predecessor (the superseded effect's result is dropped — no
//! message), and `cancel` drops it silently (no terminal arm dispatch).
//! For the named ops the bridge implements the drop by marking the
//! superseded entry dropped and cancelling its engine call; the
//! engine's `.cancelled` terminal retires the entry and its Msg is
//! swallowed before dispatch. The ONE exception is a live `Cmd.spawn`
//! key: a duplicate REJECTS the new spawn — its err arm dispatches with
//! "rejected" right after the issuing cycle (the same post-cycle
//! boundary `now` dispatches use) — because a running subprocess is
//! never killed implicitly; cancel it first. And spawn's explicit
//! cancel stays loud (err arm "cancelled"), because killing a process
//! is an observable event.
//!   Sub timer   -> `fx.startTimer` (repeating) with a fixed slot table
//!                  reconciled by wire key: a new key arms the first
//!                  free slot (slot order — deterministic, never hash
//!                  order), a changed interval re-arms the same slot, a
//!                  tag-only change re-routes without re-arming, and a
//!                  key absent from the set cancels. Each fire
//!                  dispatches the named arm with the fire time in
//!                  fractional milliseconds.
//!
//! THE RESULT-ORDERING CONTRACT: routed results and timer fires are
//! ordinary engine completions — they queue in completion order and
//! dispatch when the host drains (`Effects.takeMsg`, i.e. UiApp's
//! `.effects_wake` and presented-frame drains), exactly like Zig-core
//! fx results. The bridge adds no scheduler of its own; the one
//! deliberate exception is `now` (above), which is synchronous the way
//! `fx.wallMs` is.
//!
//! Result payload lifetime: the engine's result bytes are drain
//! scratch, but a routed result's bytes become a Msg payload the core
//! may store in the model — so the Msg constructors copy them into the
//! core's frame arena first, where the commit walkers classify them as
//! frame-resident and copy whatever the model keeps into the heap.
//!
//! Malformed wire bytes are teaching panics, not error codes: the only
//! producer is the transpiler's own rt builders, so a bad record is a
//! build-pipeline bug the app author must see immediately.

const std = @import("std");
const runtime_effects = @import("effects.zig");

/// Engine-key namespace for bridge-issued host requests: `base + table
/// index`. High bits spell "TSRQ" so a bridge key is recognizable in
/// journals and logs and never collides with hand-chosen Zig-core keys.
pub const request_key_base: u64 = 0x5453_5251_0000_0000;

/// Engine-key namespace for bridge-reconciled subscription timers
/// ("TSTI"). Timer keys are their own engine namespace already; the
/// base keeps journal entries self-describing.
pub const timer_key_base: u64 = 0x5453_5449_0000_0000;

/// Engine-key namespace for bridge-issued named engine ops — read_file
/// / write_file / fetch / clip_read ("TSFX"): `base + table index`,
/// deterministic in issue order, sharing the engine's effect slots
/// with `request_key_base` keys without ever colliding.
pub const effect_key_base: u64 = 0x5453_4658_0000_0000;

/// Engine-key namespace for one-shot delays ("TSDL"), in the engine's
/// timer key space alongside `timer_key_base`.
pub const delay_key_base: u64 = 0x5453_444C_0000_0000;

/// Engine-key namespace for fire-and-forget clipboard writes ("TSCW"):
/// `base + issue counter` (wrapping u32), so back-to-back writes never
/// collide on an active key.
pub const clip_write_key_base: u64 = 0x5453_4357_0000_0000;

/// Engine-key namespace for spawn STREAMS ("TSSP"): `base + table
/// index`, deterministic in issue order. Spawns share the engine's
/// `max_effects` slots with the named ops without ever colliding on a
/// key.
pub const spawn_key_base: u64 = 0x5453_5350_0000_0000;

/// The engine key of the bridge's single audio playback channel
/// ("TSAU"). Audio keys are their own engine namespace and one player
/// is the whole surface, so one constant key is the honest shape.
pub const audio_key_base: u64 = 0x5453_4155_0000_0000;

/// The spawn wire record's "no line routing" tag sentinel (mirrors
/// rt.zig's `spawn_no_line_tag`).
pub const spawn_no_line_tag: u8 = 0xFF;

/// Longest wire key (request or timer) the format can carry: the key
/// length field is one byte.
pub const max_wire_key_bytes: usize = 255;

/// Bound on `Cmd.now`-chained dispatches from one external dispatch
/// (an update whose `now` arm requests another `now`, transitively).
/// Sized like `max_effect_replay_clock_entries`: more clock reads per
/// drain window than this is a runaway update loop, not an app shape.
pub const max_now_chain: usize = 64;

/// Most `now` records one command value may carry.
pub const max_nows_per_cmd: usize = 16;

pub fn TsCoreHost(comptime core: type) type {
    return struct {
        pub const Model = core.Model;
        pub const Msg = core.Msg;
        pub const Fx = runtime_effects.Effects(Msg);

        const msg_arms = @typeInfo(Msg).@"union".fields;

        const update_returns_cmd = @typeInfo(@TypeOf(core.update)).@"fn".return_type.? != *const Model;
        const init_returns_cmd = @typeInfo(@TypeOf(core.initialModel)).@"fn".return_type.? != *const Model;
        const has_subscriptions = @hasDecl(core, "subscriptions");

        /// One in-flight routed request: the wire key names it for
        /// replace/cancel, the tags route its terminal, and the table
        /// index IS the engine key (minus `request_key_base`). Entries
        /// retire when their terminal delivers. Sized to the engine's
        /// slot table — the engine cannot hold more in flight anyway.
        const RequestEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            ok_tag: u8 = 0,
            err_tag: u8 = 0,

            fn wireKey(entry: *const RequestEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One reconciled subscription timer. `every_ms` keeps the wire
        /// value (f64) so interval-change detection compares exactly
        /// what the app declared. Key and tag stay sticky after cancel
        /// (`used = false`): a fire already queued when its timer was
        /// cancelled still routes to the arm it was armed with.
        const TimerEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            every_ms: f64 = 0,
            tag: u8 = 0,

            fn wireKey(entry: *const TimerEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One in-flight named engine op (read_file / write_file /
        /// fetch / clip_read): same lifecycle as `RequestEntry` — the
        /// table index IS the engine key (minus `effect_key_base`),
        /// entries retire when their terminal delivers. A `dropped`
        /// entry (superseded by a key reuse, or wire-cancelled) stays
        /// in the table so its engine `.cancelled` terminal can retire
        /// it, but its wire key is no longer live and its terminal is
        /// SWALLOWED — the one-rule discipline's silent drop. Sized to
        /// the engine's shared effect slots.
        const EffectEntry = struct {
            used: bool = false,
            dropped: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            ok_tag: u8 = 0,
            err_tag: u8 = 0,

            fn wireKey(entry: *const EffectEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One armed one-shot delay. Retires on fire or cancel;
        /// re-issuing a live wire key re-arms the same slot (the engine
        /// timer replaces in place under the same engine key).
        const DelayEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            tag: u8 = 0,

            fn wireKey(entry: *const DelayEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One live spawn STREAM — the non-retiring entry kind: line
        /// results route through it repeatedly across dispatches, and
        /// only the exit terminal (or the engine's `.cancelled` end
        /// after a wire cancel) retires it. The table index IS the
        /// engine key (minus `spawn_key_base`), deterministic in issue
        /// order like every bridge table.
        const StreamEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            /// `spawn_no_line_tag` = lines dispatch nothing.
            line_tag: u8 = spawn_no_line_tag,
            exit_tag: u8 = 0,
            err_tag: u8 = 0,
            collect: bool = false,

            fn wireKey(entry: *const StreamEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// The single audio stream entry (one player is the whole
        /// engine surface). Non-retiring: audio_ctl `stop` closes it, a
        /// new audio_play re-keys and re-routes it in place.
        const AudioEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            event_tag: u8 = 0,

            fn wireKey(entry: *const AudioEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One in-flight image load, keyed by the app's own numeric
        /// ImageId (which IS the engine key — the registry id and the
        /// effect key are one value by design). Retires on its one
        /// terminal.
        const ImageEntry = struct {
            used: bool = false,
            id: u64 = 0,
            event_tag: u8 = 0,
        };

        var model_root: *const Model = undefined;
        /// The platform caches directory for URL audio sources, set by
        /// the wiring (`TsUiApp`'s `audio_cache_dir`, or `setAudioCacheDir`
        /// directly) once at boot — never read from the environment
        /// inside a dispatch, so replay's deterministic-init contract
        /// holds. Empty = no derivation (stream-only playback for URL
        /// records that carry no cache path of their own).
        var audio_cache_dir_len: usize = 0;
        var audio_cache_dir_buf: [runtime_effects.max_effect_audio_path_bytes]u8 = undefined;
        var audio_cache_path_buf: [runtime_effects.max_effect_audio_path_bytes]u8 = undefined;
        var requests: [runtime_effects.max_effects]RequestEntry = @splat(.{});
        var timers: [runtime_effects.max_effect_timers]TimerEntry = @splat(.{});
        var effects_table: [runtime_effects.max_effects]EffectEntry = @splat(.{});
        var delays: [runtime_effects.max_effect_timers]DelayEntry = @splat(.{});
        var streams: [runtime_effects.max_effects]StreamEntry = @splat(.{});
        var audio_entry: AudioEntry = .{};
        var images: [runtime_effects.max_effects]ImageEntry = @splat(.{});
        /// The platform caches directory for URL image sources, the
        /// audio cache dir's twin (`setImageCacheDir` / `TsUiApp`'s
        /// `image_cache_dir`): bridge-side derivation of the
        /// content-addressed cache path, never an env read in update.
        var image_cache_dir_len: usize = 0;
        var image_cache_dir_buf: [runtime_effects.max_effect_image_path_bytes]u8 = undefined;
        var image_cache_path_buf: [runtime_effects.max_effect_image_path_bytes]u8 = undefined;
        var clip_write_counter: u32 = 0;
        /// Set by a result callback whose entry was dropped (replaced
        /// or wire-cancelled): the terminal is journal-visible but must
        /// not reach the core — `dispatch` consumes the flag and skips
        /// exactly the Msg the callback just built. Safe because the
        /// callback runs inside `fx.takeMsg` and the very next bridge
        /// call is `dispatch` with that Msg (both drain paths —
        /// `TsCoreHost.drain` and the `TsUiApp` update_fx seam — keep
        /// that adjacency).
        var swallow_next_dispatch: bool = false;

        /// A `now` record captured during the command walk, dispatched
        /// after the issuing cycle's frame reset.
        const PendingNow = struct { tag: u8, ms: i64 };

        /// A spawn issue the bridge itself refused (duplicate live wire
        /// key — the one reject in the keyed-effect discipline),
        /// dispatched as the spawn's err arm with "rejected" after the
        /// issuing cycle's frame reset, at the same boundary `now`
        /// dispatches use.
        const max_rejects_per_cmd: usize = runtime_effects.max_effects;

        /// An image load the bridge itself refused (duplicate live id,
        /// an unrepresentable id, a full image table), dispatched as the
        /// load's event arm with state "rejected" at the same post-cycle
        /// boundary. `id` echoes the requested ImageId so concurrent
        /// rejections stay distinguishable — 0 when the wire value is
        /// not an exactly-carried positive integer, because there is no
        /// honest integer to echo for one.
        const ImageReject = struct { tag: u8, id: u64 };

        /// One cycle's staging for bridge-refused image loads. Unlike
        /// the spawn-reject buffer, the count here is the APP's to
        /// choose — a `Cmd.batch` of N loads against a full table must
        /// yield N rejected results, never a crash — so the stage never
        /// caps at the table size: the inline buffer covers everyday
        /// command values without touching an allocator, and the first
        /// overflow spills once into an engine-allocator block sized by
        /// the wire's own arithmetic bound. Staging exists because the
        /// command walk cannot dispatch (the wire bytes are frame-arena
        /// resident, and a nested cycle's frame reset would free them
        /// mid-walk): rejects are captured during the walk and
        /// delivered after the issuing cycle's frame reset, at the same
        /// boundary `now` dispatches use — stack and heap storage both
        /// survive the nested delivery cycles that boundary runs.
        const ImageRejectStage = struct {
            /// Every image_load record occupies at least this many wire
            /// bytes ([op][id f64][event_tag], three empty long-bytes
            /// fields, [expected f64]), so a command value of L bytes
            /// carries at most L / 30 of them — the spill bound needs
            /// no second record parser to stay in sync with.
            const min_image_load_record_bytes: usize = 1 + 8 + 1 + 3 * 4 + 8;

            inline_buf: [max_rejects_per_cmd]ImageReject = undefined,
            spill: []ImageReject = &.{},
            count: usize = 0,
            /// The arithmetic ceiling on this cycle's image_load record
            /// count (and therefore on its rejects).
            bound: usize,
            allocator: std.mem.Allocator,

            fn open(fx: *Fx, cmd_len: usize) ImageRejectStage {
                return .{
                    .bound = cmd_len / min_image_load_record_bytes,
                    .allocator = fx.allocator,
                };
            }

            fn push(self: *ImageRejectStage, tag: u8, id: u64) void {
                if (self.count < self.inline_buf.len) {
                    self.inline_buf[self.count] = .{ .tag = tag, .id = id };
                    self.count += 1;
                    return;
                }
                if (self.spill.len == 0) {
                    // First overflow: size by the wire bound once and
                    // move the inline prefix over — one allocation for
                    // the whole cycle, and only on cycles that earn it.
                    self.spill = self.allocator.alloc(ImageReject, self.bound) catch
                        @panic("ts core host: out of memory staging rejected image loads");
                    @memcpy(self.spill[0..self.count], &self.inline_buf);
                }
                // The wire arithmetic sized the spill: rejects <= loads
                // <= bound, so the store below can never run past it.
                std.debug.assert(self.count < self.spill.len);
                self.spill[self.count] = .{ .tag = tag, .id = id };
                self.count += 1;
            }

            fn staged(self: *const ImageRejectStage) []const ImageReject {
                if (self.spill.len > 0) return self.spill[0..self.count];
                return self.inline_buf[0..self.count];
            }

            fn close(self: *ImageRejectStage) void {
                if (self.spill.len > 0) self.allocator.free(self.spill);
                self.spill = &.{};
            }
        };

        /// Install the core: reset the kernel and the bridge tables
        /// (deterministic re-init — the seam session replay relies on),
        /// run the core's `initialModel`, commit it, and perform the
        /// boot command and initial subscriptions. Wire this to
        /// `UiApp.Options.init_fx` so boot effects fire on the
        /// installing frame, before the first view build — the same
        /// init semantics Zig cores get. (The `TsUiApp` adapter splits
        /// this into `boot` at construction and `performBoot` at
        /// install, so the committed boot model exists before the
        /// effects channel does.)
        pub fn init(fx: *Fx) void {
            boot();
            performBoot(fx);
        }

        /// The pre-effects half of `init`: reset the kernel and bridge
        /// tables and commit the boot model, performing NO effects. The
        /// committed model is readable immediately (`model()`); the
        /// boot command and initial subscriptions run in `performBoot`,
        /// on the installing frame.
        pub fn boot() void {
            core.rt.resetAll();
            requests = @splat(.{});
            timers = @splat(.{});
            effects_table = @splat(.{});
            delays = @splat(.{});
            streams = @splat(.{});
            audio_entry = .{};
            images = @splat(.{});
            clip_write_counter = 0;
            audio_cache_dir_len = 0;
            image_cache_dir_len = 0;
            swallow_next_dispatch = false;
            const initial = core.initialModel();
            model_root = core.commitModelRoot(if (comptime init_returns_cmd) initial.model else initial);
            core.rt.frameReset();
        }

        /// The effects half of `init`: perform the boot command and
        /// reconcile the initial subscriptions against the committed
        /// boot model. The command bytes are re-derived by re-running
        /// the PURE `initialModel` (they were frame-resident and did not
        /// survive `boot`'s frame reset; the duplicate model value is
        /// frame-transient garbage) — purity is the transpiled subset's
        /// own guarantee, so the bytes are identical by construction.
        pub fn performBoot(fx: *Fx) void {
            if (comptime init_returns_cmd) {
                const again = core.initialModel();
                finishCycle(fx, again.cmd, 0);
            } else {
                finishCycle(fx, "", 0);
            }
        }

        /// The committed model root (valid until the next dispatch).
        pub fn model() *const Model {
            return model_root;
        }

        /// Configure the caches directory audio-cache derivation uses.
        /// Call after `boot` (which clears it) and before any dispatch —
        /// wiring-time configuration, exactly like soundboard's boot-time
        /// `app_dirs` resolution: no env read ever happens inside update.
        pub fn setAudioCacheDir(dir: []const u8) void {
            if (dir.len > audio_cache_dir_buf.len) {
                @panic("ts core host: the audio cache directory path is longer than the engine's audio path bound");
            }
            @memcpy(audio_cache_dir_buf[0..dir.len], dir);
            audio_cache_dir_len = dir.len;
        }

        fn audioCacheDir() []const u8 {
            return audio_cache_dir_buf[0..audio_cache_dir_len];
        }

        /// The cache path an audio_play record plays under: the record's
        /// own when it carries one; otherwise, for URL sources with a
        /// configured caches directory, the engine's conventional
        /// content-addressed path (`<cache_dir>/audio/<sha256[..16]>.<ext>`
        /// via `audioCachePath`) — derived HERE, outside the core, so
        /// update stays pure and the derivation is a fixed function of
        /// the wire bytes (replay re-derives identically). No directory
        /// configured, or a path over the buffer bound, degrades to ""
        /// (stream-only, the engine's own no-cache mode).
        fn effectiveAudioCachePath(cache_path: []const u8, url: []const u8) []const u8 {
            if (cache_path.len > 0 or url.len == 0 or audio_cache_dir_len == 0) return cache_path;
            return runtime_effects.audioCachePath(&audio_cache_path_buf, audioCacheDir(), url) catch "";
        }

        /// Configure the caches directory image-cache derivation uses —
        /// `setAudioCacheDir`'s twin, same wiring-time contract.
        pub fn setImageCacheDir(dir: []const u8) void {
            if (dir.len > image_cache_dir_buf.len) {
                @panic("ts core host: the image cache directory path is longer than the engine's image path bound");
            }
            @memcpy(image_cache_dir_buf[0..dir.len], dir);
            image_cache_dir_len = dir.len;
        }

        fn imageCacheDir() []const u8 {
            return image_cache_dir_buf[0..image_cache_dir_len];
        }

        /// The cache path an image_load record loads under: the
        /// record's own when it carries one; otherwise, for URL sources
        /// with a configured caches directory, the engine's
        /// conventional content-addressed path
        /// (`<cache_dir>/images/<sha256[..16]>.<ext>` via
        /// `imageCachePath`) — `effectiveAudioCachePath`'s twin, a
        /// fixed function of the wire bytes so replay re-derives
        /// identically.
        fn effectiveImageCachePath(cache_path: []const u8, url: []const u8) []const u8 {
            if (cache_path.len > 0 or url.len == 0 or image_cache_dir_len == 0) return cache_path;
            return runtime_effects.imageCachePath(&image_cache_path_buf, imageCacheDir(), url) catch "";
        }

        /// One full dispatch cycle for `msg`. The `TsUiApp` adapter
        /// wires this to `UiApp.Options.update_fx` (refreshing the
        /// app-held root from `model()` afterwards) so host events and
        /// drained effect results run the transpiled core through the
        /// same path Zig cores use. A Msg flagged by its own result
        /// callback as a dropped entry's terminal is swallowed here —
        /// the silent drop the keyed-effect discipline promises.
        pub fn dispatch(fx: *Fx, msg: Msg) void {
            if (swallow_next_dispatch) {
                swallow_next_dispatch = false;
                return;
            }
            dispatchDepth(fx, msg, 0);
        }

        /// Drain every queued effect completion into the core — the
        /// bridge-shaped mirror of `UiApp.drainEffects`' loop. Hosts
        /// that embed the core without a UiApp call this on wake/frame.
        pub fn drain(fx: *Fx) void {
            while (fx.takeMsg()) |msg| dispatch(fx, msg);
        }

        fn dispatchDepth(fx: *Fx, msg: Msg, depth: usize) void {
            if (depth >= max_now_chain) {
                @panic("ts core host: more than 64 chained Cmd.now dispatches from one event - update is requesting timestamps in a loop");
            }
            if (comptime update_returns_cmd) {
                const result = core.update(model_root, msg);
                model_root = core.commitModelRoot(result.model);
                finishCycle(fx, result.cmd, depth);
            } else {
                model_root = core.commitModelRoot(core.update(model_root, msg));
                finishCycle(fx, "", depth);
            }
        }

        /// The tail of every cycle: walk the command bytes, reconcile
        /// subscriptions against the NEW committed model, reset the
        /// frame arena, then run the cycle's `now` dispatches and
        /// bridge-refused spawn rejections (each a full cycle of its
        /// own, on the fresh frame — nows first, rejections after, in
        /// record order; deterministic under record and replay alike).
        fn finishCycle(fx: *Fx, cmd: []const u8, depth: usize) void {
            var nows: [max_nows_per_cmd]PendingNow = undefined;
            var now_count: usize = 0;
            var rejects: [max_rejects_per_cmd]u8 = undefined;
            var reject_count: usize = 0;
            var image_rejects = ImageRejectStage.open(fx, cmd.len);
            defer image_rejects.close();
            runCmd(fx, cmd, &nows, &now_count, &rejects, &reject_count, &image_rejects);
            reconcileTimers(fx);
            core.rt.frameReset();
            for (nows[0..now_count]) |pending| {
                dispatchDepth(fx, msgFromTagNumber(pending.tag, @floatFromInt(pending.ms)), depth + 1);
            }
            for (rejects[0..reject_count]) |err_tag| {
                dispatchDepth(fx, msgFromTagBytes(err_tag, "rejected"), depth + 1);
            }
            // Bridge-refused image loads (duplicate live id, an
            // unrepresentable id, a full image table): the event arm's
            // "rejected" state echoing the refused id, regenerated
            // deterministically under replay like the spawn rejections
            // above.
            for (image_rejects.staged()) |reject| {
                dispatchDepth(fx, msgFromTagImage(reject.tag, .{ .id = reject.id, .outcome = .rejected }), depth + 1);
            }
        }

        // ------------------------------------------------- command walk

        /// Walk one command value (v3 wire format; batch is plain
        /// concatenation, the empty slice is `Cmd.none`).
        fn runCmd(
            fx: *Fx,
            cmd: []const u8,
            nows: *[max_nows_per_cmd]PendingNow,
            now_count: *usize,
            rejects: *[max_rejects_per_cmd]u8,
            reject_count: *usize,
            image_rejects: *ImageRejectStage,
        ) void {
            var at: usize = 0;
            while (at < cmd.len) {
                const op = cmd[at];
                at += 1;
                switch (op) {
                    // persist [op]
                    0x01 => fx.hostSend("core.persist", ""),
                    // now [op][msg_tag]
                    0x02 => {
                        const tag = takeByte(cmd, &at);
                        if (now_count.* >= max_nows_per_cmd) {
                            @panic("ts core host: one command value carries more than 16 Cmd.now records");
                        }
                        // The journaled clock read (replay pops the same
                        // value), captured in record order.
                        nows[now_count.*] = .{ .tag = tag, .ms = fx.wallMs() };
                        now_count.* += 1;
                    },
                    // host [op][name_len][name][argc][argc * f64 LE]
                    0x03 => {
                        const name = takeShortBytes(cmd, &at);
                        const argc: usize = takeByte(cmd, &at);
                        const args = takeBytes(cmd, &at, argc * 8);
                        fx.hostSend(name, args);
                    },
                    // host_bytes [op][name_len][name][len u32 LE][payload]
                    0x04 => {
                        const name = takeShortBytes(cmd, &at);
                        const payload = takeLongBytes(cmd, &at);
                        fx.hostSend(name, payload);
                    },
                    // request [op][name_len][name][key_len][key]
                    //         [ok_tag][err_tag][len u32 LE][payload]
                    0x05 => {
                        const name = takeShortBytes(cmd, &at);
                        const key = takeShortBytes(cmd, &at);
                        const ok_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const payload = takeLongBytes(cmd, &at);
                        issueRequest(fx, name, key, ok_tag, err_tag, payload);
                    },
                    // cancel [op][key_len][key]
                    0x06 => {
                        const key = takeShortBytes(cmd, &at);
                        cancelWireKey(fx, key);
                    },
                    // read_file [op][key_len][key][ok][err][path_len u32 LE][path]
                    0x07 => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        fx.readFile(.{
                            .key = effect_key_base + allocEffectEntry(fx, head),
                            .path = file_path,
                            .on_result = fileResultMsg,
                        });
                    },
                    // write_file [op][key_len][key][ok][err]
                    //            [path_len u32 LE][path][bytes_len u32 LE][bytes]
                    0x08 => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        fx.writeFile(.{
                            .key = effect_key_base + allocEffectEntry(fx, head),
                            .path = file_path,
                            .bytes = bytes,
                            .on_result = fileResultMsg,
                        });
                    },
                    // fetch [op][key_len][key][ok][err][method u8][timeout u32 LE]
                    //       [url_len u32 LE][url][header_count u8]
                    //       ([name_len u8][name][value_len u32 LE][value])*
                    //       [body_len u32 LE][body]
                    0x09 => {
                        const head = takeRoutedHead(cmd, &at);
                        const method = fetchMethod(takeByte(cmd, &at));
                        const timeout_bytes = takeBytes(cmd, &at, 4);
                        const timeout_ms = std.mem.readInt(u32, timeout_bytes[0..4], .little);
                        const url = takeLongBytes(cmd, &at);
                        const header_count: usize = takeByte(cmd, &at);
                        if (header_count > runtime_effects.max_effect_fetch_headers) {
                            @panic("ts core host: a fetch wire record carries more headers than the engine accepts - the transpiler's own bound should have stopped this build");
                        }
                        var headers: [runtime_effects.max_effect_fetch_headers]std.http.Header = undefined;
                        for (0..header_count) |i| {
                            const name = takeShortBytes(cmd, &at);
                            const value = takeLongBytes(cmd, &at);
                            headers[i] = .{ .name = name, .value = value };
                        }
                        const body = takeLongBytes(cmd, &at);
                        fx.fetch(.{
                            .key = effect_key_base + allocEffectEntry(fx, head),
                            .method = method,
                            .url = url,
                            .headers = headers[0..header_count],
                            .body = if (body.len > 0) body else null,
                            // Wire 0 = "the engine's default" — the record
                            // never bakes the default in.
                            .timeout_ms = if (timeout_ms == 0) runtime_effects.default_effect_fetch_timeout_ms else timeout_ms,
                            .on_response = fetchResultMsg,
                        });
                    },
                    // clip_write [op][bytes_len u32 LE][bytes]
                    0x0A => {
                        const bytes = takeLongBytes(cmd, &at);
                        // Fire-and-forget: no routing, on_result stays null,
                        // and the rotating key keeps back-to-back writes off
                        // each other's active keys.
                        fx.writeClipboard(.{
                            .key = clip_write_key_base + clip_write_counter,
                            .text = bytes,
                            .on_result = null,
                        });
                        clip_write_counter +%= 1;
                    },
                    // clip_read [op][key_len][key][ok][err]
                    0x0B => {
                        const head = takeRoutedHead(cmd, &at);
                        fx.readClipboard(.{
                            .key = effect_key_base + allocEffectEntry(fx, head),
                            .on_result = clipboardResultMsg,
                        });
                    },
                    // delay [op][key_len][key][after_ms f64 LE][msg_tag]
                    0x0C => {
                        const key = takeShortBytes(cmd, &at);
                        const after_bits = takeBytes(cmd, &at, 8);
                        const after_ms: f64 = @bitCast(std.mem.readInt(u64, after_bits[0..8], .little));
                        const tag = takeByte(cmd, &at);
                        if (!(after_ms >= 1) or !(after_ms <= 31_536_000_000.0)) {
                            // Same bound as Sub.timer: the lower rejects NaN,
                            // the upper (one year) keeps ns conversion in range.
                            @panic("ts core host: Cmd.delay interval must be between 1ms and one year");
                        }
                        armDelay(fx, key, after_ms, tag);
                    },
                    // spawn [op][key_len][key][line_tag][exit_tag][err_tag]
                    //       [mode u8][argc u8]([arg_len u32 LE][arg])*
                    //       [stdin_len u32 LE][stdin]
                    0x0D => {
                        const key = takeShortBytes(cmd, &at);
                        const line_tag = takeByte(cmd, &at);
                        const exit_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const mode = takeByte(cmd, &at);
                        if (mode > 1) {
                            @panic("ts core host: unknown spawn output mode wire value - the core and this runtime disagree on cmd_format_version");
                        }
                        const argc: usize = takeByte(cmd, &at);
                        if (argc == 0 or argc > runtime_effects.max_effect_argv) {
                            @panic("ts core host: a spawn wire record carries more argv elements than the engine accepts - the transpiler's own bound should have stopped this build");
                        }
                        var argv: [runtime_effects.max_effect_argv][]const u8 = undefined;
                        for (0..argc) |i| argv[i] = takeLongBytes(cmd, &at);
                        const stdin = takeLongBytes(cmd, &at);
                        issueSpawn(fx, .{ .key = key, .line_tag = line_tag, .exit_tag = exit_tag, .err_tag = err_tag }, mode == 1, argv[0..argc], stdin, rejects, reject_count);
                    },
                    // audio_play [op][key_len][key][event_tag]
                    //            [path_len u32 LE][path][url_len u32 LE][url]
                    //            [cache_len u32 LE][cache][expected f64 LE]
                    0x0E => {
                        const key = takeShortBytes(cmd, &at);
                        const event_tag = takeByte(cmd, &at);
                        const audio_path = takeLongBytes(cmd, &at);
                        const url = takeLongBytes(cmd, &at);
                        const cache_path = takeLongBytes(cmd, &at);
                        const expected_bits = takeBytes(cmd, &at, 8);
                        const expected: f64 = @bitCast(std.mem.readInt(u64, expected_bits[0..8], .little));
                        // One player is the whole surface: a new play
                        // re-keys and re-routes the single entry in place,
                        // exactly as the engine replaces its channel.
                        audio_entry.used = true;
                        audio_entry.key_len = key.len;
                        @memcpy(audio_entry.key[0..key.len], key);
                        audio_entry.event_tag = event_tag;
                        fx.playAudio(.{
                            .key = audio_key_base,
                            .path = audio_path,
                            .url = url,
                            .cache_path = effectiveAudioCachePath(cache_path, url),
                            // The wire carries the app's number; anything
                            // that is not a representable byte count means
                            // "unknown size" (0), the engine's own default.
                            .expected_bytes = if (expected >= 1 and expected <= 9007199254740992.0)
                                @intFromFloat(expected)
                            else
                                0,
                            .on_event = audioEventMsg,
                        });
                    },
                    // audio_ctl [op][key_len][key][verb u8][value f64 LE]
                    0x0F => {
                        const key = takeShortBytes(cmd, &at);
                        const verb = takeByte(cmd, &at);
                        const value_bits = takeBytes(cmd, &at, 8);
                        const value: f64 = @bitCast(std.mem.readInt(u64, value_bits[0..8], .little));
                        runAudioCtl(fx, key, verb, value);
                    },
                    // window_show [op][label_len][label]
                    0x10 => {
                        const label = takeShortBytes(cmd, &at);
                        fx.showWindow(label);
                    },
                    // quit_app [op]
                    0x11 => fx.quitApp(),
                    // image_load [op][id f64 LE][event_tag]
                    //            [path_len u32 LE][path][url_len u32 LE][url]
                    //            [cache_len u32 LE][cache][expected f64 LE]
                    0x12 => {
                        const id_bits = takeBytes(cmd, &at, 8);
                        const id_value: f64 = @bitCast(std.mem.readInt(u64, id_bits[0..8], .little));
                        const event_tag = takeByte(cmd, &at);
                        const image_path = takeLongBytes(cmd, &at);
                        const url = takeLongBytes(cmd, &at);
                        const cache_path = takeLongBytes(cmd, &at);
                        const expected_bits = takeBytes(cmd, &at, 8);
                        const expected: f64 = @bitCast(std.mem.readInt(u64, expected_bits[0..8], .little));
                        issueImageLoad(fx, id_value, event_tag, image_path, url, cache_path, expected, image_rejects);
                    },
                    // image_cancel [op][id f64 LE]
                    0x13 => {
                        const id_bits = takeBytes(cmd, &at, 8);
                        const id_value: f64 = @bitCast(std.mem.readInt(u64, id_bits[0..8], .little));
                        runImageCancel(fx, id_value);
                    },
                    else => @panic("ts core host: unknown command wire record - the core and this runtime disagree on cmd_format_version"),
                }
            }
        }

        /// The shared routed-op head: [key_len][key][ok_tag][err_tag].
        const RoutedHead = struct { key: []const u8, ok_tag: u8, err_tag: u8 };

        fn takeRoutedHead(cmd: []const u8, at: *usize) RoutedHead {
            const key = takeShortBytes(cmd, at);
            const ok_tag = takeByte(cmd, at);
            const err_tag = takeByte(cmd, at);
            return .{ .key = key, .ok_tag = ok_tag, .err_tag = err_tag };
        }

        fn fetchMethod(wire: u8) std.http.Method {
            return switch (wire) {
                0 => .GET,
                1 => .POST,
                2 => .PUT,
                3 => .DELETE,
                4 => .PATCH,
                5 => .HEAD,
                else => @panic("ts core host: unknown fetch method wire value - the core and this runtime disagree on cmd_format_version"),
            };
        }

        /// Claim a named-op table entry. A live wire key is the keyed-
        /// effect discipline's REPLACE: the in-flight predecessor is
        /// dropped (marked, its engine call cancelled, its terminal
        /// swallowed — no message) and the new op takes a fresh entry.
        /// A full table is a panic like the request table's — it
        /// mirrors the engine's slot count, which cannot hold more in
        /// flight either (a dropped entry holds its slot only until
        /// its `.cancelled` terminal drains).
        fn allocEffectEntry(fx: *Fx, head: RoutedHead) u64 {
            if (head.key.len > 0) {
                if (findEffect(head.key)) |existing| dropEffectEntry(fx, existing);
            }
            const index = freeEffectIndex() orelse
                @panic("ts core host: more than 16 named engine ops in flight - the op table mirrors the engine's max_effects slots");
            const entry = &effects_table[index];
            entry.used = true;
            entry.dropped = false;
            entry.key_len = head.key.len;
            @memcpy(entry.key[0..head.key.len], head.key);
            entry.ok_tag = head.ok_tag;
            entry.err_tag = head.err_tag;
            return index;
        }

        /// The silent drop shared by replace and wire cancel: the entry
        /// stops being live (its key is free immediately) and its
        /// engine call is cancelled — the `.cancelled` terminal retires
        /// the entry through the result callback, which swallows it.
        fn dropEffectEntry(fx: *Fx, index: usize) void {
            effects_table[index].dropped = true;
            fx.cancel(effect_key_base + index);
        }

        /// A dropped entry's key is dead to lookup: reissuing it is a
        /// fresh effect, and cancel aimed at it finds nothing.
        fn findEffect(key: []const u8) ?usize {
            for (&effects_table, 0..) |*entry, index| {
                if (entry.used and !entry.dropped and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeEffectIndex() ?usize {
            for (&effects_table, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// Arm (or re-arm) a one-shot delay. A live wire key reuses its
        /// slot: the engine timer replaces in place under the same
        /// engine key and restarts from now — the debounce discipline.
        fn armDelay(fx: *Fx, key: []const u8, after_ms: f64, tag: u8) void {
            const index = blk: {
                if (key.len > 0) {
                    if (findDelay(key)) |existing| break :blk existing;
                }
                break :blk freeDelayIndex() orelse
                    @panic("ts core host: more than 16 armed delays - the delay table mirrors the engine's max_effect_timers");
            };
            const entry = &delays[index];
            entry.used = true;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.tag = tag;
            fx.startTimer(.{
                .key = delay_key_base + index,
                .interval_ms = intervalMs(after_ms),
                .mode = .one_shot,
                .on_fire = delayFireMsg,
            });
        }

        fn findDelay(key: []const u8) ?usize {
            for (&delays, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeDelayIndex() ?usize {
            for (&delays, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        // ------------------------------------------------ spawn streams

        const SpawnHead = struct { key: []const u8, line_tag: u8, exit_tag: u8, err_tag: u8 };

        /// Open a spawn stream: claim a non-retiring stream entry (the
        /// keyed-effect discipline's ONE exception — a live wire key
        /// REJECTS the new spawn, because a running subprocess is never
        /// killed implicitly; cancel it first) and hand the argv to the
        /// engine. Everything dynamic
        /// the engine refuses (argv bytes over the block bound, stdin
        /// over 4 KiB, no free slot) comes back as one `.rejected` exit
        /// through the stream's own err arm — never silent.
        fn issueSpawn(
            fx: *Fx,
            head: SpawnHead,
            collect: bool,
            argv: []const []const u8,
            stdin: []const u8,
            rejects: *[max_rejects_per_cmd]u8,
            reject_count: *usize,
        ) void {
            if (head.key.len > 0 and findStream(head.key) != null) {
                if (reject_count.* >= max_rejects_per_cmd) {
                    @panic("ts core host: one command value carries more rejected named ops than the effect table holds");
                }
                rejects[reject_count.*] = head.err_tag;
                reject_count.* += 1;
                return;
            }
            const index = freeStreamIndex() orelse
                @panic("ts core host: more than 16 spawn streams in flight - the stream table mirrors the engine's max_effects slots");
            const entry = &streams[index];
            entry.used = true;
            entry.key_len = head.key.len;
            @memcpy(entry.key[0..head.key.len], head.key);
            entry.line_tag = head.line_tag;
            entry.exit_tag = head.exit_tag;
            entry.err_tag = head.err_tag;
            entry.collect = collect;
            fx.spawn(.{
                .key = spawn_key_base + index,
                .argv = argv,
                .stdin = if (stdin.len > 0) stdin else null,
                .output = if (collect) .collect else .lines,
                .on_line = if (head.line_tag != spawn_no_line_tag) spawnLineMsg else null,
                .on_exit = spawnExitMsg,
            });
        }

        fn findStream(key: []const u8) ?usize {
            for (&streams, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeStreamIndex() ?usize {
            for (&streams, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// The stream entry an engine spawn result names — looked up
        /// WITHOUT retiring (lines flow through it repeatedly; only the
        /// exit terminal retires, in `spawnExitMsg`).
        fn streamAt(key: u64) *StreamEntry {
            if (key < spawn_key_base) {
                @panic("ts core host: a spawn result arrived outside the bridge's stream key namespace");
            }
            const index = key - spawn_key_base;
            if (index >= streams.len or !streams[index].used) {
                @panic("ts core host: a spawn result arrived for a stream the bridge is not tracking");
            }
            return &streams[index];
        }

        /// `LineMsgFn` for spawn streams: every stdout line routes the
        /// entry's line arm with the line bytes; the entry stays live.
        /// Only set when the wire carries a line arm, so this never
        /// sees `spawn_no_line_tag`.
        fn spawnLineMsg(line: runtime_effects.EffectLine) Msg {
            const entry = streamAt(line.key);
            return msgFromTagBytes(entry.line_tag, line.line);
        }

        /// `ExitMsgFn` for spawn streams — the stream's ONE terminal,
        /// retiring the entry: a clean `.exited` end routes the exit
        /// arm (line mode: the code as its single number payload;
        /// collect mode: the code/output record, with a truncated
        /// collect routing err "truncated" instead — a cut stdout must
        /// never parse as whole); every other reason routes the err arm
        /// with the reason name as bytes.
        fn spawnExitMsg(exit: runtime_effects.EffectExit) Msg {
            const entry = streamAt(exit.key);
            entry.used = false;
            if (exit.reason == .exited) {
                if (!entry.collect) {
                    return msgFromTagNumber(entry.exit_tag, @floatFromInt(exit.code));
                }
                if (!exit.output_truncated) {
                    return msgFromTagNumberBytes("spawn exit", "{ code, output }", entry.exit_tag, exit.code, exit.output);
                }
            }
            const reason = if (exit.reason == .exited) "truncated" else @tagName(exit.reason);
            return msgFromTagBytes(entry.err_tag, reason);
        }

        // ------------------------------------------------- audio stream

        /// The audio_ctl record: drive the single playback channel,
        /// gated by the wire key — a verb aimed at a key that is not
        /// the open stream no-ops (its playback is already gone), the
        /// same idle no-op the engine's own verbs keep. `stop` closes
        /// the stream: the entry retires and later platform stragglers
        /// are the engine's to swallow.
        fn runAudioCtl(fx: *Fx, key: []const u8, verb: u8, value: f64) void {
            if (!audio_entry.used or !std.mem.eql(u8, audio_entry.wireKey(), key)) return;
            switch (verb) {
                0 => fx.pauseAudio(),
                1 => fx.resumeAudio(),
                2 => {
                    audio_entry.used = false;
                    fx.stopAudio();
                },
                // The wire carries the app's f64; anything that is not a
                // millisecond offset seeks to 0 (the engine clamps the
                // high end to the duration itself).
                3 => fx.seekAudio(if (value >= 0 and value <= 9007199254740992.0) @intFromFloat(value) else 0),
                // The engine clamps volume to 0..1 (NaN clamps to the
                // bound arithmetic's result deterministically).
                4 => fx.setAudioVolume(@floatCast(value)),
                else => @panic("ts core host: unknown audio_ctl verb wire value - the core and this runtime disagree on cmd_format_version"),
            }
        }

        /// `AudioMsgFn` for the audio stream: every playback event
        /// routes the entry's event arm. The entry never retires here —
        /// `completed`/`failed` streams may still speak (the app often
        /// starts the next track from `completed`), and audio_ctl
        /// `stop` is the explicit close.
        fn audioEventMsg(event: runtime_effects.EffectAudio) Msg {
            if (!audio_entry.used) {
                @panic("ts core host: an audio event arrived with no open bridge stream");
            }
            return msgFromTagAudio(audio_entry.event_tag, event);
        }

        /// Issue one image load. The keyed-effect discipline here is
        /// the SPAWN exception, by the same reasoning: one load per id
        /// at a time, never replaced implicitly — a duplicate LIVE id
        /// rejects the new load (event arm, state "rejected", at the
        /// post-cycle boundary), and so do an id the f64 wire cannot
        /// honestly carry into the u64 registry (0, negatives,
        /// fractions, 2^53 and past) and a 17th in-flight load (the table
        /// mirrors the engine's max_effects slots, whose own exhaustion
        /// answer is the same rejected result). Everything else the
        /// engine refuses dynamically (a full registry, a bad source)
        /// comes back through the entry's own event arm — never silent.
        fn issueImageLoad(
            fx: *Fx,
            id_value: f64,
            event_tag: u8,
            image_path: []const u8,
            url: []const u8,
            cache_path: []const u8,
            expected: f64,
            image_rejects: *ImageRejectStage,
        ) void {
            // Strictly BELOW 2^53 (the SDK contract): at 2^53 the f64
            // grid steps by 2, so 2^53 is the first value that aliases
            // a neighbor (2^53 + 1) on the wire — the bridge rejects it
            // rather than guess which integer the app meant. 2^53 - 1
            // is the last id every tier carries exactly.
            const representable = std.math.isFinite(id_value) and
                id_value >= 1 and id_value < 9007199254740992.0 and
                @floor(id_value) == id_value;
            if (!representable) {
                image_rejects.push(event_tag, 0);
                return;
            }
            const id: u64 = @intFromFloat(id_value);
            if (findImage(id) != null) {
                image_rejects.push(event_tag, id);
                return;
            }
            const index = freeImageIndex() orelse {
                // All 16 entries hold live loads — one gallery screen's
                // Cmd.batch reaches this. The engine answers its own
                // slot exhaustion with a dynamic `.rejected` result, and
                // the audio channel's exhaustion story is a quiet
                // in-place replace; a full bridge table speaks the same
                // vocabulary: exactly one rejected result through the
                // event arm, never a crash — however many loads one
                // batch stages against it.
                image_rejects.push(event_tag, id);
                return;
            };
            const entry = &images[index];
            entry.used = true;
            entry.id = id;
            entry.event_tag = event_tag;
            fx.loadImage(.{
                .id = id,
                .path = image_path,
                .url = url,
                .cache_path = effectiveImageCachePath(cache_path, url),
                // The wire carries the app's number; anything that is
                // not a representable byte count means "unknown size"
                // (0), the engine's own default.
                .expected_bytes = if (expected >= 1 and expected <= 9007199254740992.0)
                    @intFromFloat(expected)
                else
                    0,
                .on_result = imageResultMsg,
            });
        }

        fn findImage(id: u64) ?usize {
            for (&images, 0..) |*entry, index| {
                if (entry.used and entry.id == id) return index;
            }
            return null;
        }

        fn freeImageIndex() ?usize {
            for (&images, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// The image_cancel record: end the in-flight load under the
        /// id, if any, LOUDLY — the engine delivers the load's one
        /// terminal as `.cancelled`, which routes the entry's own event
        /// arm through `imageResultMsg` and retires the entry (freeing
        /// the id for a fresh load), the spawn cancel discipline. An id
        /// naming no live entry — or one the wire cannot carry exactly,
        /// which no load could ever park under — is a no-op, the same
        /// idle no-op audio_ctl keeps: whatever it aimed at is already
        /// gone. The raw id IS the engine key (image loads never mint a
        /// bridge namespace), and every bridge key base sits above 2^53,
        /// so the cancel can never reach another table's slot.
        fn runImageCancel(fx: *Fx, id_value: f64) void {
            const representable = std.math.isFinite(id_value) and
                id_value >= 1 and id_value < 9007199254740992.0 and
                @floor(id_value) == id_value;
            if (!representable) return;
            const id: u64 = @intFromFloat(id_value);
            if (findImage(id) == null) return;
            fx.cancel(id);
        }

        /// `ImageMsgFn` for image loads: the ONE terminal routes the
        /// entry's event arm and retires the entry.
        fn imageResultMsg(result: runtime_effects.EffectImageResult) Msg {
            const index = findImage(result.id) orelse
                @panic("ts core host: an image result arrived with no open bridge entry");
            const entry = &images[index];
            entry.used = false;
            return msgFromTagImage(entry.event_tag, result);
        }

        /// The wire `cancel` record: first match wins across the four
        /// keyed tables — requests (silent drop), named engine ops
        /// (silent drop: the entry is marked dropped, the engine's
        /// `.cancelled` terminal retires it, and its Msg is swallowed —
        /// no arm dispatches), spawn streams (the child dies and its
        /// exit routes the err arm with "cancelled" — killing a process
        /// IS an observable event, so spawn's cancel stays loud), then
        /// delays (silent — a cancelled delay just never fires).
        /// Unknown keys are a no-op; the audio stream is not cancel's
        /// to end (audio_ctl `stop` closes it).
        fn cancelWireKey(fx: *Fx, key: []const u8) void {
            if (key.len == 0) return;
            if (findRequest(key)) |index| {
                fx.cancelHostRequest(request_key_base + index);
                requests[index].used = false;
                return;
            }
            if (findEffect(key)) |index| {
                dropEffectEntry(fx, index);
                return;
            }
            if (findStream(key)) |index| {
                // Same shape: the engine ends the child and the
                // `.cancelled` exit retires the entry in spawnExitMsg.
                fx.cancel(spawn_key_base + index);
                return;
            }
            if (findDelay(key)) |index| {
                fx.cancelTimer(delay_key_base + index);
                delays[index].used = false;
            }
        }

        /// Issue (or replace) a routed request. Keyed requests reuse
        /// their live table entry — re-routing the tags in place while
        /// the engine replaces the in-flight call under the same engine
        /// key. Unkeyed requests (`key.len == 0`) each take a fresh
        /// entry: nothing can replace or cancel them.
        fn issueRequest(fx: *Fx, name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, payload: []const u8) void {
            const index = blk: {
                if (key.len > 0) {
                    if (findRequest(key)) |existing| break :blk existing;
                }
                break :blk freeRequestIndex() orelse
                    @panic("ts core host: more than 16 host requests in flight - the request table mirrors the engine's max_effects slots");
            };
            const entry = &requests[index];
            entry.used = true;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.ok_tag = ok_tag;
            entry.err_tag = err_tag;
            fx.hostRequest(.{
                .key = request_key_base + index,
                .name = name,
                .payload = payload,
                .on_result = hostResultMsg,
            });
        }

        fn findRequest(key: []const u8) ?usize {
            for (&requests, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeRequestIndex() ?usize {
            for (&requests, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// `HostMsgFn` for every bridge request: route the terminal to
        /// the entry's ok/err arm with the result bytes, retiring the
        /// entry. Runs during the drain, before the Msg dispatches —
        /// the frame arena is empty, so the payload copy lands at its
        /// base and commits with the model it may end up in.
        fn hostResultMsg(result: runtime_effects.EffectHostResult) Msg {
            if (result.key < request_key_base) {
                @panic("ts core host: a host result arrived outside the bridge's request key namespace");
            }
            const index = result.key - request_key_base;
            if (index >= requests.len or !requests[index].used) {
                @panic("ts core host: a host result arrived for a request the bridge is not tracking");
            }
            const entry = &requests[index];
            entry.used = false;
            return msgFromTagBytes(if (result.ok) entry.ok_tag else entry.err_tag, result.bytes);
        }

        // ------------------------------------------- named engine ops

        /// Retire the named-op entry an engine terminal names and hand
        /// back its routing tags plus whether the entry was dropped —
        /// a dropped entry's terminal must be swallowed, not routed.
        fn takeEffectEntry(key: u64) struct { ok_tag: u8, err_tag: u8, dropped: bool } {
            if (key < effect_key_base) {
                @panic("ts core host: an effect terminal arrived outside the bridge's named-op key namespace");
            }
            const index = key - effect_key_base;
            if (index >= effects_table.len or !effects_table[index].used) {
                @panic("ts core host: an effect terminal arrived for a named op the bridge is not tracking");
            }
            const entry = &effects_table[index];
            entry.used = false;
            return .{ .ok_tag = entry.ok_tag, .err_tag = entry.err_tag, .dropped = entry.dropped };
        }

        /// A dropped entry's terminal (the `.cancelled` end of a
        /// replaced or wire-cancelled op): flag the next dispatch to
        /// swallow it and hand back an inert stand-in Msg — the flagged
        /// dispatch never reads it. The err arm's bytes shape makes a
        /// valid value; nothing routes.
        fn swallowedMsg(err_tag: u8) Msg {
            swallow_next_dispatch = true;
            return msgFromTagBytes(err_tag, "");
        }

        /// `FileMsgFn` for read_file/write_file: reads route their ok
        /// arm with the content bytes, writes their (payload-less) ok
        /// arm; every non-ok outcome routes the err arm with the
        /// outcome's name as bytes. A dropped entry's terminal routes
        /// nothing — the silent drop.
        fn fileResultMsg(result: runtime_effects.EffectFileResult) Msg {
            const tags = takeEffectEntry(result.key);
            if (tags.dropped) return swallowedMsg(tags.err_tag);
            if (result.outcome == .ok) {
                if (result.op == .read) return msgFromTagBytes(tags.ok_tag, result.bytes);
                return msgFromTagVoid(tags.ok_tag);
            }
            return msgFromTagBytes(tags.err_tag, @tagName(result.outcome));
        }

        /// `ResponseMsgFn` for fetch: an `.ok` un-truncated response
        /// routes the ok arm as `{ status, body }`; everything else —
        /// truncation included, so a cut body never parses as whole —
        /// routes the err arm with the reason as bytes. A dropped
        /// entry's terminal routes nothing — the silent drop.
        fn fetchResultMsg(response: runtime_effects.EffectResponse) Msg {
            const tags = takeEffectEntry(response.key);
            if (tags.dropped) return swallowedMsg(tags.err_tag);
            if (response.outcome == .ok and !response.truncated) {
                return msgFromTagNumberBytes("fetch response", "{ status, body }", tags.ok_tag, response.status, response.body);
            }
            const reason = if (response.outcome == .ok) "truncated" else @tagName(response.outcome);
            return msgFromTagBytes(tags.err_tag, reason);
        }

        /// `ClipboardMsgFn` for clip_read (writes are fire-and-forget
        /// and never route): ok routes the text bytes, everything else
        /// the outcome name. A dropped entry's terminal routes nothing
        /// — the silent drop.
        fn clipboardResultMsg(result: runtime_effects.EffectClipboardResult) Msg {
            const tags = takeEffectEntry(result.key);
            if (tags.dropped) return swallowedMsg(tags.err_tag);
            if (result.outcome == .ok) return msgFromTagBytes(tags.ok_tag, result.text);
            return msgFromTagBytes(tags.err_tag, @tagName(result.outcome));
        }

        /// `TimerMsgFn` for one-shot delays: the slot retires on fire
        /// (platform one-shots self-stop) and the named arm dispatches
        /// with the fire time in fractional milliseconds.
        fn delayFireMsg(timer: runtime_effects.EffectTimer) Msg {
            if (timer.outcome == .rejected) {
                @panic("ts core host: the platform rejected a Cmd.delay timer (no timer service, or the fx timer table is full)");
            }
            if (timer.key < delay_key_base) {
                @panic("ts core host: a delay fired outside the bridge's delay key namespace");
            }
            const index = timer.key - delay_key_base;
            if (index >= delays.len or !delays[index].used) {
                @panic("ts core host: a delay fired for a slot the bridge is not tracking");
            }
            delays[index].used = false;
            const ms = @as(f64, @floatFromInt(timer.timestamp_ns)) / std.time.ns_per_ms;
            return msgFromTagNumber(delays[index].tag, ms);
        }

        // ------------------------------------------ subscription timers

        /// Reconcile the declarative subscription set against the fixed
        /// timer table — the same algorithm as the transpiler package's
        /// run-fidelity drivers, engine-backed: match by key, arm new
        /// keys into the first free slot, re-arm on interval change,
        /// re-route on tag change, cancel the missing. Slot order
        /// everywhere, so record/replay walk identical tables.
        fn reconcileTimers(fx: *Fx) void {
            if (comptime !has_subscriptions) return;
            const subs = core.subscriptions(model_root);
            var seen = [_]bool{false} ** timers.len;
            var at: usize = 0;
            while (at < subs.len) {
                const op = takeByte(subs, &at);
                if (op != 0x01) {
                    @panic("ts core host: unknown subscription wire record - the core and this runtime disagree on cmd_format_version");
                }
                // timer [op][key_len][key][every_ms f64 LE][msg_tag]
                const key = takeShortBytes(subs, &at);
                const every_bits = takeBytes(subs, &at, 8);
                const every_ms: f64 = @bitCast(std.mem.readInt(u64, every_bits[0..8], .little));
                const tag = takeByte(subs, &at);
                if (!(every_ms >= 1) or !(every_ms <= 31_536_000_000.0)) {
                    // The lower bound also rejects NaN; the upper (one
                    // year) keeps the engine's ns conversion in range.
                    @panic("ts core host: Sub.timer interval must be between 1ms and one year");
                }
                var slot: ?usize = null;
                for (&timers, 0..) |*entry, index| {
                    if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) slot = index;
                }
                if (slot) |index| {
                    seen[index] = true;
                    const entry = &timers[index];
                    if (entry.every_ms != every_ms) {
                        entry.every_ms = every_ms;
                        // Interval change re-arms: the engine replaces
                        // the active key in place and the platform timer
                        // restarts from now.
                        fx.startTimer(.{
                            .key = timer_key_base + index,
                            .interval_ms = intervalMs(every_ms),
                            .mode = .repeating,
                            .on_fire = timerFireMsg,
                        });
                    }
                    // A tag-only change re-routes without re-arming.
                    entry.tag = tag;
                } else {
                    const index = freeTimerIndex() orelse
                        @panic("ts core host: more than 16 subscription timers - the timer table mirrors the engine's max_effect_timers");
                    seen[index] = true;
                    const entry = &timers[index];
                    entry.used = true;
                    entry.key_len = key.len;
                    @memcpy(entry.key[0..key.len], key);
                    entry.every_ms = every_ms;
                    entry.tag = tag;
                    fx.startTimer(.{
                        .key = timer_key_base + index,
                        .interval_ms = intervalMs(every_ms),
                        .mode = .repeating,
                        .on_fire = timerFireMsg,
                    });
                }
            }
            for (&timers, 0..) |*entry, index| {
                if (entry.used and !seen[index]) {
                    entry.used = false;
                    fx.cancelTimer(timer_key_base + index);
                }
            }
        }

        fn freeTimerIndex() ?usize {
            for (&timers, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// The engine arms whole milliseconds; the wire carries f64.
        /// Round half up, floor at 1 (validated above).
        fn intervalMs(every_ms: f64) u64 {
            return @intFromFloat(@max(1.0, @round(every_ms)));
        }

        /// `TimerMsgFn` for every bridge timer: dispatch the slot's arm
        /// with the fire time in fractional milliseconds.
        fn timerFireMsg(timer: runtime_effects.EffectTimer) Msg {
            if (timer.outcome == .rejected) {
                @panic("ts core host: the platform rejected a subscription timer (no timer service, or the fx timer table is full)");
            }
            if (timer.key < timer_key_base) {
                @panic("ts core host: a timer fired outside the bridge's timer key namespace");
            }
            const index = timer.key - timer_key_base;
            if (index >= timers.len) {
                @panic("ts core host: a timer fired outside the bridge's timer table");
            }
            const ms = @as(f64, @floatFromInt(timer.timestamp_ns)) / std.time.ns_per_ms;
            return msgFromTagNumber(timers[index].tag, ms);
        }

        // -------------------------------------------- Msg construction

        /// Build the Msg arm at declaration-order index `tag` carrying
        /// `bytes` as its single payload. The bytes are copied into the
        /// core's frame arena first: the engine's slices are drain
        /// scratch, and the commit walkers only copy frame-resident
        /// pointers into the model heap.
        fn msgFromTagBytes(tag: u8, bytes: []const u8) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime arm.type == []const u8) {
                        const copy = core.rt.frameAlloc(u8, bytes.len);
                        @memcpy(copy, bytes);
                        return @unionInit(Msg, arm.name, copy);
                    }
                    @panic("ts core host: a routed result targets Msg arm '" ++ arm.name ++ "', whose payload is not bytes");
                }
            }
            @panic("ts core host: a routed result names a Msg tag outside the union");
        }

        /// Build the payload-less Msg arm at index `tag` (write_file's
        /// ok route — success carries nothing).
        fn msgFromTagVoid(tag: u8) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime arm.type == void) {
                        return @unionInit(Msg, arm.name, {});
                    }
                    @panic("ts core host: a routed result targets Msg arm '" ++ arm.name ++ "', which is not payload-less");
                }
            }
            @panic("ts core host: a routed result names a Msg tag outside the union");
        }

        /// Build the two-field number/bytes record arm at index `tag`
        /// (fetch's `{ status, body }` and a collect spawn's
        /// `{ code, output }`): the arm must be a struct of exactly one
        /// number field and one bytes field, matched BY TYPE (the
        /// transpiler validates the shape, so field names stay the
        /// app's). The bytes copy into the core's frame arena like
        /// every routed payload; the number widens into its field the
        /// way the subset's number model classes it (i64 or f64).
        fn msgFromTagNumberBytes(comptime what: []const u8, comptime shape: []const u8, tag: u8, number: anytype, bytes: []const u8) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    const arm_info = @typeInfo(arm.type);
                    if (comptime arm_info == .@"struct") {
                        const fields = arm_info.@"struct".fields;
                        const record_shape = comptime blk: {
                            if (fields.len != 2) break :blk false;
                            var bytes_fields = 0;
                            var number_fields = 0;
                            for (fields) |f| {
                                if (f.type == []const u8) bytes_fields += 1;
                                if (f.type == i64 or f.type == f64) number_fields += 1;
                            }
                            break :blk bytes_fields == 1 and number_fields == 1;
                        };
                        if (comptime record_shape) {
                            var payload: arm.type = undefined;
                            inline for (fields) |f| {
                                if (comptime f.type == []const u8) {
                                    const copy = core.rt.frameAlloc(u8, bytes.len);
                                    @memcpy(copy, bytes);
                                    @field(payload, f.name) = copy;
                                } else if (comptime f.type == f64) {
                                    @field(payload, f.name) = @floatFromInt(number);
                                } else {
                                    @field(payload, f.name) = @intCast(number);
                                }
                            }
                            return @unionInit(Msg, arm.name, payload);
                        }
                    }
                    @panic("ts core host: a " ++ what ++ " targets Msg arm '" ++ arm.name ++ "', which is not a " ++ shape ++ " record");
                }
            }
            @panic("ts core host: a " ++ what ++ " names a Msg tag outside the union");
        }

        /// Whether an arm payload struct is the audio event record: the
        /// six SDK-fixed fields, matched by NAME — `state` (any enum;
        /// its members are matched by member name at delivery),
        /// `positionMs`/`durationMs` (numbers), `playing`/`buffering`
        /// (booleans), `bands` (bytes).
        fn audioArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 6) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "positionMs") or std.mem.eql(u8, f.name, "durationMs")) {
                    if (f.type != i64 and f.type != f64) ok = false;
                } else if (std.mem.eql(u8, f.name, "playing") or std.mem.eql(u8, f.name, "buffering")) {
                    if (f.type != bool) ok = false;
                } else if (std.mem.eql(u8, f.name, "bands")) {
                    if (f.type != []const u8) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        /// The arm's `state` member for an engine event kind, matched
        /// by member NAME (the transpiler pins the member set, so the
        /// app's declaration order never matters to the wire).
        fn audioStateValue(comptime E: type, kind: runtime_effects.EffectAudioEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: an audio event kind has no member in the event arm's state union - the transpiler's own shape check should have stopped this build");
        }

        /// Build the six-field audio event arm at index `tag` from an
        /// engine event, by field name. The band bytes copy into the
        /// core's frame arena like every routed bytes payload; the
        /// millisecond fields widen the way the subset's number model
        /// classes them (i64 or f64).
        fn msgFromTagAudio(tag: u8, event: runtime_effects.EffectAudio) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime audioArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = audioStateValue(f.type, event.kind);
                            } else if (comptime std.mem.eql(u8, f.name, "positionMs")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.position_ms) else @intCast(event.position_ms);
                            } else if (comptime std.mem.eql(u8, f.name, "durationMs")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.duration_ms) else @intCast(event.duration_ms);
                            } else if (comptime std.mem.eql(u8, f.name, "playing")) {
                                @field(payload, f.name) = event.playing;
                            } else if (comptime std.mem.eql(u8, f.name, "buffering")) {
                                @field(payload, f.name) = event.buffering;
                            } else {
                                const copy = core.rt.frameAlloc(u8, event.bands.len);
                                @memcpy(copy, &event.bands);
                                @field(payload, f.name) = copy;
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: an audio event targets Msg arm '" ++ arm.name ++ "', which is not the six-field audio event record");
                }
            }
            @panic("ts core host: an audio event names a Msg tag outside the union");
        }

        /// The five-field image result record, matched by field name —
        /// `audioArmShape`'s twin.
        fn imageArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 5) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "id") or std.mem.eql(u8, f.name, "width") or std.mem.eql(u8, f.name, "height") or std.mem.eql(u8, f.name, "status")) {
                    if (f.type != i64 and f.type != f64) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        /// The arm's `state` member for an engine image outcome,
        /// matched by member NAME — `audioStateValue`'s twin.
        fn imageStateValue(comptime E: type, outcome: runtime_effects.EffectImageOutcome) E {
            const name = @tagName(outcome);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: an image outcome has no member in the result arm's state union - the transpiler's own shape check should have stopped this build");
        }

        /// Build the five-field image result arm at index `tag` from an
        /// engine result, by field name. `id` is the requested ImageId
        /// echoed verbatim (always below 2^53 — the bridge refused
        /// anything wider — so both number classes carry it exactly).
        fn msgFromTagImage(tag: u8, result: runtime_effects.EffectImageResult) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime imageArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = imageStateValue(f.type, result.outcome);
                            } else if (comptime std.mem.eql(u8, f.name, "id")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(result.id) else @intCast(result.id);
                            } else if (comptime std.mem.eql(u8, f.name, "width")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(result.width) else @intCast(result.width);
                            } else if (comptime std.mem.eql(u8, f.name, "height")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(result.height) else @intCast(result.height);
                            } else {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(result.status) else @intCast(result.status);
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: an image result targets Msg arm '" ++ arm.name ++ "', which is not the five-field image result record");
                }
            }
            @panic("ts core host: an image result names a Msg tag outside the union");
        }

        /// Build the Msg arm at index `tag` carrying one number (`now`
        /// timestamps and timer fires; an i64-classed arm truncates the
        /// way the subset's number model does at index sites).
        fn msgFromTagNumber(tag: u8, value: f64) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime arm.type == f64) {
                        return @unionInit(Msg, arm.name, value);
                    } else if (comptime arm.type == i64) {
                        return @unionInit(Msg, arm.name, @intFromFloat(value));
                    }
                    @panic("ts core host: a timestamp targets Msg arm '" ++ arm.name ++ "', whose payload is not a number");
                }
            }
            @panic("ts core host: a timestamp names a Msg tag outside the union");
        }

        // ------------------------------------------------- wire cursor

        fn takeByte(bytes: []const u8, at: *usize) u8 {
            if (at.* >= bytes.len) @panic("ts core host: truncated wire record");
            const value = bytes[at.*];
            at.* += 1;
            return value;
        }

        fn takeBytes(bytes: []const u8, at: *usize, len: usize) []const u8 {
            if (len > bytes.len - at.*) @panic("ts core host: truncated wire record");
            const slice = bytes[at.* .. at.* + len];
            at.* += len;
            return slice;
        }

        /// A one-byte-length-prefixed field (names and keys).
        fn takeShortBytes(bytes: []const u8, at: *usize) []const u8 {
            const len: usize = takeByte(bytes, at);
            return takeBytes(bytes, at, len);
        }

        /// A u32-LE-length-prefixed field (payloads).
        fn takeLongBytes(bytes: []const u8, at: *usize) []const u8 {
            const len_bytes = takeBytes(bytes, at, 4);
            const len: usize = std.mem.readInt(u32, len_bytes[0..4], .little);
            return takeBytes(bytes, at, len);
        }
    };
}
