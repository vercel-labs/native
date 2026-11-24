// AudioListener: where the page's ear is. Its position, forward and up vectors are AudioParams on
// the destination node's unused parameter slots, so the panner reads them at each render quantum
// and automation on them works like any other parameter.

import type { BaseAudioContext } from "./context.ts";
import { AudioParam } from "./param.ts";

export class AudioListener {
  readonly positionX: AudioParam;
  readonly positionY: AudioParam;
  readonly positionZ: AudioParam;
  readonly forwardX: AudioParam;
  readonly forwardY: AudioParam;
  readonly forwardZ: AudioParam;
  readonly upX: AudioParam;
  readonly upY: AudioParam;
  readonly upZ: AudioParam;

  constructor(context: BaseAudioContext) {
    // Destination node 0 holds the listener in parameter slots 0 through 8.
    this.positionX = new AudioParam(context, 0, 0, 0);
    this.positionY = new AudioParam(context, 0, 1, 0);
    this.positionZ = new AudioParam(context, 0, 2, 0);
    this.forwardX = new AudioParam(context, 0, 3, 0);
    this.forwardY = new AudioParam(context, 0, 4, 0);
    this.forwardZ = new AudioParam(context, 0, 5, -1);
    this.upX = new AudioParam(context, 0, 6, 0);
    this.upY = new AudioParam(context, 0, 7, 1);
    this.upZ = new AudioParam(context, 0, 8, 0);
  }

  setPosition(x: number, y: number, z: number): void {
    this.positionX.value = x;
    this.positionY.value = y;
    this.positionZ.value = z;
  }

  setOrientation(x: number, y: number, z: number, xUp: number, yUp: number, zUp: number): void {
    this.forwardX.value = x;
    this.forwardY.value = y;
    this.forwardZ.value = z;
    this.upX.value = xUp;
    this.upY.value = yUp;
    this.upZ.value = zUp;
  }
}
