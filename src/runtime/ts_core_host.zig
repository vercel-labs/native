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
//!                  next drain, in command-stream order with the
//!                  engine's own refusals, the refused id echoed; ids
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
//!   image_unregister
//!               -> `fx.unregisterImage(id)`: free the registry slot
//!                  under the id — registration's synchronous
//!                  discipline in reverse, direct registry surgery
//!                  with no terminal and no Msg. An id with no
//!                  registration (or one the wire cannot carry
//!                  exactly) is a no-op, image_cancel's idle rule. It
//!                  never touches the load table: a load in flight
//!                  under the id keeps running and its terminal still
//!                  registers the pixels — cancel the load first to
//!                  keep the slot free.
//!   channel_open-> `fx.openChannel` keyed by the app's own numeric key
//!                  (the image_load id convention: the raw key IS the
//!                  engine key, and the bridge holds a key->tag table).
//!                  The entry is non-retiring the spawn way: every
//!                  channel event routes the event arm — a five-field
//!                  record built by field NAME (key/state/bytes/
//!                  droppedPending/droppedTotal; `state`'s enum members
//!                  are matched by member name, exactly the
//!                  data/closed/rejected set) — until the one `closed`
//!                  (or a refused open's `rejected`) terminal retires
//!                  it. POSTING is not a TS-tier verb: transpiled cores
//!                  are single-threaded, so the thread-safe posting
//!                  handle is native-side API (`Effects.channelHandle`)
//!                  for embedders and platform-services extensions —
//!                  the TS tier opens, closes, and receives. A
//!                  duplicate LIVE key rejects the new open (one
//!                  channel per key, never replaced implicitly),
//!                  dispatching state "rejected" at the next drain, in
//!                  command-stream order with the engine's own
//!                  refusals, the refused key echoed; keys the wire
//!                  cannot carry exactly reject the same way echoing
//!                  key 0, and so does a full bridge table.
//!   channel_close-> `fx.closeChannel(key)` on the live channel under
//!                  the key, if any: staged posts flush and the
//!                  engine's one `.closed` terminal routes the entry's
//!                  event arm and retires it. A key naming no live
//!                  channel (or one the wire cannot carry exactly) is
//!                  a no-op, audio_ctl's idle rule. Channels are keyed
//!                  numerically, so the string-keyed cancel never
//!                  touches them — this is their close.
//!   pty_spawn   -> `fx.ptySpawn` through the PTY table (`pty_key_base`
//!                  + index) — non-retiring the spawn way: coalesced
//!                  "output" batches route the event arm across
//!                  dispatches — a six-field record built by field NAME
//!                  (state/bytes/code/reason/signal/droppedWrites;
//!                  `state`'s and `reason`'s enum members are matched
//!                  by member name, so the app's declaration order is
//!                  free) — and the exactly-one "exit" terminal retires
//!                  the entry. An empty wire TERM opens with the
//!                  engine's default (the fetch-timeout convention);
//!                  grid dimensions ride the wire as f64 subset numbers
//!                  and a value the u16 transport cannot carry exactly
//!                  spawns with dimension 0, which the engine answers
//!                  with one "rejected" exit — loud, never a guess. A
//!                  duplicate LIVE wire key rejects the new spawn (the
//!                  spawn discipline: a running terminal's child is a
//!                  running subprocess, never killed implicitly),
//!                  dispatching one "exit" with reason "rejected" at
//!                  the next drain, in command-stream order with the
//!                  engine's own refusals; a full bridge table rejects
//!                  the same way.
//!   pty_write   -> `fx.ptyWrite` on the live session under the wire
//!                  key — fire-and-forget (keystrokes): a key naming no
//!                  open session is a no-op (the exit was already on
//!                  its way), and refused payloads count into the exit
//!                  event's droppedWrites, never silence.
//!   pty_resize  -> `fx.ptyResize` on the live session under the wire
//!                  key — fire-and-forget like pty_write; a key naming
//!                  no open session is a no-op, and a grid value the
//!                  u16 transport cannot carry exactly resizes nothing
//!                  (the no-op rule: there is no honest grid to push).
//!   pty_kill    -> `fx.ptyKill` on the live session under the wire key
//!                  — LOUD, the spawn cancel discipline: the engine
//!                  ends the child and the session's one "exit"
//!                  terminal routes its own event arm with reason
//!                  "cancelled", retiring the entry. A key naming no
//!                  open session is a no-op. Sessions are keyed by
//!                  their own family's verbs, so the string-keyed
//!                  `cancel` record never touches them — pty_kill is
//!                  their kill, the way audio_ctl stop is audio's
//!                  close.
//!   audio_ctl   -> the engine's control verbs (`fx.pauseAudio`/
//!                  `resumeAudio`/`stopAudio`/`seekAudio`/
//!                  `setAudioVolume`), gated by the wire key: a verb
//!                  whose key does not name the open stream is a no-op
//!                  (the playback it aimed at is gone). `stop` also
//!                  retires the bridge entry — no events for that key
//!                  after it.
//!   video_load  -> `fx.loadVideo` on the bridge's single video entry.
//!                  The engine key is `videoKeyForTag` (the
//!                  `video_key_base` namespace with the load's event
//!                  tag in the low byte; the engine has ONE player, so
//!                  the bridge holds one stream), non-retiring the
//!                  audio way, gated by the wire key for verbs: every
//!                  `EffectVideo` event (loaded/position/completed/
//!                  failed/rejected) routes the arm of the load whose
//!                  key it echoes —
//!                  a seven-field record built by field NAME (state/
//!                  positionMs/durationMs/playing/buffering/width/
//!                  height; `state`'s enum members are matched by
//!                  member name, so the app's declaration order is
//!                  free) — until video_ctl `stop` (or a replacing
//!                  video_load, which re-keys and re-routes the same
//!                  entry) closes it. The record's surface is the
//!                  app's own media-surface id (decoded frames flow
//!                  platform-side into that texture channel, never
//!                  through this bridge); an id the wire cannot carry
//!                  exactly reaches the engine as 0, which it refuses
//!                  with one `.rejected` event — never silent.
//!                  `completed`/`failed`/`rejected` do NOT retire the
//!                  entry: stop is the explicit close, audio's rule.
//!   video_ctl   -> the engine's control verbs (`fx.playVideo`/
//!                  `pauseVideo`/`stopVideo`/`seekVideo`/
//!                  `setVideoVolume`/`setVideoMuted`/`setVideoLoop`),
//!                  gated by the wire key: a verb whose key does not
//!                  name the open stream is a no-op (the playback it
//!                  aimed at is gone). `stop` also retires the bridge
//!                  entry — no events for that key after it.
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
//!                  audio and video streams are not cancel's to end —
//!                  their ctl `stop` records are their closes.
//!
//! THE KEYED-EFFECT DISCIPLINE is ONE rule across request, read_file,
//! write_file, fetch, clip_read, and delay: a keyed effect REPLACES its
//! live predecessor (the superseded effect's result is dropped — no
//! message), and `cancel` drops it silently (no terminal arm dispatch).
//! For the named ops the bridge implements the drop by marking the
//! superseded entry dropped and cancelling its engine call; the
//! engine's `.cancelled` terminal retires the entry and its Msg is
//! swallowed before dispatch. The ONE exception is a live `Cmd.spawn`
//! key: a duplicate REJECTS the new spawn — its err arm dispatches
//! with "rejected" on the next drain, at the refusal's command-stream
//! position (see the rejection-ordering paragraph below) — because a
//! running subprocess is never killed implicitly; cancel it first. And
//! spawn's explicit cancel stays loud (err arm "cancelled"), because
//! killing a process is an observable event.
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
//! `fx.wallMs` is. Bridge-refused rejections (spawn/image/channel)
//! stage into the ENGINE's loop-side pending order at refusal time
//! (`Effects.stageLoopMsg`) and dispatch at the next drain — the same
//! delivery moment as the engine's own refusals, so a `Cmd.batch`
//! whose records are refused by DIFFERENT layers (the bridge's table
//! validation, the engine's cross-family key gate) still dispatches
//! its rejections in COMMAND-STREAM order: one seq-ordered stream is
//! the ordering authority for every rejection, `Cmd.batch`'s
//! performed-in-order contract extended to refusals. A second
//! delivery moment is exactly how families fall out of stream order,
//! so a new refusing family joins by staging, never by dispatching
//! from its own boundary.
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

/// The engine-key namespace of the bridge's single video playback
/// channel ("TSVI") — the audio key's twin, except the low byte
/// carries the issuing load's event-arm tag: every `EffectVideo` event
/// echoes the key of the playback that produced it, so a staged
/// synchronous `.failed` that delivers AFTER a replacing load re-keyed
/// the entry still routes the arm of the load it answers (the mutable
/// entry's tag would misroute it to the replacement's arm).
pub const video_key_base: u64 = 0x5453_5649_0000_0000;

/// The engine key for a video load routed to `event_tag`'s arm.
pub fn videoKeyForTag(event_tag: u8) u64 {
    return video_key_base | event_tag;
}

/// Engine-key namespace for pty sessions ("TSPT"): `base + table
/// index`, deterministic in issue order. Ptys share the keyed
/// families' one engine key space without ever colliding on a key.
pub const pty_key_base: u64 = 0x5453_5054_0000_0000;

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

        /// The single video stream entry — the audio entry's exact
        /// shape (one player is the whole engine surface). Non-retiring:
        /// video_ctl `stop` closes it, a new video_load re-keys and
        /// re-routes it in place.
        const VideoEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            event_tag: u8 = 0,
            /// The load identity this entry's own accepted load minted
            /// (`Effects.videoMintedToken`): the proof that the
            /// playback on the single engine channel is still THIS
            /// stream — a load the bridge never issued (a declarative
            /// element's) may have replaced it, and the entry's verbs
            /// must not mutate or cancel someone else's playback.
            token: u64 = 0,

            fn wireKey(entry: *const VideoEntry) []const u8 {
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

        /// One open external-source channel, keyed by the app's own
        /// numeric key (which IS the engine key, the image
        /// convention). Non-retiring the spawn way: `data` events flow
        /// through it across dispatches; the one `closed` (or a
        /// refused open's `rejected`) terminal retires it. Sized to
        /// the engine's channel table.
        const ChannelEntry = struct {
            used: bool = false,
            key: u64 = 0,
            event_tag: u8 = 0,
        };

        /// One live pty session — the stream entries' non-retiring
        /// shape: "output" events route through it repeatedly across
        /// dispatches, and only the one "exit" terminal retires it. The
        /// table index IS the engine key (minus `pty_key_base`),
        /// deterministic in issue order; sized to the engine's pty
        /// table.
        const PtyEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            event_tag: u8 = 0,

            fn wireKey(entry: *const PtyEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
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
        var video_entry: VideoEntry = .{};
        var images: [runtime_effects.max_effects]ImageEntry = @splat(.{});
        var channels: [runtime_effects.max_effect_channels]ChannelEntry = @splat(.{});
        var ptys: [runtime_effects.max_effect_ptys]PtyEntry = @splat(.{});
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

        // Bridge-refused dispatches (a spawn under a live wire key, an
        // image load or channel open under a duplicate live id/key, an
        // unrepresentable one, or a full bridge table) do NOT dispatch
        // from the bridge's own boundary: each refusal builds its
        // record's err/event arm Msg ("rejected", echoing the
        // requested ImageId / channel key where the family has one —
        // 0 when the wire value is not an exactly-carried positive
        // integer, since there is no honest integer to echo) and
        // stages it into the ENGINE's loop-side pending order at
        // refusal time (`Effects.stageLoopMsg`). One seq-ordered
        // stream is the ordering authority for every rejection, so a
        // batch mixing bridge-refused and engine-refused records
        // dispatches all of them in command-stream order at the next
        // drain — see the result-ordering contract in the module doc.
        // The staged Msgs are self-contained (static reason bytes and
        // scalar echoes, never frame-arena slices) and regenerate
        // deterministically under replay: the walk re-runs against the
        // same table state, so record and replay stage identical
        // sequences — `stageLoopMsg`'s two caller contracts.

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
            video_entry = .{};
            images = @splat(.{});
            channels = @splat(.{});
            ptys = @splat(.{});
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
        /// Bounded to the completions that existed at entry, exactly
        /// like `UiApp.drainEffects`: a completion produced by a
        /// dispatch inside this pass waits for the wake its producer
        /// already nudged, keeping the session journal's event
        /// boundaries causal (see `Effects.DrainBoundary`).
        pub fn drain(fx: *Fx) void {
            var boundary = fx.drainBoundary();
            while (fx.takeMsgWithin(&boundary)) |msg| dispatch(fx, msg);
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

        /// The tail of every cycle: walk the command bytes (staging any
        /// bridge-refused rejections into the engine's pending order as
        /// it goes — see the rejection note above `init`), reconcile
        /// subscriptions against the NEW committed model, reset the
        /// frame arena, then run the cycle's `now` dispatches (each a
        /// full cycle of its own, on the fresh frame, in record order;
        /// deterministic under record and replay alike).
        fn finishCycle(fx: *Fx, cmd: []const u8, depth: usize) void {
            var nows: [max_nows_per_cmd]PendingNow = undefined;
            var now_count: usize = 0;
            runCmd(fx, cmd, &nows, &now_count);
            reconcileTimers(fx);
            core.rt.frameReset();
            for (nows[0..now_count]) |pending| {
                dispatchDepth(fx, msgFromTagNumber(pending.tag, @floatFromInt(pending.ms)), depth + 1);
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
                        issueSpawn(fx, .{ .key = key, .line_tag = line_tag, .exit_tag = exit_tag, .err_tag = err_tag }, mode == 1, argv[0..argc], stdin);
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
                        issueImageLoad(fx, id_value, event_tag, image_path, url, cache_path, expected);
                    },
                    // image_cancel [op][id f64 LE]
                    0x13 => {
                        const id_bits = takeBytes(cmd, &at, 8);
                        const id_value: f64 = @bitCast(std.mem.readInt(u64, id_bits[0..8], .little));
                        runImageCancel(fx, id_value);
                    },
                    // image_unregister [op][id f64 LE]
                    0x14 => {
                        const id_bits = takeBytes(cmd, &at, 8);
                        const id_value: f64 = @bitCast(std.mem.readInt(u64, id_bits[0..8], .little));
                        runImageUnregister(fx, id_value);
                    },
                    // channel_open [op][key f64 LE][event_tag]
                    0x15 => {
                        const key_bits = takeBytes(cmd, &at, 8);
                        const key_value: f64 = @bitCast(std.mem.readInt(u64, key_bits[0..8], .little));
                        const event_tag = takeByte(cmd, &at);
                        issueChannelOpen(fx, key_value, event_tag);
                    },
                    // channel_close [op][key f64 LE]
                    0x16 => {
                        const key_bits = takeBytes(cmd, &at, 8);
                        const key_value: f64 = @bitCast(std.mem.readInt(u64, key_bits[0..8], .little));
                        runChannelClose(fx, key_value);
                    },
                    // video_load [op][key_len][key][event_tag][surface f64 LE]
                    //            [path_len u32 LE][path][url_len u32 LE][url]
                    //            [flags u8]
                    0x17 => {
                        const key = takeShortBytes(cmd, &at);
                        const event_tag = takeByte(cmd, &at);
                        const surface_bits = takeBytes(cmd, &at, 8);
                        const surface: f64 = @bitCast(std.mem.readInt(u64, surface_bits[0..8], .little));
                        const video_path = takeLongBytes(cmd, &at);
                        const url = takeLongBytes(cmd, &at);
                        const flags = takeByte(cmd, &at);
                        const options: Fx.LoadVideoOptions = .{
                            // The tag rides the key's low byte so every
                            // event routes the arm of the load that
                            // produced it (see `videoKeyForTag`).
                            .key = videoKeyForTag(event_tag),
                            // The wire carries the app's number; a surface
                            // that is not an exactly-carried positive
                            // integer (0, negatives, fractions, 2^53 and
                            // past — the image id bound) reaches the engine
                            // as 0, which the validation refuses with one
                            // `.rejected` event — never silent.
                            .surface = if (surface >= 1 and surface < 9007199254740992.0 and @floor(surface) == surface)
                                @intFromFloat(surface)
                            else
                                0,
                            .path = video_path,
                            .url = url,
                            .autoplay = (flags & 0x01) != 0,
                            .loop = (flags & 0x02) != 0,
                            .muted = (flags & 0x04) != 0,
                            .on_event = videoEventMsg,
                        };
                        // A load the engine's own deterministic gates
                        // would refuse must not commit the routing
                        // entry: the engine keeps the CURRENT playback
                        // on a rejected load, so re-keying first would
                        // route the surviving stream's events and verbs
                        // through the refused load's key and arm. Stage
                        // the rejection to the refused arm directly
                        // (the channel-admission precedent) and leave
                        // the entry — and the engine — untouched.
                        if (Fx.videoLoadRejected(options)) {
                            fx.stageLoopMsg(msgFromTagVideo(event_tag, .{
                                .key = videoKeyForTag(event_tag),
                                .kind = .rejected,
                            }));
                        } else {
                            // One player is the whole surface: an
                            // accepted load re-keys and re-routes the
                            // single entry in place, exactly as the
                            // engine replaces its channel.
                            video_entry.used = true;
                            video_entry.key_len = key.len;
                            @memcpy(video_entry.key[0..key.len], key);
                            video_entry.event_tag = event_tag;
                            fx.loadVideo(options);
                            // The identity this load minted (valid even
                            // when a synchronous refusal already reset
                            // the channel): the entry's verbs prove
                            // ownership against it.
                            video_entry.token = fx.videoMintedToken();
                        }
                    },
                    // video_ctl [op][key_len][key][verb u8][value f64 LE]
                    0x18 => {
                        const key = takeShortBytes(cmd, &at);
                        const verb = takeByte(cmd, &at);
                        const value_bits = takeBytes(cmd, &at, 8);
                        const value: f64 = @bitCast(std.mem.readInt(u64, value_bits[0..8], .little));
                        runVideoCtl(fx, key, verb, value);
                    },
                    // pty_spawn [op][key_len][key][event_tag]
                    //           [cols f64 LE][rows f64 LE][term_len][term]
                    //           [argc u8]([arg_len u32 LE][arg])*
                    0x19 => {
                        const key = takeShortBytes(cmd, &at);
                        const event_tag = takeByte(cmd, &at);
                        const cols_bits = takeBytes(cmd, &at, 8);
                        const cols: f64 = @bitCast(std.mem.readInt(u64, cols_bits[0..8], .little));
                        const rows_bits = takeBytes(cmd, &at, 8);
                        const rows: f64 = @bitCast(std.mem.readInt(u64, rows_bits[0..8], .little));
                        const term = takeShortBytes(cmd, &at);
                        const argc: usize = takeByte(cmd, &at);
                        if (argc == 0 or argc > runtime_effects.max_effect_argv) {
                            @panic("ts core host: a pty_spawn wire record carries more argv elements than the engine accepts - the transpiler's own bound should have stopped this build");
                        }
                        var argv: [runtime_effects.max_effect_argv][]const u8 = undefined;
                        for (0..argc) |i| argv[i] = takeLongBytes(cmd, &at);
                        issuePtySpawn(fx, key, event_tag, cols, rows, term, argv[0..argc]);
                    },
                    // pty_write [op][key_len][key][bytes_len u32 LE][bytes]
                    0x1A => {
                        const key = takeShortBytes(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        // TS `Cmd.ptyWrite` is fire-and-forget: a refusal
                        // counts into the exit's dropped_writes, so the
                        // acceptance result is ignored here.
                        if (findPty(key)) |index| _ = fx.ptyWrite(pty_key_base + index, bytes);
                    },
                    // pty_resize [op][key_len][key][cols f64 LE][rows f64 LE]
                    0x1B => {
                        const key = takeShortBytes(cmd, &at);
                        const cols_bits = takeBytes(cmd, &at, 8);
                        const cols: f64 = @bitCast(std.mem.readInt(u64, cols_bits[0..8], .little));
                        const rows_bits = takeBytes(cmd, &at, 8);
                        const rows: f64 = @bitCast(std.mem.readInt(u64, rows_bits[0..8], .little));
                        runPtyResize(fx, key, cols, rows);
                    },
                    // pty_kill [op][key_len][key]
                    0x1C => {
                        const key = takeShortBytes(cmd, &at);
                        // LOUD: the engine ends the child and the session's
                        // one "cancelled" exit routes its own event arm,
                        // retiring the entry in ptyEventMsg.
                        if (findPty(key)) |index| fx.ptyKill(pty_key_base + index);
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
        ) void {
            if (head.key.len > 0 and findStream(head.key) != null) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
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

        // ------------------------------------------------- video stream

        /// The video_ctl record: drive the single playback channel,
        /// gated by the wire key — a verb aimed at a key that is not
        /// the open stream no-ops (its playback is already gone), the
        /// same idle no-op the engine's own verbs keep. `stop` closes
        /// the stream: the entry retires and later platform stragglers
        /// are the engine's to swallow.
        fn runVideoCtl(fx: *Fx, key: []const u8, verb: u8, value: f64) void {
            if (!video_entry.used or !std.mem.eql(u8, video_entry.wireKey(), key)) return;
            if (verb == 2) {
                // `Cmd.videoStop` is the stream's CANCEL: the engine
                // drops THIS stream's staged answers (token-scoped —
                // even the synchronous terminal of a batch that
                // loaded, failed, and stopped in one dispatch, and
                // even when a later load reuses the same event tag),
                // and stops the player only while the channel still
                // plays this stream — a playback some other caller
                // loaded since (a declarative element) survives
                // untouched. A REPLACED predecessor sharing this arm
                // keeps its own owed terminal; only stop cancels.
                const token = video_entry.token;
                video_entry.used = false;
                fx.stopVideoCancel(token);
                return;
            }
            // The wire key names the bridge's entry, but the single
            // engine player may since have been replaced by a load the
            // bridge never issued (a declarative <video>): transport
            // verbs act only while the entry's own stream is the
            // playback on the channel — anything else is a stale key
            // and no-ops, the idle rule. VOLUME is the one exception
            // with the channel IDLE: it is a remembered preference the
            // next load re-applies (a failed load's handler routinely
            // sets it before retrying), and with nobody's playback on
            // the channel there is nothing to protect — a FOREIGN live
            // playback still gates it, its volume is not this key's to
            // move.
            if (fx.videoOwnerToken() != video_entry.token) {
                if (verb == 4 and fx.videoOwnerToken() == 0) {
                    fx.setVideoVolume(@floatCast(value));
                }
                return;
            }
            switch (verb) {
                0 => fx.playVideo(),
                1 => fx.pauseVideo(),
                // The wire carries the app's f64. In-window offsets pass
                // through (the engine clamps to the duration itself); a
                // FINITE offset PAST the exact-integer window saturates
                // just below it — still beyond every real duration, so
                // the engine's clamp lands it at the end, exactly what
                // an oversized forward seek asks for. Non-finite values
                // and negatives are not millisecond offsets at all (the
                // literal validation rejects them) and seek to 0.
                3 => fx.seekVideo(if (value >= 0 and value <= 9007199254740992.0)
                    @intFromFloat(value)
                else if (value > 9007199254740992.0 and std.math.isFinite(value))
                    runtime_effects.max_effect_video_scalar_exclusive - 1
                else
                    0),
                // The engine clamps volume to 0..1 (NaN clamps to the
                // bound arithmetic's result deterministically).
                4 => fx.setVideoVolume(@floatCast(value)),
                5 => fx.setVideoMuted(value != 0),
                6 => fx.setVideoLoop(value != 0),
                else => @panic("ts core host: unknown video_ctl verb wire value - the core and this runtime disagree on cmd_format_version"),
            }
        }

        /// `VideoMsgFn` for the video stream: every playback event
        /// routes by the TAG its own key carries (`videoKeyForTag`) —
        /// never the mutable entry's tag, which a replacing load in the
        /// same batch may already have re-pointed at another arm while
        /// the replaced playback's staged terminal was still awaiting
        /// its drain (a REPLACED stream still speaks its terminal).
        /// Stopped streams never reach here at all: video_ctl `stop`
        /// cancels the key's staged answers inside the engine
        /// (`stopVideoCancel`) and the engine swallows its own
        /// post-stop stragglers, so every event arriving carries a
        /// live stream's tag. The entry never retires here —
        /// `completed`/`failed` streams may still speak (the app often
        /// starts the next clip from `completed`), and video_ctl
        /// `stop` is the explicit close.
        fn videoEventMsg(event: runtime_effects.EffectVideo) Msg {
            return msgFromTagVideo(@intCast(event.key & 0xFF), event);
        }

        /// Issue one image load. The keyed-effect discipline here is
        /// the SPAWN exception, by the same reasoning: one load per id
        /// at a time, never replaced implicitly — a duplicate LIVE id
        /// rejects the new load (event arm, state "rejected", staged
        /// into the engine's pending order and delivered at the next
        /// drain), and so do an id the f64 wire cannot
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
                fx.stageLoopMsg(msgFromTagImage(event_tag, .{ .id = 0, .outcome = .rejected }));
                return;
            }
            const id: u64 = @intFromFloat(id_value);
            if (findImage(id) != null) {
                fx.stageLoopMsg(msgFromTagImage(event_tag, .{ .id = id, .outcome = .rejected }));
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
                fx.stageLoopMsg(msgFromTagImage(event_tag, .{ .id = id, .outcome = .rejected }));
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
                // not a representable WHOLE byte count — fractional,
                // out of range, NaN — means "unknown size" (0), the
                // engine's own default. The integer clause matters:
                // @intFromFloat would truncate 1.5 to 1, and the cache
                // would then verify downloads against a size the app
                // never declared — re-fetching on every launch. The
                // bound is strictly BELOW 2^53, the id gate's: 2^53 is
                // the first f64 that aliases a neighbor (2^53 + 1
                // arrives as the same wire value), so there is no one
                // honest count to install — it maps to "unknown" with
                // the fractionals rather than becoming a verification
                // size every real download misses. 0 is the honest
                // mapping; the emitter already stops the literal
                // spellings (NS1030).
                .expected_bytes = if (expected >= 1 and expected < 9007199254740992.0 and @floor(expected) == expected)
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

        /// The image_unregister record: free the registry slot under
        /// the id — direct registry surgery, registration's synchronous
        /// discipline in reverse (no terminal, no Msg; the engine call
        /// answers a bool the wire has no channel to carry, and a miss
        /// means whatever it aimed at is already gone — image_cancel's
        /// idle no-op). The bridge's load table is deliberately NOT
        /// consulted: unregister targets the REGISTRY, and a load in
        /// flight under the id is not a registry occupant — its
        /// terminal registers as usual, re-occupying the id, so an app
        /// that wants the slot to STAY free cancels the load first. An
        /// id the wire cannot carry exactly could never have been
        /// registered through this bridge, so it no-ops the same way.
        fn runImageUnregister(fx: *Fx, id_value: f64) void {
            const representable = std.math.isFinite(id_value) and
                id_value >= 1 and id_value < 9007199254740992.0 and
                @floor(id_value) == id_value;
            if (!representable) return;
            const id: u64 = @intFromFloat(id_value);
            _ = fx.unregisterImage(id);
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

        /// Open one external-source channel. The keyed-effect
        /// discipline here is the spawn/image exception, by the same
        /// reasoning: one channel per key at a time, never replaced
        /// implicitly — a duplicate LIVE key rejects the new open
        /// (event arm, state "rejected", staged into the engine's
        /// pending order and delivered at the next drain),
        /// and so do a key the f64 wire cannot honestly carry into the
        /// u64 engine (0, negatives, fractions, 2^53 and past — the
        /// image id gate) and a bridge table already holding
        /// `max_effect_channels` live channels. Everything else the
        /// engine refuses dynamically (a key occupied by another
        /// family, the engine's own table) comes back through the
        /// entry's event arm as its `.rejected` terminal — never
        /// silent. Posting is native-side API: embedders resolve
        /// `Effects.channelHandle(key)` and feed from their own
        /// threads; this bridge only opens, closes, and routes.
        fn issueChannelOpen(
            fx: *Fx,
            key_value: f64,
            event_tag: u8,
        ) void {
            const representable = std.math.isFinite(key_value) and
                key_value >= 1 and key_value < 9007199254740992.0 and
                @floor(key_value) == key_value;
            if (!representable) {
                fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = 0, .kind = .rejected }));
                return;
            }
            const key: u64 = @intFromFloat(key_value);
            if (findChannel(key) != null) {
                fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = key, .kind = .rejected }));
                return;
            }
            const index = freeChannelIndex() orelse {
                fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = key, .kind = .rejected }));
                return;
            };
            const entry = &channels[index];
            entry.used = true;
            entry.key = key;
            entry.event_tag = event_tag;
            _ = fx.openChannel(.{
                .key = key,
                .on_event = channelEventMsg,
            });
        }

        fn findChannel(key: u64) ?usize {
            for (&channels, 0..) |*entry, index| {
                if (entry.used and entry.key == key) return index;
            }
            return null;
        }

        fn freeChannelIndex() ?usize {
            for (&channels, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// The channel_close record: close the live channel under the
        /// key, if any — the engine flushes staged posts, delivers the
        /// one `.closed` terminal through `channelEventMsg` (which
        /// retires the entry), and frees the key. A key naming no live
        /// entry — or one the wire cannot carry exactly, which no
        /// channel could ever open under — is a no-op, audio_ctl's
        /// idle rule. The raw key IS the engine key (the image
        /// convention; every bridge key base sits above 2^53, so this
        /// can never reach another table's slot).
        fn runChannelClose(fx: *Fx, key_value: f64) void {
            const representable = std.math.isFinite(key_value) and
                key_value >= 1 and key_value < 9007199254740992.0 and
                @floor(key_value) == key_value;
            if (!representable) return;
            const key: u64 = @intFromFloat(key_value);
            if (findChannel(key) == null) return;
            fx.closeChannel(key);
        }

        /// `ChannelMsgFn` for external-source channels: every event
        /// routes the entry's event arm; the `closed` and `rejected`
        /// terminals retire the entry (freeing the key for a fresh
        /// open), `data` events keep it live — the spawn stream shape.
        fn channelEventMsg(event: runtime_effects.EffectChannelEvent) Msg {
            const index = findChannel(event.key) orelse
                @panic("ts core host: a channel event arrived with no open bridge entry");
            const entry = &channels[index];
            if (event.kind != .data) entry.used = false;
            return msgFromTagChannel(entry.event_tag, event);
        }

        // -------------------------------------------------- pty sessions

        /// Open a pty session: claim a non-retiring entry (the spawn
        /// exception, by the same reasoning — a live wire key REJECTS
        /// the new spawn, because a running terminal's child is a
        /// running subprocess and is never killed implicitly; kill it
        /// first) and hand the request to the engine. Everything
        /// dynamic the engine refuses (argv over the block bound, a
        /// zero grid, a full engine table) comes back as one
        /// "rejected" exit through the entry's own event arm — never
        /// silent — and a transport that could not start as one
        /// "spawn_failed".
        fn issuePtySpawn(
            fx: *Fx,
            key: []const u8,
            event_tag: u8,
            cols: f64,
            rows: f64,
            term: []const u8,
            argv: []const []const u8,
        ) void {
            if (key.len > 0 and findPty(key) != null) {
                // The rejection is STAGED (delivered a later frame), so its
                // key must be self-contained: the wire key points into this
                // dispatch's command buffer, gone by delivery, so copy it
                // into the engine's durable staged-key store and reference
                // that. The app's key rides the refusal, correlating it
                // with its command — however many rejections one batch
                // stages, each keeps its own durable buffer.
                fx.stageLoopMsg(msgFromTagPty(event_tag, fx.stageLoopKey(key), true, .{ .key = 0, .kind = .exit, .reason = .rejected }));
                return;
            }
            const index = freePtyIndex() orelse {
                // The bridge table mirrors the engine's pty table, whose
                // own exhaustion answer is the same rejected exit — one
                // vocabulary for every refusal, never a crash. Staged, so
                // the requested key rides the engine's durable staged-key
                // store, not the frame arena.
                fx.stageLoopMsg(msgFromTagPty(event_tag, fx.stageLoopKey(key), true, .{ .key = 0, .kind = .exit, .reason = .rejected }));
                return;
            };
            const entry = &ptys[index];
            entry.used = true;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.event_tag = event_tag;
            if (term.len == 0) {
                // Wire "" = "the engine's default TERM" — the record
                // never bakes the default in (the fetch-timeout rule).
                fx.ptySpawn(.{
                    .key = pty_key_base + index,
                    .argv = argv,
                    .cols = ptyDimension(cols),
                    .rows = ptyDimension(rows),
                    .on_event = ptyEventMsg,
                });
            } else {
                fx.ptySpawn(.{
                    .key = pty_key_base + index,
                    .argv = argv,
                    .cols = ptyDimension(cols),
                    .rows = ptyDimension(rows),
                    .term = term,
                    .on_event = ptyEventMsg,
                });
            }
        }

        /// The wire carries the app's f64; the transport's grid is u16.
        /// Anything that is not a whole dimension in 1..65535 maps to
        /// 0, which `ptySpawn` answers with one deterministic
        /// "rejected" exit — loud, never a truncated guess (the emitter
        /// already stops the literal spellings, NS1030).
        fn ptyDimension(value: f64) u16 {
            if (!(std.math.isFinite(value) and value >= 1 and value <= 65535 and @floor(value) == value)) return 0;
            return @intFromFloat(value);
        }

        /// The pty_resize record: push a new grid to the live session
        /// under the wire key, if any — fire-and-forget. A key naming
        /// no session, or a grid value the u16 transport cannot carry
        /// exactly, is a no-op (there is no honest grid to push, and
        /// the engine's clamp would otherwise shrink the child to a
        /// 1x1 the app never asked for).
        fn runPtyResize(fx: *Fx, key: []const u8, cols: f64, rows: f64) void {
            const index = findPty(key) orelse return;
            const c = ptyDimension(cols);
            const r = ptyDimension(rows);
            if (c == 0 or r == 0) return;
            fx.ptyResize(pty_key_base + index, c, r);
        }

        fn findPty(key: []const u8) ?usize {
            if (key.len == 0) return null;
            for (&ptys, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freePtyIndex() ?usize {
            for (&ptys, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        /// `PtyMsgFn` for pty sessions: every event routes the entry's
        /// event arm; the one "exit" terminal retires the entry
        /// (freeing the wire key for a fresh session), "output"
        /// batches keep it live — the spawn stream shape.
        fn ptyEventMsg(event: runtime_effects.EffectPtyEvent) Msg {
            if (event.key < pty_key_base) {
                @panic("ts core host: a pty event arrived outside the bridge's pty key namespace");
            }
            const index = event.key - pty_key_base;
            if (index >= ptys.len or !ptys[index].used) {
                @panic("ts core host: a pty event arrived for a session the bridge is not tracking");
            }
            const entry = &ptys[index];
            const wire_key = entry.wireKey();
            if (event.kind == .exit) entry.used = false;
            // Live delivery is same-frame, so the key rides the frame arena.
            return msgFromTagPty(entry.event_tag, wire_key, false, event);
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

        /// `msgFromTagBytes` for STATIC payloads (the staged rejection
        /// Msgs' "rejected"): no frame-arena copy, because a staged
        /// Msg outlives the issuing cycle's frame reset — it is held
        /// in the engine's pending order until the next drain, so its
        /// payload must be self-contained (`stageLoopMsg`'s contract).
        /// The commit walkers keep non-frame pointers as-is, and a
        /// static string's lifetime is the program's.
        fn msgFromTagStaticBytes(tag: u8, comptime bytes: []const u8) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime arm.type == []const u8) {
                        return @unionInit(Msg, arm.name, bytes);
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

        /// Whether an arm payload struct is the video event record: the
        /// seven SDK-fixed fields, matched by NAME — `state` (any enum;
        /// its members are matched by member name at delivery),
        /// `positionMs`/`durationMs` (numbers), `playing`/`buffering`
        /// (booleans), `width`/`height` (numbers).
        fn videoArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 7) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "positionMs") or std.mem.eql(u8, f.name, "durationMs") or
                    std.mem.eql(u8, f.name, "width") or std.mem.eql(u8, f.name, "height"))
                {
                    if (f.type != i64 and f.type != f64) ok = false;
                } else if (std.mem.eql(u8, f.name, "playing") or std.mem.eql(u8, f.name, "buffering")) {
                    if (f.type != bool) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        /// The arm's `state` member for an engine event kind, matched
        /// by member NAME — `audioStateValue`'s twin.
        fn videoStateValue(comptime E: type, kind: runtime_effects.EffectVideoEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: a video event kind has no member in the event arm's state union - the transpiler's own shape check should have stopped this build");
        }

        /// Build the seven-field video event arm at index `tag` from an
        /// engine event, by field name. The millisecond and dimension
        /// fields widen the way the subset's number model classes them
        /// (i64 or f64).
        fn msgFromTagVideo(tag: u8, event: runtime_effects.EffectVideo) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime videoArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = videoStateValue(f.type, event.kind);
                            } else if (comptime std.mem.eql(u8, f.name, "positionMs")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.position_ms) else @intCast(event.position_ms);
                            } else if (comptime std.mem.eql(u8, f.name, "durationMs")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.duration_ms) else @intCast(event.duration_ms);
                            } else if (comptime std.mem.eql(u8, f.name, "playing")) {
                                @field(payload, f.name) = event.playing;
                            } else if (comptime std.mem.eql(u8, f.name, "buffering")) {
                                @field(payload, f.name) = event.buffering;
                            } else if (comptime std.mem.eql(u8, f.name, "width")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.width) else @intCast(event.width);
                            } else {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.height) else @intCast(event.height);
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: a video event targets Msg arm '" ++ arm.name ++ "', which is not the seven-field video event record");
                }
            }
            @panic("ts core host: a video event names a Msg tag outside the union");
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

        /// The five-field channel event record, matched by field name —
        /// `imageArmShape`'s twin: `key` (number), `state` (any enum;
        /// members matched by name at delivery), `bytes` (bytes),
        /// `droppedPending`/`droppedTotal` (numbers).
        fn channelArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 5) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "bytes")) {
                    if (f.type != []const u8) ok = false;
                } else if (std.mem.eql(u8, f.name, "key") or std.mem.eql(u8, f.name, "droppedPending") or std.mem.eql(u8, f.name, "droppedTotal")) {
                    if (f.type != i64 and f.type != f64) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        /// The arm's `state` member for an engine channel event kind,
        /// matched by member NAME — `imageStateValue`'s twin.
        fn channelStateValue(comptime E: type, kind: runtime_effects.EffectChannelEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: a channel event kind has no member in the event arm's state union - the transpiler's own shape check should have stopped this build");
        }

        /// Build the five-field channel event arm at index `tag` from
        /// an engine event, by field name. The bytes copy into the
        /// core's frame arena like every routed payload (the engine's
        /// slice is drain scratch); `key` is the channel key echoed
        /// verbatim (always below 2^53 — the bridge refused anything
        /// wider — so both number classes carry it exactly), and the
        /// drop counters widen the way the subset's number model
        /// classes them.
        fn msgFromTagChannel(tag: u8, event: runtime_effects.EffectChannelEvent) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime channelArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = channelStateValue(f.type, event.kind);
                            } else if (comptime std.mem.eql(u8, f.name, "key")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.key) else @intCast(event.key);
                            } else if (comptime std.mem.eql(u8, f.name, "droppedPending")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.dropped_pending) else @intCast(event.dropped_pending);
                            } else if (comptime std.mem.eql(u8, f.name, "droppedTotal")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.dropped_total) else @intCast(event.dropped_total);
                            } else if (event.bytes.len == 0) {
                                // Payload-free events (rejected/closed
                                // terminals, and the staged rejection
                                // Msgs that must be self-contained
                                // across the frame reset) carry the
                                // static empty slice, never a
                                // zero-length frame pointer.
                                @field(payload, f.name) = "";
                            } else {
                                const copy = core.rt.frameAlloc(u8, event.bytes.len);
                                @memcpy(copy, event.bytes);
                                @field(payload, f.name) = copy;
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: a channel event targets Msg arm '" ++ arm.name ++ "', which is not the five-field channel event record");
                }
            }
            @panic("ts core host: a channel event names a Msg tag outside the union");
        }

        /// The six-field pty event record, matched by field name —
        /// `channelArmShape`'s twin: `state` and `reason` (any enums;
        /// members matched by name at delivery), `bytes` (bytes),
        /// `code`/`signal`/`droppedWrites` (numbers).
        fn ptyArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 7) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state") or std.mem.eql(u8, f.name, "reason")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "bytes") or std.mem.eql(u8, f.name, "key")) {
                    if (f.type != []const u8) ok = false;
                } else if (std.mem.eql(u8, f.name, "code") or std.mem.eql(u8, f.name, "signal") or std.mem.eql(u8, f.name, "droppedWrites")) {
                    if (f.type != i64 and f.type != f64) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        /// The arm's `state` member for an engine pty event kind,
        /// matched by member NAME — `channelStateValue`'s twin.
        fn ptyStateValue(comptime E: type, kind: runtime_effects.EffectPtyEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: a pty event kind has no member in the event arm's state union - the transpiler's own shape check should have stopped this build");
        }

        /// The arm's `reason` member for an engine exit reason, matched
        /// by member NAME — the state member's twin.
        fn ptyReasonValue(comptime E: type, reason: runtime_effects.EffectExitReason) E {
            const name = @tagName(reason);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: a pty exit reason has no member in the event arm's reason union - the transpiler's own shape check should have stopped this build");
        }

        /// Build the six-field pty event arm at index `tag` from an
        /// engine event, by field name. The output bytes copy into the
        /// core's frame arena like every routed payload (the engine's
        /// slice is drain scratch); payload-free events — exits, and
        /// the staged rejection Msgs that must be self-contained across
        /// the frame reset — carry the static empty slice, the channel
        /// record's rule.
        fn msgFromTagPty(tag: u8, wire_key: []const u8, key_durable: bool, event: runtime_effects.EffectPtyEvent) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime ptyArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = ptyStateValue(f.type, event.kind);
                            } else if (comptime std.mem.eql(u8, f.name, "reason")) {
                                @field(payload, f.name) = ptyReasonValue(f.type, event.reason);
                            } else if (comptime std.mem.eql(u8, f.name, "code")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.code) else @intCast(event.code);
                            } else if (comptime std.mem.eql(u8, f.name, "signal")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.signal) else @intCast(event.signal);
                            } else if (comptime std.mem.eql(u8, f.name, "droppedWrites")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.dropped_writes) else @intCast(event.dropped_writes);
                            } else if (comptime std.mem.eql(u8, f.name, "key")) {
                                // The app's own session key, so two sessions
                                // sharing one event arm are told apart by this
                                // field (never the engine key). A LIVE event
                                // routes and delivers within one frame, so its
                                // key copies into the frame arena like every
                                // routed payload. A STAGED rejection (issued
                                // now, delivered a later frame, past a frame
                                // reset) passes `key_durable = true` with a key
                                // already in the durable reject ring, so it is
                                // referenced directly — a frame-arena copy there
                                // would dangle by delivery.
                                if (wire_key.len == 0) {
                                    @field(payload, f.name) = "";
                                } else if (key_durable) {
                                    @field(payload, f.name) = wire_key;
                                } else {
                                    const copy = core.rt.frameAlloc(u8, wire_key.len);
                                    @memcpy(copy, wire_key);
                                    @field(payload, f.name) = copy;
                                }
                            } else if (event.bytes.len == 0) {
                                @field(payload, f.name) = "";
                            } else {
                                const copy = core.rt.frameAlloc(u8, event.bytes.len);
                                @memcpy(copy, event.bytes);
                                @field(payload, f.name) = copy;
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: a pty event targets Msg arm '" ++ arm.name ++ "', which is not the seven-field pty event record");
                }
            }
            @panic("ts core host: a pty event names a Msg tag outside the union");
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
