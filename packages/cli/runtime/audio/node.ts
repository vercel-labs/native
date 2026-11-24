// AudioNode: the handle a script holds for one node in the native graph. Everything the node
// does to samples lives in the engine; this keeps the graph edits, the channel settings and the
// node's place in its context.

import type { BaseAudioContext } from "./context.ts";
import { AudioParam } from "./param.ts";
import { AudioEventTarget } from "./events.ts";
import { hostAudioConnect, hostAudioDisconnect, hostAudioNodeCreate, hostAudioNodeRelease } from "../host.ts";

// Node types, mirrored by NODE_* in host/audio.c.
export const TYPE_DESTINATION = 0;
export const TYPE_GAIN = 1;
export const TYPE_OSCILLATOR = 2;
export const TYPE_BUFFER_SOURCE = 3;
export const TYPE_BIQUAD = 4;
export const TYPE_STEREO_PANNER = 5;
export const TYPE_ANALYSER = 6;
export const TYPE_CONSTANT_SOURCE = 7;
export const TYPE_PANNER = 8;
export const TYPE_DELAY = 9;
export const TYPE_COMPRESSOR = 10;
export const TYPE_CONVOLVER = 11;

export type ChannelCountMode = "max" | "clamped-max" | "explicit";
export type ChannelInterpretation = "speakers" | "discrete";

export interface AudioNodeOptions {
  channelCount?: number;
  channelCountMode?: ChannelCountMode;
  channelInterpretation?: ChannelInterpretation;
}

/** Checks an options bag's channel settings, which several node options extend. */
export function applyNodeOptions(node: AudioNode, options: AudioNodeOptions | undefined): void {
  if (options === undefined) return;
  if (options.channelCount !== undefined) node.channelCount = options.channelCount;
  if (options.channelCountMode !== undefined) node.channelCountMode = options.channelCountMode;
  if (options.channelInterpretation !== undefined) node.channelInterpretation = options.channelInterpretation;
}

export class AudioNode extends AudioEventTarget {
  readonly context: BaseAudioContext;
  readonly numberOfInputs: number;
  readonly numberOfOutputs: number;
  channelCount: number = 2;
  channelCountMode: ChannelCountMode = "max";
  channelInterpretation: ChannelInterpretation = "speakers";
  readonly _native: number;
  protected released: boolean = false;

  protected constructor(context: BaseAudioContext, type: number, inputs: number, existing: number = -1,
    extra: number = 0) {
    super();
    this.context = context;
    this.numberOfInputs = inputs;
    this.numberOfOutputs = 1;
    if (existing >= 0) {
      this._native = existing;
    } else {
      const id = hostAudioNodeCreate(context._native, type, extra);
      if (id < 0) throw new Error("NotSupportedError: the audio engine could not make the node");
      this._native = id;
    }
    context._registerNode(this);
  }

  connect(destination: AudioNode, output?: number, input?: number): AudioNode;
  connect(destination: AudioParam, output?: number): void;
  connect(destination: AudioNode | AudioParam, output: number = 0, input: number = 0): AudioNode | void {
    if (destination instanceof AudioParam) {
      throw new Error("NotSupportedError: connecting to an AudioParam is not supported yet");
    }
    if (!(destination instanceof AudioNode) || destination.context !== this.context) {
      throw new Error("InvalidAccessError: nodes from different contexts can't be connected");
    }
    if (output < 0 || output >= this.numberOfOutputs) throw new Error("IndexSizeError: output is out of range");
    if (input < 0 || input >= destination.numberOfInputs) throw new Error("IndexSizeError: input is out of range");
    hostAudioConnect(this.context._native, this._native, destination._native, output, input);
    return destination;
  }

  disconnect(): void;
  disconnect(output: number): void;
  disconnect(destination: AudioNode): void;
  disconnect(destination: AudioNode, output: number): void;
  disconnect(destination: AudioNode, output: number, input: number): void;
  disconnect(destination?: AudioNode | number, output?: number, input?: number): void {
    if (this.released) return;
    const dst = destination instanceof AudioNode ? destination._native : -1;
    const out = typeof destination === "number" ? destination : output === undefined ? -1 : output;
    const inp = input === undefined ? -1 : input;
    hostAudioDisconnect(this.context._native, this._native, dst, out, inp);
  }

  /** An event the engine reports for this node; only the source nodes have any. */
  _ended(): void {}

  /** Gives the engine node back. Sources do this once they end; a context's close frees the rest. */
  _release(): void {
    if (this.released) return;
    this.released = true;
    hostAudioNodeRelease(this.context._native, this._native);
    this.context._unregisterNode(this);
  }
}

export class AudioDestinationNode extends AudioNode {
  readonly maxChannelCount: number = 2;

  constructor(context: BaseAudioContext) {
    super(context, TYPE_DESTINATION, 1, 0);
  }
}
