// AudioBuffer: sample data a script fills and a source node plays. The arrays live here, where
// getChannelData() hands them out; the engine gets a copy when a source first plays the buffer.

import type { BaseAudioContext } from "./context.ts";
import {
  hostAudioBufferChannels, hostAudioBufferCreate, hostAudioBufferFrames, hostAudioBufferRate,
  hostAudioBufferRead, hostAudioBufferRelease, hostAudioBufferWrite,
} from "../host.ts";

export interface AudioBufferOptions {
  length: number;
  numberOfChannels?: number;
  sampleRate: number;
}

export class AudioBuffer {
  readonly sampleRate: number;
  readonly length: number;
  readonly numberOfChannels: number;
  readonly duration: number;
  private channels: Float32Array[];
  /** The engine's copy, and the context it belongs to; 0 until a source plays the buffer. */
  private nativeId: number = 0;
  private nativeContext: number = 0;

  constructor(options: AudioBufferOptions) {
    const channels = options.numberOfChannels === undefined ? 1 : options.numberOfChannels;
    const length = options.length;
    const rate = options.sampleRate;
    if (channels < 1 || channels > 2) {
      throw new Error(`NotSupportedError: an AudioBuffer has 1 or 2 channels here, not ${channels}`);
    }
    if (length <= 0) throw new Error("NotSupportedError: an AudioBuffer's length must be positive");
    if (!(rate > 0)) throw new Error("NotSupportedError: an AudioBuffer's sampleRate must be positive");
    this.numberOfChannels = channels;
    this.length = length;
    this.sampleRate = rate;
    this.duration = length / rate;
    this.channels = [];
    for (let i = 0; i < channels; i++) this.channels.push(new Float32Array(length));
  }

  getChannelData(channel: number): Float32Array {
    if (channel < 0 || channel >= this.numberOfChannels) {
      throw new Error(`IndexSizeError: channel ${channel} is out of range`);
    }
    return this.channels[channel];
  }

  copyFromChannel(destination: Float32Array, channelNumber: number, bufferOffset: number = 0): void {
    const source = this.getChannelData(channelNumber);
    const start = bufferOffset < 0 ? 0 : bufferOffset;
    const count = Math.min(destination.length, source.length - start);
    for (let i = 0; i < count; i++) destination[i] = source[start + i];
  }

  copyToChannel(source: Float32Array, channelNumber: number, bufferOffset: number = 0): void {
    const destination = this.getChannelData(channelNumber);
    const start = bufferOffset < 0 ? 0 : bufferOffset;
    const count = Math.min(source.length, destination.length - start);
    for (let i = 0; i < count; i++) destination[start + i] = source[i];
  }

  /** The engine-side buffer for `context`, uploaded from these arrays the first time it is asked
   *  for. A decoded buffer already has one. */
  _nativeFor(context: BaseAudioContext): number {
    const id = context._native;
    if (this.nativeId !== 0 && this.nativeContext === id) {
      // Arrays changed after an upload are sent again, so a script that fills a decoded buffer
      // still hears its edit.
      this.upload(id, this.nativeId);
      return this.nativeId;
    }
    if (this.nativeId !== 0 && this.nativeContext !== id) {
      // A buffer is shared with a second context: each context keeps its own engine copy.
      this.nativeId = 0;
    }
    const made = hostAudioBufferCreate(id, this.numberOfChannels, this.length, this.sampleRate);
    if (made < 0) throw new Error("NotSupportedError: the audio engine could not make the buffer");
    this.nativeId = made;
    this.nativeContext = id;
    this.upload(id, made);
    return made;
  }

  private upload(context: number, buffer: number): void {
    for (let ch = 0; ch < this.numberOfChannels; ch++) {
      const data = this.channels[ch];
      const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      hostAudioBufferWrite(context, buffer, ch, bytes);
    }
  }

  /** Adopts a buffer the engine decoded. */
  static _fromNative(context: BaseAudioContext, id: number): AudioBuffer {
    const channels = hostAudioBufferChannels(context._native, id);
    const frames = hostAudioBufferFrames(context._native, id);
    const rate = hostAudioBufferRate(context._native, id);
    const buffer = new AudioBuffer({ length: frames, numberOfChannels: channels, sampleRate: rate });
    for (let ch = 0; ch < channels; ch++) {
      hostAudioBufferRead(context._native, id, ch, (bytes: Uint8Array) => {
        const floats = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
        const data = buffer.channels[ch];
        const count = Math.min(floats.length, data.length);
        for (let i = 0; i < count; i++) data[i] = floats[i];
      });
    }
    buffer.nativeId = id;
    buffer.nativeContext = context._native;
    return buffer;
  }

  /** Gives up the engine's copy, if it made one. */
  _release(): void {
    if (this.nativeId !== 0) {
      hostAudioBufferRelease(this.nativeContext, this.nativeId);
      this.nativeId = 0;
    }
  }
}
