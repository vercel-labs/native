// The processing nodes: gain, biquad, stereo pan, analyser, panner, delay and compressor. The
// samples run in the engine; the analyser hands its input back as time-domain data for the
// JavaScript side of the FFT.

import type { BaseAudioContext } from "./context.ts";
import type { AudioBuffer } from "./buffer.ts";
import { AudioNode, TYPE_ANALYSER, TYPE_BIQUAD, TYPE_COMPRESSOR, TYPE_CONVOLVER, TYPE_DELAY, TYPE_GAIN, TYPE_PANNER, TYPE_STEREO_PANNER, applyNodeOptions, type AudioNodeOptions } from "./node.ts";
import { AudioParam } from "./param.ts";
import { hostAudioAnalyserData, hostAudioBiquadType, hostAudioCompressorReduction, hostAudioConvolverBuffer, hostAudioPannerConfig } from "../host.ts";

export interface GainOptions extends AudioNodeOptions {
  gain?: number;
}

export class GainNode extends AudioNode {
  readonly gain: AudioParam;

  constructor(context: BaseAudioContext, options?: GainOptions) {
    super(context, TYPE_GAIN, 1);
    this.gain = new AudioParam(context, this._native, 0, 1);
    if (options !== undefined) {
      if (options.gain !== undefined) this.gain.value = options.gain;
      applyNodeOptions(this, options);
    }
  }
}

export type BiquadFilterType =
  "lowpass" | "highpass" | "bandpass" | "lowshelf" | "highshelf" | "peaking" | "notch" | "allpass";

const BIQUAD_TYPES: string[] = ["lowpass", "highpass", "bandpass", "lowshelf", "highshelf", "peaking", "notch", "allpass"];

export interface BiquadFilterOptions extends AudioNodeOptions {
  type?: BiquadFilterType;
  Q?: number;
  detune?: number;
  frequency?: number;
  gain?: number;
}

export class BiquadFilterNode extends AudioNode {
  readonly frequency: AudioParam;
  readonly detune: AudioParam;
  readonly Q: AudioParam;
  readonly gain: AudioParam;
  private filterType: BiquadFilterType = "lowpass";

  constructor(context: BaseAudioContext, options?: BiquadFilterOptions) {
    super(context, TYPE_BIQUAD, 1);
    this.frequency = new AudioParam(context, this._native, 0, 350);
    this.detune = new AudioParam(context, this._native, 1, 0);
    this.Q = new AudioParam(context, this._native, 2, 1);
    this.gain = new AudioParam(context, this._native, 3, 0);
    if (options !== undefined) {
      if (options.Q !== undefined) this.Q.value = options.Q;
      if (options.detune !== undefined) this.detune.value = options.detune;
      if (options.frequency !== undefined) this.frequency.value = options.frequency;
      if (options.gain !== undefined) this.gain.value = options.gain;
      if (options.type !== undefined) this.type = options.type;
      applyNodeOptions(this, options);
    }
  }

  get type(): BiquadFilterType {
    return this.filterType;
  }

  set type(type: BiquadFilterType) {
    const index = BIQUAD_TYPES.indexOf(type);
    if (index < 0) throw new TypeError(`type: ${String(type)} is not a biquad filter type`);
    this.filterType = type;
    hostAudioBiquadType(this.context._native, this._native, index);
  }

  /**
   * The response the filter would give a list of frequencies, from the same coefficients the
   * engine computes for the settings the parameters hold now.
   */
  getFrequencyResponse(frequencyHz: Float32Array, magResponse: Float32Array, phaseResponse: Float32Array): void {
    if (frequencyHz.length !== magResponse.length || frequencyHz.length !== phaseResponse.length) {
      throw new Error("InvalidAccessError: the three arrays must have the same length");
    }
    const rate = this.context.sampleRate;
    const f0 = this.frequency.value * Math.pow(2, this.detune.value / 1200);
    const q = this.Q.value <= 0 ? 0.0001 : this.Q.value;
    const db = this.gain.value;
    const w0 = 2 * Math.PI * Math.min(f0, rate / 2) / rate;
    const cw = Math.cos(w0), sw = Math.sin(w0);
    const alpha = sw / (2 * q);
    const A = Math.pow(10, db / 40);
    let b0 = 0, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (this.filterType) {
      case "highpass":
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
      case "bandpass":
        b0 = alpha; b1 = 0; b2 = -alpha;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
      case "lowshelf":
        b0 = A * ((A + 1) - (A - 1) * cw + 2 * Math.sqrt(A) * alpha);
        b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        b2 = A * ((A + 1) - (A - 1) * cw - 2 * Math.sqrt(A) * alpha);
        a0 = (A + 1) + (A - 1) * cw + 2 * Math.sqrt(A) * alpha;
        a1 = -2 * ((A - 1) + (A + 1) * cw);
        a2 = (A + 1) + (A - 1) * cw - 2 * Math.sqrt(A) * alpha;
        break;
      case "highshelf":
        b0 = A * ((A + 1) + (A - 1) * cw + 2 * Math.sqrt(A) * alpha);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 = A * ((A + 1) + (A - 1) * cw - 2 * Math.sqrt(A) * alpha);
        a0 = (A + 1) - (A - 1) * cw + 2 * Math.sqrt(A) * alpha;
        a1 = 2 * ((A - 1) - (A + 1) * cw);
        a2 = (A + 1) - (A - 1) * cw - 2 * Math.sqrt(A) * alpha;
        break;
      case "peaking":
        b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
        a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
        break;
      case "notch":
        b0 = 1; b1 = -2 * cw; b2 = 1;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
      case "allpass":
        b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
      default:
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    }
    for (let i = 0; i < frequencyHz.length; i++) {
      const w = 2 * Math.PI * frequencyHz[i] / rate;
      const cos1 = Math.cos(w), sin1 = -Math.sin(w);
      const cos2 = Math.cos(2 * w), sin2 = -Math.sin(2 * w);
      const nr = b0 + b1 * cos1 + b2 * cos2;
      const ni = b1 * sin1 + b2 * sin2;
      const dr = a0 + a1 * cos1 + a2 * cos2;
      const di = a1 * sin1 + a2 * sin2;
      const den = dr * dr + di * di;
      const hr = (nr * dr + ni * di) / den;
      const hi = (ni * dr - nr * di) / den;
      magResponse[i] = Math.sqrt(hr * hr + hi * hi);
      phaseResponse[i] = Math.atan2(hi, hr);
    }
  }
}

export interface StereoPannerOptions extends AudioNodeOptions {
  pan?: number;
}

export class StereoPannerNode extends AudioNode {
  readonly pan: AudioParam;

  constructor(context: BaseAudioContext, options?: StereoPannerOptions) {
    super(context, TYPE_STEREO_PANNER, 1);
    this.pan = new AudioParam(context, this._native, 0, 0);
    if (options !== undefined) {
      if (options.pan !== undefined) this.pan.value = options.pan;
      applyNodeOptions(this, options);
    }
  }
}

export interface AnalyserOptions extends AudioNodeOptions {
  fftSize?: number;
  maxDecibels?: number;
  minDecibels?: number;
  smoothingTimeConstant?: number;
}

/** A power-of-two FFT of `size`, in place on real and imaginary parts. */
function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      const tr = re[i]; re[i] = re[j]; re[j] = tr;
      const ti = im[i]; im[i] = im[j]; im[j] = ti;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const angle = -2 * Math.PI / len;
    const wr = Math.cos(angle), wi = Math.sin(angle);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const next = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = next;
      }
    }
  }
}

export class AnalyserNode extends AudioNode {
  private size: number = 2048;
  private smoothing: number = 0.8;
  private minimum: number = -100;
  private maximum: number = -30;
  private previous: Float32Array | null = null;

  constructor(context: BaseAudioContext, options?: AnalyserOptions) {
    super(context, TYPE_ANALYSER, 1);
    if (options !== undefined) {
      if (options.fftSize !== undefined) this.fftSize = options.fftSize;
      if (options.maxDecibels !== undefined) this.maxDecibels = options.maxDecibels;
      if (options.minDecibels !== undefined) this.minDecibels = options.minDecibels;
      if (options.smoothingTimeConstant !== undefined) this.smoothingTimeConstant = options.smoothingTimeConstant;
      applyNodeOptions(this, options);
    }
  }

  get fftSize(): number {
    return this.size;
  }

  set fftSize(size: number) {
    if (size < 32 || size > 32768 || (size & (size - 1)) !== 0) {
      throw new Error("IndexSizeError: fftSize must be a power of two from 32 to 32768");
    }
    this.size = size;
    this.previous = null;
  }

  get frequencyBinCount(): number {
    return this.size / 2;
  }

  get minDecibels(): number {
    return this.minimum;
  }

  set minDecibels(value: number) {
    if (!(value < this.maximum)) throw new Error("IndexSizeError: minDecibels must be below maxDecibels");
    this.minimum = value;
  }

  get maxDecibels(): number {
    return this.maximum;
  }

  set maxDecibels(value: number) {
    if (!(value > this.minimum)) throw new Error("IndexSizeError: maxDecibels must be above minDecibels");
    this.maximum = value;
  }

  get smoothingTimeConstant(): number {
    return this.smoothing;
  }

  set smoothingTimeConstant(value: number) {
    if (!(value >= 0 && value <= 1)) throw new Error("IndexSizeError: smoothingTimeConstant must be from 0 to 1");
    this.smoothing = value;
  }

  private timeData(): Float32Array {
    const data = new Float32Array(this.size);
    hostAudioAnalyserData(this.context._native, this._native, this.size, (bytes: Uint8Array) => {
      const floats = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
      const count = Math.min(floats.length, data.length);
      for (let i = 0; i < count; i++) data[i] = floats[i];
    });
    return data;
  }

  getFloatTimeDomainData(array: Float32Array): void {
    const data = this.timeData();
    const count = Math.min(array.length, data.length);
    for (let i = 0; i < count; i++) array[i] = data[i];
  }

  getByteTimeDomainData(array: Uint8Array): void {
    const data = this.timeData();
    const count = Math.min(array.length, data.length);
    for (let i = 0; i < count; i++) {
      const v = Math.floor(128 * (data[i] + 1));
      array[i] = v < 0 ? 0 : v > 255 ? 255 : v;
    }
  }

  private magnitudes(): Float32Array {
    const time = this.timeData();
    const n = this.size;
    const re = new Float64Array(n);
    const im = new Float64Array(n);
    // The Blackman window the specification applies before the transform.
    for (let i = 0; i < n; i++) {
      const w = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / n) + 0.08 * Math.cos(4 * Math.PI * i / n);
      re[i] = time[i] * w;
    }
    fft(re, im);
    const bins = n / 2;
    const mag = new Float32Array(bins);
    const previous = this.previous;
    for (let k = 0; k < bins; k++) {
      // A full-scale sine reads 0 dBFS: the transform's magnitude times two, over the window's
      // coherent gain.
      const raw = 2 * Math.sqrt(re[k] * re[k] + im[k] * im[k]) / (n * 0.42);
      const smoothed = previous === null ? raw : this.smoothing * previous[k] + (1 - this.smoothing) * raw;
      mag[k] = smoothed;
    }
    this.previous = mag;
    return mag;
  }

  getFloatFrequencyData(array: Float32Array): void {
    const mag = this.magnitudes();
    const count = Math.min(array.length, mag.length);
    for (let i = 0; i < count; i++) array[i] = 20 * Math.log10(Math.max(mag[i], 1e-12));
  }

  getByteFrequencyData(array: Uint8Array): void {
    const mag = this.magnitudes();
    const count = Math.min(array.length, mag.length);
    const range = this.maximum - this.minimum;
    for (let i = 0; i < count; i++) {
      const db = 20 * Math.log10(Math.max(mag[i], 1e-12));
      const value = Math.floor(255 * (db - this.minimum) / range);
      array[i] = value < 0 ? 0 : value > 255 ? 255 : value;
    }
  }
}


export type PanningModelType = "equalpower" | "HRTF";
export type DistanceModelType = "linear" | "inverse" | "exponential";

export interface PannerOptions extends AudioNodeOptions {
  panningModel?: PanningModelType;
  distanceModel?: DistanceModelType;
  positionX?: number;
  positionY?: number;
  positionZ?: number;
  orientationX?: number;
  orientationY?: number;
  orientationZ?: number;
  refDistance?: number;
  maxDistance?: number;
  rolloffFactor?: number;
  coneInnerAngle?: number;
  coneOuterAngle?: number;
  coneOuterGain?: number;
}

/**
 * A source with a place in space. The listener's position and orientation are on the context's
 * AudioListener, and the panner mixes its mono input to the two output channels from the angle
 * and distance between them. HRTF asks for the same equal-power mix: there is no head model here.
 */
export class PannerNode extends AudioNode {
  readonly positionX: AudioParam;
  readonly positionY: AudioParam;
  readonly positionZ: AudioParam;
  readonly orientationX: AudioParam;
  readonly orientationY: AudioParam;
  readonly orientationZ: AudioParam;
  private model: PanningModelType = "equalpower";
  private distance: DistanceModelType = "inverse";
  private ref = 1;
  private max = 10000;
  private rolloff = 1;
  private inner = 360;
  private outer = 360;
  private outerGain = 0;

  constructor(context: BaseAudioContext, options?: PannerOptions) {
    super(context, TYPE_PANNER, 1);
    this.positionX = new AudioParam(context, this._native, 0, 0);
    this.positionY = new AudioParam(context, this._native, 1, 0);
    this.positionZ = new AudioParam(context, this._native, 2, 0);
    this.orientationX = new AudioParam(context, this._native, 3, 1);
    this.orientationY = new AudioParam(context, this._native, 4, 0);
    this.orientationZ = new AudioParam(context, this._native, 5, 0);
    if (options !== undefined) {
      if (options.panningModel !== undefined) this.panningModel = options.panningModel;
      if (options.distanceModel !== undefined) this.distanceModel = options.distanceModel;
      if (options.positionX !== undefined) this.positionX.value = options.positionX;
      if (options.positionY !== undefined) this.positionY.value = options.positionY;
      if (options.positionZ !== undefined) this.positionZ.value = options.positionZ;
      if (options.orientationX !== undefined) this.orientationX.value = options.orientationX;
      if (options.orientationY !== undefined) this.orientationY.value = options.orientationY;
      if (options.orientationZ !== undefined) this.orientationZ.value = options.orientationZ;
      if (options.refDistance !== undefined) this.refDistance = options.refDistance;
      if (options.maxDistance !== undefined) this.maxDistance = options.maxDistance;
      if (options.rolloffFactor !== undefined) this.rolloffFactor = options.rolloffFactor;
      if (options.coneInnerAngle !== undefined) this.coneInnerAngle = options.coneInnerAngle;
      if (options.coneOuterAngle !== undefined) this.coneOuterAngle = options.coneOuterAngle;
      if (options.coneOuterGain !== undefined) this.coneOuterGain = options.coneOuterGain;
      applyNodeOptions(this, options);
    }
    this.pushConfig();
  }

  get panningModel(): PanningModelType {
    return this.model;
  }

  set panningModel(model: PanningModelType) {
    if (model !== "equalpower" && model !== "HRTF") throw new TypeError(`panningModel: ${String(model)} is not a panning model`);
    this.model = model;
    this.pushConfig();
  }

  get distanceModel(): DistanceModelType {
    return this.distance;
  }

  set distanceModel(model: DistanceModelType) {
    if (model !== "linear" && model !== "inverse" && model !== "exponential") {
      throw new TypeError(`distanceModel: ${String(model)} is not a distance model`);
    }
    this.distance = model;
    this.pushConfig();
  }

  get refDistance(): number {
    return this.ref;
  }

  set refDistance(value: number) {
    if (!(value >= 0)) throw new RangeError("refDistance must not be negative");
    this.ref = value;
    this.pushConfig();
  }

  get maxDistance(): number {
    return this.max;
  }

  set maxDistance(value: number) {
    if (!(value > 0)) throw new RangeError("maxDistance must be positive");
    this.max = value;
    this.pushConfig();
  }

  get rolloffFactor(): number {
    return this.rolloff;
  }

  set rolloffFactor(value: number) {
    if (!(value >= 0)) throw new RangeError("rolloffFactor must not be negative");
    this.rolloff = value;
    this.pushConfig();
  }

  get coneInnerAngle(): number {
    return this.inner;
  }

  set coneInnerAngle(value: number) {
    if (!(value >= 0 && value <= 360)) throw new RangeError("coneInnerAngle must be from 0 to 360");
    this.inner = value;
    this.pushConfig();
  }

  get coneOuterAngle(): number {
    return this.outer;
  }

  set coneOuterAngle(value: number) {
    if (!(value >= 0 && value <= 360)) throw new RangeError("coneOuterAngle must be from 0 to 360");
    this.outer = value;
    this.pushConfig();
  }

  get coneOuterGain(): number {
    return this.outerGain;
  }

  set coneOuterGain(value: number) {
    if (!(value >= 0 && value <= 1)) throw new RangeError("coneOuterGain must be from 0 to 1");
    this.outerGain = value;
    this.pushConfig();
  }

  setPosition(x: number, y: number, z: number): void {
    this.positionX.value = x;
    this.positionY.value = y;
    this.positionZ.value = z;
  }

  setOrientation(x: number, y: number, z: number): void {
    this.orientationX.value = x;
    this.orientationY.value = y;
    this.orientationZ.value = z;
  }

  private pushConfig(): void {
    const distance = this.distance === "linear" ? 0 : this.distance === "exponential" ? 2 : 1;
    hostAudioPannerConfig(this.context._native, this._native, this.model === "HRTF" ? 1 : 0, distance,
      this.ref, this.max, this.rolloff, this.inner, this.outer, this.outerGain);
  }
}

export interface DelayOptions extends AudioNodeOptions {
  delayTime?: number;
  maxDelayTime?: number;
}

/** A delay line whose delayTime is an AudioParam. Longer than a minute is refused: each node's
 *  line is allocated up front, and a minute is already more than a game needs. */
export class DelayNode extends AudioNode {
  readonly delayTime: AudioParam;

  constructor(context: BaseAudioContext, options?: DelayOptions) {
    const maximum = options !== undefined && options.maxDelayTime !== undefined ? options.maxDelayTime : 1;
    if (!(maximum > 0) || maximum > 60) throw new RangeError("maxDelayTime must be above zero and at most 60 seconds");
    super(context, TYPE_DELAY, 1, -1, maximum);
    this.delayTime = new AudioParam(context, this._native, 0, 0);
    if (options !== undefined) {
      if (options.delayTime !== undefined) this.delayTime.value = options.delayTime;
      applyNodeOptions(this, options);
    }
  }
}

export interface DynamicsCompressorOptions extends AudioNodeOptions {
  threshold?: number;
  knee?: number;
  ratio?: number;
  attack?: number;
  release?: number;
}

export class DynamicsCompressorNode extends AudioNode {
  readonly threshold: AudioParam;
  readonly knee: AudioParam;
  readonly ratio: AudioParam;
  readonly attack: AudioParam;
  readonly release: AudioParam;

  constructor(context: BaseAudioContext, options?: DynamicsCompressorOptions) {
    super(context, TYPE_COMPRESSOR, 1);
    this.threshold = new AudioParam(context, this._native, 0, -24);
    this.knee = new AudioParam(context, this._native, 1, 30);
    this.ratio = new AudioParam(context, this._native, 2, 12);
    this.attack = new AudioParam(context, this._native, 3, 0.003);
    this.release = new AudioParam(context, this._native, 4, 0.25);
    if (options !== undefined) {
      if (options.threshold !== undefined) this.threshold.value = options.threshold;
      if (options.knee !== undefined) this.knee.value = options.knee;
      if (options.ratio !== undefined) this.ratio.value = options.ratio;
      if (options.attack !== undefined) this.attack.value = options.attack;
      if (options.release !== undefined) this.release.value = options.release;
      applyNodeOptions(this, options);
    }
  }

  /** The gain reduction the last render quantum applied, in dB (negative while compressing). */
  get reduction(): number {
    return hostAudioCompressorReduction(this.context._native, this._native);
  }
}


export interface ConvolverOptions extends AudioNodeOptions {
  buffer?: AudioBuffer | null;
  disableNormalization?: boolean;
}

/** Reverberation from an impulse response, convolved directly. A long impulse costs its taps per
 *  sample, so this suits the short room responses a game carries rather than minutes of audio. */
export class ConvolverNode extends AudioNode {
  private impulse: AudioBuffer | null = null;
  private normalization = true;

  constructor(context: BaseAudioContext, options?: ConvolverOptions) {
    super(context, TYPE_CONVOLVER, 1);
    if (options !== undefined) {
      if (options.disableNormalization !== undefined) this.normalize = !options.disableNormalization;
      if (options.buffer !== undefined) this.buffer = options.buffer;
      applyNodeOptions(this, options);
    }
  }

  get buffer(): AudioBuffer | null {
    return this.impulse;
  }

  set buffer(buffer: AudioBuffer | null) {
    this.impulse = buffer;
    this.configure();
  }

  get normalize(): boolean {
    return this.normalization;
  }

  set normalize(value: boolean) {
    this.normalization = value === true;
    this.configure();
  }

  private configure(): void {
    const id = this.impulse === null ? 0 : this.impulse._nativeFor(this.context);
    hostAudioConvolverBuffer(this.context._native, this._native, id, this.normalization ? 1 : 0);
  }
}
