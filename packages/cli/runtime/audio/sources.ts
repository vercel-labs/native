// The nodes that make sound: an oscillator, a buffer, a constant. Each fills a source in the
// native graph and reports "ended" once it stops, which is the one event a source node has.

import { Event } from "../dom.ts";
import type { BaseAudioContext } from "./context.ts";
import { AudioBuffer } from "./buffer.ts";
import { AudioNode, TYPE_BUFFER_SOURCE, TYPE_CONSTANT_SOURCE, TYPE_OSCILLATOR, applyNodeOptions, type AudioNodeOptions } from "./node.ts";
import { AudioParam } from "./param.ts";
import { hostAudioOscillatorType, hostAudioSourceBuffer, hostAudioSourceLoop, hostAudioSourceStart, hostAudioSourceStop } from "../host.ts";

export type OscillatorType = "sine" | "square" | "sawtooth" | "triangle";

function finiteTime(value: number, what: string): void {
  if (!isFinite(value)) throw new TypeError(`${what} must be a finite number`);
  if (value < 0) throw new RangeError(`${what} must not be negative`);
}

export class AudioScheduledSourceNode extends AudioNode {
  protected ended = false;
  private endedHandler: ((event: Event) => void) | null = null;

  get onended(): ((event: Event) => void) | null {
    return this.endedHandler;
  }

  set onended(handler: ((event: Event) => void) | null) {
    if (this.endedHandler !== null) this.removeEventListener("ended", this.endedHandler);
    this.endedHandler = handler;
    if (handler !== null) this.addEventListener("ended", handler);
  }

  /** Called from the frame that hears the engine finish or a stop reach the render clock. */
  protected fireEnded(): void {
    if (this.ended) return;
    this.ended = true;
    this.dispatchEvent(new Event("ended"));
    this._release();
  }

  /** The context's event poll, for the engine's report that this source is done. */
  _ended(): void {
    this.fireEnded();
  }
}

export interface AudioBufferSourceOptions {
  buffer?: AudioBuffer | null;
  detune?: number;
  loop?: boolean;
  loopEnd?: number;
  loopStart?: number;
  playbackRate?: number;
  channelCount?: number;
  channelCountMode?: "max" | "clamped-max" | "explicit";
  channelInterpretation?: "speakers" | "discrete";
}

export class AudioBufferSourceNode extends AudioScheduledSourceNode {
  buffer: AudioBuffer | null = null;
  loop: boolean = false;
  loopStart: number = 0;
  loopEnd: number = 0;
  readonly playbackRate: AudioParam;
  readonly detune: AudioParam;
  private started: boolean = false;
  private stopped: boolean = false;

  constructor(context: BaseAudioContext, options?: AudioBufferSourceOptions) {
    super(context, TYPE_BUFFER_SOURCE, 0);
    this.playbackRate = new AudioParam(context, this._native, 0, 1);
    this.detune = new AudioParam(context, this._native, 1, 0);
    if (options !== undefined) {
      if (options.buffer !== undefined) this.buffer = options.buffer;
      if (options.detune !== undefined) this.detune.value = options.detune;
      if (options.loop !== undefined) this.loop = options.loop;
      if (options.loopEnd !== undefined) this.loopEnd = options.loopEnd;
      if (options.loopStart !== undefined) this.loopStart = options.loopStart;
      if (options.playbackRate !== undefined) this.playbackRate.value = options.playbackRate;
      applyNodeOptions(this, options as AudioNodeOptions);
    }
  }

  start(when: number = 0, offset: number = 0, duration?: number): void {
    if (this.started || this.ended) throw new Error("InvalidStateError: start() may only be called once");
    finiteTime(when, "when");
    if (offset < 0 || !isFinite(offset)) throw new RangeError("offset must not be negative");
    if (duration !== undefined && (duration < 0 || !isFinite(duration))) throw new RangeError("duration must not be negative");
    this.started = true;
    const buffer = this.buffer;
    if (buffer !== null) hostAudioSourceBuffer(this.context._native, this._native, buffer._nativeFor(this.context));
    hostAudioSourceLoop(this.context._native, this._native, this.loop ? 1 : 0, this.loopStart, this.loopEnd);
    hostAudioSourceStart(this.context._native, this._native, when, offset, duration === undefined ? 0 : duration, duration === undefined ? 0 : 1);
  }

  stop(when: number = 0): void {
    if (!this.started) throw new Error("InvalidStateError: stop() before start()");
    if (this.stopped || this.ended) return;
    finiteTime(when, "when");
    this.stopped = true;
    hostAudioSourceStop(this.context._native, this._native, when);
  }
}

export interface OscillatorOptions extends AudioNodeOptions {
  type?: OscillatorType;
  frequency?: number;
  detune?: number;
  periodicWave?: unknown;
}

const OSCILLATOR_TYPES: string[] = ["sine", "square", "sawtooth", "triangle"];

export class OscillatorNode extends AudioScheduledSourceNode {
  readonly frequency: AudioParam;
  readonly detune: AudioParam;
  private waveType: OscillatorType = "sine";
  private started: boolean = false;
  private stopped: boolean = false;

  constructor(context: BaseAudioContext, options?: OscillatorOptions) {
    super(context, TYPE_OSCILLATOR, 0);
    this.frequency = new AudioParam(context, this._native, 0, 440);
    this.detune = new AudioParam(context, this._native, 1, 0);
    if (options !== undefined) {
      if (options.frequency !== undefined) this.frequency.value = options.frequency;
      if (options.detune !== undefined) this.detune.value = options.detune;
      if (options.type !== undefined) this.type = options.type;
      applyNodeOptions(this, options);
    }
  }

  get type(): OscillatorType {
    return this.waveType;
  }

  set type(type: OscillatorType) {
    const index = OSCILLATOR_TYPES.indexOf(type);
    if (index < 0) throw new TypeError(`type: ${String(type)} is not an oscillator type`);
    this.waveType = type;
    hostAudioOscillatorType(this.context._native, this._native, index);
  }

  start(when: number = 0): void {
    if (this.started || this.ended) throw new Error("InvalidStateError: start() may only be called once");
    finiteTime(when, "when");
    this.started = true;
    hostAudioSourceStart(this.context._native, this._native, when, 0, 0, 0);
  }

  stop(when: number = 0): void {
    if (!this.started) throw new Error("InvalidStateError: stop() before start()");
    if (this.stopped || this.ended) return;
    finiteTime(when, "when");
    this.stopped = true;
    hostAudioSourceStop(this.context._native, this._native, when);
  }
}

export interface ConstantSourceOptions extends AudioNodeOptions {
  offset?: number;
}

export class ConstantSourceNode extends AudioScheduledSourceNode {
  readonly offset: AudioParam;
  private started: boolean = false;
  private stopped: boolean = false;

  constructor(context: BaseAudioContext, options?: ConstantSourceOptions) {
    super(context, TYPE_CONSTANT_SOURCE, 0);
    this.offset = new AudioParam(context, this._native, 0, 1);
    if (options !== undefined) {
      if (options.offset !== undefined) this.offset.value = options.offset;
      applyNodeOptions(this, options);
    }
  }

  start(when: number = 0): void {
    if (this.started || this.ended) throw new Error("InvalidStateError: start() may only be called once");
    finiteTime(when, "when");
    this.started = true;
    hostAudioSourceStart(this.context._native, this._native, when, 0, 0, 0);
  }

  stop(when: number = 0): void {
    if (!this.started) throw new Error("InvalidStateError: stop() before start()");
    if (this.stopped || this.ended) return;
    finiteTime(when, "when");
    this.stopped = true;
    hostAudioSourceStop(this.context._native, this._native, when);
  }
}
