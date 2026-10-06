//! The native host consumer for compiled TypeScript app cores: bridges
//! the versioned command/subscription wire format a compiled core
//! emits (`cmd_format_version` 9) onto the real effect engine
//! (`effects.zig`). The TypeScript tier's core module is a pure
//! Model/Msg/update core whose effects are INERT BYTES — this module is
//! the one place those bytes become engine calls, so the entire
//! existing effects machinery (executors, keyed slots, the completion
//! queue, the session journal, replay) carries TypeScript cores without
//! a parallel engine.
//!
//! `TsCoreHost(core)` is comptime-generic over the core module (the
//! corewire-generated mirror over a compiled archive, or any
//! hand-written module of the same shape) and expects:
//!
//!   core.rt              the core's runtime: `frameAlloc`,
//!                        `frameReset`, `resetAll`
//!   core.Model           the committed model struct
//!   core.Msg             the app Msg `union(enum)` (wire tags are the
//!                        arms' declaration-order indices)
//!   core.initialModel()  `*const Model`, or `InitResult{ model, cmd }`
//!                        for a boot command
//!   core.bootCommand()   the boot `Cmd` without reinitializing the core,
//!                        required when `initialModel` returns `InitResult`
//!   core.update(m, msg)  `*const Model`, or `UpdateResult{ model, cmd }`
//!   core.commitModelRoot the frame-end commit walker
//!   core.subscriptions   optional: `fn (*const Model) []const u8`
//!
//! Like the runtime it drives, a host instance is container-level
//! state — the contract is ONE LIVE APP PER CORE MODULE: two apps
//! over the same core in one process would share a committed root and
//! one set of bridge tables. A compiled archive additionally owns the
//! process's fixed-prefix C ABI symbol set, so a process carries ONE
//! compiled core (each e2e battery is its own binary for exactly that
//! reason).
//!
//! THE DISPATCH CYCLE — every Msg runs update → commit → command walk →
//! subscription reconcile → frame reset, in that order, because the
//! command and subscription bytes are frame-arena resident and must be
//! consumed before the reset. Wire records map onto the engine as:
//!
//!   persist     -> `fx.hostSend("core.persist", core.persistenceSnapshot())`
//!                  — no model bytes ride the Cmd wire; the host asks
//!                  the already-committed core for canonical bytes while
//!                  walking the command.
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
//!   fetch_stream -> `fx.fetch` (`.stream`) through the STREAM table;
//!                  every complete response line routes the line arm,
//!                  and the ONE terminal retires the entry: `.ok`
//!                  routes the HTTP status through the one-number ok
//!                  arm, every other outcome routes the err arm with
//!                  its name. Wire timeout 0 and max-line 0 select the
//!                  engine defaults. `cancel` is loud for a live fetch
//!                  stream: it ends with err "cancelled", with no lines
//!                  after the cancel.
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
//!                  it. POSTING is not a TS-tier verb: TypeScript cores
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
//!   window_hide -> `fx.hideWindow(label)` — retain the live window and
//!                  its views while ordering it out; window_show is the
//!                  inverse.
//!   dock_presence -> `fx.setDockPresence(visible)` — macOS regular/
//!                  accessory activation-policy switch; unsupported
//!                  hosts safely ignore it.
//!   quit_app    -> `fx.quitApp()` — the graceful terminate through the
//!                  same shutdown path a last-window close takes.
//!   show_notification -> `fx.showNotification` fire-and-forget; invalid or
//!                  unavailable requests fail closed, and replay suppresses
//!                  the external user-visible side effect.
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
//! producer is the compiled core's own runtime builders, so a bad record is a
//! build-pipeline bug the app author must see immediately.

const std = @import("std");
const runtime_effects = @import("effects.zig");
const platform = @import("../platform/root.zig");

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

/// Engine-key namespace for relational effects ("TSDB"). The DB family has
/// its own engine table, so these never consume the general request slots.
pub const db_key_base: u64 = 0x5453_4442_0000_0000;

/// Dedicated raw-file stream key namespace ("TSFS").
pub const file_stream_key_base: u64 = 0x5453_4653_0000_0000;

/// The spawn wire record's "no line routing" tag sentinel (the wire
/// format's shared constant).
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

        /// Generated service contracts bind their operation table and the
        /// canonical result decoder here. Ordinary HostCallBinding users do
        /// not install this seam, so raw Cmd.request keeps its byte result.
        pub const ServiceResultBinding = struct {
            index_fn: *const fn (name: []const u8) ?u16,
            streaming_fn: *const fn (operation: u16) bool,
            decode_fn: *const fn (operation: u16, tag: u8, bytes: []const u8) Msg,
        };

        const msg_arms = @typeInfo(Msg).@"union".fields;

        const update_returns_cmd = @typeInfo(@TypeOf(core.update)).@"fn".return_type.? != *const Model;
        const init_returns_cmd = @typeInfo(@TypeOf(core.initialModel)).@"fn".return_type.? != *const Model;
        const has_subscriptions = @hasDecl(core, "subscriptions");
        pub const environment_messages = if (@hasDecl(core, "envMsgs")) core.envMsgs else .{};

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
            service_operation: ?u16 = null,
            service_channel: ?u64 = null,
            ok_void: bool = false,

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
            full_result: bool = false,
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
            full_result: bool = false,
            mode: runtime_effects.TimerMode = .one_shot,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            tag: u8 = 0,

            fn wireKey(entry: *const DelayEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        /// One live spawn or fetch STREAM — the non-retiring entry kind: line
        /// results route through it repeatedly across dispatches, and
        /// only the exit terminal (or the engine's `.cancelled` end
        /// after a wire cancel) retires it. The table index IS the
        /// engine key (minus `spawn_key_base`), deterministic in issue
        /// order like every bridge table.
        const StreamEntry = struct {
            used: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            /// `spawn_no_line_tag` = lines dispatch nothing (spawn only;
            /// fetch streams always carry a line route).
            line_tag: u8 = spawn_no_line_tag,
            exit_tag: u8 = 0,
            err_tag: u8 = 0,
            collect: bool = false,
            complete_events: bool = false,
            /// Fetch lines are data records, so a cut or dropped line makes
            /// the eventual success terminal unusable. Spawn line mode keeps
            /// its existing best-effort contract.
            fetch: bool = false,
            damaged: bool = false,

            fn wireKey(entry: *const StreamEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        const FileStreamEntry = struct {
            used: bool = false,
            sink: bool = false,
            busy: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            chunk_tag: u8 = 0,
            done_tag: u8 = 0,
            err_tag: u8 = 0,
            cancelling: bool = false,
            fn wireKey(entry: *const FileStreamEntry) []const u8 {
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

        /// One microphone/system capture stream. Capture uses the engine's
        /// channel transport internally but keeps a distinct bridge table so
        /// terminal events retain the requested source and output format.
        /// Replacing a source may briefly leave its old entry closing while
        /// the new key is already live, so this mirrors channel capacity.
        const AudioCaptureEntry = struct {
            used: bool = false,
            key: u64 = 0,
            event_tag: u8 = 0,
            source: platform.AudioCaptureSource = .microphone,
            sample_rate: u32 = 0,
            channels: u8 = 0,
        };

        /// One live pty session — the stream entries' non-retiring
        /// shape: "output" events route through it repeatedly across
        /// dispatches, and only the one "exit" terminal retires it. The
        /// table index IS the engine key (minus `pty_key_base`),
        /// deterministic in issue order; sized to the engine's pty
        /// table.
        const PtyEntry = struct {
            used: bool = false,
            bound: bool = false,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            event_tag: u8 = 0,

            fn wireKey(entry: *const PtyEntry) []const u8 {
                return entry.key[0..entry.key_len];
            }
        };

        const DbEntry = struct {
            used: bool = false,
            query: bool = true,
            live: bool = false,
            signature: u64 = 0,
            key_len: usize = 0,
            key: [max_wire_key_bytes]u8 = undefined,
            page_tag: u8 = 0,
            done_tag: u8 = 0,
            err_tag: u8 = 0,

            fn wireKey(entry: *const DbEntry) []const u8 {
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
        var requests: [runtime_effects.max_effects + runtime_effects.max_store_effects + runtime_effects.max_credentials_effects]RequestEntry = @splat(.{});
        var timers: [runtime_effects.max_effect_timers]TimerEntry = @splat(.{});
        var effects_table: [runtime_effects.max_effects]EffectEntry = @splat(.{});
        var delays: [runtime_effects.max_effect_timers]DelayEntry = @splat(.{});
        var streams: [runtime_effects.max_effects]StreamEntry = @splat(.{});
        var file_streams: [runtime_effects.max_effect_file_streams]FileStreamEntry = @splat(.{});
        var audio_entry: AudioEntry = .{};
        var video_entry: VideoEntry = .{};
        var images: [runtime_effects.max_effects]ImageEntry = @splat(.{});
        var channels: [runtime_effects.max_effect_channels]ChannelEntry = @splat(.{});
        var audio_captures: [runtime_effects.max_effect_channels]AudioCaptureEntry = @splat(.{});
        var ptys: [runtime_effects.max_effect_ptys]PtyEntry = @splat(.{});
        var dbs: [runtime_effects.max_db_effects]DbEntry = @splat(.{});
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
        var service_results: ?ServiceResultBinding = null;
        var pending_service_channel_close: ?u64 = null;

        pub fn bindServiceResults(binding: ?ServiceResultBinding) void {
            service_results = binding;
        }

        /// A `now` record captured during the command walk, dispatched
        /// after the issuing cycle's frame reset.
        const ClipboardWriteEntry = struct {
            used: bool = false,
            key: [max_wire_key_bytes]u8 = undefined,
            key_len: usize = 0,
            tag: u8 = 0,
            fn wireKey(self: *const ClipboardWriteEntry) []const u8 {
                return self.key[0..self.key_len];
            }
        };
        var clipboard_writes: [runtime_effects.max_effects]ClipboardWriteEntry = @splat(.{});
        const clipboard_result_key_base: u64 = 0x5453_4352_0000_0000;

        const PendingNow = union(enum) {
            clock: struct { tag: u8, ms: i64 },
            decimal_clock: struct { tag: u8, ms: i64 },
            video: struct { tag: u8, snapshot: Fx.VideoSnapshot, key: [max_wire_key_bytes]u8, key_len: usize },
        };

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
            audio_captures = @splat(.{});
            ptys = @splat(.{});
            dbs = @splat(.{});
            clip_write_counter = 0;
            clipboard_writes = @splat(.{});
            audio_cache_dir_len = 0;
            image_cache_dir_len = 0;
            swallow_next_dispatch = false;
            const initial = core.initialModel();
            model_root = core.commitModelRoot(if (comptime init_returns_cmd) initial.model else initial);
            core.rt.frameReset();
        }

        /// The effects half of `init`: perform the boot command and
        /// reconcile the initial subscriptions against the committed
        /// boot model. The generated shim re-materializes only the boot
        /// command through `bootCommand`; calling `initialModel` here would
        /// reinitialize the compiled core and discard a model restored
        /// between `boot` and `performBoot`.
        pub fn performBoot(fx: *Fx) void {
            if (comptime init_returns_cmd) {
                finishCycle(fx, core.bootCommand(), 0);
            } else {
                finishCycle(fx, "", 0);
            }
        }

        /// The committed model root (valid until the next dispatch).
        pub fn model() *const Model {
            return model_root;
        }

        /// Replace the committed core model from canonical snapshot bytes and
        /// refresh the host mirror. Generated external cores expose the inverse
        /// of `modelSnapshot`; hand-written test cores intentionally do not.
        pub fn restoreSnapshot(snapshot: []const u8) void {
            if (comptime !@hasDecl(core, "restoreModel")) {
                @panic("ts core host: this core exposes no restoreModel entry - regenerate it with core ABI version 2");
            } else {
                model_root = core.restoreModel(snapshot);
            }
        }

        /// Run the generated pure migration seam. The returned bytes are a
        /// host-owned current-format snapshot and must be freed by `allocator`.
        pub fn migrateSnapshot(snapshot: []const u8, from_version: u64, allocator: std.mem.Allocator) ?[]u8 {
            if (comptime @hasDecl(core, "migrateModel")) {
                return core.migrateModel(snapshot, from_version, allocator);
            }
            return null;
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
        /// drained effect results run the TypeScript core through the
        /// same path Zig cores use. A Msg flagged by its own result
        /// callback as a dropped entry's terminal is swallowed here —
        /// the silent drop the keyed-effect discipline promises.
        pub fn dispatch(fx: *Fx, msg: Msg) void {
            if (swallow_next_dispatch) {
                swallow_next_dispatch = false;
                return;
            }
            if (pending_service_channel_close) |channel_key| {
                pending_service_channel_close = null;
                fx.closeChannel(channel_key);
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
            reconcileSubscriptions(fx);
            fx.flushDbSubscriptions();
            core.rt.frameReset();
            for (nows[0..now_count]) |*pending| {
                const reply = switch (pending.*) {
                    .clock => |clock| msgFromTagNumber(clock.tag, @floatFromInt(clock.ms)),
                    .decimal_clock => |clock| msgFromTagBytes(clock.tag, decimalFrame(clock.ms)),
                    .video => |*video| msgFromVideoSnapshot(video.tag, video.snapshot, video.key[0..video.key_len]),
                };
                dispatchDepth(fx, reply, depth + 1);
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
                    0x01 => {
                        const snapshot = if (comptime @hasDecl(core, "persistenceSnapshot")) core.persistenceSnapshot() else "";
                        fx.hostSend("core.persist", snapshot);
                    },
                    // now [op][msg_tag]
                    0x02 => {
                        const tag = takeByte(cmd, &at);
                        if (now_count.* >= max_nows_per_cmd) {
                            @panic("ts core host: one command value carries more than 16 Cmd.now records");
                        }
                        // The journaled clock read (replay pops the same
                        // value), captured in record order.
                        nows[now_count.*] = .{ .clock = .{ .tag = tag, .ms = fx.wallMs() } };
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
                    //         [ok_tag][err_tag][typed_service][len u32 LE][payload]
                    0x05 => {
                        const name = takeShortBytes(cmd, &at);
                        const key = takeShortBytes(cmd, &at);
                        const ok_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const typed_service = takeByte(cmd, &at);
                        if (typed_service > 1) @panic("ts core host: invalid typed-service request flag");
                        const payload = takeLongBytes(cmd, &at);
                        issueRequest(fx, name, key, ok_tag, err_tag, typed_service == 1, payload);
                    },
                    // cancel [op][key_len][key]
                    0x06 => {
                        const key = takeShortBytes(cmd, &at);
                        cancelWireKey(fx, key);
                    },
                    // Complete file terminals and exact journaled clocks.
                    0x37, 0x38 => {
                        const key = takeShortBytes(cmd, &at);
                        const tag = takeByte(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const bytes = if (op == 0x38) takeLongBytes(cmd, &at) else "";
                        const file_op: runtime_effects.EffectFileOp = if (op == 0x38) .write else .read;
                        const index = allocEffectEntryWithFileResult(fx, .{ .key = key, .ok_tag = tag, .err_tag = tag }, file_op) orelse continue;
                        if (file_op == .read) fx.readFile(.{ .key = effect_key_base + index, .path = file_path, .on_result = completeFileResultMsg }) else fx.writeFile(.{ .key = effect_key_base + index, .path = file_path, .bytes = bytes, .on_result = completeFileResultMsg });
                    },
                    0x39 => {
                        const tag = takeByte(cmd, &at);
                        if (now_count.* >= max_nows_per_cmd) @panic("ts core host: too many clock replies");
                        nows[now_count.*] = .{ .decimal_clock = .{ .tag = tag, .ms = fx.wallMs() } };
                        now_count.* += 1;
                    },
                    0x3A => {
                        const key = takeShortBytes(cmd, &at);
                        const mode = takeByte(cmd, &at);
                        if (mode > 1) @panic("ts core host: invalid timer mode");
                        const ms: f64 = @bitCast(std.mem.readInt(u64, takeBytes(cmd, &at, 8)[0..8], .little));
                        const tag = takeByte(cmd, &at);
                        armResultTimer(fx, key, ms, tag, if (mode == 1) .repeating else .one_shot);
                    },
                    // read_file [op][key_len][key][ok][err][path_len u32 LE][path]
                    0x07 => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.readFile(.{
                            .key = effect_key_base + effect_index,
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
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.writeFile(.{
                            .key = effect_key_base + effect_index,
                            .path = file_path,
                            .bytes = bytes,
                            .on_result = fileResultMsg,
                        });
                    },
                    // append/stat and streaming raw-file effects.
                    0x2B => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.appendFile(.{ .key = effect_key_base + effect_index, .path = file_path, .bytes = bytes, .on_result = fileResultMsg });
                    },
                    0x2C => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.statFile(.{ .key = effect_key_base + effect_index, .path = file_path, .on_result = fileResultMsg });
                    },
                    0x32 => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.deleteFile(.{ .key = effect_key_base + effect_index, .path = file_path, .on_result = fileResultMsg });
                    },
                    0x2D => {
                        const key = takeShortBytes(cmd, &at);
                        const chunk_tag = takeByte(cmd, &at);
                        const done_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        issueReadFileStream(fx, key, chunk_tag, done_tag, err_tag, file_path);
                    },
                    0x2E => {
                        const head = takeRoutedHead(cmd, &at);
                        const file_path = takeLongBytes(cmd, &at);
                        issueWriteFileStream(fx, head, file_path);
                    },
                    0x2F => {
                        const head = takeRoutedHead(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        issueWriteFileChunk(fx, head, bytes);
                    },
                    0x30 => issueWriteFileClose(fx, takeRoutedHead(cmd, &at)),
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
                            @panic("ts core host: a fetch wire record carries more headers than the engine accepts - the frontend's own bound should have stopped this build");
                        }
                        var headers: [runtime_effects.max_effect_fetch_headers]std.http.Header = undefined;
                        for (0..header_count) |i| {
                            const name = takeShortBytes(cmd, &at);
                            const value = takeLongBytes(cmd, &at);
                            headers[i] = .{ .name = name, .value = value };
                        }
                        const body = takeLongBytes(cmd, &at);
                        // Both Cmd.fetch overloads occupy one public key
                        // space. A buffered fetch must not start beside a
                        // live line stream under the same key: cancel would
                        // otherwise find this named op first and leave the
                        // stream running. The live stream owns the key, so
                        // reject the newcomer through its own err arm.
                        if (head.key.len > 0 and (findStream(head.key) != null or reservedWireKeyOccupied(head.key))) {
                            fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
                        } else {
                            const effect_index = allocEffectEntry(fx, head) orelse continue;
                            fx.fetch(.{
                                .key = effect_key_base + effect_index,
                                .method = method,
                                .url = url,
                                .headers = headers[0..header_count],
                                .body = if (body.len > 0) body else null,
                                // Wire 0 = "the engine's default" — the record
                                // never bakes the default in.
                                .timeout_ms = if (timeout_ms == 0) runtime_effects.default_effect_fetch_timeout_ms else timeout_ms,
                                .on_response = fetchResultMsg,
                            });
                        }
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
                    // Complete spawn records; the legacy opcode remains unchanged.
                    0x33 => {
                        const key = takeShortBytes(cmd, &at);
                        const line_tag = takeByte(cmd, &at);
                        const exit_tag = takeByte(cmd, &at);
                        const mode = takeByte(cmd, &at);
                        const argc = takeByte(cmd, &at);
                        if (mode > 1 or argc == 0 or argc > runtime_effects.max_effect_argv) @panic("ts core host: invalid complete spawn wire record");
                        var argv: [runtime_effects.max_effect_argv][]const u8 = undefined;
                        for (0..argc) |i| argv[i] = takeLongBytes(cmd, &at);
                        const stdin = takeLongBytes(cmd, &at);
                        issueSpawn(fx, .{ .key = key, .line_tag = line_tag, .exit_tag = exit_tag, .err_tag = exit_tag, .complete_events = true }, mode == 1, argv[0..argc], stdin);
                    },
                    // Routed write completion, including rejection and cancellation.
                    0x34 => {
                        const key = takeShortBytes(cmd, &at);
                        const tag = takeByte(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        issueClipboardWrite(fx, key, tag, bytes);
                    },
                    // Capture now; reply after resetting the ABI result arena, in
                    // command order like Cmd.now. No intervening host turn occurs.
                    0x35 => {
                        const tag = takeByte(cmd, &at);
                        if (now_count.* >= max_nows_per_cmd) @panic("ts core host: over 16 immediate capability replies in one command");
                        const snapshot = fx.videoSnapshot();
                        const key = if (video_entry.used and fx.videoOwnerToken() == video_entry.token) video_entry.wireKey() else "";
                        nows[now_count.*] = .{ .video = .{ .tag = tag, .snapshot = snapshot, .key = undefined, .key_len = key.len } };
                        @memcpy(nows[now_count.*].video.key[0..key.len], key);
                        now_count.* += 1;
                    },
                    // clip_read [op][key_len][key][ok][err]
                    0x0B => {
                        const head = takeRoutedHead(cmd, &at);
                        const effect_index = allocEffectEntry(fx, head) orelse continue;
                        fx.readClipboard(.{
                            .key = effect_key_base + effect_index,
                            .on_result = clipboardResultMsg,
                        });
                    },
                    // delay [op][key_len][key][after_ms f64 LE][msg_tag]
                    0x0C => {
                        const key = takeShortBytes(cmd, &at);
                        const after_bits = takeBytes(cmd, &at, 8);
                        const after_ms: f64 = @bitCast(std.mem.readInt(u64, after_bits[0..8], .little));
                        const tag = takeByte(cmd, &at);
                        if (comptime !@hasDecl(core, "nativeTimerPolicy")) {
                            if (!(after_ms >= 1) or !(after_ms <= 31_536_000_000.0)) {
                                // Same bound as Sub.timer: the lower rejects NaN,
                                // the upper (one year) keeps ns conversion in range.
                                @panic("ts core host: Cmd.delay interval must be between 1ms and one year");
                            }
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
                            @panic("ts core host: a spawn wire record carries more argv elements than the engine accepts - the frontend's own bound should have stopped this build");
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
                    // channel_open [op][key f64 LE][event_tag][max_pending]
                    0x15 => {
                        const key_bits = takeBytes(cmd, &at, 8);
                        const key_value: f64 = @bitCast(std.mem.readInt(u64, key_bits[0..8], .little));
                        const event_tag = takeByte(cmd, &at);
                        const max_pending = takeByte(cmd, &at);
                        _ = issueChannelOpen(fx, key_value, event_tag, max_pending);
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
                            @panic("ts core host: a pty_spawn wire record carries more argv elements than the engine accepts - the frontend's own bound should have stopped this build");
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
                    // show_notification [op][title_len u32 LE][title]
                    //                   [subtitle_len u32 LE][subtitle]
                    //                   [body_len u32 LE][body]
                    0x1D => {
                        const title = takeLongBytes(cmd, &at);
                        const subtitle = takeLongBytes(cmd, &at);
                        const body = takeLongBytes(cmd, &at);
                        fx.showNotification(.{
                            .title = title,
                            .subtitle = subtitle,
                            .body = body,
                        });
                    },
                    // actionable_notification [op 0x31][id/title/subtitle/body/
                    // action_label/action_command as u32-length bytes]
                    0x31 => {
                        const notification_id = takeLongBytes(cmd, &at);
                        const title = takeLongBytes(cmd, &at);
                        const subtitle = takeLongBytes(cmd, &at);
                        const body = takeLongBytes(cmd, &at);
                        const action_label = takeLongBytes(cmd, &at);
                        const action_command = takeLongBytes(cmd, &at);
                        fx.showNotification(.{
                            .id = notification_id,
                            .title = title,
                            .subtitle = subtitle,
                            .body = body,
                            .action_label = action_label,
                            .action_command = action_command,
                        });
                    },
                    // audio_capture_start [op][key f64 LE][source u8]
                    //                     [sample_rate u32 LE][channels u8]
                    //                     [event_tag u8]
                    0x1E => {
                        const key_bits = takeBytes(cmd, &at, 8);
                        const key_value: f64 = @bitCast(std.mem.readInt(u64, key_bits[0..8], .little));
                        const source_wire = takeByte(cmd, &at);
                        const source = std.enums.fromInt(platform.AudioCaptureSource, source_wire) orelse
                            @panic("ts core host: unknown audio capture source wire value - the core and this runtime disagree on cmd_format_version");
                        const sample_rate = std.mem.readInt(u32, takeBytes(cmd, &at, 4)[0..4], .little);
                        const capture_channels = takeByte(cmd, &at);
                        const event_tag = takeByte(cmd, &at);
                        issueAudioCaptureStart(fx, key_value, source, sample_rate, capture_channels, event_tag);
                    },
                    // audio_capture_stop [op][key f64 LE]
                    0x1F => {
                        const key_bits = takeBytes(cmd, &at, 8);
                        const key_value: f64 = @bitCast(std.mem.readInt(u64, key_bits[0..8], .little));
                        runAudioCaptureStop(fx, key_value);
                    },
                    // fetch_stream [op][key_len][key][line][ok][err]
                    //              [method u8][timeout u32 LE]
                    //              [max_line_bytes u32 LE]
                    //              [url_len u32 LE][url][header_count u8]
                    //              ([name_len u8][name][value_len u32 LE][value])*
                    //              [body_len u32 LE][body]
                    0x20 => {
                        const key = takeShortBytes(cmd, &at);
                        const line_tag = takeByte(cmd, &at);
                        const ok_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const method = fetchMethod(takeByte(cmd, &at));
                        const timeout_bytes = takeBytes(cmd, &at, 4);
                        const timeout_ms = std.mem.readInt(u32, timeout_bytes[0..4], .little);
                        const max_line_bytes_wire = takeBytes(cmd, &at, 4);
                        const max_line_bytes = std.mem.readInt(u32, max_line_bytes_wire[0..4], .little);
                        const url = takeLongBytes(cmd, &at);
                        const header_count: usize = takeByte(cmd, &at);
                        if (header_count > runtime_effects.max_effect_fetch_headers) {
                            @panic("ts core host: a streaming fetch wire record carries more headers than the engine accepts - the frontend's own bound should have stopped this build");
                        }
                        var headers: [runtime_effects.max_effect_fetch_headers]std.http.Header = undefined;
                        for (0..header_count) |i| {
                            const name = takeShortBytes(cmd, &at);
                            const value = takeLongBytes(cmd, &at);
                            headers[i] = .{ .name = name, .value = value };
                        }
                        const body = takeLongBytes(cmd, &at);
                        issueFetchStream(fx, .{
                            .key = key,
                            .line_tag = line_tag,
                            .exit_tag = ok_tag,
                            .err_tag = err_tag,
                        }, .{
                            .method = method,
                            .url = url,
                            .headers = headers[0..header_count],
                            .body = if (body.len > 0) body else null,
                            .timeout_ms = if (timeout_ms == 0) runtime_effects.default_effect_fetch_timeout_ms else timeout_ms,
                            .max_line_bytes = if (max_line_bytes == 0) runtime_effects.max_effect_line_bytes else max_line_bytes,
                        });
                    },
                    // window_hide [op][label_len][label]
                    0x21 => {
                        const label = takeShortBytes(cmd, &at);
                        fx.hideWindow(label);
                    },
                    // dock_presence [op][visible u8]
                    0x22 => fx.setDockPresence(takeByte(cmd, &at) != 0),
                    // service_stream_request [op][channel_key f64 LE]
                    //                        [event_tag][max_pending]
                    //                        [name_len][name][key_len][key]
                    //                        [ok_tag][err_tag]
                    //                        [payload_len u32 LE][payload]
                    0x28 => {
                        const channel_bits = takeBytes(cmd, &at, 8);
                        const channel_value: f64 = @bitCast(std.mem.readInt(u64, channel_bits[0..8], .little));
                        const event_tag = takeByte(cmd, &at);
                        const max_pending = takeByte(cmd, &at);
                        const name = takeShortBytes(cmd, &at);
                        const key = takeShortBytes(cmd, &at);
                        const ok_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const payload = takeLongBytes(cmd, &at);
                        issueServiceStreamRequest(fx, name, key, ok_tag, err_tag, channel_value, event_tag, max_pending, payload);
                    },
                    // store_set [op][route][scope u32][key bytes][value bytes]
                    0x23 => {
                        const head = takeRoutedHead(cmd, &at);
                        const scope = takeU32(cmd, &at);
                        if (scope != 0) @panic("ts core host: record-store scope is reserved and must be zero in cmd format v3");
                        const record_key = takeLongBytes(cmd, &at);
                        const bytes = takeLongBytes(cmd, &at);
                        const request_key = allocStoreRequestEntry(fx, head, true) orelse continue;
                        fx.storeSet(.{
                            .key = request_key,
                            .record_key = record_key,
                            .bytes = bytes,
                            .on_result = hostResultMsg,
                        });
                    },
                    // store_get [op][route][scope u32][key bytes]
                    0x24 => {
                        const head = takeRoutedHead(cmd, &at);
                        const scope = takeU32(cmd, &at);
                        if (scope != 0) @panic("ts core host: record-store scope is reserved and must be zero in cmd format v3");
                        const record_key = takeLongBytes(cmd, &at);
                        const request_key = allocStoreRequestEntry(fx, head, false) orelse continue;
                        fx.storeGet(.{
                            .key = request_key,
                            .record_key = record_key,
                            .on_result = hostResultMsg,
                        });
                    },
                    // store_delete [op][route][scope u32][key bytes]
                    0x25 => {
                        const head = takeRoutedHead(cmd, &at);
                        const scope = takeU32(cmd, &at);
                        if (scope != 0) @panic("ts core host: record-store scope is reserved and must be zero in cmd format v3");
                        const record_key = takeLongBytes(cmd, &at);
                        const request_key = allocStoreRequestEntry(fx, head, true) orelse continue;
                        fx.storeDelete(.{
                            .key = request_key,
                            .record_key = record_key,
                            .on_result = hostResultMsg,
                        });
                    },
                    // store_scan [op][route][scope u32][prefix bytes]
                    //            [limit u32][after bytes]
                    0x26 => {
                        const head = takeRoutedHead(cmd, &at);
                        const scope = takeU32(cmd, &at);
                        if (scope != 0) @panic("ts core host: record-store scope is reserved and must be zero in cmd format v3");
                        const prefix = takeLongBytes(cmd, &at);
                        const limit = takeU32(cmd, &at);
                        const after = takeLongBytes(cmd, &at);
                        const request_key = allocStoreRequestEntry(fx, head, false) orelse continue;
                        fx.storeScan(.{
                            .key = request_key,
                            .prefix = prefix,
                            .limit = limit,
                            .after = after,
                            .on_result = hostResultMsg,
                        });
                    },
                    // store_set_many [op][route][scope u32][count u32]
                    //                [count * (key bytes,value bytes)]
                    0x27 => {
                        const head = takeRoutedHead(cmd, &at);
                        const scope = takeU32(cmd, &at);
                        if (scope != 0) @panic("ts core host: record-store scope is reserved and must be zero in cmd format v3");
                        const count: usize = @intCast(takeU32(cmd, &at));
                        var entries: [runtime_effects.max_effect_store_batch_entries]Fx.StoreEntry = undefined;
                        var kept: usize = 0;
                        for (0..count) |_| {
                            const record_key = takeLongBytes(cmd, &at);
                            const bytes = takeLongBytes(cmd, &at);
                            if (kept < entries.len) {
                                entries[kept] = .{ .key = record_key, .bytes = bytes };
                                kept += 1;
                            }
                        }
                        const request_key = allocStoreRequestEntry(fx, head, true) orelse continue;
                        fx.storeSetMany(.{
                            .key = request_key,
                            .entries = if (count <= entries.len) entries[0..kept] else &.{},
                            .on_result = hostResultMsg,
                        });
                    },
                    // db_query [op][key][page][done][err][sql bytes]
                    //          [param count u32][tagged params]
                    0x29 => {
                        const key = takeShortBytes(cmd, &at);
                        const page_tag = takeByte(cmd, &at);
                        const done_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const sql = takeLongBytes(cmd, &at);
                        const count: usize = @intCast(takeU32(cmd, &at));
                        var params: [runtime_effects.max_effect_db_parameters]runtime_effects.EffectDbValue = undefined;
                        var kept: usize = 0;
                        for (0..count) |_| {
                            const value = takeDbValue(cmd, &at);
                            if (kept < params.len) {
                                params[kept] = value;
                                kept += 1;
                            }
                        }
                        const index = allocDbEntry(fx, key, true, page_tag, done_tag, err_tag) orelse continue;
                        fx.dbQuery(.{
                            .key = db_key_base + index,
                            .sql = if (count <= params.len) sql else "",
                            .params = if (count <= params.len) params[0..kept] else &.{},
                            .on_result = dbResultMsg,
                        });
                    },
                    // db_exec [op][key][ok][err][statement count u32]
                    //         [statement sql bytes][param count u32][params]...
                    0x2A => {
                        const key = takeShortBytes(cmd, &at);
                        const ok_tag = takeByte(cmd, &at);
                        const err_tag = takeByte(cmd, &at);
                        const count: usize = @intCast(takeU32(cmd, &at));
                        var statements: [runtime_effects.max_effect_db_exec_statements]runtime_effects.EffectDbStatement = undefined;
                        var values: [runtime_effects.max_effect_db_exec_statements * runtime_effects.max_effect_db_parameters]runtime_effects.EffectDbValue = undefined;
                        var statement_kept: usize = 0;
                        var value_kept: usize = 0;
                        var valid = count <= statements.len;
                        for (0..count) |_| {
                            const sql = takeLongBytes(cmd, &at);
                            const param_count: usize = @intCast(takeU32(cmd, &at));
                            const start = value_kept;
                            if (param_count > runtime_effects.max_effect_db_parameters) valid = false;
                            for (0..param_count) |_| {
                                const value = takeDbValue(cmd, &at);
                                if (value_kept < values.len) {
                                    values[value_kept] = value;
                                    value_kept += 1;
                                } else {
                                    valid = false;
                                }
                            }
                            if (statement_kept < statements.len and start + param_count <= value_kept) {
                                statements[statement_kept] = .{ .sql = sql, .params = values[start .. start + param_count] };
                                statement_kept += 1;
                            }
                        }
                        const index = allocDbEntry(fx, key, false, 0, ok_tag, err_tag) orelse continue;
                        fx.dbExec(.{
                            .key = db_key_base + index,
                            .statements = if (valid and count == statement_kept) statements[0..statement_kept] else &.{},
                            .on_result = dbResultMsg,
                        });
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

        fn takeDbValue(cmd: []const u8, at: *usize) runtime_effects.EffectDbValue {
            return switch (takeByte(cmd, at)) {
                0 => .null_value,
                1 => blk: {
                    const raw = takeBytes(cmd, at, 8);
                    const number: f64 = @bitCast(std.mem.readInt(u64, raw[0..8], .little));
                    if (std.math.isFinite(number) and @trunc(number) == number and number >= -9_007_199_254_740_991.0 and number <= 9_007_199_254_740_991.0) {
                        break :blk .{ .integer = @intFromFloat(number) };
                    }
                    break :blk .{ .real = number };
                },
                2 => .{ .text = takeLongBytes(cmd, at) },
                3 => .{ .blob = takeLongBytes(cmd, at) },
                4 => .{ .integer = if (takeByte(cmd, at) == 0) 0 else 1 },
                else => @panic("ts core host: unknown SQLite parameter tag - the core and runtime disagree on cmd_format_version"),
            };
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
        fn allocEffectEntry(fx: *Fx, head: RoutedHead) ?u64 {
            return allocEffectEntryWithFileResult(fx, head, null);
        }
        fn allocEffectEntryWithFileResult(fx: *Fx, head: RoutedHead, file_op: ?runtime_effects.EffectFileOp) ?u64 {
            const blocked = head.key.len > 0 and (reservedWireKeyOccupiedExcept(head.key, .effect) or (file_op != null and (findRequest(head.key) != null or findStream(head.key) != null or findDelay(head.key) != null or findPty(head.key) != null or findDb(head.key) != null)));
            const plan = if (comptime @hasDecl(core, "nativeEffectPolicy")) compiledEffectDeclaration(head, blocked) else blk: {
                break :blk EffectPlan{
                    .admitted = !blocked,
                    .slot = if (blocked) null else freeEffectIndex(),
                    .drop = if (blocked or head.key.len == 0) null else findEffect(head.key),
                    .ok_tag = head.ok_tag,
                    .err_tag = head.err_tag,
                };
            };
            if (!plan.admitted) {
                if (file_op) |operation| stageFileRejected(fx, head, operation) else fx.stageLoopMsg(msgFromTagStaticBytes(plan.err_tag, "rejected"));
                return null;
            }
            // A dropped predecessor remains occupied until its terminal drains.
            // Preserve the reference order even when no free slot is available.
            if (plan.drop) |existing| dropEffectEntry(fx, existing);
            const index = plan.slot orelse {
                if (file_op) |operation| {
                    stageFileRejected(fx, head, operation);
                    return null;
                }
                @panic("ts core host: more than 16 named engine ops in flight - the op table mirrors the engine's max_effects slots");
            };
            const entry = &effects_table[index];
            entry.used = true;
            entry.dropped = false;
            entry.full_result = file_op != null;
            entry.key_len = head.key.len;
            @memcpy(entry.key[0..head.key.len], head.key);
            entry.ok_tag = plan.ok_tag;
            entry.err_tag = plan.err_tag;
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) return compiledEffectLookup(key);
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

        const EffectPlan = struct { admitted: bool, slot: ?usize, drop: ?usize, ok_tag: u8, err_tag: u8 };
        const max_effect_policy_bytes = 5 + max_wire_key_bytes + 16 * (5 + max_wire_key_bytes);

        fn writeEffectTable(request: []u8, start: usize) usize {
            var at = start;
            for (&effects_table) |*entry| {
                request[at] = @intFromBool(entry.used);
                request[at + 1] = @intFromBool(entry.dropped);
                request[at + 2] = @intCast(entry.key_len);
                @memcpy(request[at + 3 ..][0..entry.key_len], entry.wireKey());
                at += 3 + entry.key_len;
                request[at] = entry.ok_tag;
                request[at + 1] = entry.err_tag;
                at += 2;
            }
            return at;
        }

        fn compiledEffectDeclaration(head: RoutedHead, blocked: bool) EffectPlan {
            var request: [max_effect_policy_bytes]u8 = undefined;
            request[0] = 0;
            request[1] = @intCast(head.key.len);
            @memcpy(request[2..][0..head.key.len], head.key);
            const at = 2 + head.key.len;
            request[at] = @intFromBool(blocked);
            request[at + 1] = head.ok_tag;
            request[at + 2] = head.err_tag;
            const end = writeEffectTable(&request, at + 3);
            var result: [5]u8 = undefined;
            if (core.nativeEffectPolicy(request[0..end], &result) != result.len or result[0] > 1)
                @panic("ts core host: invalid compiled effect declaration result");
            const slot: ?usize = if (result[1] == 255) null else result[1];
            const drop: ?usize = if (result[2] == 255) null else result[2];
            if (slot) |index| {
                if (index >= effects_table.len or effects_table[index].used)
                    @panic("ts core host: invalid compiled effect allocation slot");
            }
            if (drop) |index| {
                if (index >= effects_table.len or !effects_table[index].used or effects_table[index].dropped)
                    @panic("ts core host: invalid compiled effect predecessor slot");
            }
            if (result[0] == 0 and (slot != null or drop != null))
                @panic("ts core host: rejected effect declaration contains live slots");
            return .{ .admitted = result[0] == 1, .slot = slot, .drop = drop, .ok_tag = result[3], .err_tag = result[4] };
        }

        fn compiledEffectLookup(key: []const u8) ?usize {
            var request: [max_effect_policy_bytes]u8 = undefined;
            request[0] = 1;
            request[1] = @intCast(key.len);
            @memcpy(request[2..][0..key.len], key);
            const end = writeEffectTable(&request, 2 + key.len);
            var result: [1]u8 = undefined;
            if (core.nativeEffectPolicy(request[0..end], &result) != result.len)
                @panic("ts core host: invalid compiled effect lookup result");
            if (result[0] == 255) return null;
            if (result[0] >= effects_table.len or !effects_table[result[0]].used or effects_table[result[0]].dropped)
                @panic("ts core host: invalid compiled effect lookup slot");
            return result[0];
        }

        /// Arm (or re-arm) a one-shot delay. A live wire key reuses its
        /// slot: the engine timer replaces in place under the same
        /// engine key and restarts from now — the debounce discipline.
        fn armDelay(fx: *Fx, key: []const u8, after_ms: f64, tag: u8) void {
            // A delay has no err arm. Preserve an incumbent file stream and
            // fail closed instead of creating a second owner that Cmd.cancel
            // could not address unambiguously.
            const plan: DelayPlan = if (comptime @hasDecl(core, "nativeTimerPolicy")) compiledDelayDeclaration(key, after_ms, tag, reservedWireKeyOccupiedExcept(key, .delay), false) orelse return else blk: {
                if (reservedWireKeyOccupiedExcept(key, .delay)) return;
                const index = if (key.len > 0) findDelay(key) orelse freeDelayIndex() else freeDelayIndex();
                break :blk .{
                    .slot = index orelse @panic("ts core host: more than 16 armed delays - the delay table mirrors the engine's max_effect_timers"),
                    .tag = tag,
                    .interval_ms = intervalMs(after_ms),
                };
            };
            const index = plan.slot;
            const entry = &delays[index];
            entry.used = true;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.tag = plan.tag;
            entry.full_result = false;
            entry.mode = .one_shot;
            fx.startTimer(.{
                .key = delay_key_base + index,
                .interval_ms = plan.interval_ms,
                .mode = .one_shot,
                .on_fire = delayFireMsg,
            });
        }

        fn findDelay(key: []const u8) ?usize {
            if (comptime @hasDecl(core, "nativeTimerPolicy")) return compiledDelayLookup(key);
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

        // ------------------------------------------- spawn / fetch streams

        const SpawnHead = struct { key: []const u8, line_tag: u8, exit_tag: u8, err_tag: u8, complete_events: bool = false };

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
            const index = if (comptime @hasDecl(core, "nativeStreamPolicy")) compiledStreamAdmission(head.key, false) else blk: {
                if (head.key.len > 0 and (findStream(head.key) != null or reservedWireKeyOccupied(head.key))) break :blk null;
                break :blk freeStreamIndex();
            };
            const slot = index orelse {
                fx.stageLoopMsg(if (head.complete_events)
                    msgFromSpawnExit(head.exit_tag, .{ .key = 0, .reason = .rejected }, fx.stageLoopKey(head.key))
                else
                    msgFromTagStaticBytes(head.err_tag, "rejected"));
                return;
            };
            const entry = &streams[slot];
            entry.used = true;
            entry.key_len = head.key.len;
            @memcpy(entry.key[0..head.key.len], head.key);
            entry.line_tag = head.line_tag;
            entry.exit_tag = head.exit_tag;
            entry.err_tag = head.err_tag;
            entry.collect = collect;
            entry.complete_events = head.complete_events;
            entry.fetch = false;
            entry.damaged = false;
            fx.spawn(.{
                .key = spawn_key_base + slot,
                .argv = argv,
                .stdin = if (stdin.len > 0) stdin else null,
                .output = if (collect) .collect else .lines,
                .on_line = if (head.line_tag != spawn_no_line_tag) streamLineMsg else null,
                .on_exit = spawnExitMsg,
            });
        }

        const FetchStreamOptions = struct {
            method: std.http.Method,
            url: []const u8,
            headers: []const std.http.Header,
            body: ?[]const u8,
            timeout_ms: u32,
            max_line_bytes: usize,
        };

        /// Open a line-streamed fetch in the shared stream table. Like a
        /// spawn, a duplicate live wire key is rejected rather than replaced:
        /// replacing a source that has already delivered lines would splice
        /// two HTTP responses into one app-owned stream.
        fn issueFetchStream(fx: *Fx, head: SpawnHead, options: FetchStreamOptions) void {
            const index = if (comptime @hasDecl(core, "nativeStreamPolicy")) compiledStreamAdmission(head.key, true) else blk: {
                if (head.key.len > 0 and (findStream(head.key) != null or findEffect(head.key) != null or reservedWireKeyOccupied(head.key))) break :blk null;
                break :blk freeStreamIndex();
            };
            const slot = index orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
                return;
            };
            const entry = &streams[slot];
            entry.used = true;
            entry.key_len = head.key.len;
            @memcpy(entry.key[0..head.key.len], head.key);
            entry.line_tag = head.line_tag;
            entry.exit_tag = head.exit_tag;
            entry.err_tag = head.err_tag;
            entry.collect = false;
            entry.fetch = true;
            entry.complete_events = false;
            entry.damaged = false;
            fx.fetch(.{
                .key = spawn_key_base + slot,
                .method = options.method,
                .url = options.url,
                .headers = options.headers,
                .body = options.body,
                .timeout_ms = options.timeout_ms,
                .response = .stream,
                .on_line = streamLineMsg,
                .max_line_bytes = options.max_line_bytes,
                .on_response = fetchStreamResultMsg,
            });
        }

        fn findStream(key: []const u8) ?usize {
            if (comptime @hasDecl(core, "nativeStreamPolicy")) return compiledStreamLookup(key);
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

        const max_stream_policy_bytes = 5 + max_wire_key_bytes + runtime_effects.max_effects * (2 + max_wire_key_bytes);

        fn appendStreamTable(request: []u8, start: usize) usize {
            var at = start;
            for (streams) |entry| {
                request[at] = @intFromBool(entry.used);
                request[at + 1] = @intCast(entry.key_len);
                at += 2;
                @memcpy(request[at..][0..entry.key_len], entry.wireKey());
                at += entry.key_len;
            }
            return at;
        }

        fn compiledStreamSlot(request: []const u8) ?usize {
            var result: [1]u8 = undefined;
            if (core.nativeStreamPolicy(request, &result) != result.len) @panic("ts core host: invalid compiled stream slot result");
            if (result[0] == 255) return null;
            if (result[0] >= streams.len) @panic("ts core host: compiled stream slot outside table");
            return result[0];
        }

        fn compiledStreamAdmission(key: []const u8, fetch: bool) ?usize {
            var request: [max_stream_policy_bytes]u8 = undefined;
            request[0] = 0;
            request[1] = @intFromBool(fetch);
            request[2] = @intFromBool(reservedWireKeyOccupied(key));
            request[3] = @intFromBool(fetch and key.len > 0 and findEffect(key) != null);
            request[4] = @intCast(key.len);
            @memcpy(request[5..][0..key.len], key);
            const end = appendStreamTable(&request, 5 + key.len);
            const slot = compiledStreamSlot(request[0..end]) orelse return null;
            if (streams[slot].used) @panic("ts core host: compiled stream admission selected occupied slot");
            return slot;
        }

        fn compiledStreamLookup(key: []const u8) ?usize {
            var request: [max_stream_policy_bytes]u8 = undefined;
            request[0] = 1;
            request[1] = @intCast(key.len);
            @memcpy(request[2..][0..key.len], key);
            const end = appendStreamTable(&request, 2 + key.len);
            const slot = compiledStreamSlot(request[0..end]) orelse return null;
            if (!streams[slot].used) @panic("ts core host: compiled stream lookup selected unused slot");
            return slot;
        }

        const StreamCompletion = struct { tag: u8, shape: enum { bytes, number, number_bytes }, damaged: bool, retire: bool, truncated: bool };

        fn compiledStreamCompletion(request: []const u8) StreamCompletion {
            var result: [5]u8 = undefined;
            if (core.nativeStreamPolicy(request, &result) != result.len or result[1] > 2 or result[2] > 1 or result[3] > 1 or result[4] > 1)
                @panic("ts core host: invalid compiled stream completion result");
            return .{ .tag = result[0], .shape = @enumFromInt(result[1]), .damaged = result[2] != 0, .retire = result[3] != 0, .truncated = result[4] != 0 };
        }

        fn findFileStream(key: []const u8) ?usize {
            for (&file_streams, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn reservedWireKeyOccupied(key: []const u8) bool {
            return reservedWireKeyOccupiedExcept(key, .none);
        }

        /// Complete results reserve one owner across every command family.
        /// Same-family replacements retain the existing silent-drop contract.
        fn reservedWireKeyOccupiedExcept(key: []const u8, family: enum { none, effect, delay }) bool {
            if (key.len == 0) return false;
            if (findFileStream(key) != null or findClipboardWrite(key) != null) return true;
            if (family != .effect) if (findEffect(key)) |index| if (effects_table[index].full_result) return true;
            // Capability ownership is the recorded wire key, independent of
            // the compiled policy's cancellation lookup and routing decisions.
            if (family != .delay) for (&delays) |*entry| {
                if (entry.used and entry.full_result and std.mem.eql(u8, entry.wireKey(), key)) return true;
            };
            return false;
        }

        /// Every string-keyed command family shares one authored key surface.
        /// File streams use a distinct numeric engine namespace, so admission
        /// must consult the bridge tables explicitly before claiming a slot.
        fn wireKeyOccupiedOutsideFileStreams(key: []const u8) bool {
            if (key.len == 0) return false;
            return findRequest(key) != null or
                findEffect(key) != null or
                findStream(key) != null or
                findDelay(key) != null or
                findPty(key) != null or
                findDb(key) != null or
                findClipboardWrite(key) != null;
        }

        fn freeFileStreamIndex() ?usize {
            for (&file_streams, 0..) |*entry, index| if (!entry.used) return index;
            return null;
        }

        fn issueReadFileStream(fx: *Fx, key: []const u8, chunk_tag: u8, done_tag: u8, err_tag: u8, path: []const u8) void {
            if (wireKeyOccupiedOutsideFileStreams(key)) {
                fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                return;
            }
            const index = if (key.len > 0 and findFileStream(key) != null) replace: {
                const existing = findFileStream(key).?;
                if (file_streams[existing].sink) {
                    fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                    return;
                }
                // The engine retires the old read generation silently when
                // this same engine key is reissued. Reuse the bridge slot so
                // the replacement's tags become authoritative atomically.
                break :replace existing;
            } else freeFileStreamIndex() orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                return;
            };
            const entry = &file_streams[index];
            entry.* = .{ .used = true, .key_len = key.len, .chunk_tag = chunk_tag, .done_tag = done_tag, .err_tag = err_tag };
            @memcpy(entry.key[0..key.len], key);
            fx.readFileStream(.{ .key = file_stream_key_base + index, .path = path, .on_result = fileStreamResultMsg });
        }

        fn issueWriteFileStream(fx: *Fx, head: RoutedHead, path: []const u8) void {
            if (head.key.len == 0 or findFileStream(head.key) != null or wireKeyOccupiedOutsideFileStreams(head.key)) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
                return;
            }
            const index = freeFileStreamIndex() orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
                return;
            };
            const entry = &file_streams[index];
            entry.* = .{ .used = true, .sink = true, .busy = true, .key_len = head.key.len, .done_tag = head.ok_tag, .err_tag = head.err_tag };
            @memcpy(entry.key[0..head.key.len], head.key);
            fx.writeFileStream(.{ .key = file_stream_key_base + index, .path = path, .on_result = fileStreamResultMsg });
        }

        fn issueWriteFileChunk(fx: *Fx, head: RoutedHead, bytes: []const u8) void {
            const index = findFileStream(head.key) orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            };
            if (!file_streams[index].sink) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            }
            if (file_streams[index].cancelling) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            }
            if (file_streams[index].busy) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "out_of_order"));
                return;
            }
            file_streams[index].busy = true;
            file_streams[index].done_tag = head.ok_tag;
            file_streams[index].err_tag = head.err_tag;
            fx.writeFileChunk(.{ .key = file_stream_key_base + index, .bytes = bytes, .on_result = fileStreamResultMsg });
        }

        fn issueWriteFileClose(fx: *Fx, head: RoutedHead) void {
            const index = findFileStream(head.key) orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            };
            if (!file_streams[index].sink) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            }
            if (file_streams[index].cancelling) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "sink_missing"));
                return;
            }
            if (file_streams[index].busy) {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "out_of_order"));
                return;
            }
            file_streams[index].busy = true;
            file_streams[index].done_tag = head.ok_tag;
            file_streams[index].err_tag = head.err_tag;
            fx.writeFileClose(.{ .key = file_stream_key_base + index, .on_result = fileStreamResultMsg });
        }

        fn fileStreamResultMsg(result: runtime_effects.EffectFileResult) Msg {
            if (result.key < file_stream_key_base) @panic("ts core host: file stream result outside its namespace");
            const index = result.key - file_stream_key_base;
            if (index >= file_streams.len or !file_streams[index].used) @panic("ts core host: untracked file stream result");
            const entry = &file_streams[index];
            if (entry.cancelling and result.outcome == .cancelled) {
                entry.used = false;
                return msgFromTagBytes(entry.err_tag, "cancelled");
            }
            if (result.op == .read_stream and result.event == .chunk and result.outcome == .ok) return msgFromTagBytes(entry.chunk_tag, result.bytes);
            if (result.op == .read_stream and result.event == .done and result.outcome == .ok) {
                entry.used = false;
                return msgFromTagNumber(entry.done_tag, @floatFromInt(result.total));
            }
            if (result.outcome == .ok) {
                entry.busy = false;
                if (result.op == .write_stream_close) entry.used = false;
                return msgFromTagVoid(entry.done_tag);
            }
            if (result.op == .write_stream_chunk and (result.outcome == .rejected or result.outcome == .out_of_order)) {
                entry.busy = false;
                return msgFromTagBytes(entry.err_tag, @tagName(result.outcome));
            }
            entry.used = false;
            return msgFromTagBytes(entry.err_tag, @tagName(result.outcome));
        }

        /// The stream entry an engine spawn/fetch result names — looked up
        /// WITHOUT retiring (lines flow through it repeatedly; only the
        /// terminal retires it).
        fn streamAt(key: u64) *StreamEntry {
            if (key < spawn_key_base) {
                @panic("ts core host: a stream result arrived outside the bridge's stream key namespace");
            }
            const index = key - spawn_key_base;
            if (index >= streams.len or !streams[index].used) {
                @panic("ts core host: a result arrived for a stream the bridge is not tracking");
            }
            return &streams[index];
        }

        /// Shared `LineMsgFn` for spawn and fetch streams: every delivered
        /// source line routes the entry's line arm; the entry stays live.
        /// Fetch streams additionally remember any cut line or preceding
        /// queue loss so their terminal cannot later claim the response was
        /// complete.
        fn streamLineMsg(line: runtime_effects.EffectLine) Msg {
            const entry = streamAt(line.key);
            if (entry.complete_events) return msgFromSpawnLine(entry.line_tag, line, entry.wireKey());
            if (comptime @hasDecl(core, "nativeStreamPolicy")) {
                const plan = compiledStreamCompletion(&.{ 2, @intFromBool(entry.fetch), @intFromBool(entry.damaged), @intFromBool(line.truncated), @intFromBool(line.dropped_before != 0), entry.line_tag });
                if (plan.shape != .bytes) @panic("ts core host: invalid compiled stream line payload");
                entry.damaged = plan.damaged;
                if (plan.retire) entry.used = false;
                return msgFromTagBytes(plan.tag, line.line);
            }
            if (entry.fetch and (line.truncated or line.dropped_before != 0)) {
                entry.damaged = true;
            }
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
            if (entry.complete_events) {
                entry.used = false;
                return msgFromSpawnExit(entry.exit_tag, exit, entry.wireKey());
            }
            if (comptime @hasDecl(core, "nativeStreamPolicy")) {
                const plan = compiledStreamCompletion(&.{ 3, @intFromBool(entry.collect), @intFromBool(exit.reason == .exited), @intFromBool(exit.output_truncated), entry.exit_tag, entry.err_tag });
                if (plan.retire) entry.used = false;
                return switch (plan.shape) {
                    .bytes => msgFromTagBytes(plan.tag, if (plan.truncated) "truncated" else @tagName(exit.reason)),
                    .number => msgFromTagNumber(plan.tag, @floatFromInt(exit.code)),
                    .number_bytes => msgFromTagNumberBytes("spawn exit", "{ code, output }", plan.tag, exit.code, exit.output),
                };
            }
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

        /// The streamed fetch's ONE terminal. A delivered, lossless response
        /// — any HTTP status, including non-2xx — routes the status through
        /// the ok arm. A cut/dropped line routes `truncated`; transport
        /// failure, timeout, rejection, and cancellation route their
        /// machine-readable outcome through err. The terminal retires the
        /// shared stream entry, so no later line can route for the key.
        fn fetchStreamResultMsg(response: runtime_effects.EffectResponse) Msg {
            const entry = streamAt(response.key);
            if (comptime @hasDecl(core, "nativeStreamPolicy")) {
                const plan = compiledStreamCompletion(&.{ 4, @intFromBool(entry.damaged), @intFromBool(response.truncated), @intFromBool(response.dropped_before != 0), @intFromBool(response.outcome == .ok), entry.exit_tag, entry.err_tag });
                entry.damaged = plan.damaged;
                if (plan.retire) entry.used = false;
                return switch (plan.shape) {
                    .bytes => if (plan.truncated) msgFromTagStaticBytes(plan.tag, "truncated") else msgFromTagBytes(plan.tag, @tagName(response.outcome)),
                    .number => msgFromTagNumber(plan.tag, @floatFromInt(response.status)),
                    .number_bytes => @panic("ts core host: invalid compiled fetch terminal payload"),
                };
            }
            const damaged = entry.damaged or response.truncated or response.dropped_before != 0;
            entry.used = false;
            if (response.outcome == .ok) {
                if (damaged) return msgFromTagStaticBytes(entry.err_tag, "truncated");
                return msgFromTagNumber(entry.exit_tag, @floatFromInt(response.status));
            }
            return msgFromTagBytes(entry.err_tag, @tagName(response.outcome));
        }

        const MediaPlan = struct {
            valid: bool,
            slot: ?usize,
            tag: u8,
            retire: bool,
            key: u64,
            expected_bytes: u64,
            source: platform.AudioCaptureSource,
            sample_rate: u32,
            capture_channels: u8,
        };

        /// The tables and capability identities remain native-owned. The
        /// compiled core selects admission, routing and terminal retirement;
        /// exact u64 keys cross as opaque bytes, never as rounded numbers.
        fn compiledMediaPlan(
            comptime family: u8,
            operation: u8,
            key_bits: u64,
            event_kind: u8,
            tag: u8,
            source: platform.AudioCaptureSource,
            sample_rate: u32,
            capture_channels: u8,
            expected: f64,
            table: anytype,
        ) MediaPlan {
            var request: [28 + @as(usize, @max(runtime_effects.max_effects, runtime_effects.max_effect_channels)) * 16]u8 = @splat(0);
            request[0] = operation;
            request[1] = family;
            request[2] = @intCast(table.len);
            request[3] = event_kind;
            request[4] = tag;
            request[5] = @intFromEnum(source);
            request[6] = capture_channels;
            std.mem.writeInt(u64, request[8..16], key_bits, .little);
            std.mem.writeInt(u32, request[16..20], sample_rate, .little);
            std.mem.writeInt(u64, request[20..28], @bitCast(expected), .little);
            for (table, 0..) |entry, slot| {
                const at = 28 + slot * 16;
                request[at] = @intFromBool(entry.used);
                std.mem.writeInt(u64, request[at + 1 ..][0..8], if (comptime family == 0) entry.id else entry.key, .little);
                request[at + 9] = entry.event_tag;
                if (comptime family == 2) {
                    request[at + 10] = @intFromEnum(entry.source);
                    std.mem.writeInt(u32, request[at + 11 ..][0..4], entry.sample_rate, .little);
                    request[at + 15] = entry.channels;
                }
            }
            var result: [28]u8 = undefined;
            if (core.nativeEffectPolicy(request[0 .. 28 + table.len * 16], &result) != result.len or
                result[0] > 1 or result[3] > 1 or result[4] > 1 or result[6] != 0 or result[7] != 0)
                @panic("ts core host: invalid compiled media plan");
            const slot: ?usize = if (result[1] == 255) null else result[1];
            if (slot) |index| {
                if (index >= table.len) @panic("ts core host: invalid compiled media slot");
                if (operation != 3 and !table[index].used) @panic("ts core host: compiled media lookup names an idle slot");
                if (operation == 3 and table[index].used) @panic("ts core host: compiled media admission names a live slot");
            }
            return .{
                .valid = result[0] == 1,
                .slot = slot,
                .tag = result[2],
                .retire = result[3] == 1,
                .source = @enumFromInt(result[4]),
                .capture_channels = result[5],
                .key = std.mem.readInt(u64, result[8..16], .little),
                .expected_bytes = std.mem.readInt(u64, result[16..24], .little),
                .sample_rate = std.mem.readInt(u32, result[24..28], .little),
            };
        }

        fn compiledMediaLookup(comptime family: u8, key: u64, table: anytype) ?usize {
            return compiledMediaPlan(family, 7, key, 0, 0, .microphone, 0, 0, 0, table).slot;
        }

        const MediaTransportPlan = struct { action: u8, retire: bool, rekey: bool, value: f64 };

        fn compiledMediaTransport(video: bool, used: bool, ownership: u8, stored: []const u8, key: []const u8, verb: u8, value: f64) MediaTransportPlan {
            var request: [15 + max_wire_key_bytes * 2]u8 = @splat(0);
            request[0] = 6;
            request[1] = @intFromBool(video);
            request[2] = @intFromBool(used);
            request[3] = ownership;
            request[4] = verb;
            request[5] = @intCast(key.len);
            request[6] = @intCast(stored.len);
            std.mem.writeInt(u64, request[7..15], @bitCast(value), .little);
            @memcpy(request[15..][0..key.len], key);
            @memcpy(request[15 + key.len ..][0..stored.len], stored);
            var result: [12]u8 = undefined;
            if (core.nativeEffectPolicy(request[0 .. 15 + key.len + stored.len], &result) != result.len or
                (result[0] != 255 and result[0] > (if (video) @as(u8, 7) else @as(u8, 4))) or
                result[1] > 1 or result[2] > 1 or result[3] != 0)
                @panic("ts core host: invalid compiled media transport plan");
            return .{ .action = result[0], .retire = result[1] == 1, .rekey = result[2] == 1, .value = @bitCast(std.mem.readInt(u64, result[4..12], .little)) };
        }

        // ------------------------------------------------- audio stream

        /// The audio_ctl record: drive the single playback channel,
        /// gated by the wire key — a verb aimed at a key that is not
        /// the open stream no-ops (its playback is already gone), the
        /// same idle no-op the engine's own verbs keep. `stop` closes
        /// the stream: the entry retires and later platform stragglers
        /// are the engine's to swallow.
        fn runAudioCtl(fx: *Fx, key: []const u8, verb: u8, value: f64) void {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaTransport(false, audio_entry.used, 1, audio_entry.wireKey(), key, verb, value);
                if (plan.retire) audio_entry.used = false;
                switch (plan.action) {
                    0 => fx.pauseAudio(),
                    1 => fx.resumeAudio(),
                    2 => fx.stopAudio(),
                    3 => fx.seekAudio(@intFromFloat(plan.value)),
                    4 => fx.setAudioVolume(@floatCast(value)),
                    255 => {},
                    else => unreachable,
                }
                return;
            }
            if (!audio_entry.used or !std.mem.eql(u8, audio_entry.wireKey(), key)) return;
            switch (verb) {
                0 => fx.pauseAudio(),
                1 => fx.resumeAudio(),
                2 => {
                    audio_entry.used = false;
                    fx.stopAudio();
                },
                3 => fx.seekAudio(if (value >= 0 and value <= 9007199254740992.0) @intFromFloat(value) else 0),
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const owner = fx.videoOwnerToken();
                const ownership: u8 = if (owner == video_entry.token) 1 else if (owner == 0) 2 else 0;
                const plan = compiledMediaTransport(true, video_entry.used, ownership, video_entry.wireKey(), key, verb, value);
                if (plan.retire) video_entry.used = false;
                switch (plan.action) {
                    0 => fx.playVideo(),
                    1 => fx.pauseVideo(),
                    2 => fx.stopVideoCancel(video_entry.token),
                    3 => fx.seekVideo(@intFromFloat(plan.value)),
                    4 => fx.setVideoVolume(@floatCast(value)),
                    5 => fx.setVideoMuted(plan.value != 0),
                    6 => fx.setVideoLoop(plan.value != 0),
                    7 => fx.restartVideo(),
                    255 => {},
                    else => unreachable,
                }
                if (plan.rekey) video_entry.token = fx.videoMintedToken();
                return;
            }
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
                7 => {
                    fx.restartVideo();
                    video_entry.token = fx.videoMintedToken();
                },
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
            const Selection = struct { key: u64, index: usize, tag: u8, expected_bytes: u64 };
            const selection: ?Selection = if (comptime @hasDecl(core, "nativeEffectPolicy")) blk: {
                const plan = compiledMediaPlan(0, 3, @bitCast(id_value), 0, event_tag, .microphone, 0, 0, expected, &images);
                const index = plan.slot orelse {
                    fx.stageLoopMsg(msgFromTagImage(plan.tag, .{ .id = plan.key, .outcome = .rejected }));
                    break :blk null;
                };
                break :blk .{ .key = plan.key, .index = index, .tag = plan.tag, .expected_bytes = plan.expected_bytes };
            } else native: {
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
                    break :native null;
                }
                const id: u64 = @intFromFloat(id_value);
                if (findImage(id) != null) {
                    fx.stageLoopMsg(msgFromTagImage(event_tag, .{ .id = id, .outcome = .rejected }));
                    break :native null;
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
                    break :native null;
                };
                break :native .{ .key = id, .index = index, .tag = event_tag, .expected_bytes = if (expected >= 1 and expected < 9007199254740992.0 and @floor(expected) == expected) @intFromFloat(expected) else 0 };
            };
            const chosen = selection orelse return;
            const id = chosen.key;
            const index = chosen.index;
            const entry = &images[index];
            entry.used = true;
            entry.id = id;
            entry.event_tag = chosen.tag;
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
                .expected_bytes = chosen.expected_bytes,
                .on_result = imageResultMsg,
            });
        }

        fn findImage(id: u64) ?usize {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) return compiledMediaLookup(0, id, &images);
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaPlan(0, 4, @bitCast(id_value), 0, 0, .microphone, 0, 0, 0, &images);
                if (plan.slot != null) fx.cancel(plan.key);
                return;
            }
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaPlan(0, 4, @bitCast(id_value), 0, 0, .microphone, 0, 0, 0, &[_]ImageEntry{});
                if (plan.valid) _ = fx.unregisterImage(plan.key);
                return;
            }
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaPlan(0, 5, result.id, 0, 0, .microphone, 0, 0, 0, &images);
                const index = plan.slot orelse @panic("ts core host: image result has no compiled owner");
                if (plan.retire) images[index].used = false;
                return msgFromTagImage(plan.tag, result);
            }
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
            max_pending: u8,
        ) bool {
            const Selection = struct { key: u64, index: usize, tag: u8 };
            const selection: ?Selection = if (comptime @hasDecl(core, "nativeEffectPolicy")) blk: {
                const plan = compiledMediaPlan(1, 3, @bitCast(key_value), 0, event_tag, .microphone, 0, 0, 0, &channels);
                const index = plan.slot orelse {
                    fx.stageLoopMsg(msgFromTagChannel(plan.tag, .{ .key = plan.key, .kind = .rejected }));
                    break :blk null;
                };
                break :blk .{ .key = plan.key, .index = index, .tag = plan.tag };
            } else native: {
                const representable = std.math.isFinite(key_value) and
                    key_value >= 1 and key_value < 9007199254740992.0 and
                    @floor(key_value) == key_value;
                if (!representable) {
                    fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = 0, .kind = .rejected }));
                    break :native null;
                }
                const key: u64 = @intFromFloat(key_value);
                if (findChannel(key) != null) {
                    fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = key, .kind = .rejected }));
                    break :native null;
                }
                const index = freeChannelIndex() orelse {
                    fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = key, .kind = .rejected }));
                    break :native null;
                };
                break :native .{ .key = key, .index = index, .tag = event_tag };
            };
            const chosen = selection orelse return false;
            const key = chosen.key;
            const index = chosen.index;
            const entry = &channels[index];
            entry.used = true;
            entry.key = key;
            entry.event_tag = chosen.tag;
            _ = fx.openChannel(.{
                .key = key,
                .on_event = channelEventMsg,
                .max_pending = max_pending,
            });
            // A non-null lookup means the engine accepted the occupancy in
            // both live execution and replay (whose accepted handle is inert).
            // Validation and capacity refusals stage their rejection without
            // leaving an open slot.
            return fx.channelHandle(key) != null;
        }

        fn findChannel(key: u64) ?usize {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) return compiledMediaLookup(1, key, &channels);
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaPlan(1, 4, @bitCast(key_value), 0, 0, .microphone, 0, 0, 0, &channels);
                if (plan.slot != null) fx.closeChannel(plan.key);
                return;
            }
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
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const kind: u8 = switch (event.kind) {
                    .data => 0,
                    .closed => 1,
                    .rejected => 2,
                };
                const plan = compiledMediaPlan(1, 5, event.key, kind, 0, .microphone, 0, 0, 0, &channels);
                const index = plan.slot orelse @panic("ts core host: channel event has no compiled owner");
                if (plan.retire) channels[index].used = false;
                return msgFromTagChannel(plan.tag, event);
            }
            const index = findChannel(event.key) orelse
                @panic("ts core host: a channel event arrived with no open bridge entry");
            const entry = &channels[index];
            if (event.kind != .data) entry.used = false;
            return msgFromTagChannel(entry.event_tag, event);
        }

        // --------------------------------------------- audio capture streams

        fn issueAudioCaptureStart(
            fx: *Fx,
            key_value: f64,
            source: platform.AudioCaptureSource,
            sample_rate: u32,
            capture_channels: u8,
            event_tag: u8,
        ) void {
            const Selection = struct { key: u64, index: usize, tag: u8, source: platform.AudioCaptureSource, rate: u32, channels: u8 };
            const selection: ?Selection = if (comptime @hasDecl(core, "nativeEffectPolicy")) blk: {
                const plan = compiledMediaPlan(2, 3, @bitCast(key_value), 0, event_tag, source, sample_rate, capture_channels, 0, &audio_captures);
                const index = plan.slot orelse {
                    fx.stageLoopMsg(msgFromTagAudioCapture(plan.tag, .{ .key = plan.key, .kind = .rejected, .source = plan.source, .sample_rate = plan.sample_rate, .channels = plan.capture_channels }));
                    break :blk null;
                };
                break :blk .{ .key = plan.key, .index = index, .tag = plan.tag, .source = plan.source, .rate = plan.sample_rate, .channels = plan.capture_channels };
            } else native: {
                const representable = std.math.isFinite(key_value) and
                    key_value >= 1 and key_value < 9007199254740992.0 and
                    @floor(key_value) == key_value;
                const format: platform.AudioCaptureFormat = .{
                    .sample_rate = sample_rate,
                    .channels = capture_channels,
                };
                if (!representable or !format.valid()) {
                    fx.stageLoopMsg(msgFromTagAudioCapture(event_tag, .{
                        .key = if (representable) @intFromFloat(key_value) else 0,
                        .kind = .rejected,
                        .source = source,
                        .sample_rate = sample_rate,
                        .channels = capture_channels,
                    }));
                    break :native null;
                }
                const key: u64 = @intFromFloat(key_value);
                if (findAudioCapture(key) != null) {
                    fx.stageLoopMsg(msgFromTagAudioCapture(event_tag, .{
                        .key = key,
                        .kind = .rejected,
                        .source = source,
                        .sample_rate = sample_rate,
                        .channels = capture_channels,
                    }));
                    break :native null;
                }
                const index = freeAudioCaptureIndex() orelse {
                    fx.stageLoopMsg(msgFromTagAudioCapture(event_tag, .{
                        .key = key,
                        .kind = .rejected,
                        .source = source,
                        .sample_rate = sample_rate,
                        .channels = capture_channels,
                    }));
                    break :native null;
                };
                break :native .{ .key = key, .index = index, .tag = event_tag, .source = source, .rate = sample_rate, .channels = capture_channels };
            };
            const chosen = selection orelse return;
            const key = chosen.key;
            const index = chosen.index;
            audio_captures[index] = .{
                .used = true,
                .key = key,
                .event_tag = chosen.tag,
                .source = chosen.source,
                .sample_rate = chosen.rate,
                .channels = chosen.channels,
            };
            fx.startAudioCapture(.{
                .key = key,
                .source = chosen.source,
                .sample_rate = chosen.rate,
                .channels = chosen.channels,
                .on_event = audioCaptureEventMsg,
            });
        }

        fn findAudioCapture(key: u64) ?usize {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) return compiledMediaLookup(2, key, &audio_captures);
            for (&audio_captures, 0..) |*entry, index| {
                if (entry.used and entry.key == key) return index;
            }
            return null;
        }

        fn freeAudioCaptureIndex() ?usize {
            for (&audio_captures, 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        fn runAudioCaptureStop(fx: *Fx, key_value: f64) void {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                const plan = compiledMediaPlan(2, 4, @bitCast(key_value), 0, 0, .microphone, 0, 0, 0, &audio_captures);
                if (plan.slot != null) fx.stopAudioCapture(plan.key);
                return;
            }
            const representable = std.math.isFinite(key_value) and
                key_value >= 1 and key_value < 9007199254740992.0 and
                @floor(key_value) == key_value;
            if (!representable) return;
            const key: u64 = @intFromFloat(key_value);
            if (findAudioCapture(key) == null) return;
            fx.stopAudioCapture(key);
        }

        fn audioCaptureEventMsg(channel_event: runtime_effects.EffectChannelEvent) Msg {
            if (comptime @hasDecl(core, "nativeEffectPolicy")) {
                var event = runtime_effects.decodeAudioCaptureChannelEvent(channel_event);
                const kind: u8 = switch (event.kind) {
                    .started => 0,
                    .data => 1,
                    .failed => 2,
                    .stopped => 3,
                    .rejected => 4,
                };
                const plan = compiledMediaPlan(2, 5, channel_event.key, kind, 0, event.source, event.sample_rate, event.channels, 0, &audio_captures);
                const index = plan.slot orelse @panic("ts core host: capture event has no compiled owner");
                event.source = plan.source;
                event.sample_rate = plan.sample_rate;
                event.channels = plan.capture_channels;
                if (plan.retire) audio_captures[index].used = false;
                return msgFromTagAudioCapture(plan.tag, event);
            }
            const index = findAudioCapture(channel_event.key) orelse
                @panic("ts core host: an audio capture event arrived with no open bridge entry");
            const entry = &audio_captures[index];
            var event = runtime_effects.decodeAudioCaptureChannelEvent(channel_event);
            // The channel's terminal envelope carries no capture packet;
            // restore the requested identity/format from the bridge entry.
            event.source = entry.source;
            if (event.sample_rate == 0) event.sample_rate = entry.sample_rate;
            if (event.channels == 0) event.channels = entry.channels;
            const event_tag = entry.event_tag;
            if (event.kind == .stopped or event.kind == .rejected) entry.used = false;
            return msgFromTagAudioCapture(event_tag, event);
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
            if (key.len > 0 and (findPty(key) != null or reservedWireKeyOccupied(key))) {
                // The rejection is STAGED (delivered a later frame), so its
                // key must be self-contained: the wire key points into this
                // dispatch's command buffer, gone by delivery, so intern
                // it in the engine's instance-lived staged-key store and
                // reference that. The app's key rides the refusal,
                // correlating it with its command — and the interned
                // slice stays valid even committed into the model.
                fx.stageLoopMsg(msgFromTagPty(event_tag, fx.stageLoopKey(key), true, .{ .key = 0, .kind = .exit, .reason = .rejected }));
                return;
            }
            const index = reusableBoundPty(key) orelse freePtyIndex() orelse {
                // The bridge table mirrors the engine's pty table, whose
                // own exhaustion answer is the same rejected exit — one
                // vocabulary for every refusal, never a crash. Staged, so
                // the requested key rides the engine's interned
                // instance-lived staged-key store, not the frame arena.
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

        /// Named terminal bindings reserve their identity until this host resets.
        /// An ended grid remains addressable; another name cannot inherit it.
        pub fn resolvePtyKey(key: []const u8) u64 {
            if (key.len == 0) return 0;
            for (&ptys, 0..) |*entry, index| {
                if ((entry.used or entry.bound) and std.mem.eql(u8, entry.wireKey(), key)) {
                    entry.bound = true;
                    return pty_key_base + index;
                }
            }
            return 0;
        }

        fn reusableBoundPty(key: []const u8) ?usize {
            for (&ptys, 0..) |*entry, index| {
                if (entry.bound and !entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freePtyIndex() ?usize {
            for (&ptys, 0..) |*entry, index| {
                if (!entry.used and !entry.bound) return index;
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

        fn allocDbEntry(
            fx: *Fx,
            key: []const u8,
            query: bool,
            page_tag: u8,
            done_tag: u8,
            err_tag: u8,
        ) ?usize {
            if (reservedWireKeyOccupied(key)) {
                fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                return null;
            }
            const index = blk: {
                if (key.len > 0) {
                    if (findDb(key)) |existing| {
                        // One-shot queries replace only earlier one-shot
                        // queries. A live subscription owns its slot until
                        // subscription reconciliation removes or re-arms it;
                        // a command with the same wire key must reject rather
                        // than silently erase that subscription.
                        if (query and dbs[existing].query and !dbs[existing].live) break :blk existing;
                        fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                        return null;
                    }
                }
                break :blk freeDbIndex() orelse {
                    fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                    return null;
                };
            };
            const entry = &dbs[index];
            entry.used = true;
            entry.query = query;
            entry.live = false;
            entry.signature = 0;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.page_tag = page_tag;
            entry.done_tag = done_tag;
            entry.err_tag = err_tag;
            return index;
        }

        fn findDb(key: []const u8) ?usize {
            if (comptime @hasDecl(core, "nativeDbPolicy")) return compiledDbLookup(key);
            if (key.len == 0) return null;
            for (&dbs, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeDbIndex() ?usize {
            for (&dbs, 0..) |*entry, index| if (!entry.used) return index;
            return null;
        }

        fn dbResultMsg(result: runtime_effects.EffectDbResult) Msg {
            if (result.key < db_key_base) @panic("ts core host: a relational result arrived outside the bridge DB key namespace");
            const index = result.key - db_key_base;
            if (index >= dbs.len or !dbs[index].used) @panic("ts core host: a relational result arrived for an untracked command");
            const entry = &dbs[index];
            if (result.outcome != .ok) {
                if (!entry.live) entry.used = false;
                return msgFromTagBytes(entry.err_tag, @tagName(result.outcome));
            }
            return switch (result.kind) {
                .page => msgFromTagBytes(entry.page_tag, result.bytes),
                .done => blk: {
                    if (!entry.query) @panic("ts core host: a query terminal reached an exec route");
                    if (!entry.live) entry.used = false;
                    break :blk msgFromTagVoid(entry.done_tag);
                },
                .exec => blk: {
                    if (entry.query) @panic("ts core host: an exec terminal reached a query route");
                    entry.used = false;
                    break :blk msgFromTagVoid(entry.done_tag);
                },
            };
        }

        /// The wire `cancel` record: first match wins across the four
        /// keyed tables — requests (silent drop), named engine ops
        /// (silent drop: the entry is marked dropped, the engine's
        /// `.cancelled` terminal retires it, and its Msg is swallowed —
        /// no arm dispatches), spawn/fetch streams (their terminal routes
        /// the err arm with "cancelled" — ending a stream is observable,
        /// so stream cancellation stays loud), then delays (silent — a
        /// cancelled delay just never fires).
        /// Unknown keys are a no-op; the audio stream is not cancel's
        /// to end (audio_ctl `stop` closes it).
        fn cancelWireKey(fx: *Fx, key: []const u8) void {
            if (key.len == 0) return;
            if (findRequest(key)) |index| {
                const entry = requests[index];
                fx.cancelHostRequest(request_key_base + index);
                requests[index].used = false;
                if (entry.service_channel) |channel_key| {
                    fx.closeChannel(channel_key);
                    fx.stageLoopMsg(msgFromTagStaticBytes(entry.err_tag, "cancelled"));
                }
                return;
            }
            if (findEffect(key)) |index| {
                dropEffectEntry(fx, index);
                return;
            }
            if (findClipboardWrite(key)) |index| {
                fx.cancel(clipboard_result_key_base + index);
                return;
            }
            if (findStream(key)) |index| {
                // The engine's `.cancelled` terminal retires the entry in
                // spawnExitMsg or fetchStreamResultMsg.
                fx.cancel(spawn_key_base + index);
                return;
            }
            if (findFileStream(key)) |index| {
                if (!file_streams[index].sink) {
                    // Read streams are file-style: cancel is silent and the
                    // bridge entry retires immediately. Sinks remain loud.
                    file_streams[index].used = false;
                } else {
                    file_streams[index].cancelling = true;
                }
                fx.cancel(file_stream_key_base + index);
                return;
            }
            if (findDelay(key)) |index| {
                fx.cancelTimer(delay_key_base + index);
                delays[index].used = false;
                return;
            }
            if (findDb(key)) |index| {
                // Declarative live queries belong exclusively to subscription
                // reconciliation. Cmd.cancel may share their public key, but
                // it must neither hide the bridge entry nor strand the
                // engine's `.live` slot; dropping the Sub below performs the
                // matching dbUnsubscribe.
                if (dbs[index].query and !dbs[index].live) {
                    fx.cancelDbQuery(db_key_base + index);
                    dbs[index].used = false;
                }
                // Transactions are already synchronous host work by the time
                // the next record in a batch is walked. Cancel never hides
                // their terminal (or makes the bridge forget its route).
                return;
            }
        }

        const RequestPool = enum { host, store, credentials };

        fn requestPoolAt(index: usize) RequestPool {
            if (index < runtime_effects.max_effects) return .host;
            if (index < runtime_effects.max_effects + runtime_effects.max_store_effects) return .store;
            return .credentials;
        }

        /// Allocate a routed request slot. Host, record-store, and credential
        /// pools are disjoint, while wire keys still share one replacement
        /// namespace.
        fn allocRequestEntry(
            fx: *Fx,
            key: []const u8,
            ok_tag: u8,
            err_tag: u8,
            ok_void: bool,
            pool: RequestPool,
        ) ?u64 {
            if (reservedWireKeyOccupied(key)) return null;
            const index = blk: {
                if (key.len > 0) {
                    if (findRequest(key)) |existing| {
                        if (requestPoolAt(existing) == pool) break :blk existing;
                        fx.cancelHostRequest(request_key_base + existing);
                        requests[existing].used = false;
                    }
                }
                break :blk switch (pool) {
                    .host => freeRequestIndex(),
                    .store => freeStoreRequestIndex(),
                    .credentials => freeCredentialsRequestIndex(),
                } orelse return null;
            };
            const entry = &requests[index];
            entry.used = true;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.ok_tag = ok_tag;
            entry.err_tag = err_tag;
            entry.ok_void = ok_void;
            entry.service_operation = null;
            entry.service_channel = null;
            return index;
        }

        fn allocStoreRequestEntry(fx: *Fx, head: RoutedHead, ok_void: bool) ?u64 {
            const index = allocRequestEntry(fx, head.key, head.ok_tag, head.err_tag, ok_void, .store) orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(head.err_tag, "rejected"));
                return null;
            };
            return request_key_base + index;
        }

        fn allocCredentialsRequestEntry(fx: *Fx, key: []const u8, ok_tag: u8, err_tag: u8, ok_void: bool) ?u64 {
            const index = allocRequestEntry(fx, key, ok_tag, err_tag, ok_void, .credentials) orelse {
                fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
                return null;
            };
            return request_key_base + index;
        }

        /// Issue (or replace) a routed request. Raw keyed requests reuse their
        /// live table entry when the bound host supports replacement. Typed
        /// services and reject-on-duplicate host bindings refuse before
        /// touching the original entry, so its eventual terminal still owns
        /// the route and table slot it started with. Unkeyed requests each
        /// take a fresh entry.
        fn issueRequest(fx: *Fx, name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, typed_service: bool, payload: []const u8) void {
            if (!typed_service and std.mem.startsWith(u8, name, "core.credentials.")) {
                issueCredentialsRequest(fx, name, key, ok_tag, err_tag, payload);
                return;
            }
            if (key.len > 0 and findRequest(key) != null and (typed_service or fx.rejectsDuplicateHostRequestKeys())) {
                stageRequestRejected(fx, err_tag);
                return;
            }
            const index = allocRequestEntry(fx, key, ok_tag, err_tag, false, .host) orelse {
                stageRequestRejected(fx, err_tag);
                return;
            };
            const entry = &requests[index];
            if (typed_service) if (service_results) |binding| {
                entry.service_operation = binding.index_fn(name);
            };
            if (entry.service_operation) |operation| {
                const binding = service_results.?;
                if (binding.streaming_fn(operation) and payload.len >= 8) {
                    entry.service_channel = exactEngineKey(readF64(payload, 0));
                }
            }
            fx.hostRequest(.{
                .key = request_key_base + index,
                .name = name,
                .payload = payload,
                .on_result = hostResultMsg,
            });
        }

        fn issueCredentialsRequest(fx: *Fx, name: []const u8, key: []const u8, ok_tag: u8, err_tag: u8, payload: []const u8) void {
            const is_set = std.mem.eql(u8, name, "core.credentials.set");
            const is_get = std.mem.eql(u8, name, "core.credentials.get");
            const is_delete = std.mem.eql(u8, name, "core.credentials.delete");
            if (!is_set and !is_get and !is_delete) {
                stageRequestRejected(fx, err_tag);
                return;
            }
            var at: usize = 0;
            const credential_key = takeCredentialBytes(payload, &at) orelse {
                stageRequestRejected(fx, err_tag);
                return;
            };
            if (is_set) {
                const secret = takeCredentialBytes(payload, &at) orelse {
                    stageRequestRejected(fx, err_tag);
                    return;
                };
                if (at != payload.len) {
                    stageRequestRejected(fx, err_tag);
                    return;
                }
                const request_key = allocCredentialsRequestEntry(fx, key, ok_tag, err_tag, true) orelse return;
                fx.credentialsSet(.{
                    .key = request_key,
                    .credential_key = credential_key,
                    .secret = secret,
                    .host_result = hostResultMsg,
                });
                return;
            }
            if (at != payload.len) {
                stageRequestRejected(fx, err_tag);
                return;
            }
            const request_key = allocCredentialsRequestEntry(
                fx,
                key,
                ok_tag,
                err_tag,
                is_delete,
            ) orelse return;
            if (is_get) {
                fx.credentialsGet(.{
                    .key = request_key,
                    .credential_key = credential_key,
                    .host_result = hostResultMsg,
                });
            } else {
                fx.credentialsDelete(.{
                    .key = request_key,
                    .credential_key = credential_key,
                    .host_result = hostResultMsg,
                });
            }
        }

        /// Credential records can also arrive through public `Cmd.request`,
        /// so their inner fields are untrusted even though the outer command
        /// wire was emitted correctly. Decode them fallibly and route a
        /// normal rejection instead of turning authored bytes into a panic.
        fn takeCredentialBytes(bytes: []const u8, at: *usize) ?[]const u8 {
            if (at.* > bytes.len or bytes.len - at.* < 4) return null;
            const len: usize = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
            at.* += 4;
            if (len > bytes.len - at.*) return null;
            const field = bytes[at.* .. at.* + len];
            at.* += len;
            return field;
        }

        /// Streaming services are one admission, not a channel-open/request
        /// batch. A duplicate route key or an already-open channel rejects
        /// before either table changes; otherwise the ordinary channel and
        /// request issuers retain their journal/replay behavior. An engine-side
        /// channel refusal is followed by the service err arm's matching
        /// rejection without starting the service transport.
        fn issueServiceStreamRequest(
            fx: *Fx,
            name: []const u8,
            key: []const u8,
            ok_tag: u8,
            err_tag: u8,
            channel_value: f64,
            event_tag: u8,
            max_pending: u8,
            payload: []const u8,
        ) void {
            if (key.len > 0 and (findRequest(key) != null or reservedWireKeyOccupied(key))) {
                stageRequestRejected(fx, err_tag);
                return;
            }
            // Fail the existing request-table bound before opening a channel;
            // an admission failure must not leave an orphaned stream.
            if (freeRequestIndex() == null) {
                @panic("ts core host: more than 16 host requests in flight - the request table mirrors the engine's max_effects slots");
            }

            const channel_key = exactEngineKey(channel_value);
            if (channel_key) |value| {
                // `findChannel` covers every TS bridge occupancy, including a
                // rejected terminal waiting to drain. `channelHandle` also
                // sees an open embedder-owned channel and replay's parked
                // occupancy. Never let this service acquire either one.
                if (findChannel(value) != null or fx.channelHandle(value) != null) {
                    fx.stageLoopMsg(msgFromTagChannel(event_tag, .{ .key = value, .kind = .rejected }));
                    stageRequestRejected(fx, err_tag);
                    return;
                }
            }

            // Validation/table refusals generated by the bridge are final for
            // this combined command, so no service request may follow them.
            if (!issueChannelOpen(fx, channel_value, event_tag, max_pending)) {
                stageRequestRejected(fx, err_tag);
                return;
            }
            issueRequest(fx, name, key, ok_tag, err_tag, true, payload);
        }

        fn stageRequestRejected(fx: *Fx, err_tag: u8) void {
            fx.stageLoopMsg(msgFromTagStaticBytes(err_tag, "rejected"));
        }

        fn findRequest(key: []const u8) ?usize {
            for (&requests, 0..) |*entry, index| {
                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            }
            return null;
        }

        fn freeRequestIndex() ?usize {
            for (requests[0..runtime_effects.max_effects], 0..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        fn freeStoreRequestIndex() ?usize {
            const first = runtime_effects.max_effects;
            const end = first + runtime_effects.max_store_effects;
            for (requests[first..end], first..) |*entry, index| {
                if (!entry.used) return index;
            }
            return null;
        }

        fn freeCredentialsRequestIndex() ?usize {
            const first = runtime_effects.max_effects + runtime_effects.max_store_effects;
            for (requests[first..], first..) |*entry, index| {
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
            if (entry.service_channel) |channel_key| pending_service_channel_close = channel_key;
            if (result.ok) {
                if (entry.service_operation) |operation| {
                    const binding = service_results orelse
                        @panic("ts core host: a typed service result arrived after its decoder was unbound");
                    return binding.decode_fn(operation, entry.ok_tag, result.bytes);
                }
            }
            if (result.ok and entry.ok_void) return msgFromTagVoid(entry.ok_tag);
            return msgFromTagBytes(if (result.ok) entry.ok_tag else entry.err_tag, result.bytes);
        }

        // ------------------------------------------- named engine ops

        /// Retire the named-op entry an engine terminal names and hand
        /// back its routing tags plus whether the entry was dropped —
        /// a dropped entry's terminal must be swallowed, not routed.
        const EffectSuccess = enum(u8) { void_msg, bytes, stat, response };
        const EffectPayload = enum(u8) { swallow, void_msg, bytes, stat, response, reason };
        const EffectCompletion = struct { tag: u8, payload: EffectPayload, reason: u8 };

        fn takeEffectEntry(key: u64, success: EffectSuccess, ok: bool, truncated: bool) EffectCompletion {
            if (key < effect_key_base)
                @panic("ts core host: an effect terminal arrived outside the bridge's named-op key namespace");
            const index = key - effect_key_base;
            if (index >= effects_table.len or !effects_table[index].used)
                @panic("ts core host: an effect terminal arrived for a named op the bridge is not tracking");
            const plan = if (comptime @hasDecl(core, "nativeEffectPolicy")) blk: {
                var request: [69]u8 = undefined;
                request[0] = 2;
                request[1] = @intCast(index);
                request[2] = @intFromEnum(success);
                request[3] = @intFromBool(ok);
                request[4] = @intFromBool(truncated);
                for (&effects_table, 0..) |*entry, slot| {
                    const at = 5 + slot * 4;
                    request[at] = @intFromBool(entry.used);
                    request[at + 1] = @intFromBool(entry.dropped);
                    request[at + 2] = entry.ok_tag;
                    request[at + 3] = entry.err_tag;
                }
                var result: [4]u8 = undefined;
                if (core.nativeEffectPolicy(&request, &result) != result.len or result[0] != index or result[2] > 5 or result[3] > 2)
                    @panic("ts core host: invalid compiled effect completion result");
                break :blk EffectCompletion{ .tag = result[1], .payload = @enumFromInt(result[2]), .reason = result[3] };
            } else blk: {
                const entry = &effects_table[index];
                if (entry.dropped) break :blk EffectCompletion{ .tag = entry.err_tag, .payload = .swallow, .reason = 0 };
                const cut = success == .response and truncated;
                if (ok and !cut) break :blk EffectCompletion{ .tag = entry.ok_tag, .payload = @enumFromInt(@intFromEnum(success) + 1), .reason = 0 };
                break :blk EffectCompletion{ .tag = entry.err_tag, .payload = .reason, .reason = if (ok and cut) 2 else 1 };
            };
            effects_table[index].used = false;
            return plan;
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
        fn armResultTimer(fx: *Fx, key: []const u8, ms: f64, tag: u8, mode: runtime_effects.TimerMode) void {
            const blocked = key.len > 0 and (reservedWireKeyOccupiedExcept(key, .delay) or findRequest(key) != null or findEffect(key) != null or findStream(key) != null or findPty(key) != null or findDb(key) != null);
            const plan: ?DelayPlan = if (comptime @hasDecl(core, "nativeTimerPolicy")) compiledDelayDeclaration(key, ms, tag, blocked, true) else blk: {
                if (blocked or !std.math.isFinite(ms) or ms < 1 or ms > 31_536_000_000) break :blk null;
                const slot = (if (key.len > 0) findDelay(key) orelse freeDelayIndex() else freeDelayIndex()) orelse break :blk null;
                break :blk .{ .slot = slot, .tag = tag, .interval_ms = intervalMs(ms) };
            };
            const admitted = plan orelse {
                fx.stageLoopMsg(msgFromTimerResult(tag, .{ .key = 0, .outcome = .rejected }, fx.stageLoopKey(key)));
                return;
            };
            const entry = &delays[admitted.slot];
            entry.used = true;
            entry.full_result = true;
            entry.mode = mode;
            entry.key_len = key.len;
            @memcpy(entry.key[0..key.len], key);
            entry.tag = admitted.tag;
            fx.startTimer(.{ .key = delay_key_base + admitted.slot, .interval_ms = admitted.interval_ms, .mode = mode, .on_fire = delayFireMsg });
        }
        fn decimalFrame(value: anytype) []const u8 {
            var buffer: [21]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
            if (value == 0) return "0";
            const owned = core.rt.frameAlloc(u8, text.len);
            @memcpy(owned, text);
            return owned;
        }
        fn msgFromTimerResult(tag: u8, timer: runtime_effects.EffectTimer, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .timestampNs = decimalFrame(timer.timestamp_ns), .outcome = timer.outcome });
        }
        fn stageFileRejected(fx: *Fx, head: RoutedHead, operation: runtime_effects.EffectFileOp) void {
            fx.stageLoopMsg(msgFromFileResult(head.ok_tag, .{ .key = 0, .op = operation, .outcome = .rejected }, fx.stageLoopKey(head.key)));
        }
        fn msgFromFileResult(tag: u8, result: runtime_effects.EffectFileResult, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .operation = result.op, .event = result.event, .outcome = result.outcome, .bytes = result.bytes, .totalBytes = decimalFrame(result.total), .mtimeMs = decimalFrame(result.mtime_ms), .exists = result.exists, .droppedBefore = result.dropped_before });
        }
        fn completeFileResultMsg(result: runtime_effects.EffectFileResult) Msg {
            const index = result.key - effect_key_base;
            if (index >= effects_table.len or !effects_table[index].used) @panic("ts core host: untracked file completion");
            const entry = &effects_table[index];
            const route = takeEffectEntry(result.key, .void_msg, true, false);
            if (route.payload == .swallow) swallow_next_dispatch = true;
            return msgFromFileResult(route.tag, result, entry.wireKey());
        }

        fn fileResultMsg(result: runtime_effects.EffectFileResult) Msg {
            const success: EffectSuccess = if (result.op == .read) .bytes else if (result.op == .stat) .stat else .void_msg;
            const route = takeEffectEntry(result.key, success, result.outcome == .ok, false);
            return switch (route.payload) {
                .swallow => swallowedMsg(route.tag),
                .void_msg => msgFromTagVoid(route.tag),
                .bytes => msgFromTagBytes(route.tag, result.bytes),
                .stat => msgFromTagFileStat(route.tag, result),
                .reason => msgFromTagBytes(route.tag, @tagName(result.outcome)),
                .response => @panic("ts core host: file completion received a response payload plan"),
            };
        }

        fn msgFromTagFileStat(tag: u8, result: runtime_effects.EffectFileResult) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    const info = @typeInfo(arm.type);
                    if (comptime info == .@"struct" and info.@"struct".fields.len == 3) {
                        var payload: arm.type = undefined;
                        inline for (info.@"struct".fields) |field| {
                            if (comptime std.mem.eql(u8, field.name, "exists") and field.type == bool) {
                                @field(payload, field.name) = result.exists;
                            } else if (comptime std.mem.eql(u8, field.name, "size") and (field.type == i64 or field.type == u64 or field.type == f64)) {
                                @field(payload, field.name) = if (comptime field.type == f64) @floatFromInt(result.total) else @intCast(result.total);
                            } else if (comptime std.mem.eql(u8, field.name, "mtimeMs") and (field.type == i64 or field.type == u64 or field.type == f64)) {
                                @field(payload, field.name) = if (comptime field.type == f64) @floatFromInt(result.mtime_ms) else @intCast(result.mtime_ms);
                            } else @panic("ts core host: stat_file ok arm has the wrong fields");
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: stat_file ok arm must be { exists, size, mtimeMs }");
                }
            }
            @panic("ts core host: stat_file ok tag is outside Msg");
        }

        /// `ResponseMsgFn` for fetch: an `.ok` un-truncated response
        /// routes the ok arm as `{ status, body }`; everything else —
        /// truncation included, so a cut body never parses as whole —
        /// routes the err arm with the reason as bytes. A dropped
        /// entry's terminal routes nothing — the silent drop.
        fn fetchResultMsg(response: runtime_effects.EffectResponse) Msg {
            const route = takeEffectEntry(response.key, .response, response.outcome == .ok, response.truncated);
            return switch (route.payload) {
                .swallow => swallowedMsg(route.tag),
                .response => msgFromTagNumberBytes("fetch response", "{ status, body }", route.tag, response.status, response.body),
                .reason => msgFromTagBytes(route.tag, if (route.reason == 2) "truncated" else @tagName(response.outcome)),
                else => @panic("ts core host: fetch completion received an incompatible payload plan"),
            };
        }

        /// `ClipboardMsgFn` for clip_read (writes are fire-and-forget
        /// and never route): ok routes the text bytes, everything else
        /// the outcome name. A dropped entry's terminal routes nothing
        /// — the silent drop.
        fn findClipboardWrite(key: []const u8) ?usize {
            if (key.len == 0) return null;
            for (&clipboard_writes, 0..) |*entry, index| if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) return index;
            return null;
        }
        fn issueClipboardWrite(fx: *Fx, key: []const u8, tag: u8, bytes: []const u8) void {
            var slot: ?usize = null;
            if (!reservedWireKeyOccupied(key) and !wireKeyOccupiedOutsideFileStreams(key)) {
                for (&clipboard_writes, 0..) |*entry, index| if (!entry.used) {
                    slot = index;
                    break;
                };
            }
            const index = slot orelse {
                fx.stageLoopMsg(msgFromClipboard(tag, .{ .key = 0, .outcome = .rejected }, fx.stageLoopKey(key)));
                return;
            };
            clipboard_writes[index] = .{ .used = true, .key = undefined, .key_len = key.len, .tag = tag };
            @memcpy(clipboard_writes[index].key[0..key.len], key);
            fx.writeClipboard(.{ .key = clipboard_result_key_base + index, .text = bytes, .on_result = clipboardWriteResultMsg });
        }
        fn clipboardWriteResultMsg(result: runtime_effects.EffectClipboardResult) Msg {
            const index = result.key - clipboard_result_key_base;
            if (index >= clipboard_writes.len or !clipboard_writes[index].used) @panic("ts core host: untracked clipboard completion");
            const entry = &clipboard_writes[index];
            entry.used = false;
            return msgFromClipboard(entry.tag, result, entry.wireKey());
        }
        /// Match complete capability records by field NAME and type. Bytes are
        /// borrowed only until this dispatch; the core ABI copies all retained
        /// values into its committed graph. Native engine keys remain private.
        fn msgFromCapability(tag: u8, record: anytype) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime @typeInfo(arm.type) == .@"struct" and @typeInfo(arm.type).@"struct".fields.len == @typeInfo(@TypeOf(record)).@"struct".fields.len) {
                        var result: arm.type = undefined;
                        inline for (@typeInfo(arm.type).@"struct".fields) |field| {
                            if (comptime @hasField(@TypeOf(record), field.name)) {
                                const value = @field(record, field.name);
                                const V = @TypeOf(value);
                                if (comptime @typeInfo(V) == .@"enum" and @typeInfo(field.type) == .@"enum") {
                                    @field(result, field.name) = std.meta.stringToEnum(field.type, @tagName(value)) orelse @panic("ts core host: incomplete capability enum");
                                } else if (comptime (@typeInfo(V) == .int or @typeInfo(V) == .comptime_int) and field.type == f64) {
                                    @field(result, field.name) = @floatFromInt(value);
                                } else if (comptime (@typeInfo(V) == .int or @typeInfo(V) == .comptime_int) and (@typeInfo(field.type) == .int)) {
                                    @field(result, field.name) = @intCast(value);
                                } else if (comptime V == f32 and field.type == f64) {
                                    @field(result, field.name) = value;
                                } else if (comptime V == field.type) {
                                    @field(result, field.name) = value;
                                } else @panic("ts core host: incompatible capability field type");
                            } else @panic("ts core host: missing capability field");
                        }
                        return @unionInit(Msg, arm.name, result);
                    }
                    @panic("ts core host: invalid capability record arm");
                }
            }
            @panic("ts core host: invalid capability message tag");
        }
        fn msgFromSpawnLine(tag: u8, line: runtime_effects.EffectLine, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .line = line.line, .truncated = line.truncated, .droppedBefore = line.dropped_before });
        }
        fn msgFromSpawnExit(tag: u8, exit: runtime_effects.EffectExit, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .code = exit.code, .reason = exit.reason, .droppedLines = exit.dropped_lines, .output = exit.output, .outputTruncated = exit.output_truncated, .stderrTail = exit.stderr_tail, .stderrTruncated = exit.stderr_truncated });
        }
        fn msgFromClipboard(tag: u8, result: runtime_effects.EffectClipboardResult, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .operation = result.op, .outcome = result.outcome, .text = result.text, .droppedBefore = result.dropped_before });
        }
        fn msgFromVideoSnapshot(tag: u8, snapshot: Fx.VideoSnapshot, key: []const u8) Msg {
            return msgFromCapability(tag, .{ .key = key, .active = snapshot.active, .surface = snapshot.surface, .playing = snapshot.playing, .buffering = snapshot.buffering, .completed = snapshot.completed, .looping = snapshot.looping, .muted = snapshot.muted, .source = snapshot.source, .positionMs = snapshot.position_ms, .durationMs = snapshot.duration_ms, .width = snapshot.width, .height = snapshot.height, .volume = snapshot.volume });
        }

        fn clipboardResultMsg(result: runtime_effects.EffectClipboardResult) Msg {
            const route = takeEffectEntry(result.key, .bytes, result.outcome == .ok, false);
            return switch (route.payload) {
                .swallow => swallowedMsg(route.tag),
                .bytes => msgFromTagBytes(route.tag, result.text),
                .reason => msgFromTagBytes(route.tag, @tagName(result.outcome)),
                else => @panic("ts core host: clipboard completion received an incompatible payload plan"),
            };
        }

        /// `TimerMsgFn` for one-shot delays: the slot retires on fire
        /// (platform one-shots self-stop) and the named arm dispatches
        /// with the fire time in fractional milliseconds.
        fn delayFireMsg(timer: runtime_effects.EffectTimer) Msg {
            if (timer.key < delay_key_base) {
                @panic("ts core host: a delay fired outside the bridge's delay key namespace");
            }
            const index = timer.key - delay_key_base;
            if (index >= delays.len) @panic("ts core host: a delay fired outside the bridge's delay table");
            const completion = if (comptime @hasDecl(core, "nativeTimerPolicy")) compiledDelayCompletion(@intCast(index)) else blk: {
                if (!delays[index].used) @panic("ts core host: a delay fired for a slot the bridge is not tracking");
                break :blk .{ .slot = @as(usize, @intCast(index)), .tag = delays[index].tag };
            };
            const entry = &delays[completion.slot];
            if (entry.full_result) {
                if (entry.mode == .one_shot or timer.outcome == .rejected) entry.used = false;
                return msgFromTimerResult(completion.tag, timer, entry.wireKey());
            }
            if (timer.outcome == .rejected) @panic("ts core host: the platform rejected a Cmd.delay timer");
            entry.used = false;
            const ms = @as(f64, @floatFromInt(timer.timestamp_ns)) / std.time.ns_per_ms;
            return msgFromTagNumber(completion.tag, ms);
        }

        // ----------------------------------------------- subscriptions

        /// Reconcile the declarative subscription set against the fixed
        /// timer table — the same algorithm as the @native-sdk/core package's
        /// run-fidelity drivers, engine-backed: match by key, arm new
        /// keys into the first free slot, re-arm on interval change,
        /// re-route on tag change, cancel the missing. Slot order
        /// everywhere, so record/replay walk identical tables.
        fn reconcileSubscriptions(fx: *Fx) void {
            if (comptime !has_subscriptions) return;
            const borrowed_subs = core.subscriptions(model_root);
            // A cycle policy may allocate in the compiler frame. Keep the
            // stream in the shim arena, and reset both only in finishCycle.
            const subs = if (comptime @hasDecl(core, "nativeTimerPolicy") or @hasDecl(core, "nativeDbPolicy") or @hasDecl(core, "nativeEffectPolicy")) blk: {
                const copy = core.rt.frameAlloc(u8, borrowed_subs.len);
                @memcpy(copy, borrowed_subs);
                break :blk copy;
            } else borrowed_subs;
            var seen_timers = [_]bool{false} ** timers.len;
            var seen_db = [_]bool{false} ** dbs.len;

            // Free live DB slots whose wire keys disappeared before the pass
            // allocates replacements. Otherwise two independently valid sets
            // can overflow the shared family at their transient union (for
            // example, sixteen old keys replaced by one new key).
            const retained_db = retainedDbSubscriptions(subs);
            for (&dbs, 0..) |*entry, index| {
                if (entry.used and entry.live and !retained_db[index]) {
                    fx.dbUnsubscribe(db_key_base + index);
                    entry.used = false;
                }
            }

            var at: usize = 0;
            while (at < subs.len) {
                const record_start = at;
                const op = takeByte(subs, &at);
                switch (op) {
                    // timer [op][key_len][key][every_ms f64 LE][msg_tag]
                    0x01 => {
                        const key = takeShortBytes(subs, &at);
                        const every_bits = takeBytes(subs, &at, 8);
                        const every_ms: f64 = @bitCast(std.mem.readInt(u64, every_bits[0..8], .little));
                        const tag = takeByte(subs, &at);
                        if (comptime @hasDecl(core, "nativeTimerPolicy")) {
                            const plan = compiledTimerDeclaration(key, every_ms, tag, &seen_timers);
                            const entry = &timers[plan.slot];
                            entry.used = true;
                            entry.key_len = key.len;
                            @memcpy(entry.key[0..key.len], key);
                            entry.every_ms = every_ms;
                            entry.tag = plan.tag;
                            if (plan.start) fx.startTimer(.{
                                .key = timer_key_base + plan.slot,
                                .interval_ms = plan.interval_ms,
                                .mode = .repeating,
                                .on_fire = timerFireMsg,
                            });
                        } else {
                            if (!(every_ms >= 1) or !(every_ms <= 31_536_000_000.0)) {
                                @panic("ts core host: Sub.timer interval must be between 1ms and one year");
                            }
                            var slot: ?usize = null;
                            for (&timers, 0..) |*entry, index| {
                                if (entry.used and std.mem.eql(u8, entry.wireKey(), key)) slot = index;
                            }
                            if (slot) |index| {
                                seen_timers[index] = true;
                                const entry = &timers[index];
                                if (entry.every_ms != every_ms) {
                                    entry.every_ms = every_ms;
                                    fx.startTimer(.{
                                        .key = timer_key_base + index,
                                        .interval_ms = intervalMs(every_ms),
                                        .mode = .repeating,
                                        .on_fire = timerFireMsg,
                                    });
                                }
                                entry.tag = tag;
                            } else {
                                const index = freeTimerIndex() orelse
                                    @panic("ts core host: more than 16 subscription timers - the timer table mirrors the engine's max_effect_timers");
                                seen_timers[index] = true;
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
                    },
                    // live query [op][key][page][done][err][sql bytes]
                    //            [param count][tagged params]
                    //            [table count][short table names]
                    0x02 => {
                        const key = takeShortBytes(subs, &at);
                        if (key.len == 0) @panic("ts core host: a live query requires a non-empty subscription key");
                        const page_tag = takeByte(subs, &at);
                        const done_tag = takeByte(subs, &at);
                        const err_tag = takeByte(subs, &at);
                        const sql = takeLongBytes(subs, &at);
                        const param_count: usize = @intCast(takeU32(subs, &at));
                        var params: [runtime_effects.max_effect_db_parameters]runtime_effects.EffectDbValue = undefined;
                        if (param_count > params.len) @panic("ts core host: a live query carries too many SQL parameters");
                        for (0..param_count) |index| params[index] = takeDbValue(subs, &at);
                        const table_count: usize = @intCast(takeU32(subs, &at));
                        var tables: [runtime_effects.max_effect_db_live_tables][]const u8 = undefined;
                        if (table_count == 0 or table_count > tables.len) @panic("ts core host: a live query carries an invalid dependency table set");
                        for (0..table_count) |index| tables[index] = takeShortBytes(subs, &at);

                        const signature = std.hash.Wyhash.hash(0, subs[record_start..at]);
                        const plan: DbPlan = if (comptime @hasDecl(core, "nativeDbPolicy")) compiledDbDeclaration(key, signature, page_tag, done_tag, err_tag, &seen_db) else blk: {
                            const index = findDb(key) orelse freeDbIndex() orelse
                                @panic("ts core host: more relational commands and live queries are active than the database slot family can hold");
                            const entry = &dbs[index];
                            if (entry.used and !entry.live) @panic("ts core host: a live-query key collides with an in-flight database command");
                            if (seen_db[index]) @panic("ts core host: duplicate live-query subscription key");
                            seen_db[index] = true;
                            const changed = !entry.used or entry.signature != signature;
                            break :blk .{ .slot = index, .start = changed, .stop = entry.used and changed, .page_tag = page_tag, .done_tag = done_tag, .err_tag = err_tag };
                        };
                        const index = plan.slot;
                        const entry = &dbs[index];
                        if (plan.stop) fx.dbUnsubscribe(db_key_base + index);
                        if (plan.start) {
                            entry.* = .{
                                .used = true,
                                .query = true,
                                .live = true,
                                .signature = signature,
                                .key_len = key.len,
                                .page_tag = plan.page_tag,
                                .done_tag = plan.done_tag,
                                .err_tag = plan.err_tag,
                            };
                            @memcpy(entry.key[0..key.len], key);
                            fx.dbSubscribe(.{
                                .key = db_key_base + index,
                                .sql = sql,
                                .params = params[0..param_count],
                                .tables = tables[0..table_count],
                                .on_result = dbResultMsg,
                            });
                        }
                    },
                    else => @panic("ts core host: unknown subscription wire record - the core and this runtime disagree on cmd_format_version"),
                }
            }
            const cancellations: ?u16 = if (comptime @hasDecl(core, "nativeTimerPolicy")) compiledTimerCancellations(seen_timers) else null;
            for (&timers, 0..) |*entry, index| {
                const cancel = if (cancellations) |mask| mask & (@as(u16, 1) << @intCast(index)) != 0 else entry.used and !seen_timers[index];
                if (cancel) {
                    entry.used = false;
                    fx.cancelTimer(timer_key_base + index);
                }
            }
        }

        const TimerPlan = struct { slot: usize, start: bool, tag: u8, interval_ms: u64 };

        /// Native supplies owned table facts; TypeScript resolves slot order,
        /// key matching, interval changes, routes and the seen set. The callback
        /// copies the response and leaves both cycle arenas alive.
        fn compiledTimerDeclaration(key: []const u8, every_ms: f64, tag: u8, seen: *[runtime_effects.max_effect_timers]bool) TimerPlan {
            comptime std.debug.assert(runtime_effects.max_effect_timers == 16);
            var request: [13 + max_wire_key_bytes + 16 * (10 + max_wire_key_bytes)]u8 = undefined;
            request[0] = 0;
            std.mem.writeInt(u16, request[1..3], timerSeenMask(seen.*), .little);
            request[3] = @intCast(key.len);
            @memcpy(request[4..][0..key.len], key);
            var at: usize = 4 + key.len;
            std.mem.writeInt(u64, request[at..][0..8], @bitCast(every_ms), .little);
            request[at + 8] = tag;
            at += 9;
            for (&timers) |*entry| {
                const length = if (entry.used) entry.key_len else 0;
                request[at] = @intFromBool(entry.used);
                request[at + 1] = @intCast(length);
                at += 2;
                @memcpy(request[at..][0..length], entry.key[0..length]);
                at += length;
                std.mem.writeInt(u64, request[at..][0..8], @bitCast(if (entry.used) entry.every_ms else @as(f64, 0)), .little);
                at += 8;
            }
            var result: [14]u8 = undefined;
            if (core.nativeTimerPolicy(request[0..at], &result) != result.len or result[0] >= timers.len or result[1] > 1 or result[3] != 0)
                @panic("ts core host: invalid compiled timer declaration result");
            const rounded: f64 = @bitCast(std.mem.readInt(u64, result[4..12], .little));
            if (!std.math.isFinite(rounded) or rounded < 1 or rounded > 31_536_000_000 or @floor(rounded) != rounded)
                @panic("ts core host: invalid compiled timer interval result");
            const mask = std.mem.readInt(u16, result[12..14], .little);
            for (seen, 0..) |*value, index| value.* = mask & (@as(u16, 1) << @intCast(index)) != 0;
            return .{ .slot = result[0], .start = result[1] == 1, .tag = result[2], .interval_ms = @intFromFloat(rounded) };
        }

        const DelayPlan = struct { slot: usize, tag: u8, interval_ms: u64 };
        const max_delay_policy_bytes = 12 + max_wire_key_bytes + 16 * (3 + max_wire_key_bytes);

        /// Copy native-owned facts into a borrowed request. No policy call may
        /// reset the command frame: later records in a batch still borrow it.
        fn writeDelayTable(request: []u8, start: usize) usize {
            comptime std.debug.assert(runtime_effects.max_effect_timers == 16);
            var at = start;
            for (&delays) |*entry| {
                const length = if (entry.used) entry.key_len else 0;
                request[at] = @intFromBool(entry.used);
                request[at + 1] = @intCast(length);
                at += 2;
                @memcpy(request[at..][0..length], entry.key[0..length]);
                at += length;
                request[at] = entry.tag;
                at += 1;
            }
            return at;
        }

        fn compiledDelayDeclaration(key: []const u8, after_ms: f64, tag: u8, blocked: bool, rejectable: bool) ?DelayPlan {
            var request: [max_delay_policy_bytes]u8 = undefined;
            request[0] = if (rejectable) 6 else 2;
            request[1] = @intCast(key.len);
            @memcpy(request[2..][0..key.len], key);
            const value_at = 2 + key.len;
            std.mem.writeInt(u64, request[value_at..][0..8], @bitCast(after_ms), .little);
            request[value_at + 8] = tag;
            request[value_at + 9] = @intFromBool(blocked);
            const at = writeDelayTable(&request, value_at + 10);
            var result: [10]u8 = undefined;
            if (core.nativeTimerPolicy(request[0..at], &result) != result.len)
                @panic("ts core host: invalid compiled delay declaration result");
            if (result[0] == 255) return null;
            if (result[0] >= delays.len) @panic("ts core host: invalid compiled delay declaration slot");
            const rounded: f64 = @bitCast(std.mem.readInt(u64, result[2..10], .little));
            if (!std.math.isFinite(rounded) or rounded < 1 or rounded > 31_536_000_000 or @floor(rounded) != rounded)
                @panic("ts core host: invalid compiled delay interval result");
            return .{ .slot = result[0], .tag = result[1], .interval_ms = @intFromFloat(rounded) };
        }

        fn compiledDelayLookup(key: []const u8) ?usize {
            var request: [max_delay_policy_bytes]u8 = undefined;
            request[0] = 3;
            request[1] = @intCast(key.len);
            @memcpy(request[2..][0..key.len], key);
            const at = writeDelayTable(&request, 2 + key.len);
            var result: [1]u8 = undefined;
            if (core.nativeTimerPolicy(request[0..at], &result) != result.len)
                @panic("ts core host: invalid compiled delay lookup result");
            if (result[0] == 255) return null;
            if (result[0] >= delays.len or !delays[result[0]].used)
                @panic("ts core host: invalid compiled delay lookup slot");
            return result[0];
        }

        fn compiledDelayCompletion(slot: u8) struct { slot: usize, tag: u8 } {
            var request: [20]u8 = undefined;
            request[0] = 4;
            request[1] = slot;
            var used: u16 = 0;
            for (&delays, 0..) |*entry, index| {
                if (entry.used) used |= @as(u16, 1) << @intCast(index);
                request[4 + index] = entry.tag;
            }
            std.mem.writeInt(u16, request[2..4], used, .little);
            var result: [2]u8 = undefined;
            if (core.nativeTimerPolicy(&request, &result) != result.len or result[0] >= delays.len or !delays[result[0]].used)
                @panic("ts core host: invalid compiled delay completion result");
            return .{ .slot = result[0], .tag = result[1] };
        }

        fn timerSeenMask(seen: [runtime_effects.max_effect_timers]bool) u16 {
            var mask: u16 = 0;
            for (seen, 0..) |value, index| if (value) {
                mask |= @as(u16, 1) << @intCast(index);
            };
            return mask;
        }

        fn compiledTimerCancellations(seen: [runtime_effects.max_effect_timers]bool) u16 {
            var used: u16 = 0;
            for (&timers, 0..) |*entry, index| if (entry.used) {
                used |= @as(u16, 1) << @intCast(index);
            };
            var request: [5]u8 = undefined;
            request[0] = 1;
            std.mem.writeInt(u16, request[1..3], used, .little);
            std.mem.writeInt(u16, request[3..5], timerSeenMask(seen), .little);
            var result: [2]u8 = undefined;
            if (core.nativeTimerPolicy(&request, &result) != result.len) @panic("ts core host: invalid compiled timer cancellation result");
            const mask = std.mem.readInt(u16, &result, .little);
            if (mask & ~used != 0) @panic("ts core host: invalid compiled timer cancellation slots");
            return mask;
        }

        /// Parse the inert subscription stream without mutating it and mark
        /// the currently-live DB entries whose public keys remain declared.
        /// Reconciliation uses this pre-pass to retire genuinely stale slots
        /// before it allocates any new ones.
        fn retainedDbSubscriptions(subs: []const u8) [runtime_effects.max_db_effects]bool {
            var retained = [_]bool{false} ** runtime_effects.max_db_effects;
            // Keep the complete key list separate from the borrowed stream;
            // policy allocation never revokes subsequent subscription records.
            const request: []u8 = if (comptime @hasDecl(core, "nativeDbPolicy")) core.rt.frameAlloc(u8, subs.len + max_db_policy_bytes + 5) else &.{};
            var keys_at: usize = 5;
            var at: usize = 0;
            while (at < subs.len) switch (takeByte(subs, &at)) {
                0x01 => {
                    _ = takeShortBytes(subs, &at);
                    _ = takeBytes(subs, &at, 8);
                    _ = takeByte(subs, &at);
                },
                0x02 => {
                    const key = takeShortBytes(subs, &at);
                    if (key.len == 0) @panic("ts core host: a live query requires a non-empty subscription key");
                    _ = takeByte(subs, &at);
                    _ = takeByte(subs, &at);
                    _ = takeByte(subs, &at);
                    _ = takeLongBytes(subs, &at);
                    const param_count: usize = @intCast(takeU32(subs, &at));
                    if (param_count > runtime_effects.max_effect_db_parameters) @panic("ts core host: a live query carries too many SQL parameters");
                    for (0..param_count) |_| _ = takeDbValue(subs, &at);
                    const table_count: usize = @intCast(takeU32(subs, &at));
                    if (table_count == 0 or table_count > runtime_effects.max_effect_db_live_tables) @panic("ts core host: a live query carries an invalid dependency table set");
                    for (0..table_count) |_| _ = takeShortBytes(subs, &at);
                    if (comptime @hasDecl(core, "nativeDbPolicy")) {
                        request[keys_at] = @intCast(key.len);
                        keys_at += 1;
                        @memcpy(request[keys_at..][0..key.len], key);
                        keys_at += key.len;
                    } else if (findDb(key)) |index| {
                        if (dbs[index].live) retained[index] = true;
                    }
                },
                else => @panic("ts core host: unknown subscription wire record - the core and this runtime disagree on cmd_format_version"),
            };
            if (comptime @hasDecl(core, "nativeDbPolicy")) {
                request[0] = 1;
                std.mem.writeInt(u32, request[1..5], @intCast(keys_at - 5), .little);
                const end = writeDbTable(request, keys_at);
                var result: [2]u8 = undefined;
                if (core.nativeDbPolicy(request[0..end], &result) != result.len) @panic("ts core host: invalid compiled database retention result");
                const mask = std.mem.readInt(u16, &result, .little);
                for (&retained, 0..) |*value, index| value.* = mask & (@as(u16, 1) << @intCast(index)) != 0;
            }
            return retained;
        }

        const DbPlan = struct { slot: usize, start: bool, stop: bool, page_tag: u8, done_tag: u8, err_tag: u8 };
        const max_db_policy_bytes = 15 + max_wire_key_bytes + 16 * (11 + max_wire_key_bytes);

        fn writeDbTable(request: []u8, start: usize) usize {
            comptime std.debug.assert(runtime_effects.max_db_effects == 16);
            var at = start;
            for (&dbs) |*entry| {
                const length = if (entry.used) entry.key_len else 0;
                request[at] = @intFromBool(entry.used);
                request[at + 1] = @intFromBool(entry.live);
                request[at + 2] = @intCast(length);
                at += 3;
                @memcpy(request[at..][0..length], entry.key[0..length]);
                at += length;
                std.mem.writeInt(u64, request[at..][0..8], entry.signature, .little);
                at += 8;
            }
            return at;
        }

        fn compiledDbLookup(key: []const u8) ?usize {
            var request: [max_db_policy_bytes]u8 = undefined;
            request[0] = 0;
            request[1] = @intCast(key.len);
            @memcpy(request[2..][0..key.len], key);
            const at = writeDbTable(&request, 2 + key.len);
            var result: [1]u8 = undefined;
            if (core.nativeDbPolicy(request[0..at], &result) != result.len) @panic("ts core host: invalid compiled database lookup result");
            if (result[0] == 255) return null;
            if (result[0] >= dbs.len or !dbs[result[0]].used) @panic("ts core host: invalid compiled database lookup slot");
            return result[0];
        }

        fn compiledDbDeclaration(key: []const u8, signature: u64, page_tag: u8, done_tag: u8, err_tag: u8, seen: *[runtime_effects.max_db_effects]bool) DbPlan {
            var request: [max_db_policy_bytes]u8 = undefined;
            request[0] = 2;
            std.mem.writeInt(u16, request[1..3], timerSeenMask(seen.*), .little);
            request[3] = @intCast(key.len);
            @memcpy(request[4..][0..key.len], key);
            const at = 4 + key.len;
            std.mem.writeInt(u64, request[at..][0..8], signature, .little);
            request[at + 8] = page_tag;
            request[at + 9] = done_tag;
            request[at + 10] = err_tag;
            const end = writeDbTable(&request, at + 11);
            var result: [8]u8 = undefined;
            if (core.nativeDbPolicy(request[0..end], &result) != result.len or result[0] >= dbs.len or result[1] > 1 or result[2] > 1)
                @panic("ts core host: invalid compiled database declaration result");
            const mask = std.mem.readInt(u16, result[6..8], .little);
            for (seen, 0..) |*value, index| value.* = mask & (@as(u16, 1) << @intCast(index)) != 0;
            return .{ .slot = result[0], .start = result[1] == 1, .stop = result[2] == 1, .page_tag = result[3], .done_tag = result[4], .err_tag = result[5] };
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
        /// frontend validates the shape, so field names stay the
        /// app's). The bytes copy into the core's frame arena like
        /// every routed payload; the number widens into its field the
        /// way the subset's number model classes it (i64, u64, or f64).
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
                                if (f.type == i64 or f.type == u64 or f.type == f64) number_fields += 1;
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
                                    // Exit codes carry -1 sentinels by
                                    // contract: a negative host number
                                    // into an unsigned field has no
                                    // honest value, so the crossing
                                    // teaches instead of faulting in
                                    // the cast.
                                    if (comptime f.type == u64) {
                                        if (number < 0) {
                                            @panic("ts core host: a negative number reached the u64-classed field '" ++ f.name ++ "' of Msg arm '" ++ arm.name ++ "' — the unsigned class cannot carry it; declare the field i64 or f64");
                                        }
                                    }
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
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
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
        /// by member NAME (the frontend pins the member set, so the
        /// app's declaration order never matters to the wire).
        fn audioStateValue(comptime E: type, kind: runtime_effects.EffectAudioEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: an audio event kind has no member in the event arm's state union - the frontend's own shape check should have stopped this build");
        }

        /// Build the six-field audio event arm at index `tag` from an
        /// engine event, by field name. The band bytes copy into the
        /// core's frame arena like every routed bytes payload; the
        /// millisecond fields widen the way the subset's number model
        /// classes them (i64, u64, or f64).
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
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
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
            @panic("ts core host: a video event kind has no member in the event arm's state union - the frontend's own shape check should have stopped this build");
        }

        /// Build the seven-field video event arm at index `tag` from an
        /// engine event, by field name. The millisecond and dimension
        /// fields widen the way the subset's number model classes them
        /// (i64, u64, or f64).
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
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
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
            @panic("ts core host: an image outcome has no member in the result arm's state union - the frontend's own shape check should have stopped this build");
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
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
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
            @panic("ts core host: a channel event kind has no member in the event arm's state union - the frontend's own shape check should have stopped this build");
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

        fn audioCaptureArmShape(comptime T: type) bool {
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            const fields = info.@"struct".fields;
            if (fields.len != 10) return false;
            var ok = true;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "state") or std.mem.eql(u8, f.name, "source")) {
                    if (@typeInfo(f.type) != .@"enum") ok = false;
                } else if (std.mem.eql(u8, f.name, "pcm")) {
                    if (f.type != []const u8) ok = false;
                } else if (std.mem.eql(u8, f.name, "key") or
                    std.mem.eql(u8, f.name, "sampleRate") or
                    std.mem.eql(u8, f.name, "channels") or
                    std.mem.eql(u8, f.name, "timestampMs") or
                    std.mem.eql(u8, f.name, "frames") or
                    std.mem.eql(u8, f.name, "droppedPending") or
                    std.mem.eql(u8, f.name, "droppedTotal"))
                {
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
                } else {
                    ok = false;
                }
            }
            return ok;
        }

        fn audioCaptureStateValue(comptime E: type, kind: runtime_effects.EffectAudioCaptureEventKind) E {
            const name = @tagName(kind);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: an audio capture event kind has no member in the event arm's state union - the frontend's own shape check should have stopped this build");
        }

        fn audioCaptureSourceValue(comptime E: type, source: platform.AudioCaptureSource) E {
            const name = @tagName(source);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: an audio capture source has no member in the event arm's source union - the frontend's own shape check should have stopped this build");
        }

        fn msgFromTagAudioCapture(tag: u8, event: runtime_effects.EffectAudioCaptureEvent) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime audioCaptureArmShape(arm.type)) {
                        const fields = @typeInfo(arm.type).@"struct".fields;
                        var payload: arm.type = undefined;
                        inline for (fields) |f| {
                            if (comptime std.mem.eql(u8, f.name, "state")) {
                                @field(payload, f.name) = audioCaptureStateValue(f.type, event.kind);
                            } else if (comptime std.mem.eql(u8, f.name, "source")) {
                                @field(payload, f.name) = audioCaptureSourceValue(f.type, event.source);
                            } else if (comptime std.mem.eql(u8, f.name, "key")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.key) else @intCast(event.key);
                            } else if (comptime std.mem.eql(u8, f.name, "sampleRate")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.sample_rate) else @intCast(event.sample_rate);
                            } else if (comptime std.mem.eql(u8, f.name, "channels")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.channels) else @intCast(event.channels);
                            } else if (comptime std.mem.eql(u8, f.name, "timestampMs")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.timestamp_ms) else @intCast(event.timestamp_ms);
                            } else if (comptime std.mem.eql(u8, f.name, "frames")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.frames) else @intCast(event.frames);
                            } else if (comptime std.mem.eql(u8, f.name, "droppedPending")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.dropped_pending) else @intCast(event.dropped_pending);
                            } else if (comptime std.mem.eql(u8, f.name, "droppedTotal")) {
                                @field(payload, f.name) = if (comptime f.type == f64) @floatFromInt(event.dropped_total) else @intCast(event.dropped_total);
                            } else if (event.pcm_s16le.len == 0) {
                                @field(payload, f.name) = "";
                            } else {
                                const copy = core.rt.frameAlloc(u8, event.pcm_s16le.len);
                                @memcpy(copy, event.pcm_s16le);
                                @field(payload, f.name) = copy;
                            }
                        }
                        return @unionInit(Msg, arm.name, payload);
                    }
                    @panic("ts core host: an audio capture event targets Msg arm '" ++ arm.name ++ "', which is not the ten-field audio capture event record");
                }
            }
            @panic("ts core host: an audio capture event names a Msg tag outside the union");
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
                } else if (std.mem.eql(u8, f.name, "code")) {
                    // Non-exited terminals deliver the -1 code sentinel:
                    // signed by contract, so the unsigned class cannot
                    // carry it. `signal` stays zero-or-positive (the
                    // fatal signal number, else 0) and takes any class.
                    if (f.type != i64 and f.type != f64) ok = false;
                } else if (std.mem.eql(u8, f.name, "signal") or std.mem.eql(u8, f.name, "droppedWrites")) {
                    if (f.type != i64 and f.type != u64 and f.type != f64) ok = false;
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
            @panic("ts core host: a pty event kind has no member in the event arm's state union - the frontend's own shape check should have stopped this build");
        }

        /// The arm's `reason` member for an engine exit reason, matched
        /// by member NAME — the state member's twin.
        fn ptyReasonValue(comptime E: type, reason: runtime_effects.EffectExitReason) E {
            const name = @tagName(reason);
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            }
            @panic("ts core host: a pty exit reason has no member in the event arm's reason union - the frontend's own shape check should have stopped this build");
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
        /// timestamps and timer fires; an integer-classed arm — i64 or
        /// its unsigned twin — truncates the way the subset's number
        /// model does at index sites).
        fn msgFromTagNumber(tag: u8, value: f64) Msg {
            inline for (msg_arms, 0..) |arm, index| {
                if (tag == index) {
                    if (comptime arm.type == f64) {
                        return @unionInit(Msg, arm.name, value);
                    } else if (comptime arm.type == i64) {
                        return @unionInit(Msg, arm.name, @intFromFloat(value));
                    } else if (comptime arm.type == u64) {
                        // Clocks are signed by contract (a pre-epoch or
                        // skewed wall clock is a legal reading): when
                        // one reaches an unsigned arm there is no
                        // honest value, so the crossing teaches instead
                        // of faulting in the cast.
                        if (value < 0) {
                            @panic("ts core host: a negative number reached the u64-classed Msg arm '" ++ arm.name ++ "' — the unsigned class cannot carry it; declare the arm i64 or f64");
                        }
                        return @unionInit(Msg, arm.name, @intFromFloat(value));
                    }
                    @panic("ts core host: a timestamp targets Msg arm '" ++ arm.name ++ "', whose payload is not a number");
                }
            }
            @panic("ts core host: a timestamp names a Msg tag outside the union");
        }

        // ------------------------------------------------- wire cursor

        fn readF64(bytes: []const u8, at: usize) f64 {
            if (at + 8 > bytes.len) @panic("ts core host: truncated f64 service metadata");
            return @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
        }

        fn exactEngineKey(value: f64) ?u64 {
            if (!std.math.isFinite(value) or value < 1 or value >= 9007199254740992.0 or @floor(value) != value) return null;
            return @intFromFloat(value);
        }

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

        /// A fixed-width little-endian integer.
        fn takeU32(bytes: []const u8, at: *usize) u32 {
            const raw = takeBytes(bytes, at, 4);
            return std.mem.readInt(u32, raw[0..4], .little);
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

const PtyBindingTestCore = struct {
    pub const Model = struct {};
    const PtyState = enum { output, exit };
    const Reason = enum { exited, signaled, cancelled, rejected, spawn_failed };
    pub const Msg = union(enum) { event: struct { key: []const u8, state: PtyState, bytes: []const u8, code: f64, reason: Reason, signal: f64, droppedWrites: f64 } };
    var value: Model = .{};
    pub fn initialModel() *const Model {
        return &value;
    }
    pub fn update(model: *const Model, _: Msg) *const Model {
        return model;
    }
    pub fn commitModelRoot(model: *const Model) *const Model {
        return model;
    }
    pub const rt = struct {
        var arena: std.heap.ArenaAllocator = undefined;
        pub fn frameAlloc(comptime T: type, len: usize) []T {
            return arena.allocator().alloc(T, len) catch unreachable;
        }
        pub fn frameReset() void {
            _ = arena.reset(.retain_capacity);
        }
        pub fn resetAll() void {
            frameReset();
        }
    };
};

test "PTY name bindings own bytes and retain ended identities without restricting unbound reuse" {
    const Core = PtyBindingTestCore;
    const Host = TsCoreHost(Core);
    Core.rt.arena = .init(std.testing.allocator);
    defer Core.rt.arena.deinit();
    var fx = Host.Fx.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    Host.boot();
    var name = [_]u8{ 's', 'h', 255, 0 };
    Host.issuePtySpawn(&fx, &name, 0, 80, 24, "", &.{"/bin/sh"});
    const original = Host.resolvePtyKey(&name);
    try std.testing.expect(original != 0);
    @memset(&name, 'x');
    try std.testing.expectEqual(original, Host.resolvePtyKey("sh\xff\x00"));
    try std.testing.expectEqual(@as(u64, 0), Host.resolvePtyKey(&name));
    try fx.feedPtyOutput(original, "owned screen");
    const output = fx.takeMsg().?.event;
    try std.testing.expectEqualStrings("sh\xff\x00", output.key);
    try std.testing.expectEqualStrings("owned screen", output.bytes);
    try fx.feedPtyExit(original, 0, 0, .exited, 0);
    _ = fx.takeMsg();
    try std.testing.expectEqual(original, Host.resolvePtyKey("sh\xff\x00"));
    // Distinct unbound names repeatedly reuse an available effect slot, while
    // the named terminal's ended screen keeps its identity through every exit.
    for (0..8) |i| {
        var buffer: [30]u8 = undefined;
        const other = try std.fmt.bufPrint(&buffer, "unbound-{d}", .{i});
        Host.issuePtySpawn(&fx, other, 0, 80, 24, "", &.{"/bin/sh"});
        const key = fx.pendingPtyAt(0).?.key;
        try std.testing.expect(key != original);
        try fx.feedPtyExit(key, 0, 0, .exited, 0);
        _ = fx.takeMsg();
        try std.testing.expectEqual(original, Host.resolvePtyKey("sh\xff\x00"));
    }
    Host.issuePtySpawn(&fx, "sh\xff\x00", 0, 80, 24, "", &.{"/bin/sh"});
    try std.testing.expectEqual(original, fx.pendingPtyAt(0).?.key);
    Host.issuePtySpawn(&fx, "sh\xff\x00", 0, 80, 24, "", &.{"/bin/sh"});
    const refused = fx.takeMsg().?.event;
    try std.testing.expectEqual(Core.Reason.rejected, refused.reason);
    try std.testing.expectEqualStrings("sh\xff\x00", refused.key);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
    // Bound ended grids occupy the documented budget. Exhaustion still
    // delivers the normal one rejected terminal instead of aliasing a screen.
    for ([_][]const u8{ "second", "third", "fourth" }) |name_key| {
        Host.issuePtySpawn(&fx, name_key, 0, 80, 24, "", &.{"/bin/sh"});
        const key = Host.resolvePtyKey(name_key);
        try std.testing.expect(key != 0 and key != original);
        try fx.feedPtyExit(key, 0, 0, .exited, 0);
        _ = fx.takeMsg();
    }
    Host.issuePtySpawn(&fx, "fifth", 0, 80, 24, "", &.{"/bin/sh"});
    const full = fx.takeMsg().?.event;
    try std.testing.expectEqual(Core.Reason.rejected, full.reason);
    try std.testing.expectEqualStrings("fifth", full.key);
    try std.testing.expectEqual(@as(u64, 0), Host.resolvePtyKey("fifth"));
    Host.boot();
    try std.testing.expectEqual(@as(u64, 0), Host.resolvePtyKey("sh\xff\x00"));
}
