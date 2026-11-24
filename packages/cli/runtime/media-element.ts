// The audio element's engine side: a source loads through fetch(), decodes with the Web Audio
// decoders into an AudioBuffer, and plays through one shared AudioContext, so an app that never
// makes a context of its own still hears it. A source node is started at the element's playhead;
// the timer ticks currentTime and sends timeupdate, and the source's own end sends `ended`.
//
// The element's API and state live in dom.ts; this module registers the delegate it calls, so
// dom.ts never imports the audio engine (which imports the event classes from dom.ts).

import { AudioContext } from "./audio/context.ts";
import type { AudioBuffer } from "./audio/buffer.ts";
import type { AudioBufferSourceNode } from "./audio/sources.ts";
import type { GainNode } from "./audio/effects.ts";
import { Event, HTMLMediaElement, HTMLVideoElement, invalidatePaint, setMediaDelegate, setMediaRouteHook } from "./dom.ts";
import { fetch, resolveAssetPath } from "./fetch.ts";
import {
  hostVideoClose, hostVideoDuration, hostVideoHeight, hostVideoOpen, hostVideoPause, hostVideoPlay,
  hostVideoReady, hostVideoSeek, hostVideoSetMuted, hostVideoSetRate, hostVideoSetVolume, hostVideoTime,
  hostVideoWidth,
} from "./host.ts";

/** One element's playback: its buffer, the source playing it, and where the playhead is. */
class Playback {
  readonly el: HTMLMediaElement;
  buffer: AudioBuffer | null = null;
  gain: GainNode | null = null;
  source: AudioBufferSourceNode | null = null;
  playing: boolean = false;
  /** The context time and the element time the current source started at. */
  baseTime: number = 0;
  offset: number = 0;
  /** A load's token, so a superseded load leaves the element alone. */
  token: number = 0;
  /** Whether a load is in flight. */
  loading: boolean = false;
  /** A play() that is waiting for the load to finish. */
  pendingPlay: boolean = false;
  /** The context the element plays in: its own shared one, or the graph's once routed. */
  context: any = null;
  /** The MediaElementAudioSourceNode the sound goes through, when one names the element. */
  output: any = null;
  resolvers: { resolve: () => void; reject: (error: any) => void }[] = [];
  timer: ReturnType<typeof setInterval> | null = null;
  lastUpdate: number = 0;

  constructor(el: HTMLMediaElement, token: number) {
    this.el = el;
    this.token = token;
  }
}

/** The context every element shares, made the first time one loads. */
let shared: AudioContext | null = null;

function audioContext(): AudioContext {
  if (shared === null) shared = new AudioContext({ latencyHint: "playback" });
  return shared;
}

function stateOf(el: HTMLMediaElement): Playback | null {
  return el._mediaState === null ? null : el._mediaState as Playback;
}

function fire(el: HTMLMediaElement, type: string): void {
  el.dispatchEvent(new Event(type));
}

function clampTime(time: number, duration: number): number {
  if (!(time > 0)) return 0;
  return time > duration ? duration : time;
}

function applyVolume(p: Playback): void {
  if (p.gain === null) return;
  p.gain.gain.value = p.el.muted ? 0 : p.el.volume;
}

function resolvePending(p: Playback): void {
  const waiting = p.resolvers;
  p.resolvers = [];
  p.pendingPlay = false;
  for (const waiter of waiting) waiter.resolve();
}

function rejectPending(p: Playback, error: any): void {
  const waiting = p.resolvers;
  p.resolvers = [];
  p.pendingPlay = false;
  for (const waiter of waiting) waiter.reject(error);
}

// ---------------------------------------------------------------------------
// Video
//
// A video element's picture is the host's player: AVFoundation on macOS. The runtime opens it,
// drives it, polls it for metadata and the playhead, and asks for a repaint while it plays; the
// host draws the frame for the player's current time into the element's box. Its sound is the
// player's own, so a video's audio can't be routed into an AudioContext yet.

class VideoState {
  readonly el: HTMLVideoElement;
  token: number;
  handle: number = -1;
  loading: boolean = false;
  pendingPlay: boolean = false;
  ready: boolean = false;
  playing: boolean = false;
  timer: ReturnType<typeof setInterval> | null = null;
  poller: ReturnType<typeof setInterval> | null = null;
  lastUpdate: number = 0;
  started: number = 0;

  constructor(el: HTMLVideoElement, token: number) {
    this.el = el;
    this.token = token;
  }
}

function videoStateOf(el: HTMLMediaElement): VideoState | null {
  return el instanceof HTMLVideoElement && el._mediaState !== null ? el._mediaState as VideoState : null;
}

function stopVideoTimers(v: VideoState): void {
  if (v.poller !== null) {
    clearInterval(v.poller);
    v.poller = null;
  }
  if (v.timer !== null) {
    clearInterval(v.timer);
    v.timer = null;
  }
}

function closeVideo(v: VideoState): void {
  stopVideoTimers(v);
  if (v.handle >= 0) hostVideoClose(v.handle);
  v.handle = -1;
  if (v.el._videoId >= 0) v.el._videoId = -1;
}

function videoError(el: HTMLVideoElement, message: string): void {
  el.error = { code: 4, message };
  el.networkState = 3;
  el.readyState = 0;
  fire(el, "error");
}

function loadVideo(el: HTMLVideoElement): void {
  const previous = videoStateOf(el);
  const token = previous === null ? 1 : previous.token + 1;
  if (previous !== null) {
    previous.token = token;
    closeVideo(previous);
  }
  const v = new VideoState(el, token);
  el._mediaState = v;
  el._videoId = -1;
  el.paused = true;
  el.ended = false;
  el._setCurrentTime(0);
  el.duration = NaN;
  el.readyState = 0;
  el.videoWidth = 0;
  el.videoHeight = 0;
  el.error = null;
  const src = el.src;
  el.currentSrc = "";
  if (src === "") {
    el.networkState = 0;
    fire(el, "emptied");
    return;
  }
  el.networkState = 2;
  fire(el, "loadstart");
  const path = resolveAssetPath(src);
  if (path === "" || /^data:/i.test(src) || /^https?:/i.test(src)) {
    videoError(el, "the video source isn't a file in the app");
    return;
  }
  const handle = hostVideoOpen(path);
  if (handle < 0) {
    videoError(el, "the video file couldn't be opened");
    return;
  }
  v.handle = handle;
  v.loading = true;
  v.started = Date.now();
  el._videoId = handle;
  hostVideoSetVolume(handle, el.muted ? 0 : el.volume);
  hostVideoSetMuted(handle, el.muted ? 1 : 0);
  hostVideoSetRate(handle, el.playbackRate);
  v.poller = setInterval(() => pollVideo(v), 30);
}

function pollVideo(v: VideoState): void {
  const el = v.el;
  if (v.handle < 0) {
    stopVideoTimers(v);
    return;
  }
  const ready = hostVideoReady(v.handle);
  if (ready < 0 || Date.now() - v.started > 8000) {
    stopVideoTimers(v);
    v.loading = false;
    videoError(el, "the video couldn't be decoded");
    return;
  }
  if (ready === 0) return;
  stopVideoTimers(v);
  v.loading = false;
  v.ready = true;
  const duration = hostVideoDuration(v.handle);
  el.duration = duration > 0 ? duration : NaN;
  el.videoWidth = Math.round(hostVideoWidth(v.handle));
  el.videoHeight = Math.round(hostVideoHeight(v.handle));
  el.currentSrc = el.src;
  el.readyState = 4;
  el.networkState = 1;
  fire(el, "durationchange");
  fire(el, "loadedmetadata");
  fire(el, "loadeddata");
  fire(el, "canplay");
  fire(el, "canplaythrough");
  if (el.autoplay) {
    play(el).catch((e) => {
      void e;
    });
  } else if (v.pendingPlay) {
    startVideo(v);
  }
}

function startVideo(v: VideoState): Promise<void> {
  const el = v.el;
  if (v.handle < 0) return Promise.reject(new Error("InvalidStateError: the video has no source"));
  if (v.playing) {
    v.pendingPlay = false;
    return Promise.resolve();
  }
  hostVideoPlay(v.handle);
  hostVideoSetRate(v.handle, el.playbackRate);
  v.playing = true;
  v.pendingPlay = false;
  el.paused = false;
  el.ended = false;
  fire(el, "play");
  fire(el, "playing");
  v.lastUpdate = Date.now();
  v.timer = setInterval(() => tickVideo(v), 16);
  return Promise.resolve();
}

function tickVideo(v: VideoState): void {
  const el = v.el;
  if (!v.playing || v.handle < 0) return;
  const time = hostVideoTime(v.handle);
  el._setCurrentTime(time);
  invalidatePaint();
  const now = Date.now();
  if (now - v.lastUpdate >= 250) {
    v.lastUpdate = now;
    fire(el, "timeupdate");
  }
  const duration = el.duration;
  if (!(duration > 0)) return;
  if (el.loop) {
    if (time >= duration - 0.03) {
      hostVideoSeek(v.handle, 0);
      hostVideoPlay(v.handle);
    }
    return;
  }
  if (time >= duration - 0.03) finishVideo(v);
}

function finishVideo(v: VideoState): void {
  const el = v.el;
  if (!v.playing) return;
  hostVideoPause(v.handle);
  v.playing = false;
  stopVideoTimers(v);
  if (el.duration > 0) el._setCurrentTime(el.duration);
  el.ended = true;
  el.paused = true;
  fire(el, "timeupdate");
  fire(el, "ended");
}

function pauseVideo(el: HTMLVideoElement): void {
  const v = videoStateOf(el);
  if (v === null) return;
  if (v.playing) {
    hostVideoPause(v.handle);
    v.playing = false;
    stopVideoTimers(v);
    const time = hostVideoTime(v.handle);
    el._setCurrentTime(time);
  }
  if (!el.paused) {
    el.paused = true;
    fire(el, "pause");
    fire(el, "timeupdate");
  }
}

function seekVideo(el: HTMLVideoElement, time: number): void {
  const v = videoStateOf(el);
  if (v === null || v.handle < 0) return;
  const duration = el.duration;
  const target = duration > 0 ? clampTime(time, duration) : Math.max(0, time);
  fire(el, "seeking");
  hostVideoSeek(v.handle, target);
  el._setCurrentTime(target);
  if (el.ended && (!(duration > 0) || target < duration)) el.ended = false;
  fire(el, "seeked");
  fire(el, "timeupdate");
}

// ---------------------------------------------------------------------------
// Loading

function load(el: HTMLMediaElement): void {
  if (el instanceof HTMLVideoElement) {
    loadVideo(el);
    return;
  }
  const previous = stateOf(el);
  const token = previous === null ? 1 : previous.token + 1;
  if (previous !== null) {
    previous.token = token;
    previous.playing = false;
    previous.pendingPlay = false;
    rejectPending(previous, new Error("AbortError: the source changed"));
    stopSource(previous);
    stopTimer(previous);
  }
  const p = new Playback(el, token);
  // A source node made before the load still routes the sound into its graph.
  p.context = el._mediaContext;
  p.output = el._mediaOutput;
  el._mediaState = p;
  el.paused = true;
  el.ended = false;
  el._setCurrentTime(0);
  el.duration = NaN;
  el.readyState = 0;
  el.error = null;
  const src = el.src;
  el.currentSrc = "";
  if (src === "") {
    el.networkState = 0;
    fire(el, "emptied");
    return;
  }
  el.networkState = 2;
  fire(el, "loadstart");
  // A source that isn't wanted yet waits for play(); autoplay makes it wanted.
  if (el.preload === "none" && !el.autoplay) {
    el.networkState = 1;
    return;
  }
  fetchSource(el, p, token, src);
}

function fetchSource(el: HTMLMediaElement, p: Playback, token: number, src: string): void {
  p.loading = true;
  fetch(src).then((response) => response.arrayBuffer()).then((bytes) => {
    if (p.token !== token) return undefined;
    return audioContext().decodeAudioData(bytes);
  }).then((buffer) => {
    if (p.token !== token || buffer === undefined) return;
    p.loading = false;
    p.buffer = buffer;
    el.duration = buffer.duration;
    el.currentSrc = src;
    el.readyState = 4;
    el.networkState = 1;
    fire(el, "durationchange");
    fire(el, "loadedmetadata");
    fire(el, "loadeddata");
    fire(el, "canplay");
    fire(el, "canplaythrough");
    if (el.autoplay) {
      play(el).catch((e) => {
        void e;
      });
    } else if (p.pendingPlay) {
      startPlayback(p);
    }
  }).catch((error) => {
    if (p.token !== token) return;
    p.loading = false;
    el.error = { code: 4, message: String(error) };
    el.networkState = 3;
    el.readyState = 0;
    fire(el, "error");
    rejectPending(p, error);
  });
}

// ---------------------------------------------------------------------------
// Playing

function stopSource(p: Playback): void {
  const source = p.source;
  if (source === null) return;
  p.source = null;
  source.onended = null;
  try {
    source.stop();
  } catch (e) {
    void e;
  }
}

/** Starts a source for the element's playhead, without the play/playing events. */
function spawnSource(p: Playback, offset: number): void {
  const el = p.el;
  if (p.buffer === null) return;
  const context = p.context === null ? audioContext() : p.context;
  if (p.gain === null) {
    const gain: GainNode = context.createGain();
    p.gain = gain;
    gain.connect(p.output === null ? context.destination : p.output);
  }
  applyVolume(p);
  const source = context.createBufferSource();
  source.buffer = p.buffer;
  source.loop = el.loop;
  source.loopStart = 0;
  source.loopEnd = 0;
  source.playbackRate.value = el.playbackRate;
  source.connect(p.gain);
  const token = p.token;
  source.onended = () => {
    if (p.token !== token) return;
    if (p.source === source && p.playing && !source.loop) finish(p);
  };
  p.source = source;
  p.baseTime = context.currentTime;
  p.offset = offset;
  try {
    source.start(0, offset);
  } catch (e) {
    void e;
  }
}

function startPlayback(p: Playback): Promise<void> {
  const el = p.el;
  if (p.buffer === null) {
    return Promise.reject(new Error("InvalidStateError: the element has no source"));
  }
  if (p.playing) {
    resolvePending(p);
    return Promise.resolve();
  }
  el.paused = false;
  el.ended = false;
  spawnSource(p, clampTime(el.currentTime, p.buffer.duration));
  p.playing = true;
  fire(el, "play");
  fire(el, "playing");
  startTimer(p);
  resolvePending(p);
  return Promise.resolve();
}

function play(el: HTMLMediaElement): Promise<void> {
  if (el instanceof HTMLVideoElement) {
    const v = videoStateOf(el);
    if (v === null) {
      loadVideo(el);
      const fresh = videoStateOf(el);
      if (fresh === null) return Promise.reject(new Error("InvalidStateError: the video has no source"));
      fresh.pendingPlay = true;
      return Promise.resolve();
    }
    if (v.handle < 0) {
      if (el.error !== null) return Promise.reject(new Error(el.error.message));
      v.pendingPlay = true;
      return Promise.resolve();
    }
    if (!v.ready && v.loading) {
      v.pendingPlay = true;
      return Promise.resolve();
    }
    return startVideo(v);
  }
  let p = stateOf(el);
  if (p === null) {
    load(el);
    p = stateOf(el);
  }
  const state = p as Playback;
  if (state.buffer === null) {
    if (el.error !== null) return Promise.reject(new Error(el.error.message));
    state.pendingPlay = true;
    if (!state.loading) {
      // A preload="none" source hasn't been fetched yet.
      fetchSource(el, state, state.token, el.src);
    }
    return new Promise<void>((resolve, reject) => {
      state.resolvers.push({ resolve, reject });
    });
  }
  return startPlayback(state);
}

function pause(el: HTMLMediaElement): void {
  if (el instanceof HTMLVideoElement) {
    pauseVideo(el);
    return;
  }
  const p = stateOf(el);
  if (p === null) return;
  if (p.playing) {
    tick(p);
    p.playing = false;
    stopSource(p);
    stopTimer(p);
  }
  if (!el.paused) {
    el.paused = true;
    fire(el, "pause");
    fire(el, "timeupdate");
  }
}

function seek(el: HTMLMediaElement, time: number): void {
  if (el instanceof HTMLVideoElement) {
    seekVideo(el, time);
    return;
  }
  const p = stateOf(el);
  if (p === null || p.buffer === null) return;
  const target = clampTime(time, p.buffer.duration);
  fire(el, "seeking");
  el._setCurrentTime(target);
  if (p.playing) {
    stopSource(p);
    spawnSource(p, target);
  } else if (el.ended && target < p.buffer.duration) {
    el.ended = false;
  }
  fire(el, "seeked");
  fire(el, "timeupdate");
}

// ---------------------------------------------------------------------------
// The clock

function startTimer(p: Playback): void {
  if (p.timer !== null) return;
  p.lastUpdate = Date.now();
  p.timer = setInterval(() => {
    tick(p);
  }, 100);
}

function stopTimer(p: Playback): void {
  if (p.timer === null) return;
  clearInterval(p.timer);
  p.timer = null;
}

/** Advances the playhead from the context's clock and sends timeupdate about four times a
 *  second. */
function tick(p: Playback): void {
  const el = p.el;
  if (!p.playing || p.buffer === null) return;
  const context = p.context === null ? audioContext() : p.context;
  let time = p.offset + (context.currentTime - p.baseTime) * el.playbackRate;
  const duration = p.buffer.duration;
  if (el.loop && duration > 0) {
    time = time % duration;
  } else if (time >= duration) {
    // The timer hears the end first: the engine's own ended report waits for a frame, which a
    // headless run may not draw for a while.
    finish(p);
    return;
  }
  el._setCurrentTime(time);
  const now = Date.now();
  if (now - p.lastUpdate >= 250) {
    p.lastUpdate = now;
    fire(el, "timeupdate");
  }
}

function finish(p: Playback): void {
  const el = p.el;
  if (!p.playing) return;
  p.playing = false;
  stopSource(p);
  stopTimer(p);
  if (p.buffer !== null) el._setCurrentTime(p.buffer.duration);
  el.ended = true;
  el.paused = true;
  fire(el, "timeupdate");
  fire(el, "ended");
}

// ---------------------------------------------------------------------------
// The delegate

/** Moves an element's sound into the graph of the context that made its source node: the source
 *  starts again in that context at the same playhead, through the node, and the element's own
 *  output goes nowhere else. */
function route(el: HTMLMediaElement, context: any, node: any): void {
  el._mediaSource = node;
  el._mediaContext = context;
  el._mediaOutput = node;
  const p = stateOf(el);
  if (p === null) return;
  const time = el.currentTime;
  const playing = p.playing;
  if (playing) {
    p.playing = false;
    stopSource(p);
  }
  p.context = context;
  p.output = node;
  // The gain node belongs to the old context; the next source makes one here.
  p.gain = null;
  if (playing && p.buffer !== null) {
    spawnSource(p, clampTime(time, p.buffer.duration));
    p.playing = true;
    startTimer(p);
  }
}

let installed = false;

/** Registers the media element's engine with the DOM; the window module calls this as it loads. */
export function installMediaElement(): void {
  if (installed) return;
  installed = true;
  setMediaRouteHook((el: HTMLMediaElement, context: any, node: any): void => route(el, context, node));
  setMediaDelegate({
    load: (el: HTMLMediaElement): void => load(el),
    play: (el: HTMLMediaElement): Promise<void> => play(el),
    pause: (el: HTMLMediaElement): void => pause(el),
    seek: (el: HTMLMediaElement, time: number): void => seek(el, time),
    volume: (el: HTMLMediaElement): void => {
      if (el instanceof HTMLVideoElement) {
        const v = videoStateOf(el);
        if (v !== null && v.handle >= 0) {
          hostVideoSetVolume(v.handle, el.muted ? 0 : el.volume);
          hostVideoSetMuted(v.handle, el.muted ? 1 : 0);
        }
        return;
      }
      const p = stateOf(el);
      if (p !== null) applyVolume(p);
    },
    rate: (el: HTMLMediaElement): void => {
      if (el instanceof HTMLVideoElement) {
        const v = videoStateOf(el);
        if (v !== null && v.handle >= 0) hostVideoSetRate(v.handle, el.playbackRate);
        return;
      }
      const p = stateOf(el);
      if (p === null || p.buffer === null) return;
      if (p.playing) {
        const context = p.context === null ? audioContext() : p.context;
        const time = p.offset + (context.currentTime - p.baseTime) * el.playbackRate;
        p.baseTime = context.currentTime;
        p.offset = clampTime(time, p.buffer.duration);
      }
      if (p.source !== null) p.source.playbackRate.value = el.playbackRate;
    },
    loop: (el: HTMLMediaElement): void => {
      if (el instanceof HTMLVideoElement) return;
      const p = stateOf(el);
      if (p !== null && p.source !== null) p.source.loop = el.loop;
    },
  });
}
