// The source node a media element plays into an app's own graph. Creating one moves the
// element's sound out of its own output and into the context the node belongs to, at the same
// playhead, so the graph can process it (a gain, a filter, an analyser) before the destination.

import { GainNode } from "./effects.ts";
import type { BaseAudioContext } from "./context.ts";
import { routeMediaElement } from "../dom.ts";
import type { HTMLMediaElement } from "../dom.ts";

export class MediaElementAudioSourceNode extends GainNode {
  readonly mediaElement: HTMLMediaElement;

  constructor(context: BaseAudioContext, element: HTMLMediaElement) {
    super(context);
    this.mediaElement = element;
    routeMediaElement(element, context, this);
  }
}
