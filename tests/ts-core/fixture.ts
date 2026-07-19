// The end-to-end fixture core: a small status poller exercising every
// v2 effect record — an init-command request, keyed replace and cancel,
// a fire-and-forget bytes command, Cmd.now, a model-gated timer
// subscription, the named engine ops (readFile/writeFile/fetch/
// clipboard) plus the one-shot delay, and the streaming ops (a real
// subprocess spawn with line/exit routing and mid-stream cancel, and
// the audio event stream with its control verbs). Transpiled at build
// time by the repo's own transpiler (never committed as Zig) and driven
// through the real runtime by tests/ts-core/host_e2e_tests.zig.

import { Cmd, Sub, asciiBytes } from "@native-sdk/core";

export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";

export type ImageState =
  | "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed"
  | "tls_failed" | "protocol_failed" | "timed_out" | "http_status"
  | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full";

export interface Model {
  readonly polling: boolean;
  readonly ticks: number;
  readonly lastTickAt: number;
  readonly stampMs: number;
  readonly failures: number;
  readonly status: Uint8Array;
  readonly lastErr: Uint8Array;
  readonly saved: number;
  readonly code: number;
  readonly firedAt: number;
  readonly lines: number;
  readonly lastLine: Uint8Array;
  readonly exitCode: number;
  readonly audioState: AudioState;
  readonly posMs: number;
  readonly durMs: number;
  readonly playing: boolean;
  readonly bands: Uint8Array;
  readonly audioEvents: number;
  readonly cover: number;
  readonly coverW: number;
  readonly coverH: number;
  readonly imageState: ImageState;
  readonly imageStatus: number;
  readonly imageResults: number;
  // The echoed ImageId of the last image result — how concurrent loads
  // sharing the one event arm stay distinguishable in update.
  readonly lastImageId: number;
  // Model-owned dynamic ImageIds: the bridge validates these at
  // runtime (the emitter's NS1030 gate covers literals only).
  readonly nextCover: number;
  readonly topId: number;
  // Model-owned expectedBytes values the emitter's literal gate never
  // sees: a fractional count the bridge must map to "unknown size"
  // (never truncate into a wrong verification size), and a whole one
  // it must carry through exactly.
  readonly fracBytes: number;
  readonly wholeBytes: number;
}

export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "refresh" }
  | { readonly kind: "abort" }
  | { readonly kind: "stamp" }
  | { readonly kind: "note" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "stamped"; readonly at: number }
  | { readonly kind: "save" }
  | { readonly kind: "load" }
  | { readonly kind: "wrote" }
  | { readonly kind: "get" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "share" }
  | { readonly kind: "paste" }
  | { readonly kind: "later" }
  | { readonly kind: "halt" }
  | { readonly kind: "boomed"; readonly at: number }
  | { readonly kind: "run" }
  | { readonly kind: "hang" }
  | { readonly kind: "kill" }
  | { readonly kind: "lined"; readonly text: Uint8Array }
  | { readonly kind: "ended"; readonly code: number }
  | { readonly kind: "play" }
  | { readonly kind: "pause_music" }
  | { readonly kind: "set_volume" }
  | { readonly kind: "stop_music" }
  | { readonly kind: "audio_evt"; readonly state: AudioState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "show_cover" }
  | { readonly kind: "show_cover_again" }
  | { readonly kind: "load_next" }
  | { readonly kind: "load_top" }
  | { readonly kind: "load_past" }
  | { readonly kind: "load_flood" }
  | { readonly kind: "load_frac" }
  | { readonly kind: "load_sized" }
  | { readonly kind: "cancel_cover" }
  | { readonly kind: "cancel_missing" }
  | { readonly kind: "image_done"; readonly id: number; readonly state: ImageState; readonly width: number; readonly height: number; readonly status: number };

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      polling: true,
      ticks: 0,
      lastTickAt: -1,
      stampMs: -1,
      failures: 0,
      status: new Uint8Array(0),
      lastErr: new Uint8Array(0),
      saved: 0,
      code: -1,
      firedAt: -1,
      lines: 0,
      lastLine: new Uint8Array(0),
      exitCode: -1,
      audioState: "rejected",
      posMs: -1,
      durMs: -1,
      playing: false,
      bands: new Uint8Array(0),
      audioEvents: 0,
      cover: 0,
      coverW: -1,
      coverH: -1,
      imageState: "rejected",
      imageStatus: -1,
      imageResults: 0,
      lastImageId: -1,
      nextCover: 100,
      topId: 9007199254740991, // 2^53 - 1, the last exactly-carried id
      fracBytes: 1.5,
      wholeBytes: 4096,
    },
    Cmd.request("status.read", asciiBytes("boot"), { key: "status", ok: "loaded", err: "failed" }),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "toggle":
      return { ...model, polling: !model.polling };
    case "refresh":
      return [model, Cmd.request("status.read", model.status, { key: "status", ok: "loaded", err: "failed" })];
    case "abort":
      return [model, Cmd.cancel("status")];
    case "stamp":
      return [model, Cmd.now("stamped")];
    case "note":
      return [model, Cmd.host("blob.put", asciiBytes("hi"))];
    case "loaded":
      return { ...model, status: msg.body };
    case "failed":
      return { ...model, failures: model.failures + 1, lastErr: msg.why };
    case "tick":
      return { ...model, ticks: model.ticks + 1, lastTickAt: msg.at };
    case "stamped":
      return { ...model, stampMs: msg.at };
    case "save":
      // The e2e suite runs with the repo root as cwd; the store lives
      // under the zig cache like every tmp-dir test artifact.
      return [model, Cmd.writeFile(asciiBytes(".zig-cache/tmp/ts-core-e2e/store.bin"), model.status, { key: "file", ok: "wrote", err: "failed" })];
    case "load":
      return [model, Cmd.readFile(asciiBytes(".zig-cache/tmp/ts-core-e2e/store.bin"), { key: "file", ok: "loaded", err: "failed" })];
    case "wrote":
      return { ...model, saved: model.saved + 1 };
    case "get":
      return [
        model,
        Cmd.fetch(
          { url: asciiBytes("https://status.test/feed"), method: "POST", headers: { accept: "text/plain" }, body: model.status, timeoutMs: 750 },
          { key: "get", ok: "fetched", err: "failed" },
        ),
      ];
    case "fetched":
      return { ...model, code: msg.status, status: msg.body };
    case "share":
      return [model, Cmd.clipboardWrite(model.status)];
    case "paste":
      return [model, Cmd.clipboardRead({ key: "clip", ok: "loaded", err: "failed" })];
    case "later":
      return [model, Cmd.delay("boom", 150, "boomed")];
    case "halt":
      return [model, Cmd.cancel("boom")];
    case "boomed":
      return { ...model, firedAt: msg.at };
    case "run":
      // A real, hermetic child: two stdout lines, then a clean exit.
      return [model, Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("printf 'one\\ntwo\\n'")], { key: "job", line: "lined", exit: "ended", err: "failed" })];
    case "hang":
      // A child that outlives the test unless cancelled mid-stream.
      return [model, Cmd.spawn([asciiBytes("/bin/sh"), asciiBytes("-c"), asciiBytes("sleep 30")], { key: "job", line: "lined", exit: "ended", err: "failed" })];
    case "kill":
      return [model, Cmd.cancel("job")];
    case "lined":
      return { ...model, lines: model.lines + 1, lastLine: msg.text };
    case "ended":
      return { ...model, exitCode: msg.code };
    case "play":
      return [model, Cmd.audioPlay("track", { path: asciiBytes("music/track.mp3") }, { event: "audio_evt" })];
    case "pause_music":
      return [model, Cmd.audioPause("track")];
    case "set_volume":
      // The engine's remembered volume verb (0..1), on the fixture's
      // test-only path: the soundboard example carries no volume control
      // (parity with its Zig original), so the capability stays proven
      // here.
      return [model, Cmd.audioSetVolume("track", 0.8)];
    case "stop_music":
      return [model, Cmd.audioStop("track")];
    case "audio_evt":
      return {
        ...model,
        audioState: msg.state,
        posMs: msg.positionMs,
        durMs: msg.durationMs,
        playing: msg.playing,
        bands: msg.bands,
        audioEvents: model.audioEvents + 1,
      };
    case "show_cover":
      // The runtime ImageId the views bind; the model only adopts it
      // on a loaded result (the store-the-id-on-success discipline).
      return [model, Cmd.imageLoad(21, { path: asciiBytes("art/cover.png"), url: asciiBytes("https://cdn.test/cover.png") }, { event: "image_done" })];
    case "show_cover_again":
      // A duplicate live id: the bridge rejects it (state "rejected")
      // — one load per id at a time, the spawn discipline.
      return [model, Cmd.imageLoad(21, { path: asciiBytes("art/cover.png") }, { event: "image_done" })];
    case "load_next":
      // Dynamic ids straight off the model: each dispatch parks one
      // more in-flight load, so the e2e suite can fill the bridge's
      // 16-entry image table and prove the 17th answers "rejected"
      // (never a crash) while the 16 live loads stay healthy.
      return [{ ...model, nextCover: model.nextCover + 1 }, Cmd.imageLoad(model.nextCover, { path: asciiBytes("art/flood.png") }, { event: "image_done" })];
    case "load_top":
      // 2^53 - 1 reaching the bridge as a DYNAMIC value the emitter's
      // literal gate never sees: the last id every tier carries
      // exactly, so it must park a live load.
      return [model, Cmd.imageLoad(model.topId, { path: asciiBytes("art/top.png") }, { event: "image_done" })];
    case "load_past":
      // 2^53 aliases 2^53 + 1 in f64 — the first id the wire cannot
      // carry exactly. Dynamic values answer "rejected" at runtime, the
      // runtime twin of the emitter's compile-time literal gate.
      return [model, Cmd.imageLoad(model.topId + 1, { path: asciiBytes("art/past.png") }, { event: "image_done" })];
    case "load_flood":
      // Seventeen loads in ONE command value: against a full image
      // table every one must answer "rejected" at the post-cycle
      // boundary — one result per load, however many one batch stages.
      return [model, Cmd.batch([
        Cmd.imageLoad(200, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(201, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(202, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(203, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(204, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(205, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(206, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(207, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(208, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(209, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(210, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(211, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(212, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(213, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(214, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(215, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
        Cmd.imageLoad(216, { path: asciiBytes("art/flood.png") }, { event: "image_done" }),
      ])];
    case "load_frac":
      // A fractional expectedBytes reaching the bridge as a DYNAMIC
      // value the emitter's literal gate never sees: not a
      // representable whole byte count, so the bridge hands the engine
      // "unknown size" (0) — truncating to 1 would make the cache
      // verify against a size the app never declared.
      return [model, Cmd.imageLoad(61, { url: asciiBytes("https://cdn.test/frac.png"), cachePath: asciiBytes("cache/frac.png"), expectedBytes: model.fracBytes }, { event: "image_done" })];
    case "load_sized":
      // The whole-number control: a dynamic representable count rides
      // the wire into the engine exactly.
      return [model, Cmd.imageLoad(62, { url: asciiBytes("https://cdn.test/sized.png"), cachePath: asciiBytes("cache/sized.png"), expectedBytes: model.wholeBytes }, { event: "image_done" })];
    case "cancel_cover":
      // The numeric-id cancel: ends the in-flight load under id 21
      // loudly (its own event arm delivers state "cancelled") and
      // frees the id for a same-id retry.
      return [model, Cmd.imageCancel(21)];
    case "cancel_missing":
      // An id with no live load: the documented no-op — no result, no
      // crash, nothing to report on.
      return [model, Cmd.imageCancel(555)];
    case "image_done":
      // The echoed id IS the adopted id — the store-the-id-on-success
      // discipline reads it off the result instead of hardcoding it.
      if (msg.state === "loaded")
        return { ...model, cover: msg.id, coverW: msg.width, coverH: msg.height, imageState: msg.state, imageStatus: msg.status, imageResults: model.imageResults + 1, lastImageId: msg.id };
      return { ...model, imageState: msg.state, imageStatus: msg.status, imageResults: model.imageResults + 1, lastImageId: msg.id };
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.polling) return Sub.none;
  return Sub.timer("tick", 100, "tick");
}
