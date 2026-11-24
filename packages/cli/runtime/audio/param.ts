// AudioParam: the scheduling side of a parameter, with the values themselves rendered natively.
// A parameter's automation timeline lives in the engine so it can be evaluated sample by sample;
// this class checks the calls and publishes them, and its `value` getter reads what the engine's
// last render quantum left the parameter at.

import type { BaseAudioContext } from "./context.ts";
import { hostAudioParamCancel, hostAudioParamEvent, hostAudioParamSet, hostAudioParamValue } from "../host.ts";

export type AutomationRate = "a-rate" | "k-rate";

// Event kinds, mirrored by EV_* in host/audio.c.
const EV_SET_VALUE = 0;
const EV_LINEAR_RAMP = 1;
const EV_EXP_RAMP = 2;
const EV_SET_TARGET = 3;

function finite(value: number, what: string): void {
  if (!isFinite(value)) throw new TypeError(`${what} must be a finite number`);
}

export class AudioParam {
  readonly defaultValue: number;
  readonly minValue: number = -3.4028234663852886e38;
  readonly maxValue: number = 3.4028234663852886e38;
  automationRate: AutomationRate = "a-rate";
  private readonly context: BaseAudioContext;
  private readonly node: number;
  private readonly index: number;

  constructor(context: BaseAudioContext, node: number, index: number, defaultValue: number) {
    this.context = context;
    this.node = node;
    this.index = index;
    this.defaultValue = defaultValue;
    // The engine's node is made by a command that may still be queued; publish the default now so
    // a `.value` read before the first render quantum already answers what the node will use.
    hostAudioParamSet(context._native, node, index, defaultValue);
  }

  /** The parameter's current value: its intrinsic value, or where its automation is now. */
  get value(): number {
    return hostAudioParamValue(this.context._native, this.node, this.index);
  }

  set value(value: number) {
    finite(value, "value");
    hostAudioParamSet(this.context._native, this.node, this.index, value);
  }

  setValueAtTime(value: number, startTime: number): AudioParam {
    finite(value, "value");
    this.time(startTime, "startTime");
    hostAudioParamEvent(this.context._native, this.node, this.index, EV_SET_VALUE, startTime, value, 0);
    return this;
  }

  linearRampToValueAtTime(value: number, endTime: number): AudioParam {
    finite(value, "value");
    this.time(endTime, "endTime");
    hostAudioParamEvent(this.context._native, this.node, this.index, EV_LINEAR_RAMP, endTime, value, 0);
    return this;
  }

  exponentialRampToValueAtTime(value: number, endTime: number): AudioParam {
    finite(value, "value");
    if (value === 0) throw new RangeError("exponentialRampToValueAtTime: the value must not be zero");
    this.time(endTime, "endTime");
    hostAudioParamEvent(this.context._native, this.node, this.index, EV_EXP_RAMP, endTime, value, 0);
    return this;
  }

  setTargetAtTime(target: number, startTime: number, timeConstant: number): AudioParam {
    finite(target, "target");
    this.time(startTime, "startTime");
    finite(timeConstant, "timeConstant");
    if (timeConstant < 0) throw new RangeError("setTargetAtTime: timeConstant must not be negative");
    hostAudioParamEvent(this.context._native, this.node, this.index, EV_SET_TARGET, startTime, target, timeConstant);
    return this;
  }

  cancelScheduledValues(cancelTime: number): AudioParam {
    this.time(cancelTime, "cancelTime");
    hostAudioParamCancel(this.context._native, this.node, this.index, cancelTime, 0);
    return this;
  }

  cancelAndHoldAtTime(cancelTime: number): AudioParam {
    this.time(cancelTime, "cancelTime");
    hostAudioParamCancel(this.context._native, this.node, this.index, cancelTime, 1);
    return this;
  }

  private time(value: number, what: string): void {
    finite(value, what);
    if (value < 0) throw new RangeError(`${what} must not be negative`);
  }
}
