// AudioContext, OfflineAudioContext and the base they share. A context owns one native engine;
// the graph, the clock and the decoders are the engine's, while state, events and the factory
// methods are here.

import { Event, HTMLMediaElement, HTMLVideoElement } from "../dom.ts";
import { AudioEventTarget } from "./events.ts";
import { AudioBuffer } from "./buffer.ts";
import { AudioListener } from "./listener.ts";
import { AudioDestinationNode, AudioNode } from "./node.ts";
import { AnalyserNode, BiquadFilterNode, ConvolverNode, DelayNode, DynamicsCompressorNode, GainNode, PannerNode, StereoPannerNode } from "./effects.ts";
import { AudioBufferSourceNode, ConstantSourceNode, OscillatorNode } from "./sources.ts";
import { MediaElementAudioSourceNode } from "./media-source.ts";
import { setAudioFrameHook } from "../audio-hook.ts";
import {
  hostAudioBufferChannels, hostAudioBufferFrames, hostAudioBufferRate, hostAudioContextClose,
  hostAudioContextCollect, hostAudioContextCreate, hostAudioContextRate, hostAudioContextRendered,
  hostAudioContextResume, hostAudioContextSuspend, hostAudioDecode, hostAudioEvents,
  hostAudioOfflineRender,
} from "../host.ts";

export type AudioContextState = "suspended" | "running" | "closed";

export interface AudioContextOptions {
  latencyHint?: "balanced" | "interactive" | "playback" | number;
  sampleRate?: number;
}

export interface OfflineAudioContextOptions {
  numberOfChannels?: number;
  length: number;
  sampleRate: number;
}

// Ended events and freed native storage are collected once a frame: a context that renders
// offline reports them from startRendering itself, and a real-time one from the frame hook.
const CONTEXTS: BaseAudioContext[] = [];
let hookInstalled = false;

function installHook(): void {
  if (hookInstalled) return;
  hookInstalled = true;
  setAudioFrameHook(pollAudio);
}

/** Runs the named callbacks the engine has queued, for every live context. */
export function pollAudio(): void {
  for (const context of CONTEXTS) context._processEvents();
}

function removeContext(context: BaseAudioContext): void {
  const i = CONTEXTS.indexOf(context);
  if (i >= 0) CONTEXTS.splice(i, 1);
}

export class BaseAudioContext extends AudioEventTarget {
  readonly _native: number;
  readonly sampleRate: number;
  readonly destination: AudioDestinationNode;
  readonly listener: AudioListener;
  private readonly nodes: Map<number, AudioNode> = new Map();
  private contextState: AudioContextState = "suspended";
  /** An offline context's final clock, kept once it stops polling its engine. */
  protected offlineTime: number = -1;

  protected constructor(offline: boolean, rate: number) {
    super();
    const id = hostAudioContextCreate(rate, offline ? 1 : 0);
    if (id < 0) throw new Error("NotSupportedError: the audio engine could not start a context");
    this._native = id;
    this.sampleRate = hostAudioContextRate(id);
    this.destination = new AudioDestinationNode(this);
    this.listener = new AudioListener(this);
    CONTEXTS.push(this);
    installHook();
  }

  get state(): AudioContextState {
    return this.contextState;
  }

  /** Seconds of audio the context has rendered. Suspending freezes it, as a browser's does. */
  get currentTime(): number {
    if (this.offlineTime >= 0) return this.offlineTime;
    return hostAudioContextRendered(this._native) / this.sampleRate;
  }

  get onstatechange(): ((event: Event) => void) | null {
    return this.stateHandler;
  }

  set onstatechange(handler: ((event: Event) => void) | null) {
    if (this.stateHandler !== null) this.removeEventListener("statechange", this.stateHandler);
    this.stateHandler = handler;
    if (handler !== null) this.addEventListener("statechange", handler);
  }

  private stateHandler: ((event: Event) => void) | null = null;

  protected setState(state: AudioContextState): void {
    if (this.contextState === state) return;
    this.contextState = state;
    this.dispatchEvent(new Event("statechange"));
  }

  _registerNode(node: AudioNode): void {
    this.nodes.set(node._native, node);
  }

  _unregisterNode(node: AudioNode): void {
    const existing = this.nodes.get(node._native);
    if (existing === node) this.nodes.delete(node._native);
  }

  /** The node the engine named, for dispatching an event it reported. */
  _node(id: number): AudioNode | undefined {
    return this.nodes.get(id);
  }

  /** Hands over what the engine has queued: sources that ended, and freed storage to collect. */
  _processEvents(): void {
    hostAudioContextCollect(this._native);
    hostAudioEvents(this._native, (bytes: Uint8Array) => {
      const count = Math.floor(bytes.length / 4);
      for (let i = 0; i + 1 < count; i += 2) {
        const offset = i * 4;
        const node = (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) | 0;
        const kind = (bytes[offset + 4] | (bytes[offset + 5] << 8) | (bytes[offset + 6] << 16) | (bytes[offset + 7] << 24)) | 0;
        const target = this.nodes.get(node);
        if (target !== undefined && kind === 1) target._ended();
      }
    });
  }

  createGain(): GainNode {
    return new GainNode(this);
  }

  createOscillator(): OscillatorNode {
    return new OscillatorNode(this);
  }

  createBufferSource(): AudioBufferSourceNode {
    return new AudioBufferSourceNode(this);
  }

  /** Routes a media element's sound into this context's graph, instead of its own output. */
  createMediaElementSource(element: HTMLMediaElement): MediaElementAudioSourceNode {
    if (!(element instanceof HTMLMediaElement)) {
      throw new TypeError("createMediaElementSource needs a media element");
    }
    if (element instanceof HTMLVideoElement) {
      throw new Error("NotSupportedError: a video's sound plays through its player and can't be routed into a context yet");
    }
    if (element._mediaSource !== null) {
      throw new Error("InvalidStateError: a MediaElementAudioSourceNode already exists for this element");
    }
    return new MediaElementAudioSourceNode(this, element);
  }

  createBiquadFilter(): BiquadFilterNode {
    return new BiquadFilterNode(this);
  }

  createStereoPanner(): StereoPannerNode {
    return new StereoPannerNode(this);
  }

  createAnalyser(): AnalyserNode {
    return new AnalyserNode(this);
  }

  createPanner(): PannerNode {
    return new PannerNode(this);
  }

  createDelay(maxDelayTime: number = 1): DelayNode {
    return new DelayNode(this, { maxDelayTime });
  }

  createDynamicsCompressor(): DynamicsCompressorNode {
    return new DynamicsCompressorNode(this);
  }

  createConvolver(): ConvolverNode {
    return new ConvolverNode(this);
  }

  createConstantSource(): ConstantSourceNode {
    return new ConstantSourceNode(this);
  }

  createBuffer(numberOfChannels: number, length: number, sampleRate: number): AudioBuffer {
    return new AudioBuffer({ numberOfChannels, length, sampleRate });
  }

  /**
   * Decodes a whole file into an AudioBuffer. The engine's decoders run synchronously, and the
   * promise settles in a microtask, as a browser's asynchronous decode does.
   */
  async decodeAudioData(audioData: ArrayBuffer, successCallback?: (buffer: AudioBuffer) => void,
    errorCallback?: (error: Error) => void): Promise<AudioBuffer> {
    try {
      const bytes = new Uint8Array(audioData);
      const id = hostAudioDecode(this._native, bytes);
      if (id < 0) throw new Error("EncodingError: the audio data could not be decoded");
      const buffer = AudioBuffer._fromNative(this, id);
      if (buffer.length === 0 || hostAudioBufferChannels(this._native, id) === 0 ||
          hostAudioBufferFrames(this._native, id) === 0 || !(hostAudioBufferRate(this._native, id) > 0)) {
        throw new Error("EncodingError: the audio data decoded to nothing");
      }
      if (successCallback !== undefined) successCallback(buffer);
      return buffer;
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      if (errorCallback !== undefined) errorCallback(failure);
      throw failure;
    }
  }

  /** Stops polling a finished context's events; its engine stays until the process ends, because
   *  an analyser and a finished buffer can still be read from it. */
  protected retire(): void {
    removeContext(this);
    this.setState("closed");
  }

  /** Frees the context and its engine. A closed context's nodes can't be used again. */
  protected shutdown(): void {
    removeContext(this);
    hostAudioContextClose(this._native);
    this.setState("closed");
  }
}

/** The real-time context. It starts running, so an app that never asks is still heard. */
export class AudioContext extends BaseAudioContext {
  constructor(options: AudioContextOptions = {}) {
    if (options.latencyHint !== undefined && typeof options.latencyHint === "number" && !(options.latencyHint >= 0)) {
      throw new TypeError("latencyHint must not be negative");
    }
    super(false, options.sampleRate !== undefined ? options.sampleRate : 0);
    hostAudioContextResume(this._native);
    this.setState("running");
  }

  /** The render quantum's worth of latency, in seconds, plus the device's own buffering. */
  get baseLatency(): number {
    return 128 / this.sampleRate;
  }

  get outputLatency(): number {
    return 0;
  }

  resume(): Promise<void> {
    if (this.state === "closed") return Promise.reject(new Error("InvalidStateError: the context is closed"));
    hostAudioContextResume(this._native);
    this.setState("running");
    return Promise.resolve();
  }

  suspend(): Promise<void> {
    if (this.state === "closed") return Promise.reject(new Error("InvalidStateError: the context is closed"));
    hostAudioContextSuspend(this._native);
    this.setState("suspended");
    return Promise.resolve();
  }

  close(): Promise<void> {
    if (this.state === "closed") return Promise.reject(new Error("InvalidStateError: the context is closed"));
    this.shutdown();
    return Promise.resolve();
  }
}

export class OfflineAudioContext extends BaseAudioContext {
  readonly length: number;
  readonly numberOfChannels: number;
  private rendering: boolean = false;

  constructor(numberOfChannels: number, length: number, sampleRate: number);
  constructor(options: OfflineAudioContextOptions);
  constructor(optionsOrChannels: OfflineAudioContextOptions | number, length?: number, sampleRate?: number) {
    const settings: OfflineAudioContextOptions = typeof optionsOrChannels === "number"
      ? { numberOfChannels: optionsOrChannels, length: length === undefined ? 0 : length, sampleRate: sampleRate === undefined ? 0 : sampleRate }
      : optionsOrChannels;
    const channels = settings.numberOfChannels === undefined ? 1 : settings.numberOfChannels;
    if (channels < 1 || channels > 2) {
      throw new Error(`NotSupportedError: an OfflineAudioContext renders 1 or 2 channels here, not ${channels}`);
    }
    if (!(settings.length > 0)) throw new Error("NotSupportedError: length must be positive");
    super(true, settings.sampleRate);
    this.numberOfChannels = channels;
    this.length = Math.floor(settings.length);
  }

  /** Renders the whole graph and answers the page's buffer. It runs once per context. */
  startRendering(): Promise<AudioBuffer> {
    if (this.rendering) return Promise.reject(new Error("InvalidStateError: rendering has already started"));
    if (this.state === "closed") return Promise.reject(new Error("InvalidStateError: the context is closed"));
    this.rendering = true;
    this.setState("running");
    const buffer = new AudioBuffer({
      numberOfChannels: this.numberOfChannels,
      length: this.length,
      sampleRate: this.sampleRate,
    });
    const left = buffer.getChannelData(0);
    const right = this.numberOfChannels > 1 ? buffer.getChannelData(1) : null;
    const mono = this.numberOfChannels === 1;
    let offset = 0;
    while (offset < this.length) {
      const count = Math.min(4096, this.length - offset);
      hostAudioOfflineRender(this._native, count, (bytes: Uint8Array) => {
        const samples = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
        for (let i = 0; i < count; i++) {
          const l = samples[i * 2];
          const r = samples[i * 2 + 1];
          left[offset + i] = mono ? 0.5 * (l + r) : l;
          if (right !== null) right[offset + i] = r;
        }
      });
      offset += count;
      this._processEvents();
    }
    this.offlineTime = this.length / this.sampleRate;
    this.retire();
    this.dispatchEvent(new Event("complete"));
    return Promise.resolve(buffer);
  }
}
