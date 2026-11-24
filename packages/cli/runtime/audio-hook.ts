// The frame hook Web Audio's ended events ride on. It lives in a module of its own because the
// frame pipeline can't import the audio API, which imports the DOM.

/** Polls the audio engines that have work to report and dispatches their events. */
export let audioFrameHook: () => void = () => {};

export function setAudioFrameHook(fn: () => void): void {
  audioFrameHook = fn;
}
